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

  test "read/1 accepts a legacy track without sync metadata" do
    expect(Cinder.Library.FilesystemMock, :read, fn "/lib/M/.M.mkv.cinder-subtitles.json" ->
      {:ok,
       Jason.encode!(%{
         "video_moviehash" => "hash",
         "tracks" => %{"fr" => %{"origin" => "opensubtitles_hash"}}
       })}
    end)

    assert Manifest.read("/lib/M/M.mkv") == %{
             video_moviehash: "hash",
             tracks: %{"fr" => %{origin: "opensubtitles_hash"}}
           }
  end

  test "invalid optional metadata preserves provenance but quarantines synchronization" do
    expect(Cinder.Library.FilesystemMock, :read, fn "/lib/M/.M.mkv.cinder-subtitles.json" ->
      {:ok,
       Jason.encode!(%{
         "video_moviehash" => "hash",
         "tracks" => %{
           "fr" => %{
             "origin" => "opensubtitles_hash",
             "file" => "M.fr.srt",
             "sync" => %{"status" => "made-up"},
             "reset_cleanup_sync" => %{"status" => "made-up"}
           },
           "en" => %{
             "origin" => "opensubtitles_id",
             "file" => "../outside.ass"
           }
         }
       })}
    end)

    assert Manifest.read("/lib/M/M.mkv") == %{
             video_moviehash: "hash",
             tracks: %{
               "fr" => %{
                 origin: "opensubtitles_hash",
                 file: "M.fr.srt",
                 sync_invalid?: true,
                 reset_cleanup_sync_invalid?: true
               },
               "en" => %{origin: "opensubtitles_id", file_invalid?: true}
             }
           }
  end

  @tag :tmp_dir
  test "sync metadata is validated, atomically updated/cleared, and replacement drops it", %{
    tmp_dir: tmp
  } do
    video = configure_disk(tmp)
    sync = valid_sync()

    assert :ok = Manifest.put(video, "hash", "fr", "opensubtitles_hash")
    assert :ok = Manifest.put_sync(video, "fr", sync)
    assert Manifest.sync(Manifest.read(video), "fr") == sync

    assert {:error, :invalid_sync} = Manifest.put_sync(video, "fr", %{sync | rate: 0.0})
    assert Manifest.sync(Manifest.read(video), "fr") == sync

    assert :ok = Manifest.begin_reset_cleanup(video, "fr", sync)
    assert Manifest.reset_cleanup_sync(Manifest.read(video), "fr") == sync
    assert :ok = Manifest.finish_reset_cleanup(video, "fr")
    assert Manifest.sync(Manifest.read(video), "fr") == nil
    assert Manifest.reset_cleanup_sync(Manifest.read(video), "fr") == nil

    assert :ok = Manifest.put_sync(video, "fr", sync)
    assert :ok = Manifest.clear_sync(video, "fr")
    assert Manifest.sync(Manifest.read(video), "fr") == nil

    assert :ok = Manifest.put_sync(video, "fr", sync)
    assert :ok = Manifest.put(video, "new-hash", "fr", "opensubtitles_id")

    assert Manifest.read(video) == %{
             video_moviehash: "new-hash",
             tracks: %{"fr" => %{origin: "opensubtitles_id"}}
           }
  end

  @tag :tmp_dir
  test "put/5 records only a safe adjacent sidecar basename", %{tmp_dir: tmp} do
    video = configure_disk(tmp)
    sidecar = Path.rootname(video) <> ".fr.ass"
    File.write!(sidecar, "subtitle")

    assert :ok = Manifest.put(video, "hash", "fr", "opensubtitles_hash", sidecar)

    assert Manifest.read(video) == %{
             video_moviehash: "hash",
             tracks: %{
               "fr" => %{origin: "opensubtitles_hash", file: Path.basename(sidecar)}
             }
           }

    assert {:error, :invalid_sidecar_file} =
             Manifest.put(video, "hash", "fr", "opensubtitles_hash", "../outside.srt")
  end

  test "put/4 writes a temporary manifest before renaming it into place" do
    manifest = "/lib/M/.M.mkv.cinder-subtitles.json"

    expect(Cinder.Library.FilesystemMock, :read, fn ^manifest -> {:error, :enoent} end)

    expect(Cinder.Library.FilesystemMock, :write_exclusive, fn temporary, json ->
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
      operation: :write_exclusive,
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
    assert_receive {:filesystem_barrier, pid, ref, :write_exclusive, temporary}, 1_000
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

  @tag :tmp_dir
  test "temporary manifest creation rejects a symlink substituted after validation", %{
    tmp_dir: tmp
  } do
    video = configure_disk(tmp)
    outside = Path.join(tmp, "outside")
    File.write!(outside, "outside")
    Application.put_env(:cinder, :filesystem, Cinder.Test.BarrierFilesystem)

    Application.put_env(:cinder, :filesystem_barrier, %{
      owner: self(),
      operation: :write_exclusive,
      phase: :before,
      contains: ".cinder-subtitle-manifest-",
      once: true
    })

    on_exit(fn -> Application.delete_env(:cinder, :filesystem_barrier) end)

    task = Task.async(fn -> Manifest.put(video, "hash", "fr", "embedded") end)
    assert_receive {:filesystem_barrier, pid, ref, :write_exclusive, temporary}
    File.ln_s!(outside, temporary)
    send(pid, {ref, :continue})
    assert {:error, :eexist} = Task.await(task)
    assert File.read!(outside) == "outside"
    refute File.exists?(Manifest.path(video))
  end

  defp valid_sync do
    %{
      status: "aligned",
      method: "audio",
      moviehash: "hash",
      source_sha256: String.duplicate("a", 64),
      applied_sha256: String.duplicate("b", 64),
      offset_ms: 27_300,
      rate: 0.999,
      score: 42.5,
      reason: nil
    }
  end

  defp configure_disk(tmp) do
    keys = [:filesystem, :path_policy, :movies_library_path, :tv_library_path]
    saved = Map.new(keys, &{&1, Application.get_env(:cinder, &1)})
    movies = Path.join(tmp, "movies")
    video = Path.join(movies, "Movie/Movie.mkv")
    File.mkdir_p!(Path.dirname(video))
    File.write!(video, "video")
    Application.put_env(:cinder, :filesystem, Cinder.Library.Filesystem.Disk)
    Application.put_env(:cinder, :path_policy, Cinder.Library.PathPolicy)
    Application.put_env(:cinder, :movies_library_path, movies)
    Application.put_env(:cinder, :tv_library_path, Path.join(tmp, "tv"))

    on_exit(fn ->
      Enum.each(saved, fn
        {key, nil} -> Application.delete_env(:cinder, key)
        {key, value} -> Application.put_env(:cinder, key, value)
      end)
    end)

    video
  end
end
