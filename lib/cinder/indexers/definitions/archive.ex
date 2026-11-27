defmodule Cinder.Indexers.Definitions.Archive do
  @moduledoc """
  Reads the Prowlarr/Indexers zip that `codeload.github.com` serves for one commit, in memory,
  and returns the definition files and the `VERSIONS` values it holds (#1666, part of #1610).

  The zip is untrusted input, so this module parses it itself, on the pattern of
  `Cinder.Library.BookArchive.Zip`, whose moduledoc says why OTP's `:zip` cannot bound an
  inflate. `:erl_tar` is no option either: its `:memory` extraction inflates each entry whole and
  passes a `..` path through (#1616). `read/2`:

  1. refuses a commit that is not 40 lowercase hex characters (`:invalid_commit`);
  2. finds the end-of-central-directory record, refuses a ZIP64 entry count, directory size or
     offset (`:archive_corrupt`), then an entry count over 5,000 (`:archive_entry_limit`)
     before it reads the directory;
  3. reads as many central directory headers as the end record counts, and refuses as
     `:archive_corrupt` a ZIP64 entry (a size or offset at the 32-bit sentinel, or a version
     needed of 45 or more) and headers that do not end exactly where the end record's directory
     size says, so no header the count leaves out sits in the directory;
  4. checks each entry, in directory order, kept or skipped: a method other than STORED (0) and
     DEFLATED (8) is `:archive_corrupt`; a name that is empty, absolute or holds a `..`
     component is `:archive_entry_unsafe` (`Cinder.Library.BookArchive.EntryPath.safe_name/1`);
     a name outside the root folder `Indexers-<commit>/` is `:archive_layout`;
  5. keeps only `<root>VERSIONS` and `<root>definitions/v<digits>/<name>.yml`, where `<name>`
     holds no `/`, and skips every other entry without reading its data. A kept name that is
     not UTF-8 is `:archive_entry_unsafe`, and a kept name met twice is `:archive_corrupt`;
  6. reads each kept entry: its local header must name the same file with the same method, and
     its data must lie inside the zip (`:archive_corrupt` otherwise). A DEFLATED entry inflates
     with `:zlib.safeInflate/2`, which returns at most 16,384 bytes a call on OTP 29, and the
     real size is checked after each call: a file over
     `Cinder.Indexers.Definitions.Loader.max_bytes/0` is `:file_too_large`, and kept files over
     64 MiB in all are `:archive_size_limit`. A real size or CRC-32 other than the central
     directory's is `:archive_corrupt`;
  7. reads `VERSIONS` as `KEY=VALUE` lines, each side trimmed, skipping blank lines and lines
     that start with `#`. No `VERSIONS` is `:versions_missing`. Bytes that are not UTF-8, a
     line with no `=` or an empty key, a key met twice, or a `MIN_VERSION` or `MAX_VERSION`
     that is missing or not digits is `:versions_unreadable`.

  The first refusal met is the answer, and every reason is one of this module's atoms, so a
  caller can store and show it. The central directory is the sizing authority: a local header's
  size fields are never read.

  The answer is a `Cinder.Indexers.Definitions.Set`: the commit, the `VERSIONS` values and each
  kept definition file with its folder, name, git blob hash and bytes, in directory order. Which
  folders count is #1667's rule, so every `v<digits>` folder is kept.
  """

  alias Cinder.Indexers.Definitions.{Loader, Set}
  alias Cinder.Indexers.Definitions.Set.{DefinitionFile, Versions}
  alias Cinder.Library.BookArchive.EntryPath

  # 643 entries at Prowlarr/Indexers 56b20b19c18f.
  @max_entries 5_000

  # 3,680,495 kept bytes at Prowlarr/Indexers 56b20b19c18f.
  @max_expanded_bytes 67_108_864

  @eocd_signature 0x06054B50
  @eocd_fixed_size 22
  @max_eocd_scan @eocd_fixed_size + 0xFFFF

  @cd_signature 0x02014B50
  @cd_fixed_size 46

  @local_signature 0x04034B50
  @local_fixed_size 30

  @zip64_sentinel_32 0xFFFFFFFF
  @zip64_sentinel_16 0xFFFF
  @version_needed_zip64 45

  @stored 0
  @deflated 8

  @type reason ::
          :invalid_commit
          | :archive_corrupt
          | :archive_entry_limit
          | :archive_entry_unsafe
          | :archive_layout
          | :archive_size_limit
          | :file_too_large
          | :versions_missing
          | :versions_unreadable

  @reasons [
    :invalid_commit,
    :archive_corrupt,
    :archive_entry_limit,
    :archive_entry_unsafe,
    :archive_layout,
    :archive_size_limit,
    :file_too_large,
    :versions_missing,
    :versions_unreadable
  ]

  @doc "Every refusal `read/2` can answer, as the `reason` type lists them."
  @spec reasons() :: [reason()]
  def reasons, do: @reasons

  @doc "Reads `zip`, the codeload archive of `commit`. See the moduledoc for each refusal."
  @spec read(binary(), String.t()) :: {:ok, Set.t()} | {:error, reason()}
  def read(zip, commit) when is_binary(zip) and is_binary(commit) do
    with :ok <- check_commit(commit),
         {:ok, eocd} <- find_eocd(zip),
         :ok <- refuse_zip64_eocd(eocd),
         :ok <- check_entry_count(eocd.entry_count),
         {:ok, entries} <- central_directory(zip, eocd),
         {:ok, kept} <- classify(entries, "Indexers-" <> commit <> "/"),
         {:ok, files} <- read_kept(zip, kept),
         {:ok, versions} <- versions(files) do
      definitions =
        for {{:definition, folder, name}, bytes} <- files do
          %DefinitionFile{folder: folder, name: name, blob_sha: blob_sha(bytes), bytes: bytes}
        end

      {:ok, %Set{commit: commit, versions: versions, files: definitions}}
    end
  end

  @doc "The git blob hash of `bytes`: SHA-1 of `blob <size>\\0` and the bytes, lowercase hex."
  @spec blob_sha(binary()) :: String.t()
  def blob_sha(bytes) do
    :sha
    |> :crypto.hash(["blob ", Integer.to_string(byte_size(bytes)), 0, bytes])
    |> Base.encode16(case: :lower)
  end

  defp check_commit(commit) do
    if commit =~ ~r/\A[0-9a-f]{40}\z/, do: :ok, else: {:error, :invalid_commit}
  end

  defp check_entry_count(count) when count > @max_entries, do: {:error, :archive_entry_limit}
  defp check_entry_count(_count), do: :ok

  # --- end-of-central-directory record ---

  defp find_eocd(zip) do
    window = min(byte_size(zip), @max_eocd_scan)

    zip
    |> binary_part(byte_size(zip) - window, window)
    |> scan_for_eocd(0, :error)
    |> case do
      {:ok, eocd} -> {:ok, eocd}
      :error -> {:error, :archive_corrupt}
    end
  end

  # The comment can hold bytes that look like the signature, so the record is the last match
  # whose comment length takes exactly the rest of the window, as in `BookArchive.Zip`.
  defp scan_for_eocd(bytes, offset, best) when byte_size(bytes) - offset >= @eocd_fixed_size do
    case bytes do
      <<_::binary-size(^offset), @eocd_signature::little-32, _disk::little-16,
        _cd_start_disk::little-16, entries_this_disk::little-16, entry_count::little-16,
        cd_size::little-32, cd_offset::little-32, comment_len::little-16, rest::binary>>
      when byte_size(rest) == comment_len and entries_this_disk == entry_count ->
        eocd = %{entry_count: entry_count, cd_size: cd_size, cd_offset: cd_offset}
        scan_for_eocd(bytes, offset + 1, {:ok, eocd})

      _no_record_here ->
        scan_for_eocd(bytes, offset + 1, best)
    end
  end

  defp scan_for_eocd(_bytes, _offset, best), do: best

  defp refuse_zip64_eocd(%{entry_count: n, cd_size: s, cd_offset: o})
       when n == @zip64_sentinel_16 or s == @zip64_sentinel_32 or o == @zip64_sentinel_32,
       do: {:error, :archive_corrupt}

  defp refuse_zip64_eocd(_eocd), do: :ok

  # --- central directory ---

  # The records must fill the directory the end record sizes, so a record the count leaves out
  # cannot hide in it.
  defp central_directory(zip, eocd) do
    case read_cd_entries(zip, eocd.cd_offset, eocd.entry_count, []) do
      {:ok, entries, offset} when offset == eocd.cd_offset + eocd.cd_size -> {:ok, entries}
      {:ok, _entries, _offset} -> {:error, :archive_corrupt}
      {:error, _reason} = error -> error
    end
  end

  defp read_cd_entries(_zip, offset, 0, acc), do: {:ok, Enum.reverse(acc), offset}

  defp read_cd_entries(zip, offset, remaining, acc) do
    with {:ok, header} <- slice(zip, offset, @cd_fixed_size),
         {:ok, parsed} <- parse_cd_header(header),
         :ok <- refuse_zip64_entry(parsed),
         {:ok, name} <- slice(zip, offset + @cd_fixed_size, parsed.name_len) do
      next = offset + @cd_fixed_size + parsed.name_len + parsed.extra_len + parsed.comment_len
      read_cd_entries(zip, next, remaining - 1, [Map.put(parsed, :name, name) | acc])
    end
  end

  defp parse_cd_header(<<
         @cd_signature::little-32,
         _version_made_by::little-16,
         version_needed::little-16,
         _gp_flag::little-16,
         method::little-16,
         _mtime::little-16,
         _mdate::little-16,
         crc32::little-32,
         comp_size::little-32,
         uncomp_size::little-32,
         name_len::little-16,
         extra_len::little-16,
         comment_len::little-16,
         _disk_num_start::little-16,
         _internal_attr::little-16,
         _external_attr::little-32,
         local_header_offset::little-32
       >>) do
    {:ok,
     %{
       version_needed: version_needed,
       method: method,
       crc32: crc32,
       comp_size: comp_size,
       uncomp_size: uncomp_size,
       name_len: name_len,
       extra_len: extra_len,
       comment_len: comment_len,
       local_header_offset: local_header_offset
     }}
  end

  defp parse_cd_header(_other), do: {:error, :archive_corrupt}

  defp refuse_zip64_entry(%{version_needed: v}) when v >= @version_needed_zip64,
    do: {:error, :archive_corrupt}

  defp refuse_zip64_entry(%{comp_size: c, uncomp_size: u, local_header_offset: o})
       when c == @zip64_sentinel_32 or u == @zip64_sentinel_32 or o == @zip64_sentinel_32,
       do: {:error, :archive_corrupt}

  defp refuse_zip64_entry(_parsed), do: :ok

  # --- which entries are kept ---

  defp classify(entries, root) do
    entries
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn entry, {:ok, kept, seen} ->
      classify_step(classify_entry(entry, root), entry, kept, seen)
    end)
    |> case do
      {:ok, kept, _seen} -> {:ok, Enum.reverse(kept)}
      {:error, _reason} = error -> error
    end
  end

  defp classify_step(:skip, _entry, kept, seen), do: {:cont, {:ok, kept, seen}}

  defp classify_step({:keep, kind, relative}, entry, kept, seen) do
    if MapSet.member?(seen, relative),
      do: {:halt, {:error, :archive_corrupt}},
      else: {:cont, {:ok, [{kind, entry} | kept], MapSet.put(seen, relative)}}
  end

  defp classify_step({:error, _reason} = error, _entry, _kept, _seen), do: {:halt, error}

  defp classify_entry(%{method: method}, _root) when method not in [@stored, @deflated],
    do: {:error, :archive_corrupt}

  defp classify_entry(entry, root) do
    with {:ok, name} <- EntryPath.safe_name(entry.name),
         {:ok, relative} <- under_root(name, root) do
      keep(relative)
    end
  end

  defp under_root(name, root) do
    if String.starts_with?(name, root),
      do: {:ok, binary_part(name, byte_size(root), byte_size(name) - byte_size(root))},
      else: {:error, :archive_layout}
  end

  defp keep("VERSIONS"), do: keep_utf8(:versions, "VERSIONS")

  defp keep(relative) do
    case Regex.run(~r/\Adefinitions\/(v[0-9]+)\/([^\/]+\.yml)\z/, relative,
           capture: :all_but_first
         ) do
      [folder, name] -> keep_utf8({:definition, folder, name}, relative)
      nil -> :skip
    end
  end

  defp keep_utf8(kind, relative) do
    if String.valid?(relative),
      do: {:keep, kind, relative},
      else: {:error, :archive_entry_unsafe}
  end

  # --- kept entries' data ---

  defp read_kept(zip, kept) do
    kept
    |> Enum.reduce_while({:ok, [], 0}, fn {kind, entry}, {:ok, acc, used} ->
      case read_entry(zip, entry, used) do
        {:ok, bytes} -> {:cont, {:ok, [{kind, bytes} | acc], used + byte_size(bytes)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, files, _used} -> {:ok, Enum.reverse(files)}
      {:error, _reason} = error -> error
    end
  end

  defp read_entry(zip, entry, used) do
    with {:ok, data} <- entry_data(zip, entry),
         {:ok, bytes} <- expand(entry.method, data, used) do
      if byte_size(bytes) == entry.uncomp_size and :erlang.crc32(bytes) == entry.crc32,
        do: {:ok, bytes},
        else: {:error, :archive_corrupt}
    end
  end

  defp entry_data(zip, entry) do
    offset = entry.local_header_offset

    with {:ok, header} <- slice(zip, offset, @local_fixed_size),
         {:ok, local} <- parse_local_header(header),
         {:ok, local_name} <- slice(zip, offset + @local_fixed_size, local.name_len),
         :ok <- cross_check(entry, local, local_name) do
      slice(zip, offset + @local_fixed_size + local.name_len + local.extra_len, entry.comp_size)
    end
  end

  defp parse_local_header(<<
         @local_signature::little-32,
         _version_needed::little-16,
         _gp_flag::little-16,
         method::little-16,
         _mtime::little-16,
         _mdate::little-16,
         _crc32::little-32,
         _comp_size::little-32,
         _uncomp_size::little-32,
         name_len::little-16,
         extra_len::little-16
       >>),
       do: {:ok, %{method: method, name_len: name_len, extra_len: extra_len}}

  defp parse_local_header(_other), do: {:error, :archive_corrupt}

  defp cross_check(entry, local, local_name) do
    if local.method == entry.method and local_name == entry.name,
      do: :ok,
      else: {:error, :archive_corrupt}
  end

  defp expand(@stored, data, used) do
    with :ok <- check_size(byte_size(data), used), do: {:ok, :binary.copy(data)}
  end

  defp expand(@deflated, data, used) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z, -15)

      with {:ok, inflated} <- inflate(z, :zlib.safeInflate(z, data), [], 0, used) do
        # Raises `data_error` when the stream has not ended.
        :ok = :zlib.inflateEnd(z)
        {:ok, IO.iodata_to_binary(inflated)}
      end
    rescue
      ErlangError -> {:error, :archive_corrupt}
    after
      :zlib.close(z)
    end
  end

  defp inflate(z, {state, output}, acc, size, used) when state in [:continue, :finished] do
    size = size + IO.iodata_length(output)

    with :ok <- check_size(size, used) do
      case state do
        :continue -> inflate(z, :zlib.safeInflate(z, []), [acc | output], size, used)
        :finished -> {:ok, [acc | output]}
      end
    end
  end

  defp inflate(_z, _need_dictionary, _acc, _size, _used), do: {:error, :archive_corrupt}

  defp check_size(size, used) do
    cond do
      size > Loader.max_bytes() -> {:error, :file_too_large}
      used + size > @max_expanded_bytes -> {:error, :archive_size_limit}
      true -> :ok
    end
  end

  defp slice(zip, offset, length) when offset + length <= byte_size(zip),
    do: {:ok, binary_part(zip, offset, length)}

  defp slice(_zip, _offset, _length), do: {:error, :archive_corrupt}

  # --- VERSIONS ---

  defp versions(files) do
    case for({:versions, bytes} <- files, do: bytes) do
      [bytes] -> parse_versions(bytes)
      [] -> {:error, :versions_missing}
    end
  end

  defp parse_versions(bytes) do
    with true <- String.valid?(bytes),
         {:ok, values} <- versions_values(String.split(bytes, "\n"), %{}),
         {:ok, min} <- version_number(values, "MIN_VERSION"),
         {:ok, max} <- version_number(values, "MAX_VERSION") do
      {:ok, %Versions{min: min, max: max, values: values}}
    else
      _unreadable -> {:error, :versions_unreadable}
    end
  end

  defp versions_values([], values), do: {:ok, values}

  defp versions_values([line | lines], values) do
    line = String.trim(line)

    if line == "" or String.starts_with?(line, "#"),
      do: versions_values(lines, values),
      else: versions_pair(line, lines, values)
  end

  defp versions_pair(line, lines, values) do
    with [key, value] <- String.split(line, "=", parts: 2),
         key = String.trim(key),
         false <- key == "" or Map.has_key?(values, key) do
      versions_values(lines, Map.put(values, key, String.trim(value)))
    else
      _unreadable -> :error
    end
  end

  defp version_number(values, key) do
    case Map.fetch(values, key) do
      {:ok, value} ->
        if value =~ ~r/\A[0-9]+\z/, do: {:ok, String.to_integer(value)}, else: :error

      :error ->
        :error
    end
  end
end
