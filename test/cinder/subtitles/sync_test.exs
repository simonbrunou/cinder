defmodule Cinder.Subtitles.SyncTest do
  use ExUnit.Case, async: false

  import Mox

  alias Cinder.Subtitles.{Manifest, Moviehash, Sync}

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
      File.write!(path, subtitle(extension))
      assert :ok = Manifest.put(video, "hash", language, origin, path)
    end

    File.write!(Path.rootname(video) <> ".en.forced.srt", subtitle(".srt"))

    assert Sync.discover(video) |> Enum.map(&{&1.language, Path.extname(&1.sidecar_path)}) == [
             {"en", ".ass"},
             {"fr", ".vtt"}
           ]
  end

  test "malformed exact-file or sync metadata quarantines managed sidecars", %{video: video} do
    en = sidecar(video, "en", ".srt")
    fr = sidecar(video, "fr", ".ass")
    File.write!(en, subtitle(".srt"))
    File.write!(fr, subtitle(".ass"))

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

    expect(Cinder.Subtitles.Sync.EngineMock, :sync, fn ^video, ^path, output ->
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
    refute File.exists?(backup)
    assert Manifest.sync(Manifest.read(video), "en") == nil
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

  test "manual timestamp anchors apply the same affine correction", %{video: video} do
    path = managed_srt!(video)
    [item] = Sync.discover(video)

    assert {:ok, :corrected, _} =
             Sync.manual_from_anchors(item, [{1_000, 2_000}, {3_000, 6_000}])

    assert File.read!(path) =~ "00:00:02,000 --> 00:00:04,000"
  end

  test "selects the broadest non-forced embedded reference then falls back to audio", %{
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

    expect(Cinder.Library.MediaInfoMock, :extract_subtitle, fn ^video, 3 ->
      {:ok, subtitle(".srt")}
    end)

    expect(Cinder.Subtitles.Sync.EngineMock, :sync, 2, fn reference, ^path, output ->
      send(parent, {:reference, reference})

      if reference == video do
        File.write!(output, String.replace(subtitle(".srt"), "00:00:01,000", "00:00:02,000"))
        {:ok, %{score: 30.0, offset_ms: 1_000, rate: 1.0}}
      else
        File.write!(output, subtitle(".srt"))
        {:review, %{reason: :low_confidence, score: 1.0, offset_ms: 0, rate: 1.0}}
      end
    end)

    assert [%{status: :corrected}] = Sync.analyze_video(video)
    assert_receive {:reference, embedded}
    assert embedded != video
    assert_receive {:reference, ^video}
    assert File.read!(path) =~ "00:00:02,000"
    assert %{method: "audio", status: "aligned"} = Manifest.sync(Manifest.read(video), "en")
  end

  test "tries the next non-forced embedded track when the broadest one cannot be extracted", %{
    video: video
  } do
    path = managed_srt!(video)
    parent = self()

    expect(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video ->
      {:ok,
       [
         %{index: 2, language: "en", forced?: false, default?: true, packet_count: 30},
         %{index: 3, language: "fr", forced?: false, default?: false, packet_count: 20}
       ]}
    end)

    expect(Cinder.Library.MediaInfoMock, :extract_subtitle, 2, fn
      ^video, 2 -> {:error, :cannot_decode}
      ^video, 3 -> {:ok, subtitle(".srt")}
    end)

    expect(Cinder.Subtitles.Sync.EngineMock, :sync, fn reference, ^path, output ->
      send(parent, {:reference, reference})
      File.write!(output, String.replace(subtitle(".srt"), "00:00:01,000", "00:00:02,000"))
      {:ok, %{score: 30.0, offset_ms: 1_000, rate: 1.0}}
    end)

    assert [%{status: :corrected}] = Sync.analyze_video(video)
    assert_receive {:reference, reference}
    refute reference == video
  end

  test "low-confidence audio leaves bytes unchanged and marks operator review", %{video: video} do
    path = managed_srt!(video)
    original = File.read!(path)
    stub(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video -> {:ok, []} end)

    expect(Cinder.Subtitles.Sync.EngineMock, :sync, fn ^video, ^path, output ->
      File.write!(output, original)
      {:review, %{reason: :low_confidence, score: 1.0, offset_ms: 0, rate: 1.0}}
    end)

    assert [%{status: :review}] = Sync.analyze_video(video)
    assert File.read!(path) == original
    refute File.exists?(Sync.backup_path(path))

    assert %{status: "review", reason: "low_confidence"} =
             Manifest.sync(Manifest.read(video), "en")
  end

  test "a changed moviehash restores the immutable original and analyzes afresh", %{video: video} do
    path = managed_srt!(video)
    original = File.read!(path)
    [item] = Sync.discover(video)
    assert {:ok, :corrected, _} = Sync.manual(item, 1_000, 1.0)
    assert File.read!(path) != original

    File.write!(video, "x" <> String.duplicate("v", 131_071))
    stub(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video -> {:ok, []} end)

    expect(Cinder.Subtitles.Sync.EngineMock, :sync, fn ^video, ^path, output ->
      assert File.read!(path) == original
      File.write!(output, original)
      {:ok, %{score: 30.0, offset_ms: 0, rate: 1.0}}
    end)

    assert [%{status: :aligned}] = Sync.analyze_video(video)
    assert File.read!(path) == original
    refute File.exists?(Sync.backup_path(path))
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
      operation: :rename,
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
      operation: :write,
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

  test "replacement backup-removal failure blocks reanalysis until cleanup succeeds", %{
    video: video
  } do
    path = managed_srt!(video)
    [item] = Sync.discover(video)
    assert {:ok, :corrected, _} = Sync.manual(item, 1_000, 1.0)
    backup = Sync.backup_path(path)
    replacement = "1\n00:00:10,000 --> 00:00:11,000\nReplacement\n\n"
    File.write!(path, replacement)
    assert :ok = Manifest.put(video, moviehash!(video), "en", "opensubtitles_id", path)
    Application.put_env(:cinder, :filesystem, Cinder.Test.BarrierFilesystem)

    Application.put_env(:cinder, :filesystem_failure, %{
      operation: :rm,
      source_contains: ".cinder-sync-original",
      reason: :eacces,
      once: true
    })

    assert [%{status: :review, reason: "replacement_cleanup_failed"}] =
             Sync.analyze_video(video)

    assert File.read!(path) == replacement
    assert File.exists?(backup)
    assert Manifest.sync(Manifest.read(video), "en") == nil
  end

  test "a replacement download discards its stale backup and is analyzed afresh", %{video: video} do
    path = managed_srt!(video)
    [item] = Sync.discover(video)
    assert {:ok, :corrected, _} = Sync.manual(item, 1_000, 1.0)
    assert File.exists?(Sync.backup_path(path))

    replacement = "1\n00:00:10,000 --> 00:00:11,000\nReplacement\n\n"
    File.write!(path, replacement)
    assert :ok = Manifest.put(video, moviehash!(video), "en", "opensubtitles_id")
    Sync.discard_replacement(path)
    refute File.exists?(Sync.backup_path(path))

    stub(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video -> {:ok, []} end)

    expect(Cinder.Subtitles.Sync.EngineMock, :sync, fn ^video, ^path, output ->
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

    Application.put_env(:cinder, :filesystem_failure, %{
      operation: :write,
      source_contains: ".cinder-subtitle-manifest-",
      reason: :eio,
      once: true
    })

    on_exit(fn -> Application.delete_env(:cinder, :filesystem_failure) end)

    assert {:error, {:manifest, :eio}} = Sync.manual(item, 1_000, 1.0)
    assert File.read!(path) == original
    refute File.exists?(Sync.backup_path(path))
    assert Manifest.sync(Manifest.read(video), "en") == nil
  end

  test "rollback never overwrites a newer concurrent sidecar", %{video: video} do
    path = managed_srt!(video)
    original = File.read!(path)
    external = String.replace(original, "One", "Concurrent edit")
    [item] = Sync.discover(video)
    Application.put_env(:cinder, :filesystem, Cinder.Test.BarrierFilesystem)

    Application.put_env(:cinder, :filesystem_failures, [
      %{
        operation: :write,
        source_contains: ".cinder-subtitle-manifest-",
        reason: :eio,
        callback: fn -> File.write!(path, external) end
      }
    ])

    assert {:error, {:manifest_and_rollback_failed, :eio, :concurrent_change}} =
             Sync.manual(item, 1_000, 1.0)

    assert File.read!(path) == external
    assert File.read!(Sync.backup_path(path)) == original
    assert Manifest.sync(Manifest.read(video), "en") == nil
  end

  test "a failed rollback preserves the immutable backup", %{video: video} do
    path = managed_srt!(video)
    original = File.read!(path)
    [item] = Sync.discover(video)

    Application.put_env(:cinder, :filesystem, Cinder.Test.BarrierFilesystem)

    Application.put_env(:cinder, :filesystem_failures, [
      %{
        operation: :write,
        source_contains: ".cinder-subtitle-manifest-",
        reason: :eio
      },
      %{
        operation: :rename,
        source_contains: ".cinder-subtitle-sync-write-",
        reason: :eacces
      }
    ])

    assert {:error, {:manifest_and_rollback_failed, :eio, :eacces}} =
             Sync.manual(item, 1_000, 1.0)

    refute File.read!(path) == original
    assert File.read!(Sync.backup_path(path)) == original
    assert Manifest.sync(Manifest.read(video), "en") == nil
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
      operation: :write_exclusive,
      phase: :before,
      contains: ".cinder-subtitle-sync-write-",
      once: true
    })

    task = Task.async(fn -> Sync.manual(item, 1_000, 1.0) end)
    assert_receive {:filesystem_barrier, pid, ref, :write_exclusive, temporary}, 1_000
    File.ln_s!(outside, temporary)
    send(pid, {ref, :continue})

    assert {:error, _reason} = Task.await(task)
    assert File.read!(outside) == "outside"
  end

  defp managed_srt!(video) do
    path = sidecar(video, "en", ".srt")
    File.write!(path, subtitle(".srt"))
    assert :ok = Manifest.put(video, moviehash!(video), "en", "opensubtitles_hash", path)
    path
  end

  defp sidecar(video, language, extension),
    do: Path.rootname(video) <> ".#{language}" <> extension

  defp subtitle(".srt"), do: "1\n00:00:01,000 --> 00:00:02,000\nOne\n\n"
  defp subtitle(".vtt"), do: "WEBVTT\n\n00:01.000 --> 00:02.000\nOne\n"

  defp subtitle(extension) when extension in [".ass", ".ssa"],
    do: "[Events]\nDialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,One\n"

  defp moviehash!(video) do
    assert {:ok, hash} = Moviehash.of_file(video)
    hash
  end
end
