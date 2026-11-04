defmodule Cinder.Library.Filesystem.DiskFileServerTest do
  @moduledoc """
  Single-path reads of mount paths answer without the VM's one file server (`:file_server_2`), so
  a read hung on a wedged mount pins only its own process (#779, #944, #1114). Covered here, each
  on a path outside the library roots:

    * `Cinder.Library.Filesystem.Disk.dir?/1`;
    * `Disk.open_bound/2`: the lstat of the path and the stat of its descriptor path;
    * `Disk.moviehash_data/1`: the same bind, then the stat and the open of the descriptor path;
    * `Disk.read/1`;
    * `Cinder.Download.PathMapping.validate_local_prefix/2`: the stat of the local prefix.

  `ls/1` and `lstat/1` are covered through the walk in `Cinder.Library.SafeWalkTest`. The reads
  that no public entry point reaches with the file server suspended, such as the rooted helper's
  descriptor stat, which runs after a `System.find_executable/1` that queues on the server, are
  fenced by `Cinder.CodeHealth.MountPathRawReadsTest`.
  """
  # Suspends the VM file server, which every concurrent `File` call would queue behind. The
  # Disk entry points read the library roots, some of them from the database.
  use Cinder.DataCase, async: false

  import Cinder.BoundedWalkHelpers

  alias Cinder.Download.PathMapping
  alias Cinder.Library.Filesystem.Disk

  @moduletag :tmp_dir

  # A call meant to finish gets a deadline a loaded CI runner cannot miss (docs/agents/testing.md).
  @answer_ms 10_000

  # `Disk.moviehash_data/1` reads a 64 KiB head and tail, and refuses a file under twice that.
  @moviehash_size 2 * 65_536

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

  test "open_bound/2 binds a file outside the library roots while the VM file server is " <>
         "blocked",
       %{tmp_dir: tmp} do
    file = Path.join(tmp, "feature.mkv")
    File.write!(file, "video")
    stat = File.stat!(file)
    identity = {stat.major_device, stat.minor_device, stat.inode}

    open_and_close = fn ->
      with {:ok, bound} <- Disk.open_bound(file, [:read, :raw, :binary]) do
        {Disk.close_bound(bound), bound.identity}
      end
    end

    assert open_and_close.() == {:ok, identity}
    assert yield_while_file_server_blocked(open_and_close, @answer_ms) == {:ok, {:ok, identity}}
  end

  test "moviehash_data/1 hashes a file outside the library roots, and refuses a small one, " <>
         "while the VM file server is blocked",
       %{tmp_dir: tmp} do
    video = Path.join(tmp, "feature.mkv")
    head = :binary.copy("h", 65_536)
    tail = :binary.copy("t", 65_536)
    File.write!(video, [head, "middle", tail])
    small = Path.join(tmp, "small.mkv")
    File.write!(small, :binary.copy("s", @moviehash_size - 1))
    hash_both = fn -> {Disk.moviehash_data(video), Disk.moviehash_data(small)} end
    expected = {{:ok, {@moviehash_size + 6, head, tail}}, :too_small}

    assert hash_both.() == expected
    assert yield_while_file_server_blocked(hash_both, @answer_ms) == {:ok, expected}
  end

  test "read/1 reads a file outside the library roots, and reports a missing one, while the " <>
         "VM file server is blocked",
       %{tmp_dir: tmp} do
    file = Path.join(tmp, "feature.en.srt")
    File.write!(file, "1\n00:00:01,000 --> 00:00:02,000\nHello\n")
    read_both = fn -> {Disk.read(file), Disk.read(Path.join(tmp, "missing.srt"))} end
    expected = {{:ok, "1\n00:00:01,000 --> 00:00:02,000\nHello\n"}, {:error, :enoent}}

    assert read_both.() == expected
    assert yield_while_file_server_blocked(read_both, @answer_ms) == {:ok, expected}
  end

  test "PathMapping.validate_local_prefix/2 accepts a readable directory and refuses a missing " <>
         "one and a file while the VM file server is blocked",
       %{tmp_dir: tmp} do
    missing = Path.join(tmp, "missing")
    file = Path.join(tmp, "feature.mkv")
    File.write!(file, "video")

    validate_each = fn ->
      Enum.map([tmp, missing, file], &PathMapping.validate_local_prefix("/downloads", &1))
    end

    expected = [
      :ok,
      {:error, {:path_mapping_local_prefix_unreadable, missing}},
      {:error, {:path_mapping_local_prefix_unreadable, file}}
    ]

    assert validate_each.() == expected
    assert yield_while_file_server_blocked(validate_each, @answer_ms) == {:ok, expected}
  end
end
