defmodule Cinder.Subtitles.SyncTest do
  use Cinder.DataCase, async: false

  import Cinder.Test.BarrierFilesystem, only: [fail_once: 1]
  import ExUnit.CaptureLog, only: [with_log: 1]
  import Mox

  alias Cinder.Library.Filesystem.Disk
  alias Cinder.Subtitles.{Manifest, Moviehash, SidecarTransaction, Sync}

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
      :subtitle_sync_engine_report,
      :filesystem_barrier,
      :filesystem_failure
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
    stub(Cinder.Library.MediaInfoMock, :frame_rate, fn _video -> {:ok, 24_000 / 1001} end)

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
    refute File.exists?(SidecarTransaction.backup_path(path))
  end

  # The video's own track is timed to this cut already: no engine run, only the timing rules, with
  # the extracted original kept for Reset like any automatic correction.
  test "the video's own track gets the timing rules without an alignment", %{video: video} do
    path = sidecar(video, "en", ".srt")

    original =
      "1\n00:00:01,000 --> 00:00:02,000\nOne\n\n2\n00:00:02,200 --> 00:00:03,300\nTwo\n\n"

    File.write!(path, original)
    assert :ok = Manifest.put(video, moviehash!(video), "en", "own_track", path, digest(original))

    assert [%{status: :corrected, method: "native"}] = Sync.analyze_video(video)
    assert File.read!(path) == String.replace(original, "00:00:02,000", "00:00:02,117")
    assert File.read!(SidecarTransaction.backup_path(path)) == original
    assert [%{status: :aligned, method: "native"}] = Sync.analyze_video(video)
  end

  # An alignment too small to apply still leaves the downloaded timing to the Netflix rules: a
  # gap of 200 ms between two lines (3-11 frames) closes to 2 frames (83 ms at 24000/1001 fps).
  test "a small automatic correction still applies the timing rules to the downloaded timing", %{
    video: video
  } do
    path = sidecar(video, "en", ".srt")

    original =
      "1\n00:00:01,000 --> 00:00:02,000\nOne\n\n2\n00:00:02,200 --> 00:00:03,300\nTwo\n\n"

    File.write!(path, original)

    assert :ok =
             Manifest.put(
               video,
               moviehash!(video),
               "en",
               "opensubtitles_hash",
               path,
               digest(original)
             )

    stub(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video -> {:ok, []} end)

    expect(Cinder.Subtitles.Sync.EngineMock, :sync, fn _reference, _input, output ->
      File.write!(output, String.replace(original, "00:00:01,000", "00:00:01,040"))
      {:ok, %{score: 30.0, offset_ms: 40, rate: 1.0}}
    end)

    assert [%{status: :corrected}] = Sync.analyze_video(video)
    assert File.read!(path) == String.replace(original, "00:00:02,000", "00:00:02,117")
    assert File.read!(SidecarTransaction.backup_path(path)) == original
  end

  # A sidecar downloaded before downloads were validated can break the stricter grammar the rules
  # read (here an empty cue). A small alignment keeps it as downloaded, as before the rules.
  test "a small alignment of a sidecar the rules cannot read is still recorded aligned", %{
    video: video
  } do
    path = sidecar(video, "en", ".srt")
    original = "1\n00:00:01,000 --> 00:00:02,000\n\n\n2\n00:00:03,000 --> 00:00:04,000\nTwo\n\n"
    File.write!(path, original)

    assert :ok =
             Manifest.put(
               video,
               moviehash!(video),
               "en",
               "opensubtitles_hash",
               path,
               digest(original)
             )

    stub(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video -> {:ok, []} end)

    expect(Cinder.Subtitles.Sync.EngineMock, :sync, fn _reference, _input, output ->
      File.write!(output, "1\n00:00:03,000 --> 00:00:04,000\nTwo\n\n")
      {:ok, %{score: 30.0, offset_ms: 0, rate: 1.0}}
    end)

    assert [%{status: :aligned}] = Sync.analyze_video(video)
    assert File.read!(path) == original
  end

  # A line ending 300 ms before a cut, with nothing after it, ends 2 frames (83 ms) before the cut.
  test "an explicit request finds the video's cuts once and times the sidecar to them", %{
    video: video
  } do
    path = sidecar(video, "en", ".srt")
    original = "1\n00:00:01,000 --> 00:00:03,000\nOne\n\n"
    File.write!(path, original)

    assert :ok =
             Manifest.put(
               video,
               moviehash!(video),
               "en",
               "opensubtitles_hash",
               path,
               digest(original)
             )

    stub(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video -> {:ok, []} end)
    expect(Cinder.Library.MediaInfoMock, :shot_changes, fn ^video -> {:ok, [3_300]} end)

    expect(Cinder.Subtitles.Sync.EngineMock, :sync, fn _reference, input, output ->
      File.write!(output, File.read!(input))
      {:ok, %{score: 30.0, offset_ms: 0, rate: 1.0}}
    end)

    assert [%{status: :corrected}] = Sync.analyze_video(video, shot_changes: :detect)
    assert File.read!(path) == "1\n00:00:01,000 --> 00:00:03,217\nOne\n\n"
    assert %{shot_changes: true} = Manifest.sync(Manifest.read(video), "en")

    # The cuts are cached: a second explicit request neither decodes the video nor re-aligns.
    assert [%{status: :aligned}] = Sync.analyze_video(video, shot_changes: :detect)
  end

  test "a routine scan never decodes the video, and redoes a result once its cuts are cached", %{
    video: video
  } do
    path = sidecar(video, "en", ".srt")
    original = "1\n00:00:01,000 --> 00:00:03,000\nOne\n\n"
    File.write!(path, original)

    assert :ok =
             Manifest.put(
               video,
               moviehash!(video),
               "en",
               "opensubtitles_hash",
               path,
               digest(original)
             )

    stub(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video -> {:ok, []} end)

    expect(Cinder.Subtitles.Sync.EngineMock, :sync, 2, fn _reference, input, output ->
      File.write!(output, File.read!(input))
      {:ok, %{score: 30.0, offset_ms: 0, rate: 1.0}}
    end)

    assert [%{status: :aligned}] = Sync.analyze_video(video)
    refute Map.has_key?(Manifest.sync(Manifest.read(video), "en"), :shot_changes)

    Repo.insert!(%Cinder.Subtitles.ShotChanges{moviehash: moviehash!(video), times_ms: [3_300]})

    assert [%{status: :corrected}] = Sync.analyze_video(video)
    assert File.read!(path) == "1\n00:00:01,000 --> 00:00:03,217\nOne\n\n"
    assert %{shot_changes: true} = Manifest.sync(Manifest.read(video), "en")
  end

  test "a piecewise correction whose global offset reads as a no-op is still applied", %{
    video: video
  } do
    path = managed_srt!(video)
    original = File.read!(path)
    corrected = shifted_subtitle(original)
    stub(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video -> {:ok, []} end)

    expect(Cinder.Subtitles.Sync.EngineMock, :sync, fn _reference, input, output ->
      assert File.read!(input) == original
      File.write!(output, corrected)
      # A split alignment that leaves most of the file where it was and moves the tail 40s:
      # the global search that preceded it saw no shift at all.
      {:ok, %{score: 30.0, offset_ms: 0, rate: 1.0, segments: 2, max_offset_ms: 40_000}}
    end)

    assert [%{status: :corrected, segments: 2, max_offset_ms: 40_000}] = Sync.analyze_video(video)
    assert File.read!(path) == corrected
    assert File.read!(SidecarTransaction.backup_path(path)) == original

    # Recorded, because `offset_ms: 0` alone would report a 40s tail correction as no correction.
    assert %{status: "aligned", offset_ms: 0, segments: 2, max_offset_ms: 40_000} =
             Manifest.sync(Manifest.read(video), "en")
  end

  test "an embedded reference reaches the engine as a subtitle format", %{video: video} do
    _path = managed_srt!(video)
    Application.put_env(:cinder, :subtitle_sync_engine, Cinder.Test.ReportingEngine)
    Application.put_env(:cinder, :subtitle_sync_engine_report, %{owner: self()})

    expect(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video ->
      {:ok, [%{index: 2, language: "en", forced?: false, default?: true, packet_count: 20}]}
    end)

    expect(Cinder.Library.MediaInfoMock, :extract_subtitle, fn ^video, 2 ->
      {:ok, subtitle(".srt")}
    end)

    assert [%{method: "embedded", status: :aligned}] = Sync.analyze_video(video)
    assert_receive {:engine_formats, ".srt", ".srt"}
  end

  test "manual correction keeps one immutable backup, reapplies from it, and reset restores it",
       %{
         video: video
       } do
    path = managed_srt!(video)
    [item] = Sync.discover(video)
    original = File.read!(path)

    assert {:ok, :corrected, _} = Sync.manual(item, 1_000, 1.0)
    backup = SidecarTransaction.backup_path(path)
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

    assert %{method: "audio", status: "aligned", version: 6} =
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

    assert %{method: "audio", status: "aligned", version: 6} =
             Manifest.sync(Manifest.read(video), "en")
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

  test "a Cantonese sidecar still selects an embedded track tagged with the generic Chinese code (#519)",
       %{video: video} do
    managed_srt!(video, "cn")

    # Cinder.Library.MediaInfo.Ffprobe.subtitle_language/1 reports the raw, validated ffprobe
    # tag - never canonicalized through Language.normalize/1 - so the track here carries the raw
    # "chi" alias string exactly as a real Cantonese-tagged file would (#573).
    expect(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video ->
      {:ok, [%{index: 2, language: "chi", forced?: false, default?: true, packet_count: 20}]}
    end)

    expect(Cinder.Library.MediaInfoMock, :extract_subtitle, fn ^video, 2 ->
      {:ok, subtitle(".srt")}
    end)

    expect(Cinder.Subtitles.Sync.EngineMock, :sync, fn reference, input, output ->
      # The embedded "chi" track was selected as the reference, not a fallback to raw audio.
      assert File.read!(reference) == subtitle(".srt")
      assert File.read!(input) == subtitle(".srt")
      File.write!(output, shifted_subtitle(subtitle(".srt")))
      {:ok, %{score: 30.0, offset_ms: 1_000, rate: 1.0}}
    end)

    assert [%{method: "embedded", status: :corrected}] = Sync.analyze_video(video)
  end

  test "a cn (Cantonese) target prefers a lower-priority yue track over a higher-priority Mandarin cmn track (#573)",
       %{video: video} do
    managed_srt!(video, "cn")

    # cmn (explicitly Mandarin) has more packets and would win the sort-by-packet-count
    # tiebreak if it were allowed to satisfy a Cantonese target at all - proving it is filtered
    # out entirely, not merely deprioritized, requires the weaker yue track to still be picked.
    expect(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video ->
      {:ok,
       [
         %{index: 2, language: "cmn", forced?: false, default?: true, packet_count: 999},
         %{index: 3, language: "yue", forced?: false, default?: false, packet_count: 5}
       ]}
    end)

    expect(Cinder.Library.MediaInfoMock, :extract_subtitle, fn ^video, 3 ->
      {:ok, subtitle(".srt")}
    end)

    expect(Cinder.Subtitles.Sync.EngineMock, :sync, fn reference, input, output ->
      assert File.read!(reference) == subtitle(".srt")
      assert File.read!(input) == subtitle(".srt")
      File.write!(output, shifted_subtitle(subtitle(".srt")))
      {:ok, %{score: 30.0, offset_ms: 1_000, rate: 1.0}}
    end)

    assert [%{method: "embedded", status: :corrected}] = Sync.analyze_video(video)
  end

  test "a cn (Cantonese) target prefers an unambiguous yue track over a louder generic chi track (#573)",
       %{video: video} do
    managed_srt!(video, "cn")

    # "chi" (generic Chinese) satisfies "cn" via the forward-tolerance list but is ambiguous - it
    # could genuinely be Mandarin. "yue" positively identifies Cantonese. The exact track must
    # win even though the ambiguous one has far more packets (Codex review finding on PR #574).
    expect(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video ->
      {:ok,
       [
         %{index: 2, language: "chi", forced?: false, default?: true, packet_count: 999},
         %{index: 3, language: "yue", forced?: false, default?: false, packet_count: 5}
       ]}
    end)

    expect(Cinder.Library.MediaInfoMock, :extract_subtitle, fn ^video, 3 ->
      {:ok, subtitle(".srt")}
    end)

    expect(Cinder.Subtitles.Sync.EngineMock, :sync, fn reference, input, output ->
      assert File.read!(reference) == subtitle(".srt")
      assert File.read!(input) == subtitle(".srt")
      File.write!(output, shifted_subtitle(subtitle(".srt")))
      {:ok, %{score: 30.0, offset_ms: 1_000, rate: 1.0}}
    end)

    assert [%{method: "embedded", status: :corrected}] = Sync.analyze_video(video)
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
    refute File.exists?(SidecarTransaction.backup_path(path))

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
    assert File.read!(SidecarTransaction.backup_path(path)) == ""
  end

  test "video replacement rejects a mismatched immutable backup", %{video: video} do
    path = managed_srt!(video)
    [item] = Sync.discover(video)
    assert {:ok, :corrected, _} = Sync.manual(item, 1_000, 1.0)
    corrected = File.read!(path)
    metadata = Manifest.sync(Manifest.read(video), "en")
    backup = SidecarTransaction.backup_path(path)
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
    backup = SidecarTransaction.backup_path(path)
    metadata = Manifest.sync(Manifest.read(video), "en")

    fail_once(%{
      operation: :moviehash_data,
      source_contains: Path.basename(video),
      reason: :eio
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
    backup = SidecarTransaction.backup_path(path)
    metadata = Manifest.sync(Manifest.read(video), "en")
    File.write!(video, "short")

    assert [%{status: :review, reason: "moviehash_unavailable"}] = Sync.analyze_video(video)
    assert File.read!(path) == corrected
    assert File.exists?(backup)
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

    assert_receive {:filesystem_barrier, pid, ref, :open_bound, ^path}, 15_000
    File.rm!(path)
    File.ln_s!(outside, path)
    send(pid, {ref, :continue})

    assert [%{status: :failed}] = Task.await(task, 15_000)
    assert File.read!(outside) == subtitle(".srt")
    refute File.exists?(SidecarTransaction.backup_path(path))

    refute Enum.any?(File.ls!(Path.dirname(path)), fn name ->
             String.starts_with?(name, ".cinder-subtitle-sync-")
           end)
  end

  test "engine input close failure after completed analysis preserves the result", %{video: video} do
    path = managed_srt!(video)
    original = File.read!(path)

    fail_once(%{
      operation: :close_bound,
      source_contains: Path.basename(path),
      reason: :eio
    })

    stub(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video -> {:ok, []} end)

    expect(Cinder.Subtitles.Sync.EngineMock, :sync, fn _reference, _input, output ->
      File.write!(output, original)
      {:ok, %{score: 30.0, offset_ms: 0, rate: 1.0}}
    end)

    {results, log} = with_log(fn -> Sync.analyze_video(video) end)
    assert [%{status: :aligned}] = results
    assert log =~ "descriptor close failed after completed subtitle analysis"

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
    refute File.exists?(SidecarTransaction.backup_path(path))
    assert Manifest.sync(Manifest.read(video), "en") == nil
  end

  test "same-name replacement before first analysis is review-only", %{video: video} do
    path = managed_srt!(video)
    external = String.replace(subtitle(".srt"), "One", "External edit")
    File.write!(path, external)

    assert [%{status: :review, reason: "externally_modified"}] = Sync.analyze_video(video)
    assert File.read!(path) == external
    refute File.exists?(SidecarTransaction.backup_path(path))
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
    refute File.exists?(SidecarTransaction.backup_path(path))
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

    assert [%{status: :failed, reason: :concurrent_change}] = Task.await(task, 15_000)
    assert File.read!(path) == external
    refute File.exists?(SidecarTransaction.backup_path(path))
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
    assert_receive {:filesystem_barrier, pid, ref, :moviehash_data, ^video}, 15_000
    File.write!(path, external)
    send(pid, {ref, :continue})

    assert {:error, :externally_modified} = Task.await(task, 15_000)
    assert File.read!(path) == external
    refute File.exists?(SidecarTransaction.backup_path(path))
    assert Manifest.sync(Manifest.read(video), "en") == nil
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

    fail_once(%{
      operation: :close_bound,
      source_contains: Path.basename(video),
      reason: :eio
    })

    {results, log} = with_log(fn -> Sync.analyze_video(video) end)
    assert [%{status: :corrected}] = results
    assert log =~ "descriptor close failed after completed subtitle analysis"
    assert File.read!(path) =~ "00:00:02,000"
    assert %{status: "aligned"} = Manifest.sync(Manifest.read(video), "en")
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

  test "an external edit after synchronization is review-only and preserves the immutable backup",
       %{
         video: video
       } do
    path = managed_srt!(video)
    [item] = Sync.discover(video)
    assert {:ok, :corrected, _item} = Sync.manual(item, 1_000, 1.0)
    original_backup = File.read!(SidecarTransaction.backup_path(path))
    external = String.replace(subtitle(".srt"), "One", "Externally edited")
    File.write!(path, external)

    assert [%{status: :review, reason: "externally_modified"}] = Sync.analyze_video(video)
    assert File.read!(path) == external
    assert File.read!(SidecarTransaction.backup_path(path)) == original_backup

    assert %{status: "review", reason: "externally_modified"} =
             Manifest.sync(Manifest.read(video), "en")
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
    backup = SidecarTransaction.backup_path(sidecar)
    assert {:ok, bound} = Disk.create_bound(backup, content)
    assert :ok = Manifest.put_backup_tombstone(video, language, bound.identity)
    assert :ok = Disk.close_bound(bound)
    backup
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
