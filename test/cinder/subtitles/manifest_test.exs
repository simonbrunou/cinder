defmodule Cinder.Subtitles.ManifestTest do
  use Cinder.DataCase, async: false

  import Cinder.Test.BarrierFilesystem, only: [fail_once: 1]
  import ExUnit.CaptureLog
  import Mox

  alias Cinder.Settings
  alias Cinder.Subtitles.Manifest
  alias Cinder.Test.DiskTask

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

  # #1202: a manifest that cannot be read is no missing one, and a writer refuses to start from it.
  test "read/1 falls back and warns when the manifest cannot be read, and not when it is missing" do
    Cinder.Library.FilesystemMock
    |> expect(:read, fn "/lib/M/.M.mkv.cinder-subtitles.json" -> {:error, :eacces} end)
    |> expect(:read, fn "/lib/M/.M.mkv.cinder-subtitles.json" -> {:error, :enoent} end)

    log =
      capture_log(fn ->
        assert Manifest.read("/lib/M/M.mkv") == %{video_moviehash: nil, tracks: %{}}
      end)

    assert log =~ "subtitle manifest cannot be read for /lib/M/M.mkv: :eacces"
    assert unreadable_warnings(log) == 1

    log =
      capture_log(fn ->
        assert Manifest.read("/lib/M/M.mkv") == %{video_moviehash: nil, tracks: %{}}
      end)

    assert log == ""
  end

  test "fetch/1 reads a missing manifest as an empty one" do
    expect(Cinder.Library.FilesystemMock, :read, fn "/lib/M/.M.mkv.cinder-subtitles.json" ->
      {:error, :enoent}
    end)

    assert Manifest.fetch("/lib/M/M.mkv") == {:ok, %{video_moviehash: nil, tracks: %{}}}
  end

  test "fetch/1 says why it cannot read or decode a manifest, and logs nothing" do
    Cinder.Library.FilesystemMock
    |> expect(:read, fn "/lib/M/.M.mkv.cinder-subtitles.json" -> {:error, :eacces} end)
    |> expect(:read, fn "/lib/M/.M.mkv.cinder-subtitles.json" -> {:ok, "not json"} end)
    |> expect(:read, fn "/lib/M/.M.mkv.cinder-subtitles.json" -> {:ok, ~s({"tracks": {}})} end)

    log =
      capture_log(fn ->
        assert Manifest.fetch("/lib/M/M.mkv") == {:error, :eacces}
        assert Manifest.fetch("/lib/M/M.mkv") == {:error, :malformed}
        assert Manifest.fetch("/lib/M/M.mkv") == {:error, :malformed}
      end)

    assert log == ""
  end

  test "fetch/1 decodes a manifest the way read/1 does" do
    json =
      Jason.encode!(%{
        "video_moviehash" => "hash",
        "tracks" => %{
          "fr" => %{"origin" => "embedded", "source_moviehash" => "hash", "sync" => "invalid"}
        }
      })

    stub(Cinder.Library.FilesystemMock, :read, fn "/lib/M/.M.mkv.cinder-subtitles.json" ->
      {:ok, json}
    end)

    assert {:ok, state} = Manifest.fetch("/lib/M/M.mkv")
    assert state == Manifest.read("/lib/M/M.mkv")
    assert %{"fr" => %{sync_invalid?: true}} = state.tracks
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
  test "invalid cleanup markers survive unrelated manifest writes", %{tmp_dir: tmp} do
    video = configure_disk(tmp)
    sidecar = Path.rootname(video) <> ".fr.srt"

    File.write!(
      Manifest.path(video),
      Jason.encode!(%{
        video_moviehash: "hash",
        tracks: %{
          "fr" => %{
            origin: "opensubtitles_hash",
            file: Path.basename(sidecar),
            managed_sha256: String.duplicate("a", 64),
            replacement_cleanup_sync: %{status: "invalid"},
            reset_cleanup_sync: %{status: "invalid"},
            backup_tombstone: %{identity: "invalid"}
          }
        }
      })
    )

    assert :ok = Manifest.put(video, "hash", "en", "embedded")

    assert %{
             replacement_cleanup_sync_invalid?: true,
             reset_cleanup_sync_invalid?: true,
             backup_tombstone_invalid?: true
           } = Manifest.read(video).tracks["fr"]
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

  # #1071: the track an embedded sidecar came from, next to the moviehash of its file.
  @tag :tmp_dir
  test "put/8 records the source track of an embedded sidecar and read/1 keeps it", %{
    tmp_dir: tmp
  } do
    video = configure_disk(tmp)

    assert :ok = Manifest.put(video, "hash", "fr", "embedded", nil, nil, nil, 3)
    state = Manifest.read(video)
    assert %{origin: "embedded", source_moviehash: "hash", source_track: 3} = state.tracks["fr"]
    assert Manifest.embedded_track(state, "hash", "fr") == 3
    assert Manifest.embedded_track(state, "other-hash", "fr") == nil
    assert Manifest.embedded_track(state, nil, "fr") == nil

    for origin <- ~w(own_track opensubtitles_hash translated) do
      assert :ok = Manifest.put(video, "hash", "fr", origin, nil, nil, nil, 3)
      refute Map.has_key?(Manifest.read(video).tracks["fr"], :source_track)
    end

    assert :ok = Manifest.put(video, nil, "fr", "embedded", nil, nil, nil, 3)
    refute Map.has_key?(Manifest.read(video).tracks["fr"], :source_track)

    for index <- [-1, 1.5, "3"] do
      assert {:error, :invalid_source_track} =
               Manifest.put(video, "hash", "fr", "embedded", nil, nil, nil, index)
    end
  end

  test "read/1 drops a source track that is no non-negative integer and keeps the rest" do
    for index <- [-1, 1.5, "3", nil, [3]] do
      expect(Cinder.Library.FilesystemMock, :read, fn "/lib/M/.M.mkv.cinder-subtitles.json" ->
        {:ok,
         Jason.encode!(%{
           "video_moviehash" => "hash",
           "tracks" => %{
             "fr" => %{
               "origin" => "embedded",
               "source_moviehash" => "hash",
               "source_track" => index
             }
           }
         })}
      end)

      log =
        capture_log(fn ->
          assert Manifest.read("/lib/M/M.mkv") == %{
                   video_moviehash: "hash",
                   tracks: %{"fr" => %{origin: "embedded", source_moviehash: "hash"}}
                 }
        end)

      refute log =~ "malformed"
    end
  end

  @tag :tmp_dir
  test "put/8 whose manifest read fails writes nothing and keeps the other tracks", %{
    tmp_dir: tmp
  } do
    video = configure_disk(tmp)
    assert :ok = Manifest.put(video, "hash", "en", "opensubtitles_hash")
    before = File.read!(Manifest.path(video))
    fail_manifest_read(:rooted_helper_timeout)

    log =
      capture_log(fn ->
        assert {:error, {:unreadable_manifest, :rooted_helper_timeout}} =
                 Manifest.put(video, "hash", "fr", "opensubtitles_hash")
      end)

    assert log =~ "subtitle manifest cannot be read for #{video}: :rooted_helper_timeout"
    assert unreadable_warnings(log) == 1
    assert File.read!(Manifest.path(video)) == before
    assert temporary_manifests(video) == []

    assert :ok = Manifest.put(video, "hash", "fr", "opensubtitles_hash")
    assert Map.keys(Manifest.read(video).tracks) == ["en", "fr"]
  end

  @tag :tmp_dir
  test "every other writer whose manifest read fails returns the reason and writes nothing", %{
    tmp_dir: tmp
  } do
    video = configure_disk(tmp)
    sync = valid_sync()

    File.write!(
      Manifest.path(video),
      Jason.encode!(%{
        video_moviehash: "hash",
        tracks: %{
          "en" => %{origin: "opensubtitles_hash", sync: sync},
          "fr" => %{
            origin: "opensubtitles_hash",
            sync: sync,
            replacement_cleanup_sync: sync,
            reset_cleanup_sync: sync,
            backup_tombstone: %{identity: [1, 2, 3]}
          }
        }
      })
    )

    before = File.read!(Manifest.path(video))

    for {name, writer} <- writers(sync) do
      fail_manifest_read(:eio)
      {result, log} = with_log(fn -> writer.(video) end)

      assert {name, result} == {name, {:error, {:unreadable_manifest, :eio}}}
      assert {name, unreadable_warnings(log)} == {name, 1}
      assert {name, log =~ "subtitle manifest cannot be read for #{video}: :eio"} == {name, true}
      assert {name, File.read!(Manifest.path(video))} == {name, before}
    end

    assert temporary_manifests(video) == []
  end

  @tag :tmp_dir
  test "a writer on a readable or missing manifest without the language answers as before", %{
    tmp_dir: tmp
  } do
    video = configure_disk(tmp)
    sync = valid_sync()
    # The four writers that only clear a field find nothing to clear.
    clears =
      ~w(clear_sync clear_replacement_cleanup finish_reset_cleanup_2 clear_backup_tombstone)a

    for manifest <- [
          Jason.encode!(%{video_moviehash: "hash", tracks: %{"en" => %{origin: "embedded"}}}),
          nil
        ] do
      if manifest,
        do: File.write!(Manifest.path(video), manifest),
        else: File.rm(Manifest.path(video))

      for {name, writer} <- writers(sync) do
        {result, log} = with_log(fn -> writer.(video) end)
        expected = if name in clears, do: :ok, else: {:error, :unknown_track}

        assert {name, result} == {name, expected}
        assert {name, log} == {name, ""}

        assert {name, File.read(Manifest.path(video))} ==
                 {name, if(manifest, do: {:ok, manifest}, else: {:error, :enoent})}
      end

      assert :ok = Manifest.put(video, "hash", "fr", "opensubtitles_hash")

      expected = if manifest, do: ["en", "fr"], else: ["fr"]
      assert Map.keys(Manifest.read(video).tracks) == expected
    end
  end

  # #1202's out of scope: a manifest that reads but does not decode stays a fresh start, since a
  # retry cannot repair it.
  @tag :tmp_dir
  test "put/8 over a malformed manifest still writes from an empty one", %{tmp_dir: tmp} do
    video = configure_disk(tmp)
    File.write!(Manifest.path(video), "not json")

    log = capture_log(fn -> assert :ok = Manifest.put(video, "hash", "fr", "embedded") end)

    assert log =~ "subtitle manifest is malformed for #{video}"
    assert unreadable_warnings(log) == 0
    assert Map.keys(Manifest.read(video).tracks) == ["fr"]
  end

  # #1210: a path check whose `lstat` fails cannot tell whether the manifest is there, so a writer
  # refuses to start from an empty one. The movies and tv roots are both configured, and the
  # reason comes from the movies root, which holds the video.
  @tag :tmp_dir
  test "put/8 whose path check fails on the folder's lstat writes nothing and keeps the tracks",
       %{
         tmp_dir: tmp
       } do
    video = configure_disk(tmp)

    assert [Path.join(tmp, "movies"), Path.join(tmp, "tv")] -- Settings.video_library_roots() ==
             []

    assert :ok = Manifest.put(video, "hash", "en", "opensubtitles_hash")
    before = File.read!(Manifest.path(video))

    for reason <- [:rooted_helper_timeout, :eio] do
      fail_folder_lstat(video, reason)

      log =
        capture_log(fn ->
          assert {reason, Manifest.put(video, "hash", "fr", "opensubtitles_hash")} ==
                   {reason, {:error, {:unreadable_manifest, reason}}}
        end)

      assert log =~ "subtitle manifest cannot be read for #{video}: #{inspect(reason)}"
      assert {reason, unreadable_warnings(log)} == {reason, 1}
      assert {reason, File.read!(Manifest.path(video))} == {reason, before}
      assert {reason, temporary_manifests(video)} == {reason, []}
    end

    assert :ok = Manifest.put(video, "hash", "fr", "opensubtitles_hash")
    assert Map.keys(Manifest.read(video).tracks) == ["en", "fr"]
  end

  @tag :tmp_dir
  test "read/1 whose path check fails on the folder's lstat warns once and reads empty", %{
    tmp_dir: tmp
  } do
    video = configure_disk(tmp)
    assert :ok = Manifest.put(video, "hash", "en", "opensubtitles_hash")

    for reason <- [:rooted_helper_timeout, :eio] do
      fail_folder_lstat(video, reason)

      {state, log} = with_log(fn -> Manifest.read(video) end)

      assert {reason, state} == {reason, %{video_moviehash: nil, tracks: %{}}}

      assert {reason, log =~ "subtitle manifest cannot be read for #{video}: #{inspect(reason)}"} ==
               {reason, true}

      assert {reason, unreadable_warnings(log)} == {reason, 1}

      {state, log} = with_log(fn -> Manifest.read(video) end)

      assert {reason, Map.keys(state.tracks)} == {reason, ["en"]}
      assert {reason, log} == {reason, ""}
    end
  end

  @tag :tmp_dir
  test "every other writer whose path check fails on the folder's lstat writes nothing", %{
    tmp_dir: tmp
  } do
    video = configure_disk(tmp)
    sync = valid_sync()

    File.write!(
      Manifest.path(video),
      Jason.encode!(%{
        video_moviehash: "hash",
        tracks: %{
          "en" => %{origin: "opensubtitles_hash", sync: sync},
          "fr" => %{
            origin: "opensubtitles_hash",
            sync: sync,
            replacement_cleanup_sync: sync,
            reset_cleanup_sync: sync,
            backup_tombstone: %{identity: [1, 2, 3]}
          }
        }
      })
    )

    before = File.read!(Manifest.path(video))

    for {name, writer} <- writers(sync) do
      fail_folder_lstat(video, :eio)
      {result, log} = with_log(fn -> writer.(video) end)

      assert {name, result} == {name, {:error, {:unreadable_manifest, :eio}}}
      assert {name, unreadable_warnings(log)} == {name, 1}
      assert {name, log =~ "subtitle manifest cannot be read for #{video}: :eio"} == {name, true}
      assert {name, File.read!(Manifest.path(video))} == {name, before}
    end

    assert temporary_manifests(video) == []
  end

  # A symlinked folder or a path outside every video root is no transient failure: `write/2`
  # refuses it too, so the refusal reads as an empty manifest and logs nothing, as before #1210.
  @tag :tmp_dir
  test "a symlinked video folder or a video outside every root is refused without a warning", %{
    tmp_dir: tmp
  } do
    real_video = configure_disk(tmp)
    assert :ok = Manifest.put(real_video, "hash", "en", "opensubtitles_hash")
    before = File.read!(Manifest.path(real_video))
    linked = Path.join(Path.dirname(Path.dirname(real_video)), "Linked")
    File.ln_s!(Path.dirname(real_video), linked)
    outside = Path.join(tmp, "outside/Movie/Movie.mkv")
    File.mkdir_p!(Path.dirname(outside))
    File.write!(outside, "video")
    File.write!(Manifest.path(outside), before)

    for video <- [Path.join(linked, Path.basename(real_video)), outside] do
      {result, log} = with_log(fn -> Manifest.put(video, "hash", "fr", "opensubtitles_hash") end)

      assert {video, result} == {video, {:error, :unsafe_destination}}
      assert {video, log} == {video, ""}

      {state, log} = with_log(fn -> Manifest.read(video) end)

      assert {video, state} == {video, %{video_moviehash: nil, tracks: %{}}}
      assert {video, log} == {video, ""}
    end

    assert File.read!(Manifest.path(real_video)) == before
    assert File.read!(Manifest.path(outside)) == before
    assert temporary_manifests(real_video) == []
    assert temporary_manifests(outside) == []
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

  test "put/4 accepts a manifest rename whose effect can be verified" do
    manifest = "/lib/M/.M.mkv.cinder-subtitles.json"

    expect(Cinder.Library.FilesystemMock, :read, fn ^manifest -> {:error, :enoent} end)

    expect(Cinder.Library.FilesystemMock, :write_exclusive, fn temporary, json ->
      send(self(), {:temporary_manifest, temporary, json})
      :ok
    end)

    expect(Cinder.Library.FilesystemMock, :rename, fn temporary, ^manifest ->
      assert_received {:temporary_manifest, ^temporary, json}
      send(self(), {:committed_manifest, json})
      {:error, {:effect_committed, "rename", %{"phase" => "post_effect", "reason" => "EIO"}}}
    end)

    expect(Cinder.Library.FilesystemMock, :read, fn ^manifest ->
      assert_received {:committed_manifest, json}
      {:ok, json}
    end)

    stub(Cinder.Library.FilesystemMock, :rm, fn _path -> {:error, :enoent} end)

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

    assert_receive {:filesystem_barrier, pid, ref, :write_exclusive, temporary},
                   DiskTask.timeout_ms()

    backup = parent <> ".old"
    File.rename!(parent, backup)
    File.ln_s!(outside, parent)

    File.rename!(
      Path.join(backup, Path.basename(temporary)),
      Path.join(outside, Path.basename(temporary))
    )

    send(pid, {ref, :continue})

    assert DiskTask.await(task) == {:error, :unsafe_destination}
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

    assert_receive {:filesystem_barrier, pid, ref, :write_exclusive, temporary},
                   DiskTask.timeout_ms()

    File.ln_s!(outside, temporary)
    send(pid, {ref, :continue})
    assert {:error, :eexist} = DiskTask.await(task)
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

  # The ten writers but `put/8`, each writing language "fr" of `video`.
  defp writers(sync) do
    [
      put_sync: &Manifest.put_sync(&1, "fr", sync),
      clear_sync: &Manifest.clear_sync(&1, "fr"),
      begin_replacement_cleanup: &Manifest.begin_replacement_cleanup(&1, "fr", sync),
      clear_replacement_cleanup: &Manifest.clear_replacement_cleanup(&1, "fr"),
      begin_reset_cleanup: &Manifest.begin_reset_cleanup(&1, "fr", sync),
      finish_reset_cleanup_3: &Manifest.finish_reset_cleanup(&1, "fr", sync),
      finish_reset_cleanup_2: &Manifest.finish_reset_cleanup(&1, "fr"),
      put_backup_tombstone: &Manifest.put_backup_tombstone(&1, "fr", [1, 2, 3]),
      clear_backup_tombstone: &Manifest.clear_backup_tombstone(&1, "fr")
    ]
  end

  # Fails the next read of a manifest, and only that one.
  defp fail_manifest_read(reason),
    do: fail_once(%{operation: :read, source_contains: ".cinder-subtitles.json", reason: reason})

  # Fails the next `lstat` of the video's folder, the path check's walk, and only that one. The
  # manifest's own path holds the video's name, so it is excluded.
  defp fail_folder_lstat(video, reason) do
    fail_once(%{
      operation: :lstat,
      source_contains: Path.dirname(video),
      excludes: Path.basename(video),
      reason: reason
    })
  end

  defp unreadable_warnings(log),
    do: length(String.split(log, "subtitle manifest cannot be read")) - 1

  defp temporary_manifests(video),
    do: Path.wildcard(Path.join(Path.dirname(video), ".cinder-subtitle-manifest-*"))

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
