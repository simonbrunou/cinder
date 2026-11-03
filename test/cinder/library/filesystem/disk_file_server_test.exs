defmodule Cinder.Library.Filesystem.DiskFileServerTest do
  @moduledoc """
  `Cinder.Library.Filesystem.Disk`'s single-path reads answer without the VM's one file server
  (`:file_server_2`), so a read hung on a wedged mount pins only its own process (#779, #944).
  `ls/1` and `lstat/1` are covered through the walk in `Cinder.Library.SafeWalkTest`.
  """
  # Suspends the VM file server, which every concurrent `File` call would queue behind.
  use ExUnit.Case, async: false

  import Cinder.BoundedWalkHelpers

  alias Cinder.Library.Filesystem.Disk

  @moduletag :tmp_dir

  test "dir?/1 answers for a directory, a file and a missing path while the VM file server " <>
         "is blocked",
       %{tmp_dir: tmp} do
    file = Path.join(tmp, "feature.mkv")
    File.write!(file, "video")
    paths = [tmp, file, Path.join(tmp, "missing")]
    # Loads every module dir?/1 calls, so the blocked calls below load no code.
    assert Enum.map(paths, &Disk.dir?/1) == [true, false, false]

    assert yield_while_file_server_blocked(fn -> Enum.map(paths, &Disk.dir?/1) end) ==
             {:ok, [true, false, false]}
  end
end
