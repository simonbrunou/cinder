defmodule Cinder.Library.Filesystem.Disk do
  @moduledoc """
  Real `Cinder.Library.Filesystem` impl over the local filesystem.
  `ln/2` is a hardlink (`File.ln/2`); when the library and downloads live on
  different filesystems the hardlink fails with `:exdev` and `Cinder.Library`
  falls back to `cp/2` (a byte copy) instead.
  """
  @behaviour Cinder.Library.Filesystem

  require Logger

  @impl true
  def dir?(path), do: File.dir?(path)

  # ANY unlistable directory in the tree — the root or a nested one — propagates as
  # {:error, reason}: an EACCES permission mismatch or an unmounted downloads volume must
  # read as a transient FS failure (a bounded retry), not as {:ok, []}, which callers
  # classify as a deterministic release defect and answer with a permanent park + blocklist.
  # (The common torrent layout is a single video-bearing subfolder, so nested failures are
  # the same bug one level down.) Unstat-able individual ENTRIES stay best-effort + logged:
  # one broken sidecar file shouldn't block importing the rest.
  @impl true
  def find_files(dir) do
    {:ok, walk!(dir)}
  catch
    {:find_files_error, reason} -> {:error, reason}
  end

  # Recursively collect `{path, size}` for every regular file under `dir`, dotfiles INCLUDED (the
  # import's stale-temp sweep must see its own `.cinder-tmp-*` leftovers). Walks with File.ls rather
  # than Path.wildcard: cinder names libraries `Title (Year) {tmdb-N}`, and `{}` is wildcard
  # brace-expansion — globbing the literal base path would match nothing (`{}`, `[]`, `?`, `*` all).
  defp walk!(dir) do
    case File.ls(dir) do
      {:ok, entries} -> Enum.flat_map(entries, &classify(Path.join(dir, &1)))
      {:error, reason} -> throw({:find_files_error, reason})
    end
  end

  defp classify(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        walk!(path)

      {:ok, %File.Stat{type: :regular, size: size}} ->
        [{path, size}]

      other ->
        Logger.warning("find_files: cannot stat #{path}: #{inspect(other)}")
        []
    end
  end

  @impl true
  def mkdir_p(dir), do: File.mkdir_p(dir)

  @impl true
  def ln(source, dest), do: File.ln(source, dest)

  @impl true
  def cp(source, dest), do: File.cp(source, dest)

  @impl true
  def write(path, content), do: File.write(path, content)

  @impl true
  def lstat(path), do: File.lstat(path)

  @impl true
  def rename(source, dest), do: File.rename(source, dest)

  @impl true
  def rm(path), do: File.rm(path)

  @impl true
  def rmdir(dir), do: File.rmdir(dir)
end
