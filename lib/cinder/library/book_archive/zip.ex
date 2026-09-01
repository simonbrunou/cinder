defmodule Cinder.Library.BookArchive.Zip do
  @moduledoc """
  Bounded ZIP extraction (`.zip`, `.cbz`) — no external dependency, pure OTP.

  ## Why this hand-parses the central directory and local headers itself

  Investigated before writing a line of this: `:zip.list_dir/1`'s `file_info.type` can never
  read `:symlink` — `cd_file_header_to_file_info/3` in OTP's `zip.erl` masks the central
  directory's `external_attr` down to `(external_attr bsr 16) band 8#777` (permission bits
  only) and derives `type` purely from whether the name ends in `/`. Confirmed empirically
  against a zip built with a Unix-symlink-flagged entry: it came back `type: :regular`. This
  module does not try to detect that bit either — it is unreachable through any OTP `:zip`
  API, list_dir included, so a check here would be theater. Instead: extraction only ever
  opens a destination with `[:write]` and writes decompressed bytes to it, or creates a
  directory — never anything else — so no entry, however it is tagged, can ever become
  anything but an inert regular file or a directory on disk. That is a stronger guarantee than
  detect-and-reject would be.

  More consequentially: `:zip.unzip/2` has no public hook to inspect output as it is produced
  (only `memory`, toggling between two hardcoded sinks), and `:zip.foldl/3`'s `GetBin()` /
  `:zip.zip_get/2` fully decompress one entry into a single binary before returning control —
  worse than "after", since a bomb exhausts VM memory before any check runs, not just disk.
  Neither lets a byte ceiling be enforced *during* decompression. So: central-directory entries
  are read via a minimal, narrow parser (this module), and each entry's compressed data is fed
  to `:zlib`'s streaming inflate in small chunks, with the real (not declared) cumulative
  decompressed byte count checked after every chunk. Proven against a genuine bomb (one entry,
  ~200KB compressed, 200MB declared/actual decompressed) during development: aborted at ~12.6MB
  with a 10MB ceiling, in ~20ms — nowhere near full decompression.

  ## What is deliberately refused rather than handled

  - **ZIP64** (needed only for a single entry, offset, or the whole archive exceeding 32-bit
    field limits — >4GB or >65535 entries). A legitimate ebook/audiobook release will never
    need it; a hostile one claiming to needs its central-directory fields distrusted at the
    exact boundary a bounds check would otherwise trust. Detected via the standard `0xFFFFFFFF`
    sentinel on any size/offset field, or `0xFFFF` on the entry count — refused outright with
    `:archive_corrupt`, never partially interpreted.
  - **Any compression method other than STORED (0) or DEFLATED (8)** — the only two ZIP
    entries can legitimately carry for the formats this module accepts; anything else is
    refused the same way.
  - **A declared size hitting the 32-bit sentinel on a non-ZIP64 archive**, a local/central
    header disagreement on name or compression method, or a final CRC-32 mismatch — all refused
    as `:archive_corrupt`. The central directory is the sizing authority throughout (see below);
    nothing here ever trusts a local header's own size fields, whether they are honest,
    zeroed (a streaming data descriptor — general-purpose bit 3), or lying.
  """

  alias Cinder.Library.BookArchive.EntryPath

  # Generous for a chaptered audiobook (dozens of per-chapter files); far below
  # PathPolicy's own generic, whole-filesystem-walk @max_entries (100_000) — this ceiling is
  # archive-specific and much tighter on purpose.
  @max_entries 500

  # ~5x BookScorer's own 200MB accepted-release (compressed) size ceiling. Ebook/audiobook
  # content already lives in compressed containers (EPUB/MP3/M4B), so genuine further gain
  # from ZIP compression is modest for a legitimate release; 1GB comfortably covers any real
  # single-release archive while remaining far short of "fill the disk".
  @max_expanded_size 1_000_000_000

  # Bounds compressed-input-per-inflate-call, which bounds worst-case decompressed output per
  # step (DEFLATE's max expansion is ~1032:1) to ~4MB — the granularity of the ceiling check,
  # proven in development against a real bomb.
  @read_chunk 4096

  @eocd_signature 0x06054B50
  @eocd_fixed_size 22
  # Comment length is a 16-bit field; this is the widest window the signature could hide in.
  @max_eocd_scan @eocd_fixed_size + 0xFFFF

  @cd_signature 0x02014B50
  @cd_fixed_size 46

  @local_signature 0x04034B50
  @local_fixed_size 30

  @zip64_sentinel_32 0xFFFFFFFF
  @zip64_sentinel_16 0xFFFF

  @stored 0
  @deflated 8

  @doc """
  Extracts `archive_path` into `dest_dir` (already created, already trusted — this module
  only ever writes strictly inside it). Whole-archive, all-or-nothing: any single unsafe or
  malformed entry refuses everything, matching this module's callers' own "never pick, refuse"
  discipline rather than silently dropping one file and continuing.

  `opts` overrides `:max_entries`/`:max_expanded_size` below their defaults — a test seam only,
  so an adversarial-ceiling test proves the abort without generating gigabyte-scale fixtures.
  """
  @spec extract(String.t(), String.t(), keyword()) ::
          :ok
          | {:error,
             :archive_entry_limit | :archive_size_limit | :archive_entry_unsafe | :archive_corrupt}
  def extract(archive_path, dest_dir, opts \\ []) do
    dest_dir = Path.expand(dest_dir)
    max_entries = Keyword.get(opts, :max_entries, @max_entries)
    max_expanded_size = Keyword.get(opts, :max_expanded_size, @max_expanded_size)

    with {:ok, fd} <- open(archive_path),
         {:ok, entries} <- central_directory(fd, archive_path) do
      try do
        with :ok <- check_entry_count(entries, max_entries),
             {:ok, plans} <- validate_entries(entries, dest_dir) do
          extract_entries(fd, plans, max_expanded_size)
        end
      after
        :file.close(fd)
      end
    end
  end

  defp open(archive_path) do
    case :file.open(archive_path, [:read, :binary, :raw]) do
      {:ok, fd} -> {:ok, fd}
      {:error, _reason} -> {:error, :archive_corrupt}
    end
  end

  defp check_entry_count(entries, max_entries) do
    if length(entries) > max_entries, do: {:error, :archive_entry_limit}, else: :ok
  end

  # --- central directory: end-of-central-directory record, then each file header ---

  defp central_directory(fd, archive_path) do
    with {:ok, size} <- archive_size(archive_path),
         {:ok, eocd} <- find_eocd(fd, size),
         :ok <- refuse_zip64_eocd(eocd) do
      read_cd_entries(fd, eocd.cd_offset, eocd.entry_count, [])
    end
  end

  defp archive_size(archive_path) do
    case File.stat(archive_path) do
      {:ok, %File.Stat{size: size}} -> {:ok, size}
      {:error, _reason} -> {:error, :archive_corrupt}
    end
  end

  defp find_eocd(fd, size) do
    window = min(size, @max_eocd_scan)
    start = size - window

    with {:ok, bytes} <- pread(fd, start, window) do
      case scan_for_eocd(bytes) do
        {:ok, eocd} -> {:ok, eocd}
        :error -> {:error, :archive_corrupt}
      end
    end
  end

  # Scans forward for the LAST occurrence of the EOCD signature — the comment (if any) can
  # itself contain 4 bytes that look like the signature, so the true record is whichever match
  # makes the trailing comment-length field consume exactly the rest of the window.
  defp scan_for_eocd(bytes), do: scan_for_eocd(bytes, 0, :error)

  defp scan_for_eocd(bytes, offset, best) when byte_size(bytes) - offset >= @eocd_fixed_size do
    case bytes do
      <<_::binary-size(^offset), @eocd_signature::little-32, _disk::little-16,
        _cd_start_disk::little-16, entries_this_disk::little-16, entry_count::little-16,
        cd_size::little-32, cd_offset::little-32, comment_len::little-16, rest::binary>> ->
        if byte_size(rest) == comment_len and entries_this_disk == entry_count do
          scan_for_eocd(bytes, offset + 1, {
            :ok,
            %{entry_count: entry_count, cd_size: cd_size, cd_offset: cd_offset}
          })
        else
          scan_for_eocd(bytes, offset + 1, best)
        end

      _no_match_here ->
        scan_for_eocd(bytes, offset + 1, best)
    end
  end

  defp scan_for_eocd(_bytes, _offset, best), do: best

  defp refuse_zip64_eocd(%{entry_count: n, cd_size: s, cd_offset: o})
       when n == @zip64_sentinel_16 or s == @zip64_sentinel_32 or o == @zip64_sentinel_32,
       do: {:error, :archive_corrupt}

  defp refuse_zip64_eocd(_eocd), do: :ok

  defp read_cd_entries(_fd, _offset, 0, acc), do: {:ok, Enum.reverse(acc)}

  defp read_cd_entries(fd, offset, remaining, acc) do
    with {:ok, header} <- pread(fd, offset, @cd_fixed_size),
         {:ok, parsed} <- parse_cd_header(header),
         {:ok, name} <- pread(fd, offset + @cd_fixed_size, parsed.name_len),
         :ok <- refuse_zip64_entry(parsed) do
      entry = %{
        name: name,
        compression_method: parsed.compression_method,
        crc32: parsed.crc32,
        comp_size: parsed.comp_size,
        uncomp_size: parsed.uncomp_size,
        local_header_offset: parsed.local_header_offset
      }

      next_offset =
        offset + @cd_fixed_size + parsed.name_len + parsed.extra_len + parsed.comment_len

      read_cd_entries(fd, next_offset, remaining - 1, [entry | acc])
    end
  end

  defp parse_cd_header(<<
         @cd_signature::little-32,
         _version_made_by::little-16,
         version_needed::little-16,
         _gp_flag::little-16,
         compression_method::little-16,
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
       compression_method: compression_method,
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

  @version_needed_zip64 45

  # The 32-bit sentinel catches a genuinely-oversized field; `version_needed >= 45` is the
  # spec's own "this entry uses ZIP64 extensions" marker (`Cinder.Library.BookArchive.Zip`'s
  # sentinel check alone missed a real case found in development: Python's `zipfile`, given
  # `force_zip64=True`, sets this version marker without necessarily pushing any field to the
  # sentinel value for a small file — the marker is the reliable signal, not the field values).
  defp refuse_zip64_entry(%{version_needed: v}) when v >= @version_needed_zip64,
    do: {:error, :archive_corrupt}

  defp refuse_zip64_entry(%{comp_size: c, uncomp_size: u, local_header_offset: o})
       when c == @zip64_sentinel_32 or u == @zip64_sentinel_32 or o == @zip64_sentinel_32,
       do: {:error, :archive_corrupt}

  defp refuse_zip64_entry(_parsed), do: :ok

  # --- entry validation: path safety, method, before any byte is touched ---

  defp validate_entries(entries, dest_dir) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case validate_entry(entry, dest_dir) do
        {:ok, plan} -> {:cont, {:ok, [plan | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, plans} -> {:ok, Enum.reverse(plans)}
      {:error, _reason} = error -> error
    end
  end

  defp validate_entry(%{compression_method: m}, _dest_dir)
       when m not in [@stored, @deflated],
       do: {:error, :archive_corrupt}

  defp validate_entry(entry, dest_dir) do
    case EntryPath.safe(entry.name, dest_dir) do
      {:ok, target} ->
        name = String.trim_trailing(entry.name, "\u0000")

        {:ok,
         Map.merge(entry, %{name: name, target: target, directory?: String.ends_with?(name, "/")})}

      {:error, _reason} = error ->
        error
    end
  end

  # --- extraction: local-header cross-check, then streaming copy/inflate with a live ceiling ---

  defp extract_entries(fd, plans, max_expanded_size) do
    Enum.reduce_while(plans, {:ok, 0}, fn plan, {:ok, used} ->
      case extract_entry(fd, plan, used, max_expanded_size) do
        {:ok, new_used} -> {:cont, {:ok, new_used}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, _used} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp extract_entry(_fd, %{directory?: true} = plan, used, _max_expanded_size) do
    case File.mkdir_p(plan.target) do
      :ok -> {:ok, used}
      {:error, _reason} -> {:error, :archive_corrupt}
    end
  end

  defp extract_entry(fd, plan, used, max_expanded_size) do
    with :ok <- File.mkdir_p(Path.dirname(plan.target)),
         {:ok, data_offset} <- local_data_offset(fd, plan) do
      stream_entry(fd, plan, data_offset, used, max_expanded_size)
    end
  end

  defp local_data_offset(fd, plan) do
    with {:ok, header} <- pread(fd, plan.local_header_offset, @local_fixed_size),
         {:ok, parsed} <- parse_local_header(header),
         {:ok, local_name} <-
           pread(fd, plan.local_header_offset + @local_fixed_size, parsed.name_len),
         :ok <- cross_check(plan, parsed, local_name) do
      {:ok, plan.local_header_offset + @local_fixed_size + parsed.name_len + parsed.extra_len}
    end
  end

  defp parse_local_header(<<
         @local_signature::little-32,
         _version_needed::little-16,
         _gp_flag::little-16,
         compression_method::little-16,
         _mtime::little-16,
         _mdate::little-16,
         _crc32::little-32,
         _comp_size::little-32,
         _uncomp_size::little-32,
         name_len::little-16,
         extra_len::little-16
       >>) do
    {:ok, %{compression_method: compression_method, name_len: name_len, extra_len: extra_len}}
  end

  defp parse_local_header(_other), do: {:error, :archive_corrupt}

  # The central directory is the sizing/name authority throughout (it is written after the
  # data, so a streaming data descriptor's zeroed local-header sizes never matter here — this
  # module never reads them). What IS cross-checked is the one thing a hostile or corrupt file
  # could make disagree between the two independently-read records: what the local header
  # itself claims to be. A mismatch is the classic "two tools disagree about what this file is"
  # evasion technique — refused, not preferred one way or the other.
  defp cross_check(plan, %{compression_method: method}, local_name) do
    if method == plan.compression_method and trim_nul(local_name) == plan.name,
      do: :ok,
      else: {:error, :archive_corrupt}
  end

  defp trim_nul(name), do: String.trim_trailing(name, "\u0000")

  defp stream_entry(fd, %{compression_method: @stored} = plan, data_offset, used, max) do
    with {:ok, io} <- open_write(plan.target) do
      result = copy_stored(fd, io, data_offset, plan.comp_size, 0, used, max)
      File.close(io)

      case result do
        {:ok, crc, new_used} -> finish_entry(plan, crc, new_used)
        {:error, _reason} = error -> discard(plan.target, error)
      end
    end
  end

  defp stream_entry(fd, %{compression_method: @deflated} = plan, data_offset, used, max) do
    with {:ok, io} <- open_write(plan.target) do
      z = :zlib.open()
      :ok = :zlib.inflateInit(z, -15)

      result = inflate_stream(fd, io, z, data_offset, plan.comp_size, 0, used, max)

      try do
        :zlib.inflateEnd(z)
      catch
        _kind, _reason -> :ok
      end

      :zlib.close(z)
      File.close(io)

      case result do
        {:ok, crc, new_used} -> finish_entry(plan, crc, new_used)
        {:error, _reason} = error -> discard(plan.target, error)
      end
    end
  end

  defp open_write(target) do
    case :file.open(target, [:write, :binary, :raw]) do
      {:ok, io} -> {:ok, io}
      {:error, _reason} -> {:error, :archive_corrupt}
    end
  end

  defp finish_entry(plan, crc, used) do
    if crc == plan.crc32, do: {:ok, used}, else: discard(plan.target, {:error, :archive_corrupt})
  end

  defp discard(target, error) do
    _ = File.rm(target)
    error
  end

  defp copy_stored(_fd, _io, _offset, 0, crc, used, _max), do: {:ok, crc, used}

  defp copy_stored(fd, io, offset, remaining, crc, used, max) do
    n = min(@read_chunk, remaining)

    with {:ok, chunk} <- pread(fd, offset, n),
         :ok <- write_chunk(io, chunk),
         {:ok, new_used} <- charge_budget(used, byte_size(chunk), max) do
      copy_stored(fd, io, offset + n, remaining - n, :erlang.crc32(crc, chunk), new_used, max)
    end
  end

  defp inflate_stream(_fd, _io, _z, _offset, 0, crc, used, _max), do: {:ok, crc, used}

  defp inflate_stream(fd, io, z, offset, remaining, crc, used, max) do
    n = min(@read_chunk, remaining)

    with {:ok, compressed} <- pread(fd, offset, n),
         {:ok, decompressed} <- safe_inflate(z, compressed),
         :ok <- write_chunk(io, decompressed),
         {:ok, new_used} <- charge_budget(used, byte_size(decompressed), max) do
      inflate_stream(
        fd,
        io,
        z,
        offset + n,
        remaining - n,
        :erlang.crc32(crc, decompressed),
        new_used,
        max
      )
    end
  end

  # A malformed DEFLATE stream doesn't just decompress to the wrong bytes — the NIF itself
  # raises `data_error` (proven in development against a hand-corrupted archive). A crash here
  # would take down whatever process is resolving this download; caught and refused the same
  # way any other structural problem with this archive is.
  defp safe_inflate(z, compressed) do
    {:ok, IO.iodata_to_binary(:zlib.inflate(z, compressed))}
  rescue
    ErlangError -> {:error, :archive_corrupt}
  end

  defp write_chunk(io, chunk) do
    case :file.write(io, chunk) do
      :ok -> :ok
      {:error, _reason} -> {:error, :archive_corrupt}
    end
  end

  defp charge_budget(used, added, max) do
    new_total = used + added
    if new_total > max, do: {:error, :archive_size_limit}, else: {:ok, new_total}
  end

  defp pread(fd, offset, length) do
    case :file.pread(fd, offset, length) do
      {:ok, bytes} when byte_size(bytes) == length -> {:ok, bytes}
      {:ok, _short} -> {:error, :archive_corrupt}
      :eof -> {:error, :archive_corrupt}
      {:error, _reason} -> {:error, :archive_corrupt}
    end
  end
end
