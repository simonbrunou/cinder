defmodule Cinder.Test.DefinitionsZip do
  @moduledoc """
  Builds ZIP archives in memory for the indexer definitions tests, field by field, so a test
  can write the shapes OTP's `:zip` refuses to: a wrong CRC, a method other than 0 and 8, a
  ZIP64 sentinel, a local header that disagrees with the central directory, a size declared
  smaller than the data inflates to, or an end record that claims more entries than it lists.

  `codeload/2` lays the files out as `codeload.github.com` does: one root folder
  `Indexers-<commit>/` with a folder entry for each folder.
  """

  @doc """
  Builds an archive from `entries`, each `{name, data}` or `{name, data, opts}`.

  Entry options: `method` (8, DEFLATED, unless set; 0 is STORED; another value stores the data
  as it is), `compressed` (the data bytes written, in place of the compressed `data`), `crc`,
  `uncomp_size`, `version_needed` (20 unless set), `local_name` and `local_method` (the local
  header's, when they differ from the central directory's), and `cd_comp_size` and
  `cd_offset` (the central directory's compressed size and local header offset, in place of the
  real ones).

  Archive options, each in place of the real value in the end record: `entry_count`,
  `entries_this_disk` (the entry count on this disk, `entry_count` unless set) and `cd_offset`.
  """
  def build(entries, opts \\ []) do
    {locals, headers, offset} =
      Enum.reduce(entries, {[], [], 0}, fn entry, {locals, headers, offset} ->
        {local, header} = entry_records(entry, offset)
        {[local | locals], [header | headers], offset + byte_size(local)}
      end)

    directory = headers |> Enum.reverse() |> IO.iodata_to_binary()
    count = Keyword.get(opts, :entry_count, length(entries))
    on_disk = Keyword.get(opts, :entries_this_disk, count)
    cd_offset = Keyword.get(opts, :cd_offset, offset)

    end_record =
      <<0x06054B50::little-32, 0::little-16, 0::little-16, on_disk::little-16, count::little-16,
        byte_size(directory)::little-32, cd_offset::little-32, 0::little-16>>

    IO.iodata_to_binary([Enum.reverse(locals), directory, end_record])
  end

  @doc """
  Builds an archive shaped like codeload's: every file under `Indexers-<commit>/`, with a
  folder entry for the root and for each folder above a file. `files` holds `{path, data}` or
  `{path, data, opts}`, each path relative to the root.
  """
  def codeload(commit, files) do
    root = "Indexers-" <> commit <> "/"

    folders =
      files
      |> Enum.flat_map(fn file -> parent_folders(elem(file, 0)) end)
      |> Enum.uniq()
      |> Enum.map(fn folder -> {root <> folder, "", method: 0} end)

    build([{root, "", method: 0} | folders] ++ Enum.map(files, &under_root(&1, root)))
  end

  @doc """
  Deflates `data` as a raw DEFLATE stream, the form a ZIP entry holds. `flush` is `:finish`
  unless set; `:sync` writes every byte of `data` but leaves the stream without its last block.
  """
  def deflate(data, flush \\ :finish) do
    z = :zlib.open()
    :ok = :zlib.deflateInit(z, :default, :deflated, -15, 8, :default)
    compressed = IO.iodata_to_binary(:zlib.deflate(z, data, flush))
    :zlib.close(z)
    compressed
  end

  defp under_root({path, data}, root), do: {root <> path, data}
  defp under_root({path, data, opts}, root), do: {root <> path, data, opts}

  defp parent_folders(path) do
    parts = path |> String.split("/") |> Enum.drop(-1)

    for n <- 1..length(parts)//1, do: Enum.join(Enum.take(parts, n), "/") <> "/"
  end

  defp entry_records({name, data}, offset), do: entry_records({name, data, []}, offset)

  defp entry_records({name, data, opts}, offset) do
    method = Keyword.get(opts, :method, 8)
    compressed = Keyword.get_lazy(opts, :compressed, fn -> compress(data, method) end)
    crc = Keyword.get(opts, :crc, :erlang.crc32(data))
    uncomp_size = Keyword.get(opts, :uncomp_size, byte_size(data))
    comp_size = byte_size(compressed)
    cd_comp_size = Keyword.get(opts, :cd_comp_size, comp_size)
    cd_offset = Keyword.get(opts, :cd_offset, offset)
    version = Keyword.get(opts, :version_needed, 20)
    local_name = Keyword.get(opts, :local_name, name)
    local_method = Keyword.get(opts, :local_method, method)

    local =
      <<0x04034B50::little-32, version::little-16, 0::little-16, local_method::little-16,
        0::little-32, crc::little-32, comp_size::little-32, uncomp_size::little-32,
        byte_size(local_name)::little-16, 0::little-16, local_name::binary, compressed::binary>>

    header =
      <<0x02014B50::little-32, 20::little-16, version::little-16, 0::little-16, method::little-16,
        0::little-32, crc::little-32, cd_comp_size::little-32, uncomp_size::little-32,
        byte_size(name)::little-16, 0::little-16, 0::little-16, 0::little-16, 0::little-16,
        0::little-32, cd_offset::little-32, name::binary>>

    {local, header}
  end

  defp compress(data, 8), do: deflate(data)
  defp compress(data, _method), do: data
end
