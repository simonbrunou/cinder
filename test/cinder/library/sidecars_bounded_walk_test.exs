defmodule Cinder.Library.SidecarsBoundedWalkTest do
  @moduledoc """
  `Cinder.Library.Sidecars.files/1` over the real `Cinder.Library.PathPolicy` and
  `Cinder.Library.Filesystem.Disk`: its reads run under `Cinder.Library.BoundedWalk`'s deadline,
  keyed by the deepest source root holding the video's folder (#944). The guard's own rules are
  pinned in `BoundedWalkTest`.
  """
  # Suspends the VM file server and uses the app's one walk guard, both global. `DataCase`, since
  # the source roots include the library roots, which read the media profiles.
  use Cinder.DataCase, async: false

  import Cinder.BoundedWalkHelpers
  import Cinder.ConfigCase
  import Mox

  alias Cinder.Library.Filesystem.Disk
  alias Cinder.Library.FilesystemMock
  alias Cinder.Library.PathPolicy
  alias Cinder.Library.Sidecars
  alias Cinder.Test.WedgedFilesystem

  @moduletag :tmp_dir
  # A stuck walk logs a warning.
  @moduletag :capture_log

  setup :verify_on_exit!

  setup %{tmp_dir: tmp} do
    downloads = Path.join(tmp, "downloads")
    movies = Path.join(tmp, "movies")
    File.mkdir_p!(downloads)
    File.mkdir_p!(movies)

    put_env(
      filesystem: Disk,
      path_policy: PathPolicy,
      import_roots: [downloads],
      movies_library_path: movies,
      wedged_filesystem_test: self()
    )

    %{downloads: downloads, movies: movies}
  end

  test "a folder's sidecars list while the VM file server is blocked", %{downloads: downloads} do
    {video, sidecar} = release(downloads, "Release")
    # Loads every module the listing calls, so the blocked listing below loads no code.
    assert Sidecars.files(video) == [{sidecar, "en"}]

    assert yield_while_file_server_blocked(fn -> Sidecars.files(video) end) ==
             {:ok, [{sidecar, "en"}]}
  end

  # An unbounded listing hangs here, so fail in seconds rather than at ExUnit's 60 s default.
  @tag timeout: 10_000
  test "a folder whose listing never returns answers [] at the deadline, the next listing " <>
         "under its root answers [] at once, and a listing under another root still works",
       %{downloads: downloads, movies: movies} do
    put_env(filesystem: WedgedFilesystem, walk_timeout_ms: 300)
    {wedged, _sidecar} = release(downloads, "wedged")
    {video, sidecar} = release(downloads, "Release")
    {library_video, library_sidecar} = release(movies, "Movie (2020)")

    {elapsed, result} = :timer.tc(fn -> Sidecars.files(wedged) end, :millisecond)
    assert result == []
    assert elapsed < 2_300
    assert_receive {:walking, walk}
    release_walk_on_exit(walk)

    # Listings meant to finish get a deadline a loaded CI runner cannot miss, so a refusal that
    # came in well under it came at once.
    put_env(:walk_timeout_ms, 10_000)
    {elapsed, result} = :timer.tc(fn -> Sidecars.files(video) end, :millisecond)
    assert result == []
    assert elapsed < 1_000

    assert Sidecars.files(library_video) == [{library_sidecar, "en"}]

    release_walk(walk)
    assert Sidecars.files(video) == [{sidecar, "en"}]
  end

  test "a raise inside the listing raises in the caller", %{downloads: downloads} do
    put_env(filesystem: FilesystemMock)
    {video, _sidecar} = release(downloads, "Release")
    stub_with(FilesystemMock, Disk)
    expect(FilesystemMock, :find_files, fn _dir -> raise "unexpected call" end)

    assert_raise RuntimeError, "unexpected call", fn -> Sidecars.files(video) end
  end

  # A release folder holding one video and its English sidecar.
  defp release(parent, name) do
    dir = Path.join(parent, name)
    File.mkdir_p!(dir)
    video = Path.join(dir, "Movie.mkv")
    sidecar = Path.join(dir, "Movie.en.srt")
    File.write!(video, "video")
    File.write!(sidecar, "subs")
    {video, sidecar}
  end
end
