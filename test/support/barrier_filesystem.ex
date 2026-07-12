defmodule Cinder.Test.BarrierFilesystem do
  @moduledoc false
  @behaviour Cinder.Library.Filesystem

  alias Cinder.Library.Filesystem.Disk

  @impl true
  defdelegate dir?(path), to: Disk
  @impl true
  defdelegate ls(path), to: Disk

  @impl true
  def find_files(path) do
    result = Disk.find_files(path)
    pause(:find_files, path)
    result
  end

  @impl true
  defdelegate mkdir_p(path), to: Disk
  @impl true
  def ln(source, dest) do
    result = Disk.ln(source, dest)
    pause(:ln, dest)
    result
  end

  @impl true
  defdelegate cp(source, dest), to: Disk
  @impl true
  def lstat(path) do
    result = Disk.lstat(path)
    pause(:lstat, path)
    result
  end

  @impl true
  def rename(source, dest) do
    result = Disk.rename(source, dest)
    pause(:rename, dest)
    result
  end

  @impl true
  def rm(path) do
    result = Disk.rm(path)
    pause(:rm, path)
    result
  end

  @impl true
  defdelegate rmdir(path), to: Disk
  @impl true
  defdelegate read(path), to: Disk

  @impl true
  def write(path, content) do
    result = Disk.write(path, content)
    pause(:write, path)
    result
  end

  @impl true
  defdelegate moviehash_data(path), to: Disk

  defp pause(operation, path) do
    case Application.get_env(:cinder, :filesystem_barrier) do
      %{owner: owner, operation: ^operation, contains: contains} = barrier ->
        maybe_pause(barrier, owner, operation, path, contains)

      %{owner: owner, operations: operations, contains: contains} = barrier ->
        if operation in operations,
          do: maybe_pause(barrier, owner, operation, path, contains)

      _ ->
        :ok
    end
  end

  defp maybe_pause(barrier, owner, operation, path, contains) do
    excluded? = String.contains?(path, Map.get(barrier, :excludes, "\0"))

    if String.contains?(path, contains) and not excluded? do
      if Map.get(barrier, :once, false), do: Application.delete_env(:cinder, :filesystem_barrier)
      ref = make_ref()
      send(owner, {:filesystem_barrier, self(), ref, operation, path})
      receive do: ({^ref, :continue} -> :ok)
    end
  end
end
