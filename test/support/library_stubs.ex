defmodule Cinder.LibraryStubs do
  @moduledoc """
  Shared Mox stubs for the library import path (filesystem + media server).

  `stub/3` registers against the calling process, so each consuming test sets
  the Mox mode (private or global) and these stubs follow it.
  """

  import Mox

  alias Cinder.Library.{ImportStage, StagedImport}
  alias Cinder.Repo

  @doc """
  Commits `staged` the way a catalog writer does: one transaction that marks every staged file
  committed, then the staged import's own settle (effects, then the journal commit). `:ok`, or
  the writer's `{:error, reason}`.
  """
  def commit_staged(staged) do
    record_all = fn _record, ids ->
      Repo.transaction(fn -> ImportStage.mark_committed!(ids) end)
    end

    case StagedImport.commit(staged, record_all) do
      {:ok, :ok} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc "The `{episode_id, dest}` pairs a staged TV import records, sorted by episode id."
  def episode_dests(staged) do
    staged
    |> StagedImport.record()
    |> Enum.map(fn {episode_id, dest, _quality, _placed?} -> {episode_id, dest} end)
    |> Enum.sort()
  end

  @doc """
  Stubs a successful single-file import: the source is a file (not a dir), it
  lstats with the given `size`, and the mkdir_p/ln/scan calls all succeed.

  The default `size: 1` matches the movie import tests; the TV poller tests pass
  a realistic per-episode size.
  """
  def stub_import_ok(size \\ 1) do
    stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)

    stub(Cinder.Library.FilesystemMock, :lstat, fn path ->
      import_lstat(path, size)
    end)

    stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    stub(Cinder.Library.FilesystemMock, :chmod, fn _path, _mode -> :ok end)
    stub(Cinder.Library.FilesystemMock, :ln, fn _src, _dest -> :ok end)
    stub(Cinder.Library.FilesystemMock, :rm, fn _path -> :ok end)
    stub(Cinder.Library.FilesystemMock, :rename, fn _src, _dest -> :ok end)
    stub(Cinder.Library.MediaServerMock, :scan, fn _kind -> :ok end)
  end

  @doc """
  Stubs a successful cross-filesystem import: `ln` from the download returns `{:error, :exdev}`, so
  the engine copies the download into its candidate (`cp`) and then hardlinks the candidate into
  place. Mirrors `stub_import_ok/1` for the same happy-path shape.
  """
  def stub_import_exdev(size \\ 1) do
    stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)

    stub(Cinder.Library.FilesystemMock, :lstat, fn path ->
      import_lstat(path, size)
    end)

    stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    stub(Cinder.Library.FilesystemMock, :chmod, fn _path, _mode -> :ok end)

    stub(Cinder.Library.FilesystemMock, :ln, fn source, _dest ->
      if candidate_path?(source), do: :ok, else: {:error, :exdev}
    end)

    stub(Cinder.Library.FilesystemMock, :find_files, fn _ -> {:ok, []} end)
    stub(Cinder.Library.FilesystemMock, :cp, fn _src, _dest -> :ok end)
    stub(Cinder.Library.FilesystemMock, :rename, fn _src, _dest -> :ok end)
    stub(Cinder.Library.FilesystemMock, :rm, fn _path -> :ok end)
    stub(Cinder.Library.MediaServerMock, :scan, fn _kind -> :ok end)
  end

  # The staging engine's scratch-file names. This module is the one place outside the staged-import
  # tests that knows them: mocked-filesystem tests answer `lstat` for a candidate because the engine
  # stats every candidate it builds, and some fail or pause on one to drive a recovery path.

  @doc "The marker in the name of every candidate, for a barrier or failure that matches on it."
  def candidate_marker, do: ".cinder-stage-"

  @doc "Whether `path` is a candidate the staging engine builds next to its destination."
  def candidate_path?(path), do: String.contains?(Path.basename(path), candidate_marker())

  @doc "Whether `path` is the backup a staged replacement moves the original file to."
  def backup_path?(path), do: String.contains?(Path.basename(path), ".cinder-rollback-")

  @doc "Whether `path` is either staging scratch file."
  def staging_path?(path), do: candidate_path?(path) or backup_path?(path)

  defp library_path?(path),
    do:
      String.starts_with?(path, "/tmp/cinder-test-library/") or
        String.starts_with?(path, "/tmp/cinder-test-tv-library/")

  @doc """
  The `lstat` answer `stub_import_ok/1` uses: a candidate or a download exists with `size`, a
  library path does not exist yet.
  """
  def import_lstat(path, size) do
    cond do
      candidate_path?(path) ->
        {:ok, %File.Stat{type: :regular, size: size, inode: 1, major_device: 1}}

      library_path?(path) ->
        {:error, :enoent}

      true ->
        {:ok, %File.Stat{type: :regular, size: size, inode: 1, major_device: 1}}
    end
  end
end
