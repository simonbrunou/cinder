defmodule Cinder.Library.Filesystem.Disk do
  @moduledoc """
  Real `Cinder.Library.Filesystem` impl over the local filesystem.
  `ln/2` is a hardlink (`File.ln/2`); when the library and downloads live on
  different filesystems the hardlink fails with `:exdev` and `Cinder.Library`
  falls back to `cp/2` (a byte copy) instead.
  """
  @behaviour Cinder.Library.Filesystem

  @impl true
  def dir?(path), do: File.dir?(path)

  @impl true
  def find_files(dir) do
    files =
      dir
      |> Path.join("**/*")
      # match_dot: true so the import's stale-temp sweep can see its own `.cinder-tmp-*` dotfiles
      # (Path.wildcard defaults match_dot: false, which would skip them and make the sweep a no-op).
      |> Path.wildcard(match_dot: true)
      |> Enum.filter(&File.regular?/1)
      |> Enum.flat_map(fn path ->
        case File.stat(path) do
          {:ok, %File.Stat{size: size}} -> [{path, size}]
          {:error, _reason} -> []
        end
      end)

    {:ok, files}
  end

  @impl true
  def mkdir_p(dir), do: File.mkdir_p(dir)

  @impl true
  def ln(source, dest), do: File.ln(source, dest)

  @impl true
  def cp(source, dest), do: File.cp(source, dest)

  @impl true
  def lstat(path), do: File.lstat(path)

  @impl true
  def rename(source, dest), do: File.rename(source, dest)

  @impl true
  def rm(path), do: File.rm(path)

  @impl true
  def rmdir(dir), do: File.rmdir(dir)
end
