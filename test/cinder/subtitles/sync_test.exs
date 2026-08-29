defmodule Cinder.Subtitles.SyncTest do
  use Cinder.DataCase, async: false

  import Mox

  alias Cinder.Library.Filesystem.Disk
  alias Cinder.Subtitles.{Manifest, Moviehash, Sync}
  alias Cinder.Subtitles.Sync.AtomicFile

  @moduletag :tmp_dir

  setup :set_mox_global
  setup :verify_on_exit!

  setup %{tmp_dir: tmp} do
    keys = [
      :filesystem,
      :path_policy,
      :movies_library_path,
      :tv_library_path,
      :media_info,
      :subtitle_sync_engine,
      :subtitle_sync_workspace_id,
      :rooted_filesystem_helper,
      :filesystem_barrier,
      :filesystem_failure,
      :filesystem_failures
    ]

    saved = Map.new(keys, &{&1, Application.get_env(:cinder, &1)})
    movies = Path.join(tmp, "movies")
    tv = Path.join(tmp, "tv")
    File.mkdir_p!(movies)
    File.mkdir_p!(tv)
    Application.put_env(:cinder, :filesystem, Cinder.Library.Filesystem.Disk)
    Application.put_env(:cinder, :path_policy, Cinder.Library.PathPolicy)
    Application.put_env(:cinder, :movies_library_path, movies)
    Application.put_env(:cinder, :tv_library_path, tv)
    Application.put_env(:cinder, :media_info, Cinder.Library.MediaInfoMock)
    Application.put_env(:cinder, :subtitle_sync_engine, Cinder.Subtitles.Sync.EngineMock)

    on_exit(fn ->
      Enum.each(saved, fn
        {key, nil} -> Application.delete_env(:cinder, key)
        {key, value} -> Application.put_env(:cinder, key, value)
      end)
    end)

    video = Path.join(movies, "Movie/Movie.mkv")
    File.mkdir_p!(Path.dirname(video))
    File.write!(video, String.duplicate("v", 131_072))
    %{video: video}
  end

  test "discovers only OpenSubtitles-managed recognized sidecars", %{video: video} do
    for {language, origin, extension} <- [
          {"en", "opensubtitles_hash", ".ass"},
          {"fr", "opensubtitles_id", ".vtt"},
          {"de", "release_sidecar", ".srt"},
          {"es", "translated", ".ssa"}
        ] do
      path = sidecar(video, language, extension)
      content = subtitle(extension)
      File.write!(path, content)
      assert :ok = Manifest.put(video, "hash", language, origin, path, digest(content))
    end

    File.write!(Path.rootname(video) <> ".en.forced.srt", subtitle(".srt"))

    assert Sync.discover(video) |> Enum.map(&{&1.language, Path.extname(&1.sidecar_path)}) == [
             {"en", ".ass"},
             {"fr", ".vtt"}
           ]
  end

  test "videos without managed sidecars skip moviehash reads", %{video: video} do
    failure = %{
      operation: :moviehash_data,
      source_contains: Path.basename(video),
      reason: :eio,
      once: true
    }

    Application.put_env(:cinder, :filesystem, Cinder.Test.BarrierFilesystem)
    Application.put_env(:cinder, :filesystem_failure, failure)

    assert Sync.analyze_video(video) == []
    assert Application.get_env(:cinder, :filesystem_failure) == failure
  end

  test "videos without subtitle manifests skip directory scans", %{video: video} do
    Application.put_env(:cinder, :filesystem, Cinder.Library.FilesystemMock)
    Application.put_env(:cinder, :path_policy, Cinder.Test.PermissivePathPolicy)

    expect(Cinder.Library.FilesystemMock, :read, fn path ->
      assert path == Manifest.path(video)
      {:error, :enoent}
    end)

    assert Sync.discover(video) == []
  end

  test "malformed exact-file or sync metadata quarantines managed sidecars", %{video: video} do
    en = sidecar(video, "en", ".srt")
    fr = sidecar(video, "fr", ".ass")
    de = sidecar(video, "de", ".srt")
    File.write!(en, subtitle(".srt"))
    File.write!(fr, subtitle(".ass"))
    File.write!(de, subtitle(".srt"))

    File.write!(
      Manifest.path(video),
      Jason.encode!(%{
        video_moviehash: moviehash!(video),
        tracks: %{
          "en" => %{origin: "opensubtitles_hash", file: "../other.srt"},
          "fr" => %{
            origin: "opensubtitles_id",
            file: Path.basename(fr),
            sync: %{status: "invalid"}
          },
          "de" => %{
            origin: "opensubtitles_hash",
            file: Path.basename(de),
            managed_sha256: digest(subtitle(".srt")),
            backup_tombstone: %{identity: "invalid"}
          }
        }
      })
    )

    assert Sync.discover(video) == []
  end

  test "a small high-confidence automatic correction is recorded without rewriting", %{
    video: video
  } do
    path = managed_srt!(video)
    original = File.read!(path)
    before = File.stat!(path).mtime
    stub(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video -> {:ok, []} end)

    expect(Cinder.Subtitles.Sync.EngineMock, :sync, fn reference, input, output ->
      assert File.read!(reference) == File.read!(video)
      assert File.read!(input) == original
      File.write!(output, original <> "\n")
      {:ok, %{score: 30.0, offset_ms: -70, rate: 1.0}}
    end)

    assert [%{status: :aligned}] = Sync.analyze_video(video)
    assert File.read!(path) == original
    assert File.stat!(path).mtime == before
    refute File.exists?(Sync.backup_path(path))
  end

  test "manual correction keeps one immutable backup, reapplies from it, and reset restores it",
       %{
         video: video
       } do
    path = managed_srt!(video)
    [item] = Sync.discover(video)
    original = File.read!(path)

    assert {:ok, :corrected, _} = Sync.manual(item, 1_000, 1.0)
    backup = Sync.backup_path(path)
    assert File.read!(backup) == original
    assert File.read!(path) =~ "00:00:02,000"

    [item] = Sync.discover(video)
    assert {:ok, :corrected, _} = Sync.manual(item, 2_000, 1.0)
    assert File.read!(backup) == original
    assert File.read!(path) =~ "00:00:03,000"
    refute File.read!(path) =~ "00:00:04,000 --> 00:00:05,000"

    [item] = Sync.discover(video)
    assert :ok = Sync.reset(item)
    assert File.read!(path) == original
    assert File.read!(backup) == ""
    assert Manifest.sync(Manifest.read(video), "en") == nil
  end

  test "legacy embedded migration retires a proven duplicate backup", %{video: video} do
    path = managed_srt!(video)
    original = File.read!(path)
    backup = owned_backup!(video, path, original)

    assert :ok =
             Manifest.put_sync(video, "en", %{
               status: "aligned",
               method: "embedded",
               moviehash: moviehash!(video),
               source_sha256: digest(original),
               applied_sha256: digest(original),
               offset_ms: 0,
               rate: 1.0,
               score: 30.0,
               reason: nil
             })

    expect(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video -> {:ok, []} end)

    expect(Cinder.Subtitles.Sync.EngineMock, :sync, fn _reference, input, output ->
      assert File.read!(input) == original
      File.write!(output, original)
      {:ok, %{score: 30.0, offset_ms: 0, rate: 1.0}}
    end)

    assert [%{method: "audio", status: :aligned}] = Sync.analyze_video(video)
    assert File.read!(path) == original
    assert File.read!(backup) == ""

    assert %{method: "audio", status: "aligned", version: 2} =
             Manifest.sync(Manifest.read(video), "en")
  end

  test "version one automatic corrections are restored before bounded reanalysis", %{
    video: video
  } do
    path = managed_srt!(video)
    original = File.read!(path)
    corrected = shifted_subtitle(original)
    _backup = owned_backup!(video, path, original)
    File.write!(path, corrected)

    assert :ok =
             Manifest.put_sync(video, "en", %{
               version: 1,
               status: "aligned",
               method: "audio",
               moviehash: moviehash!(video),
               source_sha256: digest(original),
               applied_sha256: digest(corrected),
               offset_ms: 1_000,
               rate: 1.0,
               score: 30.0,
               reason: nil
             })

    expect(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video -> {:ok, []} end)

    expect(Cinder.Subtitles.Sync.EngineMock, :sync, fn _reference, input, output ->
      assert File.read!(input) == original
      File.write!(output, original)
      {:ok, %{score: 30.0, offset_ms: 0, rate: 1.0}}
    end)

    assert [%{method: "audio", status: :aligned}] = Sync.analyze_video(video)
    assert File.read!(path) == original

    assert %{method: "audio", status: "aligned", version: 2} =
             Manifest.sync(Manifest.read(video), "en")
  end

  test "reactivates a verified legacy mergerfs backup and rebinds its identity", %{
    video: video,
    tmp_dir: tmp
  } do
    path = managed_srt!(video)
    original = File.read!(path)
    [item] = Sync.discover(video)
    assert {:ok, :corrected, _} = Sync.manual(item, 1_000, 1.0)
    assert :ok = Sync.reset(hd(Sync.discover(video)))

    backup = Sync.backup_path(path)
    legacy_identity = [38, 0, 123_456]
    assert :ok = Manifest.put_backup_tombstone(video, "en", legacy_identity)
    helper = legacy_identity_helper!(tmp, Path.basename(backup), legacy_identity)
    Application.put_env(:cinder, :rooted_filesystem_helper, helper)

    assert {:ok, :corrected, _} = Sync.manual(hd(Sync.discover(video)), 2_000, 1.0)
    assert File.read!(backup) == original

    assert {:ok, bound} = Disk.open_bound(backup, [:read, :raw, :binary])
    assert %{identity: identity} = Manifest.backup_tombstone(Manifest.read(video), "en")
    assert identity == Tuple.to_list(bound.identity)
    assert :ok = Disk.close_bound(bound)
  end

  test "reconciles duplicate mergerfs backup tombstones and completes reanalysis", %{
    video: video,
    tmp_dir: tmp
  } do
    %{path: path, backup: backup, duplicate: duplicate, original: original} =
      duplicate_tombstones!(video, tmp)

    assert {:ok, :corrected, _} = Sync.manual(hd(Sync.discover(video)), 2_000, 1.0)

    assert File.read!(backup) == original
    refute File.exists?(duplicate)
    refute File.read!(path) == original

    assert {:ok, bound} = Disk.open_bound(backup, [:read, :raw, :binary])
    assert %{identity: identity} = Manifest.backup_tombstone(Manifest.read(video), "en")
    assert identity == Tuple.to_list(bound.identity)
    assert :ok = Disk.close_bound(bound)
  end

  test "reconciles duplicate tombstones recorded with a legacy mergerfs identity", %{
    video: video,
    tmp_dir: tmp
  } do
    legacy_identity = [38, 0, 123_456]

    %{path: path, backup: backup, duplicate: duplicate, original: original} =
      duplicate_tombstones!(video, tmp, legacy_identity: legacy_identity)

    assert %{identity: ^legacy_identity} =
             Manifest.backup_tombstone(Manifest.read(video), "en")

    assert {:ok, :corrected, _} = Sync.manual(hd(Sync.discover(video)), 2_000, 1.0)

    assert File.read!(backup) == original
    refute File.exists?(duplicate)
    refute File.read!(path) == original

    assert {:ok, bound} = Disk.open_bound(backup, [:read, :raw, :binary])
    assert %{identity: identity} = Manifest.backup_tombstone(Manifest.read(video), "en")
    assert identity == Tuple.to_list(bound.identity)
    assert :ok = Disk.close_bound(bound)
  end

  test "legacy reconciliation refuses backing paths that alias one physical file", %{
    video: video,
    tmp_dir: tmp
  } do
    legacy_identity = [38, 0, 123_456]

    %{backup: backup, duplicate: duplicate} =
      duplicate_tombstones!(video, tmp,
        legacy_identity: legacy_identity,
        alias_identity: true
      )

    assert {:error, :estale} = Sync.manual(hd(Sync.discover(video)), 2_000, 1.0)
    assert File.exists?(backup)
    assert File.exists?(duplicate)
  end

  test "a nonzero duplicate mergerfs backup container stays fail-closed", %{
    video: video,
    tmp_dir: tmp
  } do
    %{path: path, backup: backup, duplicate: duplicate} = duplicate_tombstones!(video, tmp)

    File.write!(duplicate, "unrelated payload")
    current = File.read!(path)

    assert {:error, :enotempty} = Sync.manual(hd(Sync.discover(video)), 2_000, 1.0)

    assert File.read!(duplicate) == "unrelated payload"
    assert File.read!(backup) == ""
    assert File.read!(path) == current
    assert Manifest.sync(Manifest.read(video), "en") == nil
  end

  test "duplicate mergerfs containers without a manifest tombstone stay fail-closed", %{
    video: video,
    tmp_dir: tmp
  } do
    %{path: path, backup: backup, duplicate: duplicate} = duplicate_tombstones!(video, tmp)

    assert :ok = Manifest.clear_backup_tombstone(video, "en")
    current = File.read!(path)

    # Without a recorded tombstone nothing proves the duplicates are ours, so
    # the original post-effect EEXIST surfaces unchanged instead of a new atom.
    assert {:error, {:effect_committed, "hold", %{"reason" => "EEXIST"}}} =
             Sync.manual(hd(Sync.discover(video)), 2_000, 1.0)

    assert File.exists?(duplicate)
    assert File.read!(backup) == ""
    assert File.read!(path) == current
    assert Manifest.sync(Manifest.read(video), "en") == nil
  end

  test "reset retry reconciles a workspace orphaned after exchange", %{video: video} do
    path = managed_srt!(video)
    original = File.read!(path)
    [item] = Sync.discover(video)
    assert {:ok, :corrected, _} = Sync.manual(item, 1_000, 1.0)
    [item] = Sync.discover(video)
    Application.put_env(:cinder, :filesystem, Cinder.Test.BarrierFilesystem)

    Application.put_env(:cinder, :filesystem_barrier, %{
      owner: self(),
      operation: :exchange,
      contains: ".cinder-subtitle-sync-write-",
      once: true
    })

    {:ok, task} = Task.start(fn -> Sync.reset(item) end)
    monitor = Process.monitor(task)
    assert_receive {:filesystem_barrier, ^task, _ref, :exchange, staged_path}, 5_000
    workspace = Path.dirname(staged_path)
    assert File.read!(path) == original
    assert File.dir?(workspace)

    Process.exit(task, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^task, :killed}

    assert :ok = Sync.reset(item)
    assert File.read!(path) == original
    assert File.dir?(workspace)
    assert File.read!(Sync.backup_path(path)) == ""
    assert Manifest.sync(Manifest.read(video), "en") == nil
  end

  test "analysis completes reset cleanup after backup retirement committed before metadata clear",
       %{
         video: video
       } do
    path = managed_srt!(video)
    original = File.read!(path)
    [item] = Sync.discover(video)
    assert {:ok, :corrected, _} = Sync.manual(item, 1_000, 1.0)
    backup = Sync.backup_path(path)
    [item] = Sync.discover(video)
    Application.put_env(:cinder, :filesystem, Cinder.Test.BarrierFilesystem)

    Application.put_env(:cinder, :filesystem_barrier, %{
      owner: self(),
      operation: :discard_bound,
      contains: backup,
      once: true
    })

    {:ok, task} = Task.start(fn -> Sync.reset(item) end)
    monitor = Process.monitor(task)
    assert_receive {:filesystem_barrier, ^task, _ref, :discard_bound, ^backup}, 5_000
    assert File.read!(path) == original
    assert File.read!(backup) == ""
    assert Manifest.sync(Manifest.read(video), "en") != nil
    assert Manifest.reset_cleanup_sync(Manifest.read(video), "en") != nil

    Process.exit(task, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^task, :killed}

    stub(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video -> {:ok, []} end)

    expect(Cinder.Subtitles.Sync.EngineMock, :sync, fn _reference, _input, _output ->
      {:review, %{reason: :low_confidence, score: 1.0, offset_ms: 0, rate: 1.0}}
    end)

    assert [%{status: :review}] = Sync.analyze_video(video)
    assert File.read!(path) == original
    assert File.read!(backup) == ""
    assert Manifest.reset_cleanup_sync(Manifest.read(video), "en") == nil
    assert %{status: "review"} = Manifest.sync(Manifest.read(video), "en")
  end

  test "analysis finishes a reset whose bytes committed before metadata was cleared", %{
    video: video
  } do
    path = managed_srt!(video)
    original = File.read!(path)
    [item] = Sync.discover(video)
    assert {:ok, :corrected, _} = Sync.manual(item, 1_000, 1.0)
    corrected = File.read!(path)
    File.chmod!(path, 0o600)
    assert :ok = AtomicFile.write(path, original, corrected)
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o644

    assert Manifest.sync(Manifest.read(video), "en").source_sha256 !=
             Manifest.sync(Manifest.read(video), "en").applied_sha256

    stub(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video -> {:ok, []} end)

    expect(Cinder.Subtitles.Sync.EngineMock, :sync, fn _reference, _input, _output ->
      {:review, %{reason: :low_confidence, score: 1.0, offset_ms: 0, rate: 1.0}}
    end)

    assert [%{status: :review}] = Sync.analyze_video(video)
    assert File.read!(path) == original
    assert File.read!(Sync.backup_path(path)) == ""

    assert %{status: "review", source_sha256: digest, applied_sha256: digest} =
             Manifest.sync(Manifest.read(video), "en")
  end

  test "reset never claims a matching reserved file after an aligned no-op", %{video: video} do
    path = managed_srt!(video)
    original = File.read!(path)
    stub(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video -> {:ok, []} end)

    expect(Cinder.Subtitles.Sync.EngineMock, :sync, fn _reference, _input, output ->
      File.write!(output, original)
      {:ok, %{score: 30.0, offset_ms: 0, rate: 1.0}}
    end)

    assert [%{status: :aligned}] = Sync.analyze_video(video)
    backup = Sync.backup_path(path)
    File.write!(backup, original)
    [item] = Sync.discover(video)

    assert {:error, :unexpected_backup} = Sync.reset(item)
    assert {:error, :unexpected_backup} = Sync.manual(item, 1_000, 1.0)
    assert File.read!(path) == original
    assert File.read!(backup) == original
    assert Manifest.sync(Manifest.read(video), "en") != nil
  end

  test "publishes an applying manifest state before exchanging corrected sidecar bytes", %{
    video: video
  } do
    path = managed_srt!(video)
    [item] = Sync.discover(video)
    Application.put_env(:cinder, :filesystem, Cinder.Test.BarrierFilesystem)

    Application.put_env(:cinder, :filesystem_barrier, %{
      owner: self(),
      operation: :exchange,
      contains: ".cinder-subtitle-sync-write-",
      once: true
    })

    task = Task.async(fn -> Sync.manual(item, 1_000, 1.0) end)
    assert_receive {:filesystem_barrier, pid, ref, :exchange, _temporary}, 5_000

    assert %{status: "applying"} = Manifest.sync(Manifest.read(video), "en")
    assert File.read!(Sync.backup_path(path)) == subtitle(".srt")

    send(pid, {ref, :continue})
    assert {:ok, :corrected, _} = Task.await(task)
    assert %{status: "aligned"} = Manifest.sync(Manifest.read(video), "en")
  end

  test "recovers an exchanged correction left in applying state without deleting its backup", %{
    video: video
  } do
    path = managed_srt!(video)
    [item] = Sync.discover(video)
    original = File.read!(path)
    assert {:ok, :corrected, _} = Sync.manual(item, 1_000, 1.0)
    corrected = File.read!(path)
    backup = Sync.backup_path(path)
    metadata = Manifest.sync(Manifest.read(video), "en")

    pending =
      metadata
      |> Map.put(:status, "applying")
      |> Map.put(:expected_sha256, digest(original))
      |> Map.put(:operation_id, String.duplicate("a", 22))

    assert :ok = Manifest.put_sync(video, "en", pending)
    stub(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video -> {:ok, []} end)

    assert [%{status: :aligned}] = Sync.analyze_video(video)
    assert File.read!(path) == corrected
    assert File.read!(backup) == original
    assert %{status: "aligned"} = Manifest.sync(Manifest.read(video), "en")
  end

  test "replays a pre-exchange manual applying state from the immutable source", %{video: video} do
    path = managed_srt!(video)
    [item] = Sync.discover(video)
    original = File.read!(path)
    assert {:ok, :corrected, _} = Sync.manual(item, 1_000, 1.0)
    backup = Sync.backup_path(path)
    metadata = Manifest.sync(Manifest.read(video), "en")

    pending =
      metadata
      |> Map.put(:status, "applying")
      |> Map.put(:expected_sha256, digest(original))
      |> Map.put(:operation_id, String.duplicate("a", 22))

    assert :ok = Manifest.put_sync(video, "en", pending)
    File.write!(path, original)
    stub(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video -> {:ok, []} end)

    assert [%{status: :aligned}] = Sync.analyze_video(video)
    assert File.read!(path) =~ "00:00:02,000"
    assert File.read!(backup) == original
    assert %{status: "aligned"} = Manifest.sync(Manifest.read(video), "en")
  end

  test "recovers a second manual correction interrupted before exchange", %{video: video} do
    path = managed_srt!(video)
    [item] = Sync.discover(video)
    assert {:ok, :corrected, _} = Sync.manual(item, 1_000, 1.0)
    previous = File.read!(path)
    [item] = Sync.discover(video)
    Application.put_env(:cinder, :filesystem, Cinder.Test.BarrierFilesystem)

    Application.put_env(:cinder, :filesystem_barrier, %{
      owner: self(),
      operation: :exchange,
      phase: :before,
      contains: ".cinder-subtitle-sync-write-",
      once: true
    })

    {:ok, task} = Task.start(fn -> Sync.manual(item, 2_000, 1.0) end)
    assert_receive {:filesystem_barrier, ^task, _ref, :exchange, _temporary}, 5_000
    monitor = Process.monitor(task)
    Process.exit(task, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^task, :killed}
    assert File.read!(path) == previous
    assert %{status: "applying"} = Manifest.sync(Manifest.read(video), "en")
    stub(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video -> {:ok, []} end)

    assert [%{status: :aligned}] = Sync.analyze_video(video)
    assert File.read!(path) =~ "00:00:03,000"
    assert %{status: "aligned"} = Manifest.sync(Manifest.read(video), "en")
  end

  test "recovery retires the staged file orphaned before exchange", %{video: video} do
    _path = managed_srt!(video)
    [item] = Sync.discover(video)
    Application.put_env(:cinder, :filesystem, Cinder.Test.BarrierFilesystem)

    Application.put_env(:cinder, :filesystem_barrier, %{
      owner: self(),
      operation: :exchange,
      phase: :before,
      contains: ".cinder-subtitle-sync-write-",
      once: true
    })

    {:ok, task} = Task.start(fn -> Sync.manual(item, 1_000, 1.0) end)
    assert_receive {:filesystem_barrier, ^task, _ref, :exchange, temporary}, 5_000
    workspace = Path.dirname(temporary)
    assert File.dir?(workspace)
    monitor = Process.monitor(task)
    Process.exit(task, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^task, :killed}
    assert File.dir?(workspace)

    stub(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video -> {:ok, []} end)
    assert [%{status: :aligned}] = Sync.analyze_video(video)
    assert File.read!(Path.join(workspace, ".cinder-subtitle-sync-write-staged")) == ""
  end

  test "recovery finalizes publication with an empty applying workspace", %{
    video: video
  } do
    path = managed_srt!(video)
    [item] = Sync.discover(video)
    Application.put_env(:cinder, :filesystem, Cinder.Test.BarrierFilesystem)

    Application.put_env(:cinder, :filesystem_barrier, %{
      owner: self(),
      operation: :discard_bound,
      contains: Path.basename(path),
      once: true
    })

    {:ok, task} = Task.start(fn -> Sync.manual(item, 1_000, 1.0) end)
    monitor = Process.monitor(task)
    assert_receive {:filesystem_barrier, ^task, _ref, :discard_bound, ^path}, 5_000

    [workspace] =
      Path.wildcard(Path.join(Path.dirname(path), ".cinder-subtitle-sync-cas-*"), match_dot: true)

    staged_path = Path.join(workspace, ".cinder-subtitle-sync-write-staged")
    assert File.read!(staged_path) == ""
    assert File.dir?(workspace)
    assert File.read!(path) =~ "00:00:02,000"
    assert %{status: "applying"} = Manifest.sync(Manifest.read(video), "en")

    Process.exit(task, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^task, :killed}

    stub(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video -> {:ok, []} end)
    assert [%{status: :aligned}] = Sync.analyze_video(video)
    assert File.dir?(workspace)
    assert %{status: "aligned"} = Manifest.sync(Manifest.read(video), "en")
  end

  test "unknown rooted mkdir outcome never grants cleanup ownership", %{
    video: video,
    tmp_dir: tmp
  } do
    path = managed_srt!(video)
    original = File.read!(path)
    operation_id = String.duplicate("u", 22)
    workspace = Path.join(Path.dirname(path), ".cinder-subtitle-sync-cas-#{operation_id}")
    staged = Path.join(workspace, ".cinder-subtitle-sync-write-staged")
    helper = Path.join(tmp, "unknown-mkdir.py")
    real_helper = Path.join(File.cwd!(), "priv/rooted_fs.py")

    File.write!(
      helper,
      """
      import os
      import sys

      if sys.argv[1] not in ("mkdir", "mkdir_near"):
          os.execv(sys.executable, [sys.executable, #{inspect(real_helper)}] + sys.argv[1:])

      directory = os.path.join(sys.argv[2], sys.argv[3])
      os.mkdir(directory, 0o700)
      with open(os.path.join(directory, ".cinder-subtitle-sync-write-staged"), "wb") as output:
          output.write(b"attacker-owned")
      sys.stdout.write("malformed helper response\\n")
      """
    )

    Application.put_env(:cinder, :rooted_filesystem_helper, helper)

    assert {:error, {:effect_committed, "mkdir_near", _reason}} =
             AtomicFile.write(path, shifted_subtitle(original), original, operation_id)

    assert File.read!(staged) == "attacker-owned"
    assert File.dir?(workspace)
  end

  test "recovery validates a staged pathname without deleting it", %{video: video} do
    path = managed_srt!(video)
    original = File.read!(path)
    applied = shifted_subtitle(original)
    operation_id = String.duplicate("i", 22)
    workspace = Path.join(Path.dirname(path), ".cinder-subtitle-sync-cas-#{operation_id}")
    staged = Path.join(workspace, ".cinder-subtitle-sync-write-staged")
    File.mkdir!(workspace)
    File.chmod!(workspace, 0o700)
    File.write!(staged, applied)
    assert :ok = AtomicFile.cleanup_pending(path, operation_id, digest(original), digest(applied))
    assert File.read!(staged) == applied
    assert File.dir?(workspace)
  end

  test "committed cleanup leaves an empty workspace tombstone", %{video: video} do
    path = managed_srt!(video)
    [item] = Sync.discover(video)
    assert {:ok, :corrected, _item} = Sync.manual(item, 1_000, 1.0)

    [workspace] =
      Path.wildcard(Path.join(Path.dirname(path), ".cinder-subtitle-sync-cas-*"), match_dot: true)

    assert File.read!(Path.join(workspace, ".cinder-subtitle-sync-write-staged")) == ""
    assert File.read!(path) =~ "00:00:02,000"
  end

  test "an exact no-op records alignment without rewriting or creating a backup", %{video: video} do
    path = managed_srt!(video)
    [item] = Sync.discover(video)
    before = File.stat!(path).mtime

    assert {:ok, :aligned, _} = Sync.manual(item, 0, 1.0)
    assert File.read!(path) == subtitle(".srt")
    assert File.stat!(path).mtime == before
    refute File.exists?(Sync.backup_path(path))
  end

  test "no-op manual correction rejects a video changed after moviehash lookup", %{video: video} do
    path = managed_srt!(video)
    [item] = Sync.discover(video)
    original = File.read!(path)
    Application.put_env(:cinder, :filesystem, Cinder.Test.BarrierFilesystem)

    Application.put_env(:cinder, :filesystem_barrier, %{
      owner: self(),
      operation: :moviehash_data,
      contains: Path.basename(video),
      once: true
    })

    task = Task.async(fn -> Sync.manual(item, 0, 1.0) end)
    assert_receive {:filesystem_barrier, pid, ref, :moviehash_data, ^video}, 5_000
    File.write!(video, "x" <> String.duplicate("v", 131_071))
    send(pid, {ref, :continue})

    assert {:error, :video_changed} = Task.await(task)
    assert File.read!(path) == original
    assert Manifest.sync(Manifest.read(video), "en") == nil
  end

  test "manual timestamp anchors apply the same affine correction", %{video: video} do
    path = managed_srt!(video)
    [item] = Sync.discover(video)

    assert {:ok, :corrected, _} =
             Sync.manual_from_anchors(item, [{1_000, 2_000}, {3_000, 6_000}])

    assert File.read!(path) =~ "00:00:02,000 --> 00:00:04,000"
  end

  test "selects the broadest same-language embedded reference then falls back to audio", %{
    video: video
  } do
    path = managed_srt!(video)
    parent = self()

    expect(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video ->
      {:ok,
       [
         %{index: 2, language: "en", forced?: false, default?: true, packet_count: 4},
         %{index: 3, language: "fr", forced?: false, default?: false, packet_count: 20},
         %{index: 4, language: "es", forced?: true, default?: false, packet_count: 50}
       ]}
    end)

    expect(Cinder.Library.MediaInfoMock, :extract_subtitle, fn ^video, 2 ->
      {:ok, subtitle(".srt")}
    end)

    expect(Cinder.Subtitles.Sync.EngineMock, :sync, 2, fn reference, input, output ->
      assert File.read!(input) == subtitle(".srt")
      reference_content = File.read!(reference)
      send(parent, {:reference, reference_content})

      if reference_content == File.read!(video) do
        File.write!(output, shifted_subtitle(subtitle(".srt")))
        {:ok, %{score: 30.0, offset_ms: 1_000, rate: 1.0}}
      else
        File.write!(output, subtitle(".srt"))
        {:review, %{reason: :low_confidence, score: 1.0, offset_ms: 0, rate: 1.0}}
      end
    end)

    assert [%{status: :corrected}] = Sync.analyze_video(video)
    assert_receive {:reference, embedded}
    assert embedded == subtitle(".srt")
    assert_receive {:reference, audio}
    assert audio == File.read!(video)
    assert Path.wildcard(Path.join(Path.dirname(video), ".cinder-subtitle-reference-*")) == []
    assert File.read!(path) =~ "00:00:02,000"
    assert %{method: "audio", status: "aligned"} = Manifest.sync(Manifest.read(video), "en")
  end

  test "uses audio when embedded tracks do not match the sidecar language", %{video: video} do
    path = managed_srt!(video, "fr")
    original = File.read!(path)

    expect(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video ->
      {:ok, [%{index: 2, language: "en", forced?: false, default?: true, packet_count: 20}]}
    end)

    expect(Cinder.Subtitles.Sync.EngineMock, :sync, fn reference, input, output ->
      assert File.read!(reference) == File.read!(video)
      assert File.read!(input) == original
      File.write!(output, original)
      {:review, %{reason: :low_confidence, score: 1.0, offset_ms: 0, rate: 1.0}}
    end)

    assert [%{method: "audio", status: :review}] = Sync.analyze_video(video)
    assert File.read!(path) == original
  end

  test "restores legacy embedded corrections before language-matched reanalysis", %{video: video} do
    path = managed_srt!(video, "fr")
    original = File.read!(path)
    corrected = shifted_subtitle(original)
    backup = owned_backup!(video, path, original, "fr")
    File.write!(path, corrected)

    assert :ok =
             Manifest.put_sync(video, "fr", %{
               status: "aligned",
               method: "embedded",
               moviehash: "stale-moviehash",
               source_sha256: digest(original),
               applied_sha256: digest(corrected),
               offset_ms: 1_000,
               rate: 1.0,
               score: 30.0,
               reason: nil
             })

    expect(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video ->
      {:ok, [%{index: 2, language: "en", forced?: false, default?: true, packet_count: 20}]}
    end)

    expect(Cinder.Subtitles.Sync.EngineMock, :sync, fn reference, input, output ->
      assert File.read!(reference) == File.read!(video)
      assert File.read!(input) == original
      File.write!(output, original)
      {:review, %{reason: :low_confidence, score: 1.0, offset_ms: 0, rate: 1.0}}
    end)

    assert [%{method: "audio", status: :review}] = Sync.analyze_video(video)
    assert File.read!(path) == original
    assert File.read!(backup) == ""
    assert %{method: "audio", status: "review"} = Manifest.sync(Manifest.read(video), "fr")
  end

  test "tries the next same-language track when the broadest one cannot be extracted", %{
    video: video
  } do
    _path = managed_srt!(video)
    parent = self()

    expect(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video ->
      {:ok,
       [
         %{index: 2, language: "en", forced?: false, default?: true, packet_count: 30},
         %{index: 3, language: "en", forced?: false, default?: false, packet_count: 20}
       ]}
    end)

    expect(Cinder.Library.MediaInfoMock, :extract_subtitle, 2, fn
      ^video, 2 -> {:error, :cannot_decode}
      ^video, 3 -> {:ok, subtitle(".srt")}
    end)

    expect(Cinder.Subtitles.Sync.EngineMock, :sync, fn reference, input, output ->
      assert File.read!(input) == subtitle(".srt")
      send(parent, {:reference, File.read!(reference)})
      File.write!(output, shifted_subtitle(subtitle(".srt")))
      {:ok, %{score: 30.0, offset_ms: 1_000, rate: 1.0}}
    end)

    assert [%{status: :corrected}] = Sync.analyze_video(video)
    assert_receive {:reference, reference}
    assert reference == subtitle(".srt")
  end

  test "low-confidence audio leaves bytes unchanged and marks operator review", %{video: video} do
    path = managed_srt!(video)
    original = File.read!(path)
    stub(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video -> {:ok, []} end)

    expect(Cinder.Subtitles.Sync.EngineMock, :sync, fn reference, input, output ->
      assert File.read!(reference) == File.read!(video)
      assert File.read!(input) == original
      File.write!(output, original)
      {:review, %{reason: :low_confidence, score: 1.0, offset_ms: 0, rate: 1.0}}
    end)

    assert [%{status: :review}] = Sync.analyze_video(video)
    assert File.read!(path) == original
    refute File.exists?(Sync.backup_path(path))

    assert %{status: "review", reason: "low_confidence"} =
             Manifest.sync(Manifest.read(video), "en")
  end

  test "an unchanged review result is not analyzed again", %{video: video} do
    _path = managed_srt!(video)
    expect(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video -> {:ok, []} end)

    expect(Cinder.Subtitles.Sync.EngineMock, :sync, fn _reference, input, output ->
      source = File.read!(input)
      File.write!(output, source)
      {:review, %{reason: :low_confidence, score: 1.0, offset_ms: 0, rate: 1.0}}
    end)

    assert [%{status: :review, reason: "low_confidence"}] = Sync.analyze_video(video)
    assert [%{status: :review, reason: "low_confidence"}] = Sync.analyze_video(video)
  end

  test "a changed moviehash restores the immutable original and analyzes afresh", %{video: video} do
    path = managed_srt!(video)
    original = File.read!(path)
    [item] = Sync.discover(video)
    assert {:ok, :corrected, _} = Sync.manual(item, 1_000, 1.0)
    assert File.read!(path) != original

    File.write!(video, "x" <> String.duplicate("v", 131_071))
    stub(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video -> {:ok, []} end)

    expect(Cinder.Subtitles.Sync.EngineMock, :sync, fn reference, input, output ->
      assert File.read!(reference) == File.read!(video)
      assert File.read!(input) == original
      assert File.read!(path) == original
      File.write!(output, original)
      {:ok, %{score: 30.0, offset_ms: 0, rate: 1.0}}
    end)

    assert [%{status: :aligned}] = Sync.analyze_video(video)
    assert File.read!(path) == original
    assert File.read!(Sync.backup_path(path)) == ""
  end

  test "replacement backup cleanup provenance survives failure and is retried", %{video: video} do
    path = managed_srt!(video)
    [item] = Sync.discover(video)
    assert {:ok, :corrected, _} = Sync.manual(item, 1_000, 1.0)
    previous_sync = Manifest.sync(Manifest.read(video), "en")
    backup = Sync.backup_path(path)
    replacement = String.replace(subtitle(".srt"), "One", "Replacement")
    File.write!(path, replacement)

    assert :ok =
             Manifest.put(
               video,
               moviehash!(video),
               "en",
               "opensubtitles_hash",
               path,
               digest(replacement),
               previous_sync
             )

    Application.put_env(:cinder, :filesystem, Cinder.Test.BarrierFilesystem)

    Application.put_env(:cinder, :filesystem_failure, %{
      operation: :discard_bound,
      source_contains: Path.basename(backup),
      reason: :eio,
      once: true
    })

    assert [%{status: :failed, reason: {:replacement_cleanup_failed, :eio}}] =
             Sync.analyze_video(video)

    assert File.exists?(backup)

    assert Manifest.replacement_cleanup_sync(Manifest.read(video), "en") == previous_sync

    stub(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video -> {:ok, []} end)

    expect(Cinder.Subtitles.Sync.EngineMock, :sync, fn _reference, _input, output ->
      File.write!(output, replacement)
      {:ok, %{score: 30.0, offset_ms: 0, rate: 1.0}}
    end)

    assert [%{status: :aligned}] = Sync.analyze_video(video)
    assert File.read!(backup) == ""
    assert Manifest.replacement_cleanup_sync(Manifest.read(video), "en") == nil
  end

  test "video replacement rejects a mismatched immutable backup", %{video: video} do
    path = managed_srt!(video)
    [item] = Sync.discover(video)
    assert {:ok, :corrected, _} = Sync.manual(item, 1_000, 1.0)
    corrected = File.read!(path)
    metadata = Manifest.sync(Manifest.read(video), "en")
    backup = Sync.backup_path(path)
    File.write!(backup, String.replace(subtitle(".srt"), "One", "Wrong"))
    File.write!(video, "x" <> String.duplicate("v", 131_071))
    stub(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video -> {:ok, []} end)

    assert [%{status: :review, reason: "replacement_cleanup_failed"}] =
             Sync.analyze_video(video)

    assert File.read!(path) == corrected
    assert File.exists?(backup)

    assert %{status: "review", reason: "replacement_cleanup_failed"} =
             updated =
             Manifest.sync(Manifest.read(video), "en")

    assert updated.source_sha256 == metadata.source_sha256
    assert updated.applied_sha256 == metadata.applied_sha256
    assert updated.moviehash == metadata.moviehash
  end

  test "moviehash read failure blocks analysis without cleanup or metadata mutation", %{
    video: video
  } do
    path = managed_srt!(video)
    [item] = Sync.discover(video)
    original = File.read!(path)
    assert {:ok, :corrected, _} = Sync.manual(item, 1_000, 1.0)
    corrected = File.read!(path)
    backup = Sync.backup_path(path)
    metadata = Manifest.sync(Manifest.read(video), "en")

    Application.put_env(:cinder, :filesystem, Cinder.Test.BarrierFilesystem)

    Application.put_env(:cinder, :filesystem_failure, %{
      operation: :moviehash_data,
      source_contains: Path.basename(video),
      reason: :eio,
      once: true
    })

    assert [%{status: :review, reason: "moviehash_unavailable"}] = Sync.analyze_video(video)
    assert File.read!(path) == corrected
    assert File.read!(backup) == original
    assert Manifest.sync(Manifest.read(video), "en") == metadata
  end

  test "a too-small video also preserves synchronization state", %{video: video} do
    path = managed_srt!(video)
    [item] = Sync.discover(video)
    assert {:ok, :corrected, _} = Sync.manual(item, 1_000, 1.0)
    corrected = File.read!(path)
    backup = Sync.backup_path(path)
    metadata = Manifest.sync(Manifest.read(video), "en")
    File.write!(video, "short")

    assert [%{status: :review, reason: "moviehash_unavailable"}] = Sync.analyze_video(video)
    assert File.read!(path) == corrected
    assert File.exists?(backup)
    assert Manifest.sync(Manifest.read(video), "en") == metadata
  end

  test "reset with a missing backup errors and retains corrected bytes and sync metadata", %{
    video: video
  } do
    path = managed_srt!(video)
    [item] = Sync.discover(video)
    assert {:ok, :corrected, _} = Sync.manual(item, 1_000, 1.0)
    corrected = File.read!(path)
    metadata = Manifest.sync(Manifest.read(video), "en")
    File.rm!(Sync.backup_path(path))

    [item] = Sync.discover(video)
    assert {:error, :missing_backup} = Sync.reset(item)
    assert File.read!(path) == corrected
    assert Manifest.sync(Manifest.read(video), "en") == metadata
  end

  test "reset with a mismatched backup fails closed", %{video: video} do
    path = managed_srt!(video)
    [item] = Sync.discover(video)
    assert {:ok, :corrected, _} = Sync.manual(item, 1_000, 1.0)
    corrected = File.read!(path)
    metadata = Manifest.sync(Manifest.read(video), "en")
    File.write!(Sync.backup_path(path), String.replace(subtitle(".srt"), "One", "Wrong"))

    [item] = Sync.discover(video)
    assert {:error, :backup_mismatch} = Sync.reset(item)
    assert File.read!(path) == corrected
    assert Manifest.sync(Manifest.read(video), "en") == metadata
  end

  test "reset rejects a newer external edit", %{video: video} do
    path = managed_srt!(video)
    [item] = Sync.discover(video)
    assert {:ok, :corrected, _} = Sync.manual(item, 1_000, 1.0)
    metadata = Manifest.sync(Manifest.read(video), "en")
    external = String.replace(subtitle(".srt"), "One", "External edit")
    File.write!(path, external)

    [item] = Sync.discover(video)
    assert {:error, :externally_modified} = Sync.reset(item)
    assert File.read!(path) == external
    assert File.exists?(Sync.backup_path(path))
    assert Manifest.sync(Manifest.read(video), "en") == metadata
  end

  test "engine path binding rejects a sidecar swapped to an external symlink", %{
    video: video,
    tmp_dir: tmp
  } do
    path = managed_srt!(video)
    outside = Path.join(tmp, "outside.srt")
    File.write!(outside, subtitle(".srt"))
    Application.put_env(:cinder, :filesystem, Cinder.Test.BarrierFilesystem)

    Application.put_env(:cinder, :filesystem_barrier, %{
      owner: self(),
      operation: :open_bound,
      phase: :before,
      contains: Path.basename(path),
      once: true
    })

    stub(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video -> {:ok, []} end)
    task = Task.async(fn -> Sync.analyze_video(video) end)

    assert_receive {:filesystem_barrier, pid, ref, :open_bound, ^path}, 5_000
    File.rm!(path)
    File.ln_s!(outside, path)
    send(pid, {ref, :continue})

    assert [%{status: :failed}] = Task.await(task)
    assert File.read!(outside) == subtitle(".srt")
    refute File.exists?(Sync.backup_path(path))

    refute Enum.any?(File.ls!(Path.dirname(path)), fn name ->
             String.starts_with?(name, ".cinder-subtitle-sync-")
           end)
  end

  test "engine input close failure after completed analysis preserves the result", %{video: video} do
    path = managed_srt!(video)
    original = File.read!(path)
    Application.put_env(:cinder, :filesystem, Cinder.Test.BarrierFilesystem)

    Application.put_env(:cinder, :filesystem_failure, %{
      operation: :close_bound,
      source_contains: Path.basename(path),
      reason: :eio,
      once: true
    })

    stub(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video -> {:ok, []} end)

    expect(Cinder.Subtitles.Sync.EngineMock, :sync, fn _reference, _input, output ->
      File.write!(output, original)
      {:ok, %{score: 30.0, offset_ms: 0, rate: 1.0}}
    end)

    assert [%{status: :aligned}] = Sync.analyze_video(video)

    assert File.read!(path) == original
    assert %{status: "aligned"} = Manifest.sync(Manifest.read(video), "en")
  end

  test "review results never adopt sidecar bytes changed during engine execution", %{video: video} do
    path = managed_srt!(video)
    original = File.read!(path)
    external = String.replace(original, "One", "External edit")
    stub(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video -> {:ok, []} end)

    expect(Cinder.Subtitles.Sync.EngineMock, :sync, fn _reference, _input, _output ->
      File.write!(path, external)
      {:review, %{reason: :low_confidence, score: 1.0, offset_ms: 0, rate: 1.0}}
    end)

    assert [%{status: :failed, reason: :concurrent_change}] = Sync.analyze_video(video)
    assert File.read!(path) == external
    assert Manifest.sync(Manifest.read(video), "en") == nil
  end

  test "a video changed during engine execution cannot publish old-moviehash timing", %{
    video: video
  } do
    path = managed_srt!(video)
    original = File.read!(path)
    stub(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video -> {:ok, []} end)

    expect(Cinder.Subtitles.Sync.EngineMock, :sync, fn _reference, _input, output ->
      File.write!(output, shifted_subtitle(original))
      File.write!(video, "x" <> String.duplicate("v", 131_071))
      {:ok, %{score: 30.0, offset_ms: 1_000, rate: 1.0}}
    end)

    assert [%{status: :failed, reason: :video_changed}] = Sync.analyze_video(video)
    assert File.read!(path) == original
    refute File.exists?(Sync.backup_path(path))
    assert Manifest.sync(Manifest.read(video), "en") == nil
  end

  test "same-name replacement before first analysis is review-only", %{video: video} do
    path = managed_srt!(video)
    external = String.replace(subtitle(".srt"), "One", "External edit")
    File.write!(path, external)

    assert [%{status: :review, reason: "externally_modified"}] = Sync.analyze_video(video)
    assert File.read!(path) == external
    refute File.exists?(Sync.backup_path(path))
  end

  test "legacy managed tracks without an acquisition digest are not rewrite-eligible", %{
    video: video
  } do
    path = sidecar(video, "en", ".srt")
    File.write!(path, subtitle(".srt"))
    assert :ok = Manifest.put(video, moviehash!(video), "en", "opensubtitles_hash", path)
    assert Sync.discover(video) == []
  end

  test "engine analysis uses anonymous files and leaves shared temp paths alone", %{video: video} do
    _path = managed_srt!(video)
    workspace_id = "eexist-#{System.unique_integer([:positive])}"
    workspace = Path.join(System.tmp_dir!(), ".cinder-subtitle-engine-#{workspace_id}")
    File.mkdir!(workspace)
    on_exit(fn -> File.rmdir(workspace) end)
    stub(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video -> {:ok, []} end)

    expect(Cinder.Subtitles.Sync.EngineMock, :sync, fn reference, input, output ->
      assert String.starts_with?(reference, "/proc/")
      assert String.starts_with?(input, "/proc/")
      assert String.starts_with?(output, "/proc/")
      {:review, %{reason: :low_confidence, score: 1.0, offset_ms: 0, rate: 1.0}}
    end)

    assert [%{status: :review}] = Sync.analyze_video(video)
    assert File.dir?(workspace)
  end

  test "malformed successful engine output is never published", %{video: video} do
    path = managed_srt!(video)
    original = File.read!(path)
    stub(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video -> {:ok, []} end)

    expect(Cinder.Subtitles.Sync.EngineMock, :sync, fn _reference, _input, output ->
      File.write!(output, "not a complete subtitle\n")
      {:ok, %{score: 30.0, offset_ms: 1_000, rate: 1.0}}
    end)

    assert [%{status: :failed, reason: :invalid_engine_output}] = Sync.analyze_video(video)
    assert File.read!(path) == original
    refute File.exists?(Sync.backup_path(path))
    assert Manifest.sync(Manifest.read(video), "en") == nil
  end

  test "automatic correction never overwrites bytes edited while the engine is running", %{
    video: video
  } do
    path = managed_srt!(video)
    original = File.read!(path)
    external = String.replace(original, "One", "External edit")
    owner = self()
    stub(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video -> {:ok, []} end)

    expect(Cinder.Subtitles.Sync.EngineMock, :sync, fn reference, input, output ->
      assert File.read!(reference) == File.read!(video)
      assert File.read!(input) == original
      send(owner, {:engine_started, self()})

      receive do
        :release -> :ok
      end

      File.write!(output, shifted_subtitle(original))
      {:ok, %{score: 30.0, offset_ms: 1_000, rate: 1.0}}
    end)

    task = Task.async(fn -> Sync.analyze_video(video) end)
    assert_receive {:engine_started, engine}, 5_000
    File.write!(path, external)
    send(engine, :release)

    assert [%{status: :failed, reason: :concurrent_change}] = Task.await(task)
    assert File.read!(path) == external
    refute File.exists?(Sync.backup_path(path))
    assert Manifest.sync(Manifest.read(video), "en") == nil
  end

  test "manual apply rejects a sidecar changed during moviehash lookup", %{video: video} do
    path = managed_srt!(video)
    original = File.read!(path)
    external = String.replace(original, "One", "External edit")
    [item] = Sync.discover(video)
    assert {:ok, fingerprint} = Sync.fingerprint(item)
    Application.put_env(:cinder, :filesystem, Cinder.Test.BarrierFilesystem)

    Application.put_env(:cinder, :filesystem_barrier, %{
      owner: self(),
      operation: :moviehash_data,
      contains: Path.basename(video),
      once: true
    })

    task = Task.async(fn -> Sync.manual(item, 1_000, 1.0, fingerprint) end)
    assert_receive {:filesystem_barrier, pid, ref, :moviehash_data, ^video}, 5_000
    File.write!(path, external)
    send(pid, {ref, :continue})

    assert {:error, :externally_modified} = Task.await(task)
    assert File.read!(path) == external
    refute File.exists?(Sync.backup_path(path))
    assert Manifest.sync(Manifest.read(video), "en") == nil
  end

  test "manual correction compares target bytes again immediately before replacement", %{
    video: video
  } do
    path = managed_srt!(video)
    original = File.read!(path)
    external = String.replace(original, "One", "External edit")
    [item] = Sync.discover(video)
    Application.put_env(:cinder, :filesystem, Cinder.Test.BarrierFilesystem)

    Application.put_env(:cinder, :filesystem_barrier, %{
      owner: self(),
      operation: :exchange,
      contains: ".cinder-subtitle-sync-write-",
      once: true
    })

    task = Task.async(fn -> Sync.manual(item, 1_000, 1.0) end)
    assert_receive {:filesystem_barrier, pid, ref, :exchange, _temporary}, 5_000
    File.write!(path, external)
    send(pid, {ref, :continue})

    assert {:error, :concurrent_change} = Task.await(task)
    assert File.read!(path) == external
    assert File.read!(Sync.backup_path(path)) == original
    assert Manifest.sync(Manifest.read(video), "en") == nil
  end

  test "manual correction restores a target atomically replaced immediately before exchange", %{
    video: video
  } do
    path = managed_srt!(video)
    original = File.read!(path)
    external = String.replace(original, "One", "Atomic replacement")
    replacement = path <> ".replacement"
    File.write!(replacement, external)
    [item] = Sync.discover(video)
    Application.put_env(:cinder, :filesystem, Cinder.Test.BarrierFilesystem)

    Application.put_env(:cinder, :filesystem_barrier, %{
      owner: self(),
      operation: :exchange,
      phase: :before,
      contains: ".cinder-subtitle-sync-write-",
      once: true
    })

    task = Task.async(fn -> Sync.manual(item, 1_000, 1.0) end)
    assert_receive {:filesystem_barrier, pid, ref, :exchange, _temporary}, 5_000
    File.rename!(replacement, path)
    send(pid, {ref, :continue})

    assert {:error, :concurrent_change} = Task.await(task)
    assert File.read!(path) == external
    assert File.read!(Sync.backup_path(path)) == original
    assert Manifest.sync(Manifest.read(video), "en") == nil
  end

  test "descriptor close failure after committed exchange preserves the committed journal", %{
    video: video
  } do
    path = managed_srt!(video)
    [item] = Sync.discover(video)
    Application.put_env(:cinder, :filesystem, Cinder.Test.BarrierFilesystem)

    Application.put_env(:cinder, :filesystem_failure, %{
      operation: :close_bound,
      source_contains: "/proc/",
      reason: :eio,
      once: true
    })

    assert {:ok, :corrected, _} = Sync.manual(item, 1_000, 1.0)
    assert File.read!(path) =~ "00:00:02,000"
    assert %{status: "aligned"} = Manifest.sync(Manifest.read(video), "en")
  end

  test "outer input close failure after engine publication preserves the result", %{
    video: video
  } do
    path = managed_srt!(video)
    original = File.read!(path)
    stub(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video -> {:ok, []} end)

    expect(Cinder.Subtitles.Sync.EngineMock, :sync, fn _reference, _input, output ->
      File.write!(output, shifted_subtitle(original))
      {:ok, %{score: 30.0, offset_ms: 1_000, rate: 1.0}}
    end)

    Application.put_env(:cinder, :filesystem, Cinder.Test.BarrierFilesystem)

    Application.put_env(:cinder, :filesystem_failure, %{
      operation: :close_bound,
      source_contains: Path.basename(video),
      reason: :eio,
      once: true
    })

    assert [%{status: :corrected}] = Sync.analyze_video(video)
    assert File.read!(path) =~ "00:00:02,000"
    assert %{status: "aligned"} = Manifest.sync(Manifest.read(video), "en")
  end

  test "post-effect exchange failure preserves applying recovery state", %{video: video} do
    path = managed_srt!(video)
    original = File.read!(path)
    [item] = Sync.discover(video)
    Application.put_env(:cinder, :filesystem, Cinder.Test.BarrierFilesystem)

    Application.put_env(:cinder, :filesystem_failure, %{
      operation: :exchange,
      source_contains: ".cinder-subtitle-sync-write-",
      phase: :post_effect,
      reason: :eio,
      once: true
    })

    assert {:error, {:publication_committed, _reason}} = Sync.manual(item, 1_000, 1.0)
    assert File.read!(path) =~ "00:00:02,000"
    assert File.read!(Sync.backup_path(path)) == original
    assert %{status: "applying"} = Manifest.sync(Manifest.read(video), "en")

    stub(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video -> {:ok, []} end)
    assert [%{status: :aligned}] = Sync.analyze_video(video)
    assert %{status: "aligned"} = Manifest.sync(Manifest.read(video), "en")
  end

  test "post-effect staged discard failure preserves applying recovery state", %{video: video} do
    path = managed_srt!(video)
    original = File.read!(path)
    [item] = Sync.discover(video)
    Application.put_env(:cinder, :filesystem, Cinder.Test.BarrierFilesystem)

    Application.put_env(:cinder, :filesystem_failure, %{
      operation: :discard_bound,
      source_contains: Path.basename(path),
      phase: :post_effect,
      reason: :eio,
      once: true
    })

    assert {:error, {:publication_committed, _reason}} = Sync.manual(item, 1_000, 1.0)
    assert File.read!(path) =~ "00:00:02,000"
    assert File.read!(Sync.backup_path(path)) == original
    assert %{status: "applying"} = Manifest.sync(Manifest.read(video), "en")

    stub(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video -> {:ok, []} end)
    assert [%{status: :aligned}] = Sync.analyze_video(video)
    assert %{status: "aligned"} = Manifest.sync(Manifest.read(video), "en")
  end

  test "a mismatched immutable backup fails closed", %{video: video} do
    path = managed_srt!(video)
    [item] = Sync.discover(video)
    assert {:ok, :corrected, _} = Sync.manual(item, 1_000, 1.0)
    corrected = File.read!(path)
    metadata = Manifest.sync(Manifest.read(video), "en")
    File.write!(Sync.backup_path(path), "not the immutable original")

    [item] = Sync.discover(video)
    assert {:error, :backup_mismatch} = Sync.manual(item, 2_000, 1.0)
    assert File.read!(path) == corrected
    assert File.read!(Sync.backup_path(path)) == "not the immutable original"
    assert Manifest.sync(Manifest.read(video), "en") == metadata
  end

  test "sync-less analysis never deletes an unproven reserved backup", %{video: video} do
    path = managed_srt!(video)
    backup = owned_backup!(video, path, "unrelated file")

    assert {:error, :unexpected_backup} =
             Sync.discard_replacement(video, "en", path, nil)

    stub(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video -> {:ok, []} end)

    assert [%{status: :review, reason: "replacement_cleanup_failed"}] =
             Sync.analyze_video(video)

    assert File.read!(backup) == "unrelated file"
    assert File.read!(path) == subtitle(".srt")
  end

  test "sync-less recovery rejects matching bytes under a different backup inode", %{video: video} do
    path = managed_srt!(video)
    content = File.read!(path)
    backup = owned_backup!(video, path, content)
    replacement = backup <> ".replacement"
    File.write!(replacement, content)
    File.rename!(replacement, backup)

    assert [%{status: :review, reason: "replacement_cleanup_failed"}] =
             Sync.analyze_video(video)

    assert File.read!(backup) == content
  end

  test "analysis retires a proven sync-less backup left by legacy cleanup", %{video: video} do
    path = managed_srt!(video)
    content = File.read!(path)
    backup = owned_backup!(video, path, content)

    assert [%{review_reason: "replacement_cleanup_failed"}] = Sync.discover(video)
    stub(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video -> {:ok, []} end)

    expect(Cinder.Subtitles.Sync.EngineMock, :sync, fn _reference, input, output ->
      assert File.read!(input) == content
      File.write!(output, content)
      {:ok, %{score: 30.0, offset_ms: 0, rate: 1.0}}
    end)

    assert [%{status: :aligned}] = Sync.analyze_video(video)
    assert File.read!(backup) == ""
    assert [%{review_reason: nil}] = Sync.discover(video)
  end

  test "an unsafe reserved backup remains visibly quarantined", %{video: video} do
    path = managed_srt!(video)
    backup = Sync.backup_path(path)
    File.ln_s!(path, backup)

    assert [%{review_reason: "replacement_cleanup_failed"}] = Sync.discover(video)
    stub(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video -> {:ok, []} end)

    assert [%{status: :review, reason: "replacement_cleanup_failed"}] =
             Sync.analyze_video(video)

    assert {:ok, %File.Stat{type: :symlink}} = File.lstat(backup)
  end

  test "replacement restore failure is review-only and preserves the immutable backup", %{
    video: video
  } do
    path = managed_srt!(video)
    [item] = Sync.discover(video)
    assert {:ok, :corrected, _} = Sync.manual(item, 1_000, 1.0)
    corrected = File.read!(path)
    backup = Sync.backup_path(path)
    File.write!(video, "x" <> String.duplicate("v", 131_071))
    Application.put_env(:cinder, :filesystem, Cinder.Test.BarrierFilesystem)

    Application.put_env(:cinder, :filesystem_failure, %{
      operation: :exchange,
      source_contains: ".cinder-subtitle-sync-write-",
      reason: :eio,
      once: true
    })

    assert [%{status: :review, reason: "replacement_cleanup_failed"}] =
             Sync.analyze_video(video)

    assert File.read!(path) == corrected
    assert File.exists?(backup)
    assert Manifest.sync(Manifest.read(video), "en") != nil
  end

  test "replacement manifest-clear failure keeps the original backup for retry", %{video: video} do
    path = managed_srt!(video)
    original = File.read!(path)
    [item] = Sync.discover(video)
    assert {:ok, :corrected, _} = Sync.manual(item, 1_000, 1.0)
    backup = Sync.backup_path(path)
    File.write!(video, "x" <> String.duplicate("v", 131_071))
    Application.put_env(:cinder, :filesystem, Cinder.Test.BarrierFilesystem)

    Application.put_env(:cinder, :filesystem_failure, %{
      operation: :write_exclusive,
      source_contains: ".cinder-subtitle-manifest-",
      reason: :eio,
      once: true
    })

    assert [%{status: :review, reason: "replacement_cleanup_failed"}] =
             Sync.analyze_video(video)

    assert File.read!(path) == original
    assert File.exists?(backup)
    assert Manifest.sync(Manifest.read(video), "en") != nil
  end

  test "replacement backup-removal failure preserves a journal until cleanup succeeds", %{
    video: video
  } do
    path = managed_srt!(video)
    original = File.read!(path)
    [item] = Sync.discover(video)
    assert {:ok, :corrected, _} = Sync.manual(item, 1_000, 1.0)
    previous_sync = Manifest.sync(Manifest.read(video), "en")
    backup = Sync.backup_path(path)
    File.write!(video, "x" <> String.duplicate("v", 131_071))

    Application.put_env(:cinder, :filesystem, Cinder.Test.BarrierFilesystem)

    Application.put_env(:cinder, :filesystem_failure, %{
      operation: :discard_bound,
      source_contains: ".cinder-sync-original",
      reason: :eacces,
      once: true
    })

    assert [%{status: :review, reason: "replacement_cleanup_failed"}] =
             Sync.analyze_video(video)

    assert File.read!(path) == original
    assert File.read!(backup) == original
    assert Manifest.sync(Manifest.read(video), "en") == nil
    assert Manifest.replacement_cleanup_sync(Manifest.read(video), "en") == previous_sync

    stub(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video -> {:ok, []} end)

    expect(Cinder.Subtitles.Sync.EngineMock, :sync, fn _reference, input, output ->
      assert File.read!(input) == original
      File.write!(output, original)
      {:ok, %{score: 30.0, offset_ms: 0, rate: 1.0}}
    end)

    assert [%{status: :aligned}] = Sync.analyze_video(video)
    assert File.read!(backup) == ""
    assert Manifest.replacement_cleanup_sync(Manifest.read(video), "en") == nil
  end

  test "replacement cleanup with no backup clears its journal without blocking", %{video: video} do
    path = managed_srt!(video)
    content = File.read!(path)
    [item] = Sync.discover(video)
    assert {:ok, :aligned, _} = Sync.manual(item, 0, 1.0)
    refute File.exists?(Sync.backup_path(path))
    File.write!(video, "x" <> String.duplicate("v", 131_071))
    stub(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video -> {:ok, []} end)

    expect(Cinder.Subtitles.Sync.EngineMock, :sync, fn _reference, input, output ->
      assert File.read!(input) == content
      File.write!(output, content)
      {:ok, %{score: 30.0, offset_ms: 0, rate: 1.0}}
    end)

    assert [%{status: :aligned}] = Sync.analyze_video(video)
    assert Manifest.replacement_cleanup_sync(Manifest.read(video), "en") == nil
    refute File.exists?(Sync.backup_path(path))
  end

  test "a replacement download discards its stale backup and is analyzed afresh", %{video: video} do
    path = managed_srt!(video)
    [item] = Sync.discover(video)
    assert {:ok, :corrected, _} = Sync.manual(item, 1_000, 1.0)
    previous_sync = Manifest.sync(Manifest.read(video), "en")
    assert File.exists?(Sync.backup_path(path))

    replacement = "1\n00:00:10,000 --> 00:00:11,000\nReplacement\n\n"
    File.write!(path, replacement)

    assert :ok =
             Manifest.put(
               video,
               moviehash!(video),
               "en",
               "opensubtitles_id",
               path,
               digest(replacement)
             )

    assert :ok = Sync.discard_replacement(video, "en", path, previous_sync)
    assert File.read!(Sync.backup_path(path)) == ""

    stub(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video -> {:ok, []} end)

    expect(Cinder.Subtitles.Sync.EngineMock, :sync, fn reference, input, output ->
      assert File.read!(reference) == File.read!(video)
      assert File.read!(input) == replacement
      assert File.read!(path) == replacement
      File.write!(output, replacement)
      {:ok, %{score: 30.0, offset_ms: 0, rate: 1.0}}
    end)

    assert [%{status: :aligned}] = Sync.analyze_video(video)
    assert File.read!(path) == replacement
  end

  test "an external edit after synchronization is review-only and preserves the immutable backup",
       %{
         video: video
       } do
    path = managed_srt!(video)
    [item] = Sync.discover(video)
    assert {:ok, :corrected, _item} = Sync.manual(item, 1_000, 1.0)
    original_backup = File.read!(Sync.backup_path(path))
    external = String.replace(subtitle(".srt"), "One", "Externally edited")
    File.write!(path, external)

    assert [%{status: :review, reason: "externally_modified"}] = Sync.analyze_video(video)
    assert File.read!(path) == external
    assert File.read!(Sync.backup_path(path)) == original_backup

    assert %{status: "review", reason: "externally_modified"} =
             Manifest.sync(Manifest.read(video), "en")
  end

  test "a manifest failure rolls back corrected bytes and its newly-created backup", %{
    video: video
  } do
    path = managed_srt!(video)
    original = File.read!(path)
    [item] = Sync.discover(video)

    Application.put_env(:cinder, :filesystem, Cinder.Test.BarrierFilesystem)

    Application.put_env(:cinder, :filesystem_barrier, %{
      owner: self(),
      operation: :exchange,
      contains: ".cinder-subtitle-sync-write-",
      once: true
    })

    task = Task.async(fn -> Sync.manual(item, 1_000, 1.0) end)
    assert_receive {:filesystem_barrier, pid, ref, :exchange, _temporary}, 5_000

    Application.put_env(:cinder, :filesystem_failure, %{
      operation: :write_exclusive,
      source_contains: ".cinder-subtitle-manifest-",
      reason: :eio,
      once: true
    })

    on_exit(fn -> Application.delete_env(:cinder, :filesystem_failure) end)

    send(pid, {ref, :continue})
    assert {:error, {:manifest, :eio}} = Task.await(task)
    assert File.read!(path) == original
    assert File.read!(Sync.backup_path(path)) == ""
    assert Manifest.sync(Manifest.read(video), "en") == nil
  end

  test "a failed prior-manifest restore retains the newly-created immutable backup", %{
    video: video
  } do
    path = managed_srt!(video)
    original = File.read!(path)
    [item] = Sync.discover(video)
    Application.put_env(:cinder, :filesystem, Cinder.Test.BarrierFilesystem)

    Application.put_env(:cinder, :filesystem_barrier, %{
      owner: self(),
      operation: :exchange,
      contains: ".cinder-subtitle-sync-write-",
      once: true
    })

    task = Task.async(fn -> Sync.manual(item, 1_000, 1.0) end)
    assert_receive {:filesystem_barrier, pid, ref, :exchange, _temporary}, 5_000

    Application.put_env(:cinder, :filesystem_failures, [
      %{operation: :write_exclusive, source_contains: ".cinder-subtitle-manifest-", reason: :eio},
      %{
        operation: :write_exclusive,
        source_contains: ".cinder-subtitle-manifest-",
        reason: :enospc
      }
    ])

    send(pid, {ref, :continue})
    assert {:error, {:manifest_and_rollback_failed, :eio, :enospc}} = Task.await(task)
    assert File.read!(path) == original
    assert File.read!(Sync.backup_path(path)) == original
    assert %{status: "applying"} = Manifest.sync(Manifest.read(video), "en")
  end

  test "rollback never overwrites a newer concurrent sidecar", %{video: video} do
    path = managed_srt!(video)
    original = File.read!(path)
    external = String.replace(original, "One", "Concurrent edit")
    [item] = Sync.discover(video)
    Application.put_env(:cinder, :filesystem, Cinder.Test.BarrierFilesystem)

    Application.put_env(:cinder, :filesystem_barrier, %{
      owner: self(),
      operation: :exchange,
      contains: ".cinder-subtitle-sync-write-",
      once: true
    })

    task = Task.async(fn -> Sync.manual(item, 1_000, 1.0) end)
    assert_receive {:filesystem_barrier, pid, ref, :exchange, _temporary}, 5_000

    Application.put_env(:cinder, :filesystem_failures, [
      %{
        operation: :write_exclusive,
        source_contains: ".cinder-subtitle-manifest-",
        reason: :eio,
        callback: fn -> File.write!(path, external) end
      }
    ])

    send(pid, {ref, :continue})

    assert {:error, {:manifest_and_rollback_failed, :eio, :concurrent_change}} =
             Task.await(task)

    assert File.read!(path) == external
    assert File.read!(Sync.backup_path(path)) == original
    assert %{status: "applying"} = Manifest.sync(Manifest.read(video), "en")
  end

  test "a failed second manual manifest write restores the previous correction", %{video: video} do
    path = managed_srt!(video)
    [item] = Sync.discover(video)
    assert {:ok, :corrected, item} = Sync.manual(item, 1_000, 1.0)
    previous = File.read!(path)
    previous_metadata = Manifest.sync(Manifest.read(video), "en")
    Application.put_env(:cinder, :filesystem, Cinder.Test.BarrierFilesystem)

    Application.put_env(:cinder, :filesystem_barrier, %{
      owner: self(),
      operation: :exchange,
      contains: ".cinder-subtitle-sync-write-",
      once: true
    })

    task = Task.async(fn -> Sync.manual(item, 2_000, 1.0) end)
    assert_receive {:filesystem_barrier, pid, ref, :exchange, _temporary}, 5_000

    Application.put_env(:cinder, :filesystem_failure, %{
      operation: :write_exclusive,
      source_contains: ".cinder-subtitle-manifest-",
      reason: :eio,
      once: true
    })

    send(pid, {ref, :continue})
    assert {:error, {:manifest, :eio}} = Task.await(task)
    assert File.read!(path) == previous
    assert Manifest.sync(Manifest.read(video), "en") == previous_metadata
  end

  test "a failed rollback preserves the immutable backup", %{video: video} do
    path = managed_srt!(video)
    original = File.read!(path)
    [item] = Sync.discover(video)

    Application.put_env(:cinder, :filesystem, Cinder.Test.BarrierFilesystem)

    Application.put_env(:cinder, :filesystem_barrier, %{
      owner: self(),
      operation: :exchange,
      contains: ".cinder-subtitle-sync-write-",
      once: true
    })

    task = Task.async(fn -> Sync.manual(item, 1_000, 1.0) end)
    assert_receive {:filesystem_barrier, pid, ref, :exchange, _temporary}, 5_000

    Application.put_env(:cinder, :filesystem_failures, [
      %{
        operation: :write_exclusive,
        source_contains: ".cinder-subtitle-manifest-",
        reason: :eio
      },
      %{
        operation: :exchange,
        source_contains: ".cinder-subtitle-sync-write-",
        reason: :eacces
      }
    ])

    send(pid, {ref, :continue})

    assert {:error, {:manifest_and_rollback_failed, :eio, :eacces}} =
             Task.await(task)

    refute File.read!(path) == original
    assert File.read!(Sync.backup_path(path)) == original
    assert %{status: "applying"} = Manifest.sync(Manifest.read(video), "en")
  end

  test "temporary correction writes never follow a pre-created symlink", %{
    video: video,
    tmp_dir: tmp
  } do
    _path = managed_srt!(video)
    [item] = Sync.discover(video)
    outside = Path.join(tmp, "outside.srt")
    File.write!(outside, "outside")
    Application.put_env(:cinder, :filesystem, Cinder.Test.BarrierFilesystem)

    Application.put_env(:cinder, :filesystem_barrier, %{
      owner: self(),
      operation: :create_bound,
      phase: :before,
      contains: ".cinder-subtitle-sync-write-",
      once: true
    })

    task = Task.async(fn -> Sync.manual(item, 1_000, 1.0) end)
    assert_receive {:filesystem_barrier, pid, ref, :create_bound, temporary}, 5_000
    File.ln_s!(outside, temporary)
    send(pid, {ref, :continue})

    assert {:error, _reason} = Task.await(task)
    assert File.read!(outside) == "outside"
  end

  test "disk exchange returns an error when mv cannot execute", %{tmp_dir: tmp} do
    source = Path.join(tmp, "exchange-source")
    destination = Path.join(tmp, "exchange-destination")
    File.write!(source, "source")
    File.write!(destination, "destination")
    path = System.get_env("PATH")
    System.put_env("PATH", "")
    on_exit(fn -> System.put_env("PATH", path) end)

    assert {:error, {:exchange_exec_failed, _reason}} =
             Disk.exchange(source, destination)

    assert File.read!(source) == "source"
    assert File.read!(destination) == "destination"
  end

  defp managed_srt!(video, language \\ "en") do
    path = sidecar(video, language, ".srt")
    content = subtitle(".srt")
    File.write!(path, content)

    assert :ok =
             Manifest.put(
               video,
               moviehash!(video),
               language,
               "opensubtitles_hash",
               path,
               digest(content)
             )

    path
  end

  defp owned_backup!(video, sidecar, content, language \\ "en") do
    backup = Sync.backup_path(sidecar)
    assert {:ok, bound} = Disk.create_bound(backup, content)
    assert :ok = Manifest.put_backup_tombstone(video, language, bound.identity)
    assert :ok = Disk.close_bound(bound)
    backup
  end

  # Reproduces the production state behind issue #350: a corrected-then-reset
  # track whose manifest holds an owned backup tombstone with sync: nil, while
  # the logical backup path is a zero-byte container on two mergerfs branches.
  # The shim supplies the mergerfs surface (mount detection + allpaths) that the
  # test environment cannot; the proofs and effects are the real helper.
  defp duplicate_tombstones!(video, tmp, opts \\ []) do
    path = managed_srt!(video)
    original = File.read!(path)
    [item] = Sync.discover(video)
    assert {:ok, :corrected, _} = Sync.manual(item, 1_000, 1.0)
    assert :ok = Sync.reset(hd(Sync.discover(video)))

    backup = Sync.backup_path(path)
    assert File.read!(backup) == ""
    assert %{identity: identity} = Manifest.backup_tombstone(Manifest.read(video), "en")
    assert Manifest.sync(Manifest.read(video), "en") == nil

    legacy_identity = opts[:legacy_identity]

    if legacy_identity do
      assert :ok = Manifest.put_backup_tombstone(video, "en", legacy_identity)
    end

    root = Application.fetch_env!(:cinder, :movies_library_path)
    File.write!(Path.join(root, ".mergerfs"), "")
    relative = Path.relative_to(backup, root)
    branch = Path.join(tmp, "branch-b")
    duplicate = Path.join(branch, relative)
    File.mkdir_p!(Path.dirname(duplicate))
    File.write!(duplicate, "")

    helper =
      mergerfs_duplicate_helper!(
        tmp,
        backup,
        [backup, duplicate],
        [root, branch],
        legacy_identity,
        opts[:alias_identity] || false
      )

    Application.put_env(:cinder, :rooted_filesystem_helper, helper)

    %{path: path, backup: backup, duplicate: duplicate, original: original, identity: identity}
  end

  defp mergerfs_duplicate_helper!(
         tmp,
         logical,
         containers,
         branches,
         legacy_identity,
         alias_identity
       ) do
    helper = Path.join(tmp, "mergerfs_duplicate_helper.py")
    real_helper = Path.expand("../../../priv/rooted_fs.py", __DIR__)

    File.write!(helper, """
    import os
    import sys

    LOGICAL = #{inspect(logical)}
    CONTAINERS = #{inspect(containers)}
    BRANCHES = #{inspect(branches)}
    LEGACY_IDENTITY = #{if legacy_identity, do: Jason.encode!(legacy_identity), else: "None"}
    ALIAS_IDENTITY = #{if alias_identity, do: "True", else: "False"}
    REAL_HELPER = #{inspect(real_helper)}

    real_getxattr = os.getxattr

    def targeted():
        return any(os.path.basename(LOGICAL) in arg for arg in sys.argv[2:])

    def getxattr(path, name, **kwargs):
        if name == "user.mergerfs.allpaths":
            existing = [c for c in CONTAINERS if os.path.lexists(c)]
            if existing:
                return b"\\0".join(os.fsencode(c) for c in existing)
        if name in ("user.mergerfs.branches", "user.mergerfs.srcmounts"):
            if not isinstance(path, int) or os.path.basename(
                os.readlink(f"/proc/self/fd/{path}")
            ) != ".mergerfs":
                raise OSError(61, "ENODATA")
            return os.fsencode(":".join(BRANCHES))
        # The surviving container IS the logical path here, so the mount maps
        # onto itself: this keeps the real mergerfs reactivation path (backing
        # location lookup + mapping verification) exercised after reconciling.
        if name == "user.mergerfs.fullpath" and targeted():
            return os.fsencode(LOGICAL)
        if name == "user.mergerfs.basepath" and targeted():
            return os.fsencode(BRANCHES[0])
        return real_getxattr(path, name, **kwargs)

    os.getxattr = getxattr

    # exec into a namespace we own so the helper's own functions resolve
    # mergerfs_mount through this dict; runpy would hand back a detached copy.
    namespace = {"__name__": "rooted_fs_shim", "__file__": REAL_HELPER}
    with open(REAL_HELPER, encoding="utf-8") as source:
        exec(compile(source.read(), REAL_HELPER, "exec"), namespace)

    if LEGACY_IDENTITY is not None:
        namespace["legacy_union_identity"] = lambda mountpoint, fd: LEGACY_IDENTITY

    if ALIAS_IDENTITY:
        real_tombstone_identity = namespace["tombstone_identity"]
        aliased_identity = [None]

        def tombstone_identity(branch, relative):
            identity = real_tombstone_identity(branch, relative)
            if aliased_identity[0] is None:
                aliased_identity[0] = identity
            return aliased_identity[0]

        namespace["tombstone_identity"] = tombstone_identity

    real_mount = namespace["mergerfs_mount"]

    # Scope the mergerfs illusion to the backup path, and keep it mergerfs after
    # the duplicate is gone so the post-reconciliation reactivation still runs
    # through hold_open_mergerfs rather than the ordinary rooted open.
    real_mountpoint = namespace["mergerfs_mountpoint"]
    namespace["mergerfs_mountpoint"] = (
        lambda path: BRANCHES[0] if targeted() else real_mountpoint(path)
    )
    namespace["mergerfs_mount"] = lambda path: targeted() or real_mount(path)

    sys.argv = [REAL_HELPER] + sys.argv[1:]
    operation = sys.argv[1] if len(sys.argv) > 1 else "unknown"

    try:
        namespace["main"]()
    except OSError as exc:
        committed = isinstance(exc, namespace["EffectCommittedError"])
        namespace["fail"](operation, "post_effect" if committed else "pre_effect", exc)
        sys.exit(1)
    """)

    helper
  end

  defp legacy_identity_helper!(tmp, path_fragment, identity) do
    helper = Path.join(tmp, "legacy_identity_helper.py")
    real_helper = Path.expand("../../../priv/rooted_fs.py", __DIR__)

    File.write!(helper, """
    import json
    import os
    import sys

    if (
        sys.argv[1] != "hold"
        or #{inspect(path_fragment)} not in sys.argv[3]
        or sys.argv[4] == "create"
    ):
        os.execv(sys.executable, [sys.executable, #{inspect(real_helper)}] + sys.argv[1:])

    path = os.path.join(sys.argv[2], sys.argv[3])
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    print(json.dumps({"ok": {"fd": fd, "union_identity": #{Jason.encode!(identity)}}}), flush=True)
    sys.stdin.buffer.read()
    os.close(fd)
    """)

    helper
  end

  defp shifted_subtitle(content) do
    String.replace(
      content,
      "00:00:01,000 --> 00:00:02,000",
      "00:00:02,000 --> 00:00:03,000"
    )
  end

  defp digest(content),
    do: content |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  defp sidecar(video, language, extension),
    do: Path.rootname(video) <> ".#{language}" <> extension

  defp subtitle(".srt"), do: "1\n00:00:01,000 --> 00:00:02,000\nOne\n\n"
  defp subtitle(".vtt"), do: "WEBVTT\n\n00:01.000 --> 00:02.000\nOne\n"

  defp subtitle(extension) when extension in [".ass", ".ssa"],
    do:
      "[Events]\n" <>
        "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n" <>
        "Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,One\n"

  defp moviehash!(video) do
    assert {:ok, hash} = Moviehash.of_file(video)
    hash
  end
end
