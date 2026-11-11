defmodule Cinder.Test.RecordingFilesystem do
  @moduledoc """
  Reads like `Cinder.Library.Filesystem.Disk`, and sends `{:read, path}` to the calling process for
  each path it stats or lists, so a test of `Cinder.Library.PathPolicy.walk/2` that walks in its
  own process can tell which paths the walk read (#1185).
  """

  alias Cinder.Library.Filesystem.Disk

  def lstat(path), do: record(path, &Disk.lstat/1)
  def ls(path), do: record(path, &Disk.ls/1)

  defp record(path, read) do
    send(self(), {:read, path})
    read.(path)
  end
end
