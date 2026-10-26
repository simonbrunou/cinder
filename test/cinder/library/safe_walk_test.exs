defmodule Cinder.Library.SafeWalkTest.WedgedFilesystem do
  @moduledoc false
  # Lists like `Disk`, except a directory named `wedged`, where `ls/1` hangs the way a read on a
  # wedged mount does (`Cinder.BoundedWalkHelpers.hang_walk/1`).

  alias Cinder.BoundedWalkHelpers
  alias Cinder.Library.Filesystem.Disk

  defdelegate lstat(path), to: Disk

  def ls(dir) do
    if Path.basename(dir) == "wedged",
      do: BoundedWalkHelpers.hang_walk(Application.fetch_env!(:cinder, :wedged_filesystem_test)),
      else: Disk.ls(dir)
  end
end

defmodule Cinder.Library.SafeWalkTest do
  @moduledoc """
  `Cinder.Library.safe_walk/1` over the real `Cinder.Library.PathPolicy` and
  `Cinder.Library.Filesystem.Disk`: the walk every importer and the completion content check run
  in their tick, bounded by `Cinder.Library.BoundedWalk` (issue #779). The guard's own rules are
  pinned in `BoundedWalkTest`.
  """
  # Suspends the VM file server and uses the app's one walk guard, both global.
  use ExUnit.Case, async: false

  import Cinder.BoundedWalkHelpers
  import Cinder.ConfigCase

  alias Cinder.Library
  alias Cinder.Library.Filesystem.Disk
  alias Cinder.Library.SafeWalkTest.WedgedFilesystem

  @moduletag :tmp_dir
  # A stuck walk logs a warning.
  @moduletag :capture_log

  setup %{tmp_dir: tmp} do
    downloads = Path.join(tmp, "downloads")
    File.mkdir_p!(downloads)

    put_env(
      filesystem: Disk,
      path_policy: Library.PathPolicy,
      import_roots: [downloads],
      wedged_filesystem_test: self()
    )

    %{downloads: downloads}
  end

  test "a healthy tree walks as before: nested files, no symlinks, the same refusals", %{
    downloads: downloads,
    tmp_dir: tmp
  } do
    release = Path.join(downloads, "Release")
    outside = Path.join(tmp, "outside")
    File.mkdir_p!(Path.join(release, "Subs"))
    File.mkdir_p!(outside)
    File.write!(Path.join(release, "feature.mkv"), "video")
    File.write!(Path.join(release, "Subs/en.srt"), "subs")
    File.write!(Path.join(outside, "secret.mkv"), "secret")
    File.ln_s!(outside, Path.join(release, "escaped"))
    File.ln_s!(release, Path.join(downloads, "linked"))

    deep =
      Enum.reduce(1..65, Path.join(downloads, "Deep"), fn _level, acc -> Path.join(acc, "d") end)

    File.mkdir_p!(deep)

    assert {:ok, files} = Library.safe_walk(release)

    assert Enum.sort(files) == [
             {Path.join(release, "Subs/en.srt"), 4},
             {Path.join(release, "feature.mkv"), 5}
           ]

    assert Library.safe_walk(Path.join(downloads, "Deep")) == {:error, :traversal_limit}
    assert Library.safe_walk(Path.join(release, "feature.mkv")) == {:error, :enotdir}
    assert Library.safe_walk(outside) == {:error, :unsafe_source}
    assert Library.safe_walk(Path.join(downloads, "linked")) == {:error, :unsafe_source}
  end

  test "the walk reads the tree while the VM file server is blocked", %{downloads: downloads} do
    release = Path.join(downloads, "Release")
    File.mkdir_p!(Path.join(release, "Subs"))
    File.write!(Path.join(release, "feature.mkv"), "video")
    File.write!(Path.join(release, "Subs/en.srt"), "subs")
    # Loads every module the walk calls, so the blocked walk below loads no code.
    assert {:ok, expected} = Library.safe_walk(release)

    :ok = :sys.suspend(:file_server_2)

    result =
      try do
        walk = Task.async(fn -> Library.safe_walk(release) end)
        Task.yield(walk, 2_000) || Task.shutdown(walk, :brutal_kill)
      after
        :sys.resume(:file_server_2)
      end

    assert {:ok, {:ok, files}} = result
    assert Enum.sort(files) == Enum.sort(expected)
  end

  # An unbounded walk hangs here, so fail in seconds rather than at ExUnit's 60 s default.
  @tag timeout: 10_000
  test "a walk that never returns ends at the deadline, refuses the next walk under its root " <>
         "at once, and walks resume once it returns",
       %{downloads: downloads} do
    put_env(filesystem: WedgedFilesystem, walk_timeout_ms: 300)
    wedged = Path.join(downloads, "wedged")
    release = Path.join(downloads, "Release")
    File.mkdir_p!(wedged)
    File.mkdir_p!(release)
    File.write!(Path.join(release, "feature.mkv"), "video")

    {elapsed, result} = :timer.tc(fn -> Library.safe_walk(wedged) end, :millisecond)
    assert result == {:error, :timeout}
    assert elapsed < 2_300
    assert_receive {:walking, walk}

    # Walks meant to finish get a deadline a loaded CI runner cannot miss, so a refusal that came
    # in well under it came at once.
    put_env(:walk_timeout_ms, 10_000)
    {elapsed, result} = :timer.tc(fn -> Library.safe_walk(release) end, :millisecond)
    assert result == {:error, :timeout}
    assert elapsed < 1_000

    release_walk(walk)
    assert Library.safe_walk(release) == {:ok, [{Path.join(release, "feature.mkv"), 5}]}
  end
end
