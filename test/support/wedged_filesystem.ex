defmodule Cinder.Test.WedgedFilesystem do
  @moduledoc """
  Reads like `Cinder.Library.Filesystem.Disk`, except a directory named `wedged`, where `ls/1`
  hangs the way a read on a wedged mount does (`Cinder.BoundedWalkHelpers.hang_walk/1`). The
  test that hangs it sets `:wedged_filesystem_test` to its own pid (#779, #944).
  """

  alias Cinder.BoundedWalkHelpers
  alias Cinder.Library.Filesystem.Disk
  alias Cinder.Library.PathPolicy

  defdelegate lstat(path), to: Disk
  defdelegate dir?(path), to: Disk

  def ls(dir) do
    if Path.basename(dir) == "wedged",
      do: BoundedWalkHelpers.hang_walk(Application.fetch_env!(:cinder, :wedged_filesystem_test)),
      else: Disk.ls(dir)
  end

  # `Disk.find_files/2`'s walk, reading through this module so it reaches the hanging `ls/1`.
  def find_files(dir, opts \\ []),
    do: PathPolicy.walk(dir, skip: Keyword.get(opts, :skip, []), filesystem: __MODULE__)
end
