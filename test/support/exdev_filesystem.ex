defmodule Cinder.Test.ExdevFilesystem do
  @moduledoc false
  @behaviour Cinder.Library.Filesystem

  alias Cinder.Library.Filesystem.Disk

  @impl true
  defdelegate dir?(path), to: Disk
  @impl true
  defdelegate ls(path), to: Disk
  @impl true
  defdelegate find_files(path), to: Disk
  @impl true
  defdelegate mkdir_p(path), to: Disk
  @impl true
  defdelegate cp(source, dest), to: Disk
  @impl true
  defdelegate cp_exclusive(source, dest, on_create), to: Disk
  @impl true
  defdelegate lstat(path), to: Disk
  @impl true
  defdelegate rename(source, dest), to: Disk
  @impl true
  defdelegate rm(path), to: Disk
  @impl true
  defdelegate rmdir(path), to: Disk
  @impl true
  defdelegate rm_rf(path), to: Disk
  @impl true
  defdelegate read(path), to: Disk
  @impl true
  defdelegate write(path, content), to: Disk
  @impl true
  defdelegate moviehash_data(path), to: Disk

  @impl true
  def ln(_source, _dest), do: {:error, :exdev}
end
