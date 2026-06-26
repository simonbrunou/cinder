defmodule Cinder.Library.Filesystem.Disk do
  @moduledoc """
  Real `Cinder.Library.Filesystem` impl over the local filesystem.
  `ln/2` is a hardlink (`File.ln/2`) — the library must be on the same
  filesystem as the downloads (see the Phase-4 spec's Assumptions).
  """
  @behaviour Cinder.Library.Filesystem

  @impl true
  def dir?(path), do: File.dir?(path)

  @impl true
  def find_files(dir) do
    files =
      dir
      |> Path.join("**/*")
      |> Path.wildcard()
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
  def lstat(path), do: File.lstat(path)

  @impl true
  def rename(source, dest), do: File.rename(source, dest)

  @impl true
  def rm(path), do: File.rm(path)

  @impl true
  def rmdir(dir), do: File.rmdir(dir)
end
