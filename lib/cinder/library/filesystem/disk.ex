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

  # The top-level File.ls error propagates as {:error, reason}: an unreadable root
  # (EACCES permission mismatch, an unmounted downloads volume) must read as a transient
  # FS failure — a bounded retry — not as {:ok, []}, which callers classify as a
  # deterministic release defect and answer with a permanent park + blocklist.
  @impl true
  def find_files(dir) do
    case File.ls(dir) do
      {:ok, entries} -> {:ok, Enum.flat_map(entries, &classify(Path.join(dir, &1)))}
      {:error, reason} -> {:error, reason}
    end
  end

  # Recursively collect `{path, size}` for every regular file under `dir`, dotfiles INCLUDED (the
  # import's stale-temp sweep must see its own `.cinder-tmp-*` leftovers). Walks with File.ls rather
  # than Path.wildcard: cinder names libraries `Title (Year) {tmdb-N}`, and `{}` is wildcard
  # brace-expansion — globbing the literal base path would match nothing (`{}`, `[]`, `?`, `*` all).
  # Nested errors stay best-effort (a readable root with one broken subdir still imports the
  # rest) but are logged so a permission-broken video file is diagnosable.
  defp walk(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.flat_map(entries, &classify(Path.join(dir, &1)))

      {:error, reason} ->
        Logger.warning("find_files: cannot list #{dir}: #{inspect(reason)}")
        []
    end
  end

  defp classify(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        walk(path)

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
