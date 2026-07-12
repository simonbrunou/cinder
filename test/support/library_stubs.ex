defmodule Cinder.LibraryStubs do
  @moduledoc """
  Shared Mox stubs for the library import path (filesystem + media server).

  `stub/3` registers against the calling process, so each consuming test sets
  the Mox mode (private or global) and these stubs follow it.
  """

  import Mox

  @doc """
  Stubs a successful single-file import: the source is a file (not a dir), it
  lstats with the given `size`, and the mkdir_p/ln/scan calls all succeed.

  The default `size: 1` matches the movie import tests; the TV poller tests pass
  a realistic per-episode size.
  """
  def stub_import_ok(size \\ 1) do
    stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)

    stub(Cinder.Library.FilesystemMock, :lstat, fn path ->
      import_stat(path, size)
    end)

    stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    stub(Cinder.Library.FilesystemMock, :ln, fn _src, _dest -> :ok end)
    stub(Cinder.Library.FilesystemMock, :rename, fn _src, _dest -> :ok end)
    stub(Cinder.Library.MediaServerMock, :scan, fn _kind -> :ok end)
  end

  @doc """
  Stubs a successful cross-filesystem import: `ln` always returns `{:error, :exdev}`, so the import
  falls back to the atomic copy path — `find_files` sweeps no stale temps, `cp` copies into the temp,
  and `rename` moves it onto dest. Mirrors `stub_import_ok/1` for the same happy-path shape.
  """
  def stub_import_exdev(size \\ 1) do
    stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)

    stub(Cinder.Library.FilesystemMock, :lstat, fn path ->
      import_stat(path, size)
    end)

    stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    stub(Cinder.Library.FilesystemMock, :ln, fn _src, _dest -> {:error, :exdev} end)
    stub(Cinder.Library.FilesystemMock, :find_files, fn _ -> {:ok, []} end)
    stub(Cinder.Library.FilesystemMock, :cp, fn _src, _dest -> :ok end)
    stub(Cinder.Library.FilesystemMock, :rename, fn _src, _dest -> :ok end)
    stub(Cinder.Library.MediaServerMock, :scan, fn _kind -> :ok end)
  end

  defp library_path?(path),
    do:
      String.starts_with?(path, "/tmp/cinder-test-library/") or
        String.starts_with?(path, "/tmp/cinder-test-tv-library/")

  defp import_stat(path, size) do
    cond do
      String.contains?(path, ".cinder-stage-") ->
        {:ok, %File.Stat{size: size, inode: 1, major_device: 1}}

      library_path?(path) ->
        {:error, :enoent}

      true ->
        {:ok, %File.Stat{size: size, inode: 1, major_device: 1}}
    end
  end
end
