defmodule Cinder.Subtitles.ManifestTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Mox

  alias Cinder.Subtitles.Manifest

  setup :verify_on_exit!

  test "path/1 uses a hidden adjacent manifest" do
    assert Manifest.path("/lib/M/M.mkv") == "/lib/M/.M.mkv.cinder-subtitles.json"
  end

  test "read/1 falls back when the manifest is missing" do
    expect(Cinder.Library.FilesystemMock, :read, fn "/lib/M/.M.mkv.cinder-subtitles.json" ->
      {:error, :enoent}
    end)

    assert Manifest.read("/lib/M/M.mkv") == %{video_moviehash: nil, tracks: %{}}
  end

  test "read/1 falls back and warns when the manifest is corrupt" do
    expect(Cinder.Library.FilesystemMock, :read, fn "/lib/M/.M.mkv.cinder-subtitles.json" ->
      {:ok, "not json"}
    end)

    log =
      capture_log(fn ->
        assert Manifest.read("/lib/M/M.mkv") == %{video_moviehash: nil, tracks: %{}}
      end)

    assert log =~ "subtitle manifest"
  end

  test "stable?/3 needs a current hash and provisional?/3 invalidates an old hash" do
    state = %{video_moviehash: "old", tracks: %{"fr" => %{origin: "opensubtitles_hash"}}}

    assert Manifest.stable?(state, "old", "fr")
    refute Manifest.stable?(state, "new", "fr")
    assert Manifest.provisional?(state, "new", "fr")
  end

  test "put/4 writes a temporary manifest before renaming it into place" do
    manifest = "/lib/M/.M.mkv.cinder-subtitles.json"

    expect(Cinder.Library.FilesystemMock, :read, fn ^manifest -> {:error, :enoent} end)

    expect(Cinder.Library.FilesystemMock, :write, fn temporary, json ->
      assert Path.dirname(temporary) == "/lib/M"
      assert String.contains?(temporary, ".cinder-subtitle-manifest-")

      assert %{"video_moviehash" => "hash", "tracks" => %{"fr" => %{"origin" => "embedded"}}} =
               Jason.decode!(json)

      :ok
    end)

    expect(Cinder.Library.FilesystemMock, :rename, fn temporary, ^manifest ->
      assert String.contains?(temporary, ".cinder-subtitle-manifest-")
      :ok
    end)

    assert :ok = Manifest.put("/lib/M/M.mkv", "hash", "fr", "embedded")
  end

  @tag :tmp_dir
  test "put/4 rejects a library parent replaced by a symlink after the temp write", %{
    tmp_dir: tmp
  } do
    keys = [:filesystem, :path_policy, :movies_library_path, :tv_library_path]
    saved = Map.new(keys, &{&1, Application.get_env(:cinder, &1)})
    movies = Path.join(tmp, "movies")
    parent = Path.join(movies, "Movie")
    video = Path.join(parent, "Movie.mkv")
    outside = Path.join(tmp, "outside")
    manifest = Manifest.path(video)
    File.mkdir_p!(parent)
    File.mkdir_p!(outside)
    File.write!(video, "video")
    Application.put_env(:cinder, :filesystem, Cinder.Test.BarrierFilesystem)
    Application.put_env(:cinder, :path_policy, Cinder.Library.PathPolicy)
    Application.put_env(:cinder, :movies_library_path, movies)
    Application.put_env(:cinder, :tv_library_path, Path.join(tmp, "tv"))

    Application.put_env(:cinder, :filesystem_barrier, %{
      owner: self(),
      operation: :write,
      contains: ".cinder-subtitle-manifest-"
    })

    on_exit(fn ->
      Application.delete_env(:cinder, :filesystem_barrier)

      Enum.each(saved, fn
        {key, nil} -> Application.delete_env(:cinder, key)
        {key, value} -> Application.put_env(:cinder, key, value)
      end)
    end)

    task = Task.async(fn -> Manifest.put(video, "hash", "fr", "embedded") end)
    assert_receive {:filesystem_barrier, pid, ref, :write, temporary}, 1_000
    backup = parent <> ".old"
    File.rename!(parent, backup)
    File.ln_s!(outside, parent)

    File.rename!(
      Path.join(backup, Path.basename(temporary)),
      Path.join(outside, Path.basename(temporary))
    )

    send(pid, {ref, :continue})

    assert Task.await(task) == {:error, :unsafe_destination}
    refute File.exists?(Path.join(outside, Path.basename(manifest)))
  end
end
