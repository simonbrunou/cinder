defmodule Cinder.SubtitlesTest do
  # Every test runs against a real movies library in a temp directory: `FilesystemMock` delegates
  # to `Disk` (`Mox.stub_with/2`), so a published sidecar goes through the real rooted helper,
  # and a test overrides only the call it is about (the video's moviehash, a failing write).
  use Cinder.DataCase, async: false

  import Cinder.Test.BarrierFilesystem, only: [fail_once: 1]
  import Mox
  import ExUnit.CaptureLog

  alias Cinder.ConfigCase
  alias Cinder.Library.Filesystem.Disk
  alias Cinder.Subtitles
  alias Cinder.Subtitles.Manifest
  alias Cinder.Subtitles.Moviehash
  alias Cinder.Subtitles.Sync.Worker
  alias Cinder.Subtitles.TrackProbe
  alias Cinder.Subtitles.TrackRejection
  alias Cinder.Test.DiskTask

  @moduletag :tmp_dir
  @zeros <<0::size(65_536 * 8)>>

  setup :verify_on_exit!

  setup %{tmp_dir: tmp} do
    saved_provider = Application.get_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, [])

    keys = [
      :media_info,
      :filesystem,
      :filesystem_barrier,
      :path_policy,
      :movies_library_path,
      :tv_library_path
    ]

    saved = Map.new(keys, &{&1, Application.get_env(:cinder, &1)})

    on_exit(fn ->
      Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, saved_provider)

      Enum.each(saved, fn
        {key, nil} -> Application.delete_env(:cinder, key)
        {key, value} -> Application.put_env(:cinder, key, value)
      end)
    end)

    Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, languages: "fr")
    Application.put_env(:cinder, :media_info, nil)
    Application.put_env(:cinder, :path_policy, Cinder.Library.PathPolicy)
    Application.put_env(:cinder, :movies_library_path, Path.join(tmp, "movies"))
    Application.put_env(:cinder, :tv_library_path, Path.join(tmp, "tv"))

    video = Path.join(tmp, "movies/M/M.mkv")
    put!(video, "video")

    stub_with(Cinder.Library.FilesystemMock, Disk)
    stub(Cinder.Library.FilesystemMock, :moviehash_data, fn _ -> :too_small end)
    stub(Cinder.Subtitles.TranslatorMock, :configured?, fn -> true end)

    stub(Cinder.Library.FilesystemMock, :read, fn path ->
      send(self(), {:read, path})
      Disk.read(path)
    end)

    {:ok, video: video}
  end

  test "wanted_languages/0 parses csv and is [] when blank" do
    Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, languages: "en, FR")
    assert Subtitles.wanted_languages() == ["en", "fr"]

    Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, languages: "  ")
    assert Subtitles.wanted_languages() == []
  end

  test "sidecar_path/2 preserves the normal video.lang.srt name" do
    assert Subtitles.sidecar_path("/lib/M/M.mkv", "fr") == "/lib/M/M.fr.srt"
  end

  test "a current hash manifest re-searches when its target sidecar is missing", %{video: video} do
    moviehash = Moviehash.compute(131_072, @zeros, @zeros)

    put_manifest!(video, %{
      video_moviehash: moviehash,
      tracks: %{"fr" => %{origin: "opensubtitles_hash"}}
    })

    expect(Cinder.Library.FilesystemMock, :moviehash_data, fn ^video ->
      {:ok, {131_072, @zeros, @zeros}}
    end)

    expect(Cinder.Subtitles.ProviderMock, :search, fn %{languages: ["fr"]} ->
      {:ok, [result(1, "fr", moviehash_match: true)]}
    end)

    expect(Cinder.Subtitles.ProviderMock, :download, fn 1 ->
      {:ok, "1\n00:00:01,000 --> 00:00:02,000\nHASH SRT\n\n"}
    end)

    expect(Cinder.Library.MediaServerMock, :scan, fn :movies -> :ok end)

    assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, video, :movies)

    assert File.read!(Subtitles.sidecar_path(video, "fr")) ==
             "1\n00:00:01,000 --> 00:00:02,000\nHASH SRT\n\n"
  end

  test "a malformed provider language does not hide a valid later candidate", %{video: video} do
    expect(Cinder.Subtitles.ProviderMock, :search, fn %{languages: ["fr"]} ->
      {:ok, [result(1, nil, downloads: 10), result(2, "fr")]}
    end)

    expect(Cinder.Subtitles.ProviderMock, :download, fn 2 ->
      {:ok, "1\n00:00:01,000 --> 00:00:02,000\nFR SRT\n\n"}
    end)

    expect(Cinder.Library.MediaServerMock, :scan, fn :movies -> :ok end)

    assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, video, :movies)

    assert File.read!(Subtitles.sidecar_path(video, "fr")) ==
             "1\n00:00:01,000 --> 00:00:02,000\nFR SRT\n\n"
  end

  test "a successful OpenSubtitles download enqueues synchronization", %{video: video} do
    parent = self()

    start_supervised!(
      {Worker,
       initial_scan: false,
       analyze: fn video ->
         send(parent, {:analyzed, video})
         []
       end}
    )

    expect(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, [result(1, "fr")]} end)

    expect(Cinder.Subtitles.ProviderMock, :download, fn 1 ->
      {:ok, "1\n00:00:01,000 --> 00:00:02,000\nFR SRT\n\n"}
    end)

    expect(Cinder.Library.MediaServerMock, :scan, fn :movies -> :ok end)

    assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, video, :movies)
    assert_receive {:analyzed, ^video}

    assert File.read!(Subtitles.sidecar_path(video, "fr")) ==
             "1\n00:00:01,000 --> 00:00:02,000\nFR SRT\n\n"

    track = Manifest.read(video).tracks["fr"]
    assert track.file == "M.fr.srt"

    assert track.managed_sha256 ==
             "1\n00:00:01,000 --> 00:00:02,000\nFR SRT\n\n"
             |> then(&:crypto.hash(:sha256, &1))
             |> Base.encode16(case: :lower)
  end

  test "an unacknowledged publication is verified before provenance is written", %{
    video: video
  } do
    target = Subtitles.sidecar_path(video, "fr")

    stub(Cinder.Library.FilesystemMock, :rename_exclusive, fn source, destination ->
      with :ok <- Disk.rename_exclusive(source, destination) do
        if destination == target,
          do: {:error, {:effect_committed, "rename_exclusive", %{"reason" => "EIO"}}},
          else: :ok
      end
    end)

    expect(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, [result(1, "fr")]} end)

    expect(Cinder.Subtitles.ProviderMock, :download, fn 1 ->
      {:ok, "1\n00:00:01,000 --> 00:00:02,000\nFR SRT\n\n"}
    end)

    expect(Cinder.Library.MediaServerMock, :scan, fn :movies -> :ok end)

    log =
      capture_log(fn ->
        assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, video, :movies)
      end)

    assert log =~ "subtitle publication unacknowledged for #{target}"
    assert File.read!(target) == "1\n00:00:01,000 --> 00:00:02,000\nFR SRT\n\n"
    assert Manifest.read(video).tracks["fr"].file == "M.fr.srt"
  end

  test "concurrent release-sidecar manifests serialize by video", %{video: video} do
    set_mox_global()
    Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, languages: "")

    fr = Subtitles.sidecar_path(video, "fr")
    en = Subtitles.sidecar_path(video, "en")
    put!(fr, "1\n00:00:01,000 --> 00:00:02,000\nFR SRT\n\n")
    put!(en, "1\n00:00:01,000 --> 00:00:02,000\nEN SRT\n\n")

    manifest = Manifest.path(video)
    parent = self()
    barrier = start_supervised!({Agent, fn -> %{active: true, waiters: []} end})

    stub(Cinder.Library.FilesystemMock, :read, fn path ->
      result = Disk.read(path)

      if path == manifest and Agent.get(barrier, & &1.active) do
        waiter = self()
        Agent.update(barrier, fn state -> %{state | waiters: [waiter | state.waiters]} end)
        send(parent, {:manifest_read_ready, waiter})

        receive do
          :continue_manifest_read -> result
        end
      else
        result
      end
    end)

    try do
      # As if each import placed its sidecar: an import marks only those (#918).
      assert :ok =
               Subtitles.fetch_after_import(fn -> %{} end, video, :movies,
                 languages: ["fr"],
                 placed: [fr]
               )

      assert :ok =
               Subtitles.fetch_after_import(fn -> %{} end, video, :movies,
                 languages: ["en"],
                 placed: [en]
               )

      assert_receive {:manifest_read_ready, first}, DiskTask.timeout_ms()
      refute_receive {:manifest_read_ready, _second}, 200

      # Each task reads the manifest twice inside its lock: the keep_verified? pre-check, then
      # Manifest.put's own read. The second task's first read must still only happen after the
      # first task released the lock — that's the serialization being proven.
      first_ref = Process.monitor(first)
      send(first, :continue_manifest_read)
      assert_receive {:manifest_read_ready, ^first}, DiskTask.timeout_ms()
      send(first, :continue_manifest_read)

      assert_receive {:DOWN, ^first_ref, :process, ^first, :normal}, DiskTask.timeout_ms()

      assert_receive {:manifest_read_ready, second}, DiskTask.timeout_ms()
      second_ref = Process.monitor(second)
      send(second, :continue_manifest_read)
      assert_receive {:manifest_read_ready, ^second}, DiskTask.timeout_ms()
      send(second, :continue_manifest_read)

      assert_receive {:DOWN, ^second_ref, :process, ^second, :normal}, DiskTask.timeout_ms()

      Agent.update(barrier, &%{&1 | active: false})

      assert %{
               tracks: %{
                 "en" => %{origin: "release_sidecar"},
                 "fr" => %{origin: "release_sidecar"}
               }
             } = Manifest.read(video)
    after
      barrier
      |> Agent.get(& &1.waiters)
      |> Enum.each(&send(&1, :continue_manifest_read))
    end
  end

  test "an ID result is provisional and a later hash result replaces it", %{video: video} do
    target = Subtitles.sidecar_path(video, "fr")
    calls = start_supervised!({Agent, fn -> %{hash_reads: 0, searches: 0} end})

    expect(Cinder.Library.FilesystemMock, :moviehash_data, 2, fn ^video ->
      case next(calls, :hash_reads) do
        0 -> :too_small
        1 -> {:ok, {131_072, @zeros, @zeros}}
      end
    end)

    expect(Cinder.Subtitles.ProviderMock, :search, 2, fn %{languages: ["fr"]} ->
      case next(calls, :searches) do
        0 -> {:ok, [result(1, "fr")]}
        1 -> {:ok, [result(2, "fr", moviehash_match: true)]}
      end
    end)

    expect(Cinder.Subtitles.ProviderMock, :download, 2, fn
      1 -> {:ok, "1\n00:00:01,000 --> 00:00:02,000\nID SRT\n\n"}
      2 -> {:ok, "1\n00:00:01,000 --> 00:00:02,000\nHASH SRT\n\n"}
    end)

    expect(Cinder.Library.MediaServerMock, :scan, 2, fn :movies -> :ok end)

    assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, video, :movies)

    assert %{tracks: %{"fr" => %{origin: "opensubtitles_id", file: "M.fr.srt"}}} =
             Manifest.read(video)

    assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, video, :movies)

    assert %{tracks: %{"fr" => %{origin: "opensubtitles_hash", file: "M.fr.srt"}}} =
             Manifest.read(video)

    assert File.read!(target) == "1\n00:00:01,000 --> 00:00:02,000\nHASH SRT\n\n"
  end

  test "a transient moviehash read failure preserves a verified sibling's provenance", %{
    video: video
  } do
    target_en = Subtitles.sidecar_path(video, "en")
    target_fr = Subtitles.sidecar_path(video, "fr")
    moviehash = Moviehash.compute(131_072, @zeros, @zeros)
    en_bytes = "1\n00:00:01,000 --> 00:00:02,000\nHello\n\n"

    Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, languages: "en,fr")
    put!(target_en, en_bytes)

    put_manifest!(video, %{
      video_moviehash: moviehash,
      tracks: %{"en" => %{origin: "opensubtitles_hash"}}
    })

    expect(Cinder.Library.FilesystemMock, :moviehash_data, fn ^video -> {:error, :eio} end)

    expect(Cinder.Subtitles.ProviderMock, :search, 2, fn
      %{languages: ["en"]} -> {:ok, [result(9, "en")]}
      %{languages: ["fr"]} -> {:ok, [result(1, "fr")]}
    end)

    stub(Cinder.Subtitles.ProviderMock, :download, fn
      1 -> {:ok, "1\n00:00:01,000 --> 00:00:02,000\nBonjour\n\n"}
      9 -> {:ok, "1\n00:00:01,000 --> 00:00:02,000\nDOWNGRADED EN\n\n"}
    end)

    stub(Cinder.Library.MediaServerMock, :scan, fn :movies -> :ok end)

    assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, video, :movies)

    assert File.read!(target_en) == en_bytes
    assert File.read!(target_fr) == "1\n00:00:01,000 --> 00:00:02,000\nBonjour\n\n"

    assert %{
             video_moviehash: ^moviehash,
             tracks: %{
               "en" => %{origin: "opensubtitles_hash"},
               "fr" => %{origin: "opensubtitles_id"}
             }
           } = Manifest.read(video)

    assert Manifest.stable?(Manifest.read(video), moviehash, "en")
  end

  test "an HTML provider body does not clobber an existing good sidecar", %{video: video} do
    target = Subtitles.sidecar_path(video, "fr")
    good_content = "1\n00:00:01,000 --> 00:00:02,000\nGOOD SRT\n\n"
    good_sha256 = digest(good_content)
    put!(target, good_content)

    put_manifest!(video, %{
      video_moviehash: nil,
      tracks: %{
        "fr" => %{origin: "opensubtitles_hash", file: "M.fr.srt", managed_sha256: good_sha256}
      }
    })

    stub(Cinder.Library.FilesystemMock, :moviehash_data, fn ^video ->
      {:ok, {131_072, @zeros, @zeros}}
    end)

    expect(Cinder.Subtitles.ProviderMock, :search, fn _ ->
      {:ok, [result(1, "fr", moviehash_match: true)]}
    end)

    expect(Cinder.Subtitles.ProviderMock, :download, fn 1 ->
      {:ok, "<html><body>Cloudflare interstitial</body></html>"}
    end)

    deny(Cinder.Library.MediaServerMock, :scan, 1)

    log =
      capture_log(fn ->
        assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, video, :movies)
      end)

    assert log =~ "failed validation"
    assert File.read!(target) == good_content

    assert %{tracks: %{"fr" => %{origin: "opensubtitles_hash", managed_sha256: ^good_sha256}}} =
             Manifest.read(video)
  end

  test "a manifest failure restores the previous managed sidecar", %{video: video} do
    target = Subtitles.sidecar_path(video, "fr")
    put!(target, "1\n00:00:01,000 --> 00:00:02,000\nOLD SRT\n\n")

    put_manifest!(video, %{
      video_moviehash: nil,
      tracks: %{"fr" => %{origin: "opensubtitles_id"}}
    })

    stub(Cinder.Library.FilesystemMock, :moviehash_data, fn ^video ->
      {:ok, {131_072, @zeros, @zeros}}
    end)

    fail_manifest_writes()

    expect(Cinder.Subtitles.ProviderMock, :search, fn _ ->
      {:ok, [result(1, "fr", moviehash_match: true)]}
    end)

    expect(Cinder.Subtitles.ProviderMock, :download, fn 1 ->
      {:ok, "1\n00:00:01,000 --> 00:00:02,000\nNEW SRT\n\n"}
    end)

    deny(Cinder.Library.MediaServerMock, :scan, 1)

    log =
      capture_log(fn ->
        assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, video, :movies)
      end)

    assert log =~ "subtitle provenance write failed for #{video} (fr): {:error, :eio}"
    assert File.read!(target) == "1\n00:00:01,000 --> 00:00:02,000\nOLD SRT\n\n"
    assert %{tracks: %{"fr" => %{origin: "opensubtitles_id"}}} = Manifest.read(video)
  end

  test "a manifest failure removes a newly written sidecar", %{video: video} do
    target = Subtitles.sidecar_path(video, "fr")

    stub(Cinder.Library.FilesystemMock, :moviehash_data, fn ^video ->
      {:ok, {131_072, @zeros, @zeros}}
    end)

    fail_manifest_writes()

    expect(Cinder.Subtitles.ProviderMock, :search, fn _ ->
      {:ok, [result(1, "fr", moviehash_match: true)]}
    end)

    expect(Cinder.Subtitles.ProviderMock, :download, fn 1 ->
      {:ok, "1\n00:00:01,000 --> 00:00:02,000\nNEW SRT\n\n"}
    end)

    deny(Cinder.Library.MediaServerMock, :scan, 1)

    log =
      capture_log(fn ->
        assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, video, :movies)
      end)

    assert log =~ "subtitle provenance write failed for #{video} (fr): {:error, :eio}"
    refute File.exists?(target)
  end

  # #1202: the download arrives, but the manifest it must be recorded in cannot be read.
  test "a manifest that cannot be read keeps the previous managed sidecar and every record", %{
    video: video
  } do
    target = Subtitles.sidecar_path(video, "fr")
    put!(target, "1\n00:00:01,000 --> 00:00:02,000\nOLD SRT\n\n")

    put_manifest!(video, %{
      video_moviehash: nil,
      tracks: %{"en" => %{origin: "embedded"}, "fr" => %{origin: "opensubtitles_id"}}
    })

    manifest_path = Manifest.path(video)
    manifest = File.read!(manifest_path)

    stub(Cinder.Library.FilesystemMock, :moviehash_data, fn ^video ->
      {:ok, {131_072, @zeros, @zeros}}
    end)

    stub(Cinder.Library.FilesystemMock, :read, fn
      ^manifest_path ->
        if Process.get(:manifest_unreadable), do: {:error, :eio}, else: Disk.read(manifest_path)

      path ->
        Disk.read(path)
    end)

    expect(Cinder.Subtitles.ProviderMock, :search, fn _ ->
      {:ok, [result(1, "fr", moviehash_match: true)]}
    end)

    expect(Cinder.Subtitles.ProviderMock, :download, fn 1 ->
      Process.put(:manifest_unreadable, true)
      {:ok, "1\n00:00:01,000 --> 00:00:02,000\nNEW SRT\n\n"}
    end)

    deny(Cinder.Library.MediaServerMock, :scan, 1)

    log =
      capture_log(fn ->
        assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, video, :movies)
      end)

    assert log =~ "subtitle manifest cannot be read for #{video}: :eio"

    assert log =~
             "subtitle provenance write failed for #{video} (fr): " <>
               "{:error, {:unreadable_manifest, :eio}}"

    assert File.read!(target) == "1\n00:00:01,000 --> 00:00:02,000\nOLD SRT\n\n"
    assert File.read!(manifest_path) == manifest
  end

  test "a provider failure does not call an embedded source or LibreTranslate", %{video: video} do
    expect(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:error, :down} end)

    log =
      capture_log(fn ->
        assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, video, :movies)
      end)

    assert log =~ "subtitle fetch for #{video} (fr) failed: :down"
  end

  test "an empty provider result extracts an exact embedded target track", %{video: video} do
    Application.put_env(:cinder, :media_info, Cinder.Library.MediaInfoMock)

    expect(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)

    expect(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video ->
      {:ok, [%{index: 2, language: "fr", default?: false, forced?: false}]}
    end)

    expect(Cinder.Library.MediaInfoMock, :extract_subtitle, fn ^video, 2 ->
      {:ok, "1\n00:00:01,000 --> 00:00:02,000\nFR SRT\n\n"}
    end)

    expect(Cinder.Library.MediaServerMock, :scan, fn :movies -> :ok end)

    assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, video, :movies)

    assert File.read!(Subtitles.sidecar_path(video, "fr")) ==
             "1\n00:00:01,000 --> 00:00:02,000\nFR SRT\n\n"

    assert %{tracks: %{"fr" => %{origin: "embedded"}}} = Manifest.read(video)
  end

  describe "the video's own track" do
    setup do
      Application.put_env(:cinder, :media_info, Cinder.Library.MediaInfoMock)

      stub(Cinder.Library.FilesystemMock, :moviehash_data, fn _ ->
        {:ok, {131_072, @zeros, @zeros}}
      end)

      :ok
    end

    # A full French dialogue track comes with the video: it replaces a download, the one not for
    # the hearing impaired wins over the longer SDH one, a forced signs track never qualifies, and
    # once written it is stable for this file, so the next sweep neither probes nor searches.
    test "is preferred over a download and then left alone", %{video: video} do
      expect(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video ->
        {:ok,
         [
           %{index: 2, language: "fre", default?: true, forced?: true, packet_count: 40},
           %{
             index: 3,
             language: "fre",
             default?: false,
             forced?: false,
             hearing_impaired?: true,
             packet_count: 900
           },
           %{
             index: 4,
             language: "fre",
             default?: false,
             forced?: false,
             hearing_impaired?: false,
             packet_count: 850
           }
         ]}
      end)

      expect(Cinder.Library.MediaInfoMock, :extract_subtitle, fn ^video, 4 ->
        {:ok, "1\n00:00:01,000 --> 00:00:02,000\nOWN TRACK\n\n"}
      end)

      expect(Cinder.Library.MediaServerMock, :scan, fn :movies -> :ok end)

      criteria = %{imdb_id: "tt1", embedded_subtitles: ["eng", "fre"]}
      assert :ok = Subtitles.fetch_missing(criteria, video, :movies)

      assert File.read!(Subtitles.sidecar_path(video, "fr")) ==
               "1\n00:00:01,000 --> 00:00:02,000\nOWN TRACK\n\n"

      assert %{tracks: %{"fr" => %{origin: "own_track"}}} = Manifest.read(video)
      assert :ok = Subtitles.fetch_missing(criteria, video, :movies)
    end

    # Listing tracks reads the whole file. A video whose French stream is only a forced signs track
    # (or image-based) never yields an own track, and must not be read again on every sweep.
    test "probes a file once, even when it has no qualifying track", %{video: video} do
      expect(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video ->
        {:ok, [%{index: 2, language: "fre", default?: false, forced?: true, packet_count: 40}]}
      end)

      expect(Cinder.Subtitles.ProviderMock, :search, 2, fn _ -> {:error, :down} end)
      criteria = %{imdb_id: "tt1", embedded_subtitles: ["fre"]}

      capture_log(fn ->
        assert :ok = Subtitles.fetch_missing(criteria, video, :movies)
        assert :ok = Subtitles.fetch_missing(criteria, video, :movies)
      end)
    end

    # At import the criteria come from the record as it was before the file landed, so its
    # recorded streams say nothing about the new file: the tracks are looked at regardless.
    test "is looked for at import even when the record has no streams recorded yet", %{
      video: video
    } do
      expect(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video ->
        {:ok, [%{index: 3, language: "fre", default?: false, forced?: false, packet_count: 700}]}
      end)

      expect(Cinder.Library.MediaInfoMock, :extract_subtitle, fn ^video, 3 ->
        {:ok, "1\n00:00:01,000 --> 00:00:02,000\nOWN TRACK\n\n"}
      end)

      expect(Cinder.Library.MediaServerMock, :scan, fn :movies -> :ok end)

      Subtitles.fetch_now(
        fn -> %{imdb_id: "tt1", embedded_subtitles: nil} end,
        video,
        :movies,
        []
      )

      assert File.read!(Subtitles.sidecar_path(video, "fr")) ==
               "1\n00:00:01,000 --> 00:00:02,000\nOWN TRACK\n\n"
    end

    # Another language's write after an upgrade at the same path updates the manifest-wide hash;
    # an own track extracted from the replaced file must still count as stale.
    test "is extracted again from a file that replaced the one it came from", %{video: video} do
      current = Moviehash.compute(131_072, @zeros, @zeros)
      target = Subtitles.sidecar_path(video, "fr")
      put!(target, "1\n00:00:01,000 --> 00:00:02,000\nOLD\n\n")

      put_manifest!(video, %{
        video_moviehash: current,
        tracks: %{"fr" => %{origin: "own_track", source_moviehash: "0123456789abcdef"}}
      })

      expect(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video ->
        {:ok, [%{index: 3, language: "fre", default?: false, forced?: false, packet_count: 700}]}
      end)

      expect(Cinder.Library.MediaInfoMock, :extract_subtitle, fn ^video, 3 ->
        {:ok, "1\n00:00:01,500 --> 00:00:02,500\nNEW\n\n"}
      end)

      expect(Cinder.Library.MediaServerMock, :scan, fn :movies -> :ok end)

      assert :ok =
               Subtitles.fetch_missing(
                 %{imdb_id: "tt1", embedded_subtitles: ["fre"]},
                 video,
                 :movies
               )

      assert File.read!(target) == "1\n00:00:01,500 --> 00:00:02,500\nNEW\n\n"
      assert %{tracks: %{"fr" => %{source_moviehash: ^current}}} = Manifest.read(video)
    end

    test "is not looked for once a sweep has spent its own-track time", %{video: video} do
      expect(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:error, :down} end)
      spent = System.monotonic_time(:millisecond) - 1

      capture_log(fn ->
        assert :ok =
                 Subtitles.fetch_missing(
                   %{imdb_id: "tt1", embedded_subtitles: ["fre"], own_track_until: spent},
                   video,
                   :movies
                 )
      end)
    end

    test "is not probed for when the import saw no stream in that language", %{video: video} do
      expect(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:error, :down} end)

      capture_log(fn ->
        assert :ok =
                 Subtitles.fetch_missing(
                   %{imdb_id: "tt1", embedded_subtitles: ["eng"]},
                   video,
                   :movies
                 )
      end)
    end

    test "never replaces a sidecar the operator retimed by hand", %{video: video} do
      target = Subtitles.sidecar_path(video, "fr")
      content = "1\n00:00:01,000 --> 00:00:02,000\nRETIMED\n\n"
      put!(target, content)

      put_manifest!(video, %{
        video_moviehash: nil,
        tracks: %{
          "fr" => %{
            origin: "opensubtitles_id",
            sync: %{
              version: 6,
              status: "aligned",
              method: "manual",
              moviehash: nil,
              source_sha256: String.duplicate("a", 64),
              applied_sha256: String.duplicate("b", 64),
              offset_ms: 500,
              rate: 1.0
            }
          }
        }
      })

      expect(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:error, :down} end)

      capture_log(fn ->
        assert :ok =
                 Subtitles.fetch_missing(
                   %{imdb_id: "tt1", embedded_subtitles: ["fre"]},
                   video,
                   :movies
                 )
      end)

      assert File.read!(target) == content
    end
  end

  # #861: listing a video's tracks and extracting one each read the whole file. A sweep over a file
  # that did not change must not read it again for a result that cannot change. The stubs count
  # every read and every commit (a commit asks the media server to scan): an unstubbed mock would
  # raise inside fetch_one/6's rescue, and a negative test could not tell that from no read.
  describe "a sweep over a file it already read" do
    # An ASS typesetting track converted to SRT: a blank line inside a cue fails both the timing
    # check, which the own-track path and the embedded fallback run, and the SRT parser, which
    # a translation source must pass (Monogatari on prod).
    @broken "1\n00:00:01,000 --> 00:00:02,000\nLine one\n\nLine after blank\n\n" <>
              "2\n00:00:03,000 --> 00:00:04,000\nTwo\n\n"
    @srt "1\n00:00:01,000 --> 00:00:02,000\nHello\n\n"
    @other "1\n00:00:01,000 --> 00:00:02,000\n[Door creaks]\n\n"
    # A cue that ends before it starts: the SRT parser accepts it, the timing check does not.
    @reversed "1\n00:00:02,000 --> 00:00:01,000\nHello\n\n"

    setup do
      ConfigCase.put_env(:media_info, Cinder.Library.MediaInfoMock)
      put_moviehash!(131_072)
      test = self()

      stub(Cinder.Library.MediaServerMock, :scan, fn kind ->
        send(test, {:scan, kind})
        :ok
      end)

      :ok
    end

    test "does not extract an own track the timing check rejected", %{video: video} do
      stub_reads(video, {:ok, [own_track(3, "fre")]}, %{3 => {:ok, @broken}})
      stub(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:error, :down} end)
      criteria = %{imdb_id: "tt1", embedded_subtitles: ["fre"]}

      assert effects(criteria, video) == [:probe, {:extract, 3}]
      assert effects(criteria, video) == []
    end

    test "does not extract and write an embedded sidecar it already holds", %{video: video} do
      stub_reads(video, {:ok, [track(2, "fre")]}, %{2 => {:ok, @srt}})
      stub(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)

      assert effects(%{imdb_id: "tt1"}, video) == [:probe, {:extract, 2}, {:scan, :movies}]
      assert File.read!(Subtitles.sidecar_path(video, "fr")) == @srt
      assert effects(%{imdb_id: "tt1"}, video) == []
    end

    test "still replaces an embedded sidecar with an OpenSubtitles match", %{video: video} do
      stub_reads(video, {:ok, [track(2, "fre")]}, %{2 => {:ok, @srt}})
      expect(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)

      expect(Cinder.Subtitles.ProviderMock, :search, fn _ ->
        {:ok, [result(1, "fr", moviehash_match: true)]}
      end)

      download = "1\n00:00:01,000 --> 00:00:02,000\nHASH SRT\n\n"
      expect(Cinder.Subtitles.ProviderMock, :download, fn 1 -> {:ok, download} end)

      assert effects(%{imdb_id: "tt1"}, video) == [:probe, {:extract, 2}, {:scan, :movies}]
      assert effects(%{imdb_id: "tt1"}, video) == [{:scan, :movies}]
      assert File.read!(Subtitles.sidecar_path(video, "fr")) == download
      assert %{tracks: %{"fr" => %{origin: "opensubtitles_hash"}}} = Manifest.read(video)
    end

    # #1071: the fallback tries the tracks in preference order (#575), and a busy disk fails one
    # extraction the way a damaged file does. The sidecar records the track it came from, so a
    # later sweep tries again the tracks ranked ahead of it, never the one it already holds.
    test "takes the first track once a passing failure on it left the sidecar the second", %{
      video: video
    } do
      stub_extractions(video, [track(2, "fre"), track(3, "fre")], %{
        2 => [{:error, :timeout}, {:ok, @srt}],
        3 => [{:ok, @other}]
      })

      stub(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)
      target = Subtitles.sidecar_path(video, "fr")

      assert effects(%{imdb_id: "tt1"}, video) ==
               [:probe, {:extract, 2}, {:extract, 3}, {:scan, :movies}]

      assert File.read!(target) == @other
      assert effects(%{imdb_id: "tt1"}, video) == [{:extract, 2}, {:scan, :movies}]
      assert File.read!(target) == @srt
      assert %{tracks: %{"fr" => %{origin: "embedded", source_track: 2}}} = Manifest.read(video)
      assert effects(%{imdb_id: "tt1"}, video) == []
    end

    test "extracts only the tracks ranked ahead of the one the sidecar came from", %{
      video: video
    } do
      stub_extractions(video, [track(2, "fre"), track(3, "fre"), track(4, "fre")], %{
        2 => [{:error, :timeout}],
        3 => [{:error, :timeout}],
        4 => [{:ok, @srt}]
      })

      stub(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)

      assert effects(%{imdb_id: "tt1"}, video) ==
               [:probe, {:extract, 2}, {:extract, 3}, {:extract, 4}, {:scan, :movies}]

      assert %{origin: "embedded", source_track: 4} = entry = Manifest.read(video).tracks["fr"]

      for _sweep <- 1..2 do
        assert effects(%{imdb_id: "tt1"}, video) == [{:extract, 2}, {:extract, 3}]
        assert File.read!(Subtitles.sidecar_path(video, "fr")) == @srt
        assert Manifest.read(video).tracks["fr"] == entry
      end
    end

    # Entries written between #1068 and #1071 record no track. The probe row is stored, as it is
    # for every file an embedded sidecar came out of.
    for {label, recorded} <- [
          {"no track", %{}},
          {"a track that is no candidate", %{source_track: 9}}
        ] do
      test "extracts once an embedded sidecar from this file that records #{label}", %{
        video: video
      } do
        moviehash = Moviehash.compute(131_072, @zeros, @zeros)
        target = Subtitles.sidecar_path(video, "fr")

        entry =
          Map.merge(
            %{origin: "embedded", source_moviehash: moviehash},
            unquote(Macro.escape(recorded))
          )

        put!(target, @other)
        put_manifest!(video, %{video_moviehash: moviehash, tracks: %{"fr" => entry}})
        assert {:ok, _tracks} = TrackProbe.tracks(moviehash, fn -> {:ok, [track(2, "fre")]} end)
        stub_reads(video, {:ok, [track(2, "fre")]}, %{2 => {:ok, @srt}})
        stub(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)

        assert effects(%{imdb_id: "tt1"}, video) == [{:extract, 2}, {:scan, :movies}]
        assert File.read!(target) == @srt
        assert %{tracks: %{"fr" => %{origin: "embedded", source_track: 2}}} = Manifest.read(video)
        assert effects(%{imdb_id: "tt1"}, video) == []
      end
    end

    test "does not extract a default track that did not parse as a translation source", %{
      video: video
    } do
      stub_reads(video, {:ok, [track(3, "eng", default?: true)]}, %{3 => {:ok, @broken}})
      stub(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)

      assert effects(%{imdb_id: "tt1"}, video) == [:probe, {:extract, 3}]
      assert effects(%{imdb_id: "tt1"}, video) == []
    end

    # With no translator the sidecars are still looked at: one in the wanted language under another
    # name is copied to the target.
    test "does not extract the default track when no translator is configured", %{video: video} do
      stub_reads(video, {:ok, [track(3, "eng", default?: true)]}, %{3 => {:ok, @srt}})
      stub(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)
      stub(Cinder.Subtitles.TranslatorMock, :configured?, fn -> false end)
      put!(Path.join(Path.dirname(video), "M.fre.srt"), @srt)

      assert effects(%{imdb_id: "tt1"}, video) == [:probe, {:scan, :movies}]
      assert File.read!(Subtitles.sidecar_path(video, "fr")) == @srt
      assert %{tracks: %{"fr" => %{origin: "translated"}}} = Manifest.read(video)
    end

    # #1070: with the target in place the sidecars are not looked at, whatever its origin. A
    # sidecar in its language under another name was copied over it on every sweep that found no
    # usable default track, and each copy asked the media server to scan.
    for origin <- ~w(opensubtitles_id release_sidecar translated),
        name <- ~w(M.fr.forced.srt M.fr.sdh.srt M.fre.srt),
        {default, label} <- [none: "no default track", rejected: "a rejected default track"] do
      test "keeps a #{origin} target beside #{name} with #{label}", %{video: video} do
        target = Subtitles.sidecar_path(video, "fr")
        sidecar = Path.join(Path.dirname(video), unquote(name))
        put!(target, @srt)
        put!(sidecar, @other)

        put_manifest!(video, %{
          video_moviehash: nil,
          tracks: %{"fr" => %{origin: unquote(origin)}}
        })

        entry = Manifest.read(video).tracks["fr"]
        stub_default_track(video, unquote(default))
        stub(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)

        assert effects(%{imdb_id: "tt1"}, video) == [:probe]
        refute_received {:read, ^sidecar}
        assert File.read!(target) == @srt
        assert Manifest.read(video).tracks["fr"] == entry
      end
    end

    for name <- ~w(M.fre.srt M.fr.sdh.srt),
        {default, label} <- [none: "no default track", rejected: "a rejected default track"] do
      test "copies #{name} to a missing target once with #{label}", %{video: video} do
        put!(Path.join(Path.dirname(video), unquote(name)), @srt)
        stub_default_track(video, unquote(default))
        stub(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)

        assert effects(%{imdb_id: "tt1"}, video) == [:probe, {:scan, :movies}]
        assert File.read!(Subtitles.sidecar_path(video, "fr")) == @srt
        assert %{tracks: %{"fr" => %{origin: "translated"}}} = Manifest.read(video)
        assert effects(%{imdb_id: "tt1"}, video) == []
      end
    end

    # A forced sidecar holds only the lines the audio does not carry, as a forced track does.
    for name <- ~w(M.fr.forced.srt M.en.forced.srt) do
      test "never takes #{name} as a source for a missing target", %{video: video} do
        sidecar = Path.join(Path.dirname(video), unquote(name))
        put!(sidecar, @srt)
        stub_default_track(video, :none)
        stub(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)
        stub_translate()

        assert effects(%{imdb_id: "tt1"}, video) == [:probe]
        refute_received {:read, ^sidecar}
        refute_received {:translate, _language}
        refute File.exists?(Subtitles.sidecar_path(video, "fr"))
      end
    end

    # The flagged sidecar is listed first, so a pick in listing order takes it.
    for flag <- ~w(sdh cc hi) do
      test "prefers M.fre.srt over M.fr.#{flag}.srt for a missing target", %{video: video} do
        flagged = Path.join(Path.dirname(video), "M.fr.#{unquote(flag)}.srt")
        put!(Path.join(Path.dirname(video), "M.fre.srt"), @srt)
        put!(flagged, @other)
        list_first(flagged)
        stub_default_track(video, :none)
        stub(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)

        assert effects(%{imdb_id: "tt1"}, video) == [:probe, {:scan, :movies}]
        assert File.read!(Subtitles.sidecar_path(video, "fr")) == @srt
      end

      test "copies a lone M.fr.#{flag}.srt to a missing target", %{video: video} do
        put!(Path.join(Path.dirname(video), "M.fr.#{unquote(flag)}.srt"), @other)
        stub_default_track(video, :none)
        stub(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)

        assert effects(%{imdb_id: "tt1"}, video) == [:probe, {:scan, :movies}]
        assert File.read!(Subtitles.sidecar_path(video, "fr")) == @other
        assert %{tracks: %{"fr" => %{origin: "translated"}}} = Manifest.read(video)
      end
    end

    # #1087: a flag word in a scene-named sidecar's title is no flag. Read as forced, this one
    # was never a source.
    test "copies a lone sidecar whose scene title holds Forced to a missing target", %{
      video: video
    } do
      name = "Forced.Entry.1983.1080p.BluRay.x264-GRP.fr.srt"
      put!(Path.join(Path.dirname(video), name), @srt)
      stub_default_track(video, :none)
      stub(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)

      assert effects(%{imdb_id: "tt1"}, video) == [:probe, {:scan, :movies}]
      assert File.read!(Subtitles.sidecar_path(video, "fr")) == @srt
      assert %{tracks: %{"fr" => %{origin: "translated"}}} = Manifest.read(video)
    end

    # Read as hearing-impaired, the sidecar listed first lost to `M.fre.srt`.
    test "ranks a sidecar whose scene title holds Hi as an unflagged one", %{video: video} do
      scene = Path.join(Path.dirname(video), "Hi.Mom.2021.1080p.WEB-DL.fr.srt")
      put!(Path.join(Path.dirname(video), "M.fre.srt"), @other)
      put!(scene, @srt)
      list_first(scene)
      stub_default_track(video, :none)
      stub(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)

      assert effects(%{imdb_id: "tt1"}, video) == [:probe, {:scan, :movies}]
      assert File.read!(Subtitles.sidecar_path(video, "fr")) == @srt
    end

    # The steps before the sidecars still replace a managed target.
    test "an embedded track in the language still replaces a managed target beside a sidecar", %{
      video: video
    } do
      target = Subtitles.sidecar_path(video, "fr")
      put!(target, @other)
      put!(Path.join(Path.dirname(video), "M.fre.srt"), @other)

      put_manifest!(video, %{
        video_moviehash: nil,
        tracks: %{"fr" => %{origin: "opensubtitles_id"}}
      })

      stub_reads(video, {:ok, [track(2, "fre")]}, %{2 => {:ok, @srt}})
      stub(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)

      assert effects(%{imdb_id: "tt1"}, video) == [:probe, {:extract, 2}, {:scan, :movies}]
      assert File.read!(target) == @srt
      assert %{tracks: %{"fr" => %{origin: "embedded"}}} = Manifest.read(video)
    end

    test "an OpenSubtitles match still replaces a managed target beside a sidecar", %{
      video: video
    } do
      target = Subtitles.sidecar_path(video, "fr")
      put!(target, @other)
      put!(Path.join(Path.dirname(video), "M.fre.srt"), @other)
      put_manifest!(video, %{video_moviehash: nil, tracks: %{"fr" => %{origin: "translated"}}})
      stub_default_track(video, :none)

      expect(Cinder.Subtitles.ProviderMock, :search, fn _ ->
        {:ok, [result(1, "fr", moviehash_match: true)]}
      end)

      expect(Cinder.Subtitles.ProviderMock, :download, fn 1 -> {:ok, @srt} end)

      assert effects(%{imdb_id: "tt1"}, video) == [{:scan, :movies}]
      assert File.read!(target) == @srt
      assert %{tracks: %{"fr" => %{origin: "opensubtitles_hash"}}} = Manifest.read(video)
    end

    # ffprobe's stderr merged into its JSON once broke the probe of a whole file on every sweep.
    test "does not probe again a file whose probe output did not parse", %{video: video} do
      stub_reads(video, {:error, %Jason.DecodeError{position: 0, data: ""}}, %{})
      stub(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:error, :down} end)
      criteria = %{imdb_id: "tt1", embedded_subtitles: ["fre"]}

      assert effects(criteria, video) == [:probe]
      assert effects(criteria, video) == []
    end

    # A busy disk times out a probe and fails an extraction the same way a damaged file would.
    test "probes and extracts again after a timeout", %{video: video} do
      stub_reads(video, {:error, :timeout}, %{})
      stub(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:error, :down} end)
      criteria = %{imdb_id: "tt1", embedded_subtitles: ["fre"]}

      assert effects(criteria, video) == [:probe]
      assert effects(criteria, video) == [:probe]

      put_moviehash!(131_073)
      stub_reads(video, {:ok, [own_track(3, "fre")]}, %{3 => {:error, :timeout}})

      assert effects(criteria, video) == [:probe, {:extract, 3}]
      assert effects(criteria, video) == [{:extract, 3}]
    end

    # Monogatari on prod: one English track, the default, that fails both checks, and French
    # wanted too. Each check asked for the same track, so a sweep read the file three times, and
    # the embedded fallback wrote the track the timing check had rejected as the English sidecar
    # (#1072). A file whose moviehash changed is read again.
    test "reads a file once, then not until it changes", %{video: video} do
      ConfigCase.put_config(Cinder.Subtitles.Provider.OpenSubtitles, languages: "en,fr")
      stub_reads(video, {:ok, [own_track(3, "eng", default?: true)]}, %{3 => {:ok, @broken}})
      stub(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)

      criteria = %{
        imdb_id: "tt1",
        embedded_subtitles: ["eng"],
        own_track_until: System.monotonic_time(:millisecond) + 60_000
      }

      assert effects(criteria, video) == [:probe, {:extract, 3}]
      refute File.exists?(Subtitles.sidecar_path(video, "en"))
      refute Map.has_key?(Manifest.read(video).tracks, "en")
      assert effects(criteria, video) == []

      put_moviehash!(131_073)

      assert effects(criteria, video) == [:probe, {:extract, 3}]
      assert effects(criteria, video) == []
    end

    # #1072: the embedded fallback checks each candidate as the own-track path does, and the
    # rejection it stores keeps a later sweep from reading the file again for that track.
    test "commits the next candidate after one the timing check rejects", %{video: video} do
      stub_reads(video, {:ok, [track(2, "fre"), track(3, "fre")]}, %{
        2 => {:ok, @broken},
        3 => {:ok, @srt}
      })

      stub(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)

      assert effects(%{imdb_id: "tt1"}, video) ==
               [:probe, {:extract, 2}, {:extract, 3}, {:scan, :movies}]

      assert File.read!(Subtitles.sidecar_path(video, "fr")) == @srt
      assert %{tracks: %{"fr" => %{origin: "embedded", source_track: 3}}} = Manifest.read(video)
      assert effects(%{imdb_id: "tt1"}, video) == []
    end

    # Under 200 cues, so the own-track path does not select it even when the import saw the stream.
    test "writes no sidecar from a lone candidate the timing check rejects", %{video: video} do
      stub_reads(video, {:ok, [track(2, "fre")]}, %{2 => {:ok, @broken}})
      stub(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)
      criteria = %{imdb_id: "tt1", embedded_subtitles: ["fre"]}

      assert effects(criteria, video) == [:probe, {:extract, 2}]
      refute File.exists?(Subtitles.sidecar_path(video, "fr"))
      assert TrackRejection.rejected?(Moviehash.compute(131_072, @zeros, @zeros), 2, :timing)
      assert effects(criteria, video) == []
    end

    # The content parses as SRT, so only the guard keeps it from being translated into its own
    # language.
    test "never translates a default candidate the timing check rejects into its language", %{
      video: video
    } do
      reversed = "1\n00:00:02,000 --> 00:00:01,000\nHello\n\n"
      stub_reads(video, {:ok, [track(2, "fre", default?: true)]}, %{2 => {:ok, reversed}})
      stub(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)
      stub_translate()

      assert effects(%{imdb_id: "tt1"}, video) == [:probe, {:extract, 2}]
      refute_received {:translate, _language}
      refute File.exists?(Subtitles.sidecar_path(video, "fr"))
      assert effects(%{imdb_id: "tt1"}, video) == []
      refute_received {:translate, _language}
    end

    # With no candidate left, a default track in another language is still the translation
    # source, and a sidecar in the language is still copied.
    test "translates the default track once the timing check rejects every candidate", %{
      video: video
    } do
      stub_reads(video, {:ok, [track(2, "fre"), track(3, "eng", default?: true)]}, %{
        2 => {:ok, @broken},
        3 => {:ok, @srt}
      })

      stub(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)
      stub_translate()

      assert effects(%{imdb_id: "tt1"}, video) ==
               [:probe, {:extract, 2}, {:extract, 3}, {:scan, :movies}]

      assert_received {:translate, "fr"}
      assert File.read!(Subtitles.sidecar_path(video, "fr")) =~ "Hello"
      assert %{tracks: %{"fr" => %{origin: "translated"}}} = Manifest.read(video)
    end

    test "copies a sidecar in the language once the timing check rejects every candidate", %{
      video: video
    } do
      stub_reads(video, {:ok, [track(2, "fre")]}, %{2 => {:ok, @broken}})
      put!(Path.join(Path.dirname(video), "M.fre.srt"), @other)
      stub(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)

      assert effects(%{imdb_id: "tt1"}, video) == [:probe, {:extract, 2}, {:scan, :movies}]
      assert File.read!(Subtitles.sidecar_path(video, "fr")) == @other
      assert %{tracks: %{"fr" => %{origin: "translated"}}} = Manifest.read(video)
    end

    # Without a moviehash nothing is stored, so each sweep probes and extracts again. The own
    # track and the embedded fallback check the same track in one fetch, and its rejection is
    # logged once.
    test "checks a rejected candidate again on every sweep without a moviehash", %{video: video} do
      stub(Cinder.Library.FilesystemMock, :moviehash_data, fn _ -> :too_small end)
      stub_reads(video, {:ok, [own_track(2, "fre")]}, %{2 => {:ok, @broken}})
      stub(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)
      criteria = %{imdb_id: "tt1", embedded_subtitles: ["fre"]}

      for _sweep <- 1..2 do
        log = info_log(fn -> assert :ok = Subtitles.fetch_missing(criteria, video, :movies) end)
        assert length(Regex.scan(~r/track 2 of .* failed the timing check/, log)) == 1
        assert drain_effects([]) == [:probe, {:extract, 2}]
        refute File.exists?(Subtitles.sidecar_path(video, "fr"))
      end

      assert Repo.aggregate(TrackRejection, :count) == 0
    end

    # A generic "chi" track is a candidate for both Chinese targets: one fetch checks it once.
    test "logs one rejection for a track two wanted languages share", %{video: video} do
      ConfigCase.put_config(Cinder.Subtitles.Provider.OpenSubtitles, languages: "zh,cn")
      stub(Cinder.Library.FilesystemMock, :moviehash_data, fn _ -> :too_small end)
      stub_reads(video, {:ok, [track(2, "chi")]}, %{2 => {:ok, @broken}})
      stub(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)

      log =
        info_log(fn ->
          assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, video, :movies)
        end)

      assert length(Regex.scan(~r/track 2 of .* failed the timing check/, log)) == 1
      assert drain_effects([]) == [:probe, {:extract, 2}]
    end

    # #1109: a translation keeps the cue times of its source, so every source passes the timing
    # check first. This content parses as SRT, so only that check keeps it from the translator.
    test "does not translate a default track the timing check rejects", %{video: video} do
      stub_reads(video, {:ok, [track(3, "eng", default?: true)]}, %{3 => {:ok, @reversed}})
      stub(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)
      stub_translate()
      moviehash = Moviehash.compute(131_072, @zeros, @zeros)

      assert effects(%{imdb_id: "tt1"}, video) == [:probe, {:extract, 3}]
      refute_received {:translate, _language}
      refute File.exists?(Subtitles.sidecar_path(video, "fr"))
      assert TrackRejection.rejected?(moviehash, 3, :timing)
      refute TrackRejection.rejected?(moviehash, 3, :srt)

      assert effects(%{imdb_id: "tt1"}, video) == []
      refute_received {:translate, _language}
    end

    # The own-track path or the embedded fallback stored this rejection for another language.
    test "does not extract a default track the timing check rejected on another path", %{
      video: video
    } do
      TrackRejection.reject(Moviehash.compute(131_072, @zeros, @zeros), 3, :timing)
      stub_reads(video, {:ok, [track(3, "eng", default?: true)]}, %{3 => {:ok, @srt}})
      stub(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)
      stub_translate()

      assert effects(%{imdb_id: "tt1"}, video) == [:probe]
      refute_received {:translate, _language}
      refute File.exists?(Subtitles.sidecar_path(video, "fr"))
    end

    # Without a moviehash nothing is stored, so each sweep extracts the track again. Both
    # languages would translate the same track: one fetch checks and logs it once.
    test "checks a rejected default track once per fetch without a moviehash", %{video: video} do
      ConfigCase.put_config(Cinder.Subtitles.Provider.OpenSubtitles, languages: "fr,de")
      stub(Cinder.Library.FilesystemMock, :moviehash_data, fn _ -> :too_small end)
      stub_reads(video, {:ok, [track(3, "eng", default?: true)]}, %{3 => {:ok, @reversed}})
      stub(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)
      stub_translate()

      for _sweep <- 1..2 do
        log =
          info_log(fn ->
            assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, video, :movies)
          end)

        refute log =~ "crashed"
        assert length(Regex.scan(~r/track 3 of .* failed the timing check/, log)) == 1
        assert drain_effects([]) == [:probe, {:extract, 3}]
        refute_received {:translate, _language}
      end

      refute File.exists?(Subtitles.sidecar_path(video, "fr"))
      refute File.exists?(Subtitles.sidecar_path(video, "de"))
      assert Repo.aggregate(TrackRejection, :count) == 0
    end

    # The own track for `en` is the default track the `fr` translation would use. Without a
    # moviehash only the fetch's own record keeps the translation from checking it again.
    test "does not check again a default track the own track rejected in the same fetch", %{
      video: video
    } do
      ConfigCase.put_config(Cinder.Subtitles.Provider.OpenSubtitles, languages: "en,fr")
      stub(Cinder.Library.FilesystemMock, :moviehash_data, fn _ -> :too_small end)
      stub_reads(video, {:ok, [own_track(3, "eng", default?: true)]}, %{3 => {:ok, @reversed}})
      stub(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)
      stub_translate()
      criteria = %{imdb_id: "tt1", embedded_subtitles: ["eng"]}

      log = info_log(fn -> assert :ok = Subtitles.fetch_missing(criteria, video, :movies) end)

      refute log =~ "crashed"
      assert length(Regex.scan(~r/track 3 of .* failed the timing check/, log)) == 1
      assert drain_effects([]) == [:probe, {:extract, 3}]
      refute_received {:translate, _language}
      refute File.exists?(Subtitles.sidecar_path(video, "fr"))
    end

    # The other way round: the `fr` translation rejects the track that is the `en` candidate.
    test "does not check again an embedded candidate the translation rejected in the same fetch",
         %{video: video} do
      ConfigCase.put_config(Cinder.Subtitles.Provider.OpenSubtitles, languages: "fr,en")
      stub(Cinder.Library.FilesystemMock, :moviehash_data, fn _ -> :too_small end)
      stub_reads(video, {:ok, [track(3, "eng", default?: true)]}, %{3 => {:ok, @reversed}})
      stub(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)
      stub_translate()

      log =
        info_log(fn ->
          assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, video, :movies)
        end)

      refute log =~ "crashed"
      assert length(Regex.scan(~r/track 3 of .* failed the timing check/, log)) == 1
      assert drain_effects([]) == [:probe, {:extract, 3}]
      refute File.exists?(Subtitles.sidecar_path(video, "fr"))
      refute File.exists?(Subtitles.sidecar_path(video, "en"))
    end

    test "copies a sidecar in the language once the timing check rejects the default track", %{
      video: video
    } do
      stub_reads(video, {:ok, [track(3, "eng", default?: true)]}, %{3 => {:ok, @reversed}})
      put!(Path.join(Path.dirname(video), "M.fre.srt"), @other)
      stub(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)
      stub_translate()

      assert effects(%{imdb_id: "tt1"}, video) == [:probe, {:extract, 3}, {:scan, :movies}]
      refute_received {:translate, _language}
      assert File.read!(Subtitles.sidecar_path(video, "fr")) == @other
      assert %{tracks: %{"fr" => %{origin: "translated"}}} = Manifest.read(video)
    end

    # A valid source can still render to content the check rejects. That comes from the
    # translator, so nothing is stored for the track.
    test "writes no translation that fails the timing check", %{video: video} do
      stub_reads(video, {:ok, [track(3, "eng", default?: true)]}, %{3 => {:ok, @srt}})
      stub(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)
      test = self()

      stub(Cinder.Subtitles.TranslatorMock, :translate, fn ["Hello"], "fr" ->
        send(test, {:translate, "fr"})
        {:ok, [""]}
      end)

      log =
        capture_log(fn ->
          assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, video, :movies)
        end)

      assert log =~ "subtitle translation for #{video} (fr) failed the timing check"
      assert_received {:translate, "fr"}
      assert drain_effects([]) == [:probe, {:extract, 3}]
      refute File.exists?(Subtitles.sidecar_path(video, "fr"))
      assert Repo.aggregate(TrackRejection, :count) == 0
    end

    test "does not copy a sidecar in the language that fails the timing check", %{video: video} do
      sidecar = Path.join(Path.dirname(video), "M.fre.srt")
      put!(sidecar, @reversed)
      stub_default_track(video, :none)
      stub(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)
      stub_translate()

      log =
        info_log(fn ->
          assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, video, :movies)
        end)

      refute log =~ "crashed"
      assert log =~ "subtitle sidecar #{sidecar} failed the timing check"
      assert drain_effects([]) == [:probe]
      assert_received {:read, ^sidecar}
      refute_received {:translate, _language}
      refute File.exists?(Subtitles.sidecar_path(video, "fr"))
      assert Repo.aggregate(TrackRejection, :count) == 0
    end

    test "copies M.fr.sdh.srt when M.fre.srt fails the timing check", %{video: video} do
      unflagged = Path.join(Path.dirname(video), "M.fre.srt")
      put!(unflagged, @reversed)
      put!(Path.join(Path.dirname(video), "M.fr.sdh.srt"), @other)
      stub_default_track(video, :none)
      stub(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)
      stub_translate()

      assert effects(%{imdb_id: "tt1"}, video) == [:probe, {:scan, :movies}]
      assert_received {:read, ^unflagged}
      refute_received {:translate, _language}
      assert File.read!(Subtitles.sidecar_path(video, "fr")) == @other
      assert %{tracks: %{"fr" => %{origin: "translated"}}} = Manifest.read(video)
    end

    # Listed first, the unreadable sidecar is also the one a translation would take: before
    # #1109 its read failure ended the copy there.
    test "copies M.fr.sdh.srt when M.fre.srt cannot be read", %{video: video} do
      unflagged = Path.join(Path.dirname(video), "M.fre.srt")
      put!(unflagged, @srt)
      put!(Path.join(Path.dirname(video), "M.fr.sdh.srt"), @other)
      list_first(unflagged)
      stub_default_track(video, :none)
      stub(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)
      stub_translate()

      stub(Cinder.Library.FilesystemMock, :read, fn
        ^unflagged -> {:error, :eacces}
        path -> Disk.read(path)
      end)

      assert effects(%{imdb_id: "tt1"}, video) == [:probe, {:scan, :movies}]
      refute_received {:translate, _language}
      assert File.read!(Subtitles.sidecar_path(video, "fr")) == @other
    end

    test "does not translate a sidecar that fails the timing check", %{video: video} do
      source = Path.join(Path.dirname(video), "M.eng.srt")
      put!(source, @reversed)
      stub_default_track(video, :none)
      stub(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)
      stub_translate()

      assert effects(%{imdb_id: "tt1"}, video) == [:probe]
      assert_received {:read, ^source}
      refute_received {:translate, _language}
      refute File.exists?(Subtitles.sidecar_path(video, "fr"))
      assert Repo.aggregate(TrackRejection, :count) == 0
    end

    test "translates a sidecar listed first when M.fre.srt fails the timing check", %{
      video: video
    } do
      source = Path.join(Path.dirname(video), "M.eng.srt")
      put!(Path.join(Path.dirname(video), "M.fre.srt"), @reversed)
      put!(source, @srt)
      list_first(source)
      stub_default_track(video, :none)
      stub(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)
      stub_translate()

      assert effects(%{imdb_id: "tt1"}, video) == [:probe, {:scan, :movies}]
      assert_received {:translate, "fr"}
      assert File.read!(Subtitles.sidecar_path(video, "fr")) == @srt
      assert %{tracks: %{"fr" => %{origin: "translated"}}} = Manifest.read(video)
    end

    # The translation source is checked once per fetch, whatever the number of wanted languages.
    test "checks a sidecar translation source once for two wanted languages", %{video: video} do
      ConfigCase.put_config(Cinder.Subtitles.Provider.OpenSubtitles, languages: "fr,de")
      source = Path.join(Path.dirname(video), "M.eng.srt")
      put!(source, @reversed)
      stub_default_track(video, :none)
      stub(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)
      stub_translate()

      log =
        info_log(fn ->
          assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, video, :movies)
        end)

      refute log =~ "crashed"
      assert length(Regex.scan(~r/subtitle sidecar .* failed the timing check/, log)) == 1
      assert_received {:read, ^source}
      refute_received {:read, ^source}
      refute_received {:translate, _language}
    end
  end

  # #1110: before #1072 the embedded fallback wrote a track without the timing check. A sweep
  # tries only the candidates ranked ahead of the track an entry records (#1071), so such a sidecar
  # stayed until an OpenSubtitles match replaced it (Monogatari and Frieren on prod). The fetch now
  # checks a held embedded sidecar's own bytes, removes one that fails and carries on as for a
  # missing target.
  describe "a held embedded sidecar that fails the timing check" do
    setup %{video: video} do
      ConfigCase.put_env(:media_info, Cinder.Library.MediaInfoMock)
      put_moviehash!(131_072)
      test = self()

      stub(Cinder.Library.MediaServerMock, :scan, fn kind ->
        send(test, {:scan, kind})
        :ok
      end)

      {:ok, target: target(video)}
    end

    # The issue's case: the entry records the only candidate, so no candidate ranks ahead of it.
    test "is removed when it records the only candidate", %{video: video, target: target} do
      put_embedded!(video, @broken, source_moviehash: moviehash(), source_track: 2)
      stub_reads(video, {:ok, [track(2, "fre")]}, %{2 => {:ok, @broken}})
      stub(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)

      assert effects(%{imdb_id: "tt1"}, video) == [{:scan, :movies}, :probe, {:extract, 2}]
      refute File.exists?(target)
      refute Map.has_key?(Manifest.read(video).tracks, "fr")
      assert TrackRejection.rejected?(moviehash(), 2, :timing)
      assert effects(%{imdb_id: "tt1"}, video) == []
    end

    # Written before #1068: nothing ties the entry to this file or to a track.
    test "is removed when it records neither a moviehash nor a track", %{
      video: video,
      target: target
    } do
      put_embedded!(video, @broken, [])
      stub_reads(video, {:ok, [track(2, "fre")]}, %{2 => {:ok, @broken}})
      stub(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)

      assert effects(%{imdb_id: "tt1"}, video) == [{:scan, :movies}, :probe, {:extract, 2}]
      refute File.exists?(target)
      refute Map.has_key?(Manifest.read(video).tracks, "fr")
      assert effects(%{imdb_id: "tt1"}, video) == []
    end

    # The import saw the stream, so the own-track path extracts the track and rejects it first.
    test "is removed once the own-track path rejected the track it came from", %{
      video: video,
      target: target
    } do
      put_embedded!(video, @broken, source_moviehash: moviehash(), source_track: 2)
      stub_reads(video, {:ok, [own_track(2, "fre")]}, %{2 => {:ok, @broken}})
      stub(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)
      criteria = %{imdb_id: "tt1", embedded_subtitles: ["fre"]}

      assert effects(criteria, video) == [:probe, {:extract, 2}, {:scan, :movies}]
      refute File.exists?(target)
      refute Map.has_key?(Manifest.read(video).tracks, "fr")
      assert effects(criteria, video) == []
    end

    # Prod's 64 entries that record a track: an earlier sweep stored its rejection and the probe.
    test "is removed with no read of the video once its track's rejection is stored", %{
      video: video,
      target: target
    } do
      put_embedded!(video, @broken, source_moviehash: moviehash(), source_track: 2)
      assert {:ok, _tracks} = TrackProbe.tracks(moviehash(), fn -> {:ok, [track(2, "fre")]} end)
      TrackRejection.reject(moviehash(), 2, :timing)
      stub_reads(video, {:ok, [track(2, "fre")]}, %{2 => {:ok, @broken}})
      stub(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)

      assert effects(%{imdb_id: "tt1"}, video) == [{:scan, :movies}]
      refute File.exists?(target)
      refute Map.has_key?(Manifest.read(video).tracks, "fr")
      assert effects(%{imdb_id: "tt1"}, video) == []
    end

    # The removal and the commit each ask the media server to scan.
    test "is replaced in the same fetch by a later candidate that passes", %{
      video: video,
      target: target
    } do
      put_embedded!(video, @broken, source_moviehash: moviehash(), source_track: 2)

      stub_reads(video, {:ok, [track(2, "fre"), track(3, "fre")]}, %{
        2 => {:ok, @broken},
        3 => {:ok, @srt}
      })

      stub(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)

      assert effects(%{imdb_id: "tt1"}, video) ==
               [{:scan, :movies}, :probe, {:extract, 2}, {:extract, 3}, {:scan, :movies}]

      assert File.read!(target) == @srt
      assert %{tracks: %{"fr" => %{origin: "embedded", source_track: 3}}} = Manifest.read(video)
      assert effects(%{imdb_id: "tt1"}, video) == []
    end

    test "is replaced in the same fetch by a translation of the default track", %{
      video: video,
      target: target
    } do
      put_embedded!(video, @broken, source_moviehash: moviehash(), source_track: 2)

      stub_reads(video, {:ok, [track(2, "fre"), track(3, "eng", default?: true)]}, %{
        2 => {:ok, @broken},
        3 => {:ok, @srt}
      })

      stub(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)
      stub_translate()

      assert effects(%{imdb_id: "tt1"}, video) ==
               [{:scan, :movies}, :probe, {:extract, 2}, {:extract, 3}, {:scan, :movies}]

      assert_received {:translate, "fr"}
      assert File.read!(target) =~ "Hello"
      assert %{tracks: %{"fr" => %{origin: "translated"}}} = Manifest.read(video)
    end

    test "is replaced in the same fetch by a sidecar in its language", %{
      video: video,
      target: target
    } do
      put_embedded!(video, @broken, source_moviehash: moviehash(), source_track: 2)
      put!(Path.join(Path.dirname(video), "M.fre.srt"), @other)
      stub_reads(video, {:ok, [track(2, "fre")]}, %{2 => {:ok, @broken}})
      stub(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)

      assert effects(%{imdb_id: "tt1"}, video) ==
               [{:scan, :movies}, :probe, {:extract, 2}, {:scan, :movies}]

      assert File.read!(target) == @other
      assert %{tracks: %{"fr" => %{origin: "translated"}}} = Manifest.read(video)
    end

    test "logs one line naming its path, its language and the reason", %{
      video: video,
      target: target
    } do
      put_embedded!(video, @broken, source_moviehash: moviehash(), source_track: 2)
      TrackRejection.reject(moviehash(), 2, :timing)
      stub_reads(video, {:ok, [track(2, "fre")]}, %{})
      stub(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)

      log =
        info_log(fn ->
          assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, video, :movies)
        end)

      assert [line] = Regex.scan(~r/^.*failed the timing check.*$/m, log)
      assert line |> hd() |> String.contains?([target])
      assert line |> hd() =~ "(fr)"
      assert line |> hd() =~ "invalid_subtitle"
      refute log =~ "subtitle sidecar #{target}"

      log =
        info_log(fn ->
          assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, video, :movies)
        end)

      refute log =~ "failed the timing check"
    end

    test "is removed beside a TV episode and the TV library is scanned", %{tmp_dir: tmp} do
      episode = Path.join(tmp, "tv/S/Season 01/S - S01E01.mkv")
      put!(episode, "video")
      target = target(episode)
      put_embedded!(episode, @broken, source_moviehash: moviehash(), source_track: 2)
      TrackRejection.reject(moviehash(), 2, :timing)
      stub_reads(episode, {:ok, [track(2, "fre")]}, %{})
      stub(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)

      capture_log(fn ->
        assert :ok = Subtitles.fetch_missing(%{tmdb_id: 1, season: 1, episode: 1}, episode, :tv)
      end)

      assert drain_effects([]) == [{:scan, :tv}, :probe]
      refute File.exists?(target)
      refute Map.has_key?(Manifest.read(episode).tracks, "fr")
    end

    # A manual record is the operator's retime. Sync never handles an embedded sidecar, so any
    # other record it alone writes is unexplained and may name a backup.
    for {label, field, sync} <- [
          {"a manual retime", :sync, :manual},
          {"an alignment record", :sync, :audio},
          {"a sync record that does not decode", :sync, :invalid},
          {"a reset journal", :reset_cleanup_sync, :audio},
          {"a reset journal that does not decode", :reset_cleanup_sync, :invalid}
        ] do
      test "is kept with #{label}", %{video: video, target: target} do
        record = {unquote(field), sync_record(unquote(sync))}
        put_embedded!(video, @broken, [record, source_moviehash: moviehash(), source_track: 2])
        entry = Manifest.read(video).tracks["fr"]
        stub_reads(video, {:ok, [track(2, "fre")]}, %{2 => {:ok, @broken}})
        stub(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)

        assert effects(%{imdb_id: "tt1"}, video) == [:probe]
        refute_received {:read, ^target}
        assert File.read!(target) == @broken
        assert Manifest.read(video).tracks["fr"] == entry
      end
    end

    # Bytes other than the ones Cinder wrote are someone's edit.
    test "is kept when its bytes are not the ones Cinder wrote", %{video: video, target: target} do
      put_embedded!(video, @other, source_moviehash: moviehash(), source_track: 2)
      File.write!(target, @broken)
      entry = Manifest.read(video).tracks["fr"]
      stub_reads(video, {:ok, [track(2, "fre")]}, %{2 => {:ok, @broken}})
      stub(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)

      assert effects(%{imdb_id: "tt1"}, video) == [:probe]
      assert File.read!(target) == @broken
      assert Manifest.read(video).tracks["fr"] == entry
    end

    # A backup tombstone records the zero-byte container a later correction in the language
    # reactivates, so its entry stays with the sidecar gone.
    test "keeps the entry of a backup tombstone it removes", %{video: video, target: target} do
      tombstone = put_tombstoned_embedded!(video)
      entry = Manifest.read(video).tracks["fr"]
      stub_reads(video, {:ok, [track(2, "fre")]}, %{})
      stub(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)

      log = removal_log(video)

      refute log =~ "subtitle removal failed"
      assert drain_effects([]) == [{:scan, :movies}, :probe]
      assert File.read!(Path.join(Path.dirname(target), tombstone.name)) == ""
      refute File.exists?(target)
      assert Manifest.read(video).tracks["fr"] == entry
    end

    test "carries a backup tombstone it removes to the sidecar that replaces it", %{
      video: video,
      target: target
    } do
      tombstone = put_tombstoned_embedded!(video)
      stub_reads(video, {:ok, [track(2, "fre"), track(3, "fre")]}, %{3 => {:ok, @srt}})
      stub(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)
      identity = tombstone.identity

      log = removal_log(video)

      refute log =~ "subtitle removal failed"

      assert drain_effects([]) ==
               [{:scan, :movies}, :probe, {:extract, 3}, {:scan, :movies}]

      assert File.read!(target) == @srt

      assert %{origin: "embedded", source_track: 3, backup_tombstone: %{identity: ^identity}} =
               Manifest.read(video).tracks["fr"]
    end

    # Only an embedded sidecar is checked: a sidecar of another origin is kept as before, failing
    # bytes included, and is not read for the check.
    for origin <- ~w(opensubtitles_hash opensubtitles_id own_track translated release_sidecar) do
      test "keeps a #{origin} target that fails the timing check", %{
        video: video,
        target: target
      } do
        put!(target, @broken)

        put_manifest!(video, %{
          video_moviehash: nil,
          tracks: %{"fr" => %{origin: unquote(origin), file: "M.fr.srt"}}
        })

        entry = Manifest.read(video).tracks["fr"]
        stub_reads(video, {:ok, []}, %{})
        stub(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)

        assert effects(%{imdb_id: "tt1"}, video) == [:probe]
        refute_received {:read, ^target}
        assert File.read!(target) == @broken
        assert Manifest.read(video).tracks["fr"] == entry
      end
    end

    # The sidecar changed between the check's read and the removal: nothing is removed, and the
    # fetch goes on as for a sidecar it holds.
    test "is kept when its bytes change before the removal", %{video: video, target: target} do
      put_embedded!(video, @broken, source_moviehash: moviehash(), source_track: 2)
      entry = Manifest.read(video).tracks["fr"]
      TrackRejection.reject(moviehash(), 2, :timing)
      stub_reads(video, {:ok, [track(2, "fre")]}, %{})
      stub(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)

      stub(Cinder.Library.FilesystemMock, :read, fn path ->
        result = Disk.read(path)
        if path == target, do: File.write!(target, @srt)
        result
      end)

      assert removal_log(video) =~ "subtitle removal failed for #{target}"
      assert drain_effects([]) == [:probe]
      assert File.read!(target) == @srt
      assert Manifest.read(video).tracks["fr"] == entry
    end

    test "is kept when it cannot be read", %{video: video, target: target} do
      put_embedded!(video, @broken, source_moviehash: moviehash(), source_track: 2)
      entry = Manifest.read(video).tracks["fr"]
      stub_reads(video, {:ok, [track(2, "fre")]}, %{})
      stub(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)

      stub(Cinder.Library.FilesystemMock, :read, fn path ->
        if path == target, do: {:error, :eio}, else: Disk.read(path)
      end)

      assert effects(%{imdb_id: "tt1"}, video) == [:probe]
      assert File.read!(target) == @broken
      assert Manifest.read(video).tracks["fr"] == entry
    end

    # The sidecar goes first, so it is gone and the media server scans; its entry stays until a
    # commit in the language replaces it, and a fetch treats the language as missing meanwhile.
    test "is removed when its entry cannot be dropped", %{video: video, target: target} do
      put_embedded!(video, @broken, source_moviehash: moviehash(), source_track: 2)
      entry = Manifest.read(video).tracks["fr"]
      TrackRejection.reject(moviehash(), 2, :timing)
      stub_reads(video, {:ok, [track(2, "fre")]}, %{})
      stub(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)
      fail_manifest_writes()

      log =
        capture_log(fn ->
          assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, video, :movies)
        end)

      assert log =~ "subtitle removal failed for #{target}"
      assert drain_effects([]) == [{:scan, :movies}, :probe]
      refute File.exists?(target)
      assert Manifest.read(video).tracks["fr"] == entry
      assert effects(%{imdb_id: "tt1"}, video) == []
    end
  end

  test "a cn (Cantonese) target selects a generically-tagged chi embedded track, not a fallback translation (#573)",
       %{video: video} do
    Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, languages: "cn")
    Application.put_env(:cinder, :media_info, Cinder.Library.MediaInfoMock)

    expect(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)

    expect(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video ->
      {:ok, [%{index: 2, language: "chi", default?: false, forced?: false}]}
    end)

    expect(Cinder.Library.MediaInfoMock, :extract_subtitle, fn ^video, 2 ->
      {:ok, "1\n00:00:01,000 --> 00:00:02,000\nCantonese SRT\n\n"}
    end)

    expect(Cinder.Library.MediaServerMock, :scan, fn :movies -> :ok end)

    assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, video, :movies)

    assert File.read!(Subtitles.sidecar_path(video, "cn")) ==
             "1\n00:00:01,000 --> 00:00:02,000\nCantonese SRT\n\n"

    assert %{tracks: %{"cn" => %{origin: "embedded"}}} = Manifest.read(video)
  end

  test "a cn (Cantonese) target prefers an exact yue track over an earlier ambiguous chi track (#573)",
       %{video: video} do
    Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, languages: "cn")
    Application.put_env(:cinder, :media_info, Cinder.Library.MediaInfoMock)

    expect(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)

    # "chi" (generic Chinese) comes first and satisfies "cn" via the forward-tolerance list, but
    # is ambiguous - it could genuinely be Mandarin. "yue" positively identifies Cantonese and
    # must win despite coming second (Codex review finding on PR #574).
    expect(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video ->
      {:ok,
       [
         %{index: 2, language: "chi", default?: false, forced?: false},
         %{index: 3, language: "yue", default?: false, forced?: false}
       ]}
    end)

    expect(Cinder.Library.MediaInfoMock, :extract_subtitle, fn ^video, 3 ->
      {:ok, "1\n00:00:01,000 --> 00:00:02,000\nCantonese SRT\n\n"}
    end)

    expect(Cinder.Library.MediaServerMock, :scan, fn :movies -> :ok end)

    assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, video, :movies)

    assert File.read!(Subtitles.sidecar_path(video, "cn")) ==
             "1\n00:00:01,000 --> 00:00:02,000\nCantonese SRT\n\n"

    assert %{tracks: %{"cn" => %{origin: "embedded"}}} = Manifest.read(video)
  end

  test "an unextractable exact track falls through to a usable ambiguous track, not translation (#575)",
       %{video: video} do
    Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, languages: "cn")
    Application.put_env(:cinder, :media_info, Cinder.Library.MediaInfoMock)

    expect(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)

    # "yue" (exact for "cn") sorts first but fails extraction. "chi" (generic Chinese, merely
    # ambiguous) sorts second and must still be tried and used - giving up after the first,
    # best-ranked candidate would wrongly fall to translation instead (#575).
    expect(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video ->
      {:ok,
       [
         %{index: 2, language: "yue", default?: false, forced?: false},
         %{index: 3, language: "chi", default?: false, forced?: false}
       ]}
    end)

    expect(Cinder.Library.MediaInfoMock, :extract_subtitle, 2, fn ^video, index ->
      case index do
        2 -> {:error, :corrupt}
        3 -> {:ok, "1\n00:00:01,000 --> 00:00:02,000\nCantonese SRT\n\n"}
      end
    end)

    expect(Cinder.Library.MediaServerMock, :scan, fn :movies -> :ok end)

    assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, video, :movies)

    assert File.read!(Subtitles.sidecar_path(video, "cn")) ==
             "1\n00:00:01,000 --> 00:00:02,000\nCantonese SRT\n\n"

    assert %{tracks: %{"cn" => %{origin: "embedded"}}} = Manifest.read(video)
  end

  test "a forced exact embedded track falls through to a default non-forced translation", %{
    video: video
  } do
    Application.put_env(:cinder, :media_info, Cinder.Library.MediaInfoMock)

    expect(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)

    expect(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video ->
      {:ok,
       [
         %{index: 2, language: "fr", default?: false, forced?: true},
         %{index: 3, language: "en", default?: true, forced?: false}
       ]}
    end)

    expect(Cinder.Library.MediaInfoMock, :extract_subtitle, fn ^video, 3 ->
      {:ok, "1\n00:00:01,000 --> 00:00:02,000\nHello\n\n"}
    end)

    expect(Cinder.Subtitles.TranslatorMock, :translate, fn ["Hello"], "fr" ->
      {:ok, ["Bonjour"]}
    end)

    expect(Cinder.Library.MediaServerMock, :scan, fn :movies -> :ok end)

    assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, video, :movies)
    assert File.read!(Subtitles.sidecar_path(video, "fr")) =~ "Bonjour"
    assert %{tracks: %{"fr" => %{origin: "translated"}}} = Manifest.read(video)
  end

  test "a default embedded track translates each still-missing target", %{video: video} do
    Application.put_env(:cinder, :media_info, Cinder.Library.MediaInfoMock)

    expect(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)

    expect(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video ->
      {:ok, [%{index: 3, language: "en", default?: true, forced?: false}]}
    end)

    expect(Cinder.Library.MediaInfoMock, :extract_subtitle, fn ^video, 3 ->
      {:ok, "1\n00:00:01,000 --> 00:00:02,000\nHello\n\n"}
    end)

    expect(Cinder.Subtitles.TranslatorMock, :translate, fn ["Hello"], "fr" ->
      {:ok, ["Bonjour"]}
    end)

    expect(Cinder.Library.MediaServerMock, :scan, fn :movies -> :ok end)

    assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, video, :movies)
    assert File.read!(Subtitles.sidecar_path(video, "fr")) =~ "Bonjour"
    assert %{tracks: %{"fr" => %{origin: "translated"}}} = Manifest.read(video)
  end

  test "an SRT sidecar supplies the translation source when no embedded track is usable", %{
    video: video
  } do
    Application.put_env(:cinder, :media_info, Cinder.Library.MediaInfoMock)
    source = Subtitles.sidecar_path(video, "en")
    put!(source, "1\n00:00:01,000 --> 00:00:02,000\nHello\n\n")

    expect(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)
    expect(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video -> {:ok, []} end)

    expect(Cinder.Subtitles.TranslatorMock, :translate, fn ["Hello"], "fr" ->
      {:ok, ["Bonjour"]}
    end)

    expect(Cinder.Library.MediaServerMock, :scan, fn :movies -> :ok end)

    assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, video, :movies)
    assert_received {:read, ^source}
    assert File.read!(Subtitles.sidecar_path(video, "fr")) =~ "Bonjour"
  end

  test "an unmarked target sidecar is never overwritten even when a provider candidate exists", %{
    video: video
  } do
    target = Subtitles.sidecar_path(video, "fr")
    put!(target, "manual")

    expect(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, [result(1, "fr")]} end)

    deny(Cinder.Library.FilesystemMock, :exchange, 2)
    deny(Cinder.Library.FilesystemMock, :rename_exclusive, 2)

    assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, video, :movies)
    assert File.read!(target) == "manual"
  end

  test "a default embedded track never replaces an existing release-sidecar target", %{
    video: video
  } do
    Application.put_env(:cinder, :media_info, Cinder.Library.MediaInfoMock)
    target = Subtitles.sidecar_path(video, "fr")
    put!(target, "1\n00:00:01,000 --> 00:00:02,000\nBonjour original\n\n")

    put_manifest!(video, %{
      video_moviehash: nil,
      tracks: %{"fr" => %{origin: "release_sidecar"}}
    })

    expect(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)

    expect(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video ->
      {:ok, [%{index: 3, language: "en", default?: true, forced?: false}]}
    end)

    # A translation could not replace the target, so the default track is not even extracted: that
    # would read the whole file for nothing (#861).
    stub(Cinder.Library.MediaInfoMock, :extract_subtitle, fn ^video, index ->
      send(self(), {:extract, index})
      {:ok, "1\n00:00:01,000 --> 00:00:02,000\nHello\n\n"}
    end)

    stub(Cinder.Subtitles.TranslatorMock, :translate, fn ["Hello"], "fr" ->
      {:ok, ["MACHINE-EN->FR: Hello"]}
    end)

    stub(Cinder.Library.MediaServerMock, :scan, fn :movies -> :ok end)

    log =
      capture_log(fn ->
        assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, video, :movies)
      end)

    refute_received {:extract, _index}
    refute log =~ "crashed"
    assert File.read!(target) == "1\n00:00:01,000 --> 00:00:02,000\nBonjour original\n\n"
    assert %{tracks: %{"fr" => %{origin: "release_sidecar"}}} = Manifest.read(video)
  end

  # #1202: on an unreadable manifest the marking cannot see the verified track it must keep, so it
  # skips the language, even though the next read succeeds.
  describe "release-sidecar marking whose manifest read fails" do
    # A backfill marks only a tracked language by default, and an untracked one too with the
    # opt-in (#993).
    for {opts, path} <- [{[], "by default"}, {[register_untracked: true], "with the opt-in"}] do
      test "from a backfill #{path} keeps a verified track and its sync record", %{video: video} do
        manifest = put_verified_track!(video, nil)
        fail_once(%{operation: :read, source_contains: ".cinder-subtitles.json", reason: :eio})

        log =
          capture_log(fn ->
            assert :ok = Subtitles.mark_release_sidecars(video, ["fr"], unquote(opts))
          end)

        assert File.read!(Manifest.path(video)) == manifest
        assert log =~ "subtitle manifest cannot be read for #{video}: :eio"

        assert log =~
                 "subtitle release sidecar left unmarked for #{Subtitles.sidecar_path(video, "fr")}"
      end
    end

    # The read fails once, on `fr`, and `en` is marked after it. By default the marking takes
    # only a tracked language, so `en` starts as a provider track whose bytes changed.
    for {opts, tracked_en?, path} <- [
          {[], true, "by default"},
          {[register_untracked: true], false, "with the opt-in"}
        ] do
      test "skips only the language whose read failed, #{path}", %{video: video} do
        verified = Jason.decode!(put_verified_track!(video, nil))["tracks"]["fr"]
        put!(Subtitles.sidecar_path(video, "en"), "1\n00:00:01,000 --> 00:00:02,000\nHello\n\n")

        if unquote(tracked_en?) do
          en = %{
            origin: "opensubtitles_id",
            file: "M.en.srt",
            managed_sha256: String.duplicate("d", 64)
          }

          state = Jason.decode!(File.read!(Manifest.path(video)))
          put_manifest!(video, put_in(state, ["tracks", "en"], en))
        end

        fail_once(%{operation: :read, source_contains: ".cinder-subtitles.json", reason: :eio})

        capture_log(fn ->
          assert :ok = Subtitles.mark_release_sidecars(video, ["fr", "en"], unquote(opts))
        end)

        assert %{
                 "fr" => ^verified,
                 "en" => %{"origin" => "release_sidecar", "file" => "M.en.srt"}
               } = Jason.decode!(File.read!(Manifest.path(video)))["tracks"]
      end
    end

    test "from an import keeps a verified track and returns the fetch's answer", %{
      video: video
    } do
      put!(video, String.duplicate("v", 131_072))
      fail_once(%{operation: :read, source_contains: ".cinder-subtitles.json", reason: :eio})
      # The failure swapped `FilesystemMock` for `BarrierFilesystem`, which hashes the real file.
      assert {:ok, moviehash} = Moviehash.of_file(video)
      manifest = put_verified_track!(video, moviehash)
      target = Subtitles.sidecar_path(video, "fr")
      # The stable French track needs no fetch; the English one makes the fetch's answer visible.
      Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, languages: "fr,en")

      expect(Cinder.Subtitles.ProviderMock, :search, fn %{languages: ["en"]} ->
        {:error, :quota_exceeded}
      end)

      log =
        capture_log(fn ->
          assert :quota_exceeded =
                   Subtitles.fetch_now(fn -> %{imdb_id: "tt1"} end, video, :movies,
                     languages: ["fr"],
                     placed: [target]
                   )
        end)

      assert File.read!(Manifest.path(video)) == manifest
      assert log =~ "subtitle release sidecar left unmarked for #{target}"
      refute log =~ "crashed"
    end
  end

  test "sidecar_source never reclassifies the canonical target as its own translation source",
       %{video: video} do
    Application.put_env(:cinder, :media_info, Cinder.Library.MediaInfoMock)
    target = Subtitles.sidecar_path(video, "fr")
    put!(target, "1\n00:00:01,000 --> 00:00:02,000\nProvider FR\n\n")

    put_manifest!(video, %{
      video_moviehash: nil,
      tracks: %{"fr" => %{origin: "opensubtitles_id"}}
    })

    expect(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)
    expect(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video -> {:ok, []} end)
    stub(Cinder.Library.MediaServerMock, :scan, fn :movies -> :ok end)

    assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, video, :movies)

    assert File.read!(target) == "1\n00:00:01,000 --> 00:00:02,000\nProvider FR\n\n"
    assert %{tracks: %{"fr" => %{origin: "opensubtitles_id"}}} = Manifest.read(video)
  end

  test "fetch_missing/2 remains a movies wrapper", %{video: video} do
    Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, languages: "")
    assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, video)
  end

  test "fetch_missing/3 stops after the provider reports quota", %{video: video} do
    Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, languages: "en,fr")

    expect(Cinder.Subtitles.ProviderMock, :search, fn %{languages: ["en"]} ->
      {:ok, [result(1, "en")]}
    end)

    expect(Cinder.Subtitles.ProviderMock, :download, fn 1 -> {:error, :quota_exceeded} end)

    assert :quota_exceeded = Subtitles.fetch_missing(%{imdb_id: "tt1"}, video, :movies)
  end

  test "subtitle publication rejects a library parent replaced by a symlink after staging", %{
    video: video,
    tmp_dir: tmp
  } do
    Application.put_env(:cinder, :filesystem, Cinder.Test.BarrierFilesystem)
    parent = Path.dirname(video)
    outside = Path.join(tmp, "outside")
    target = Subtitles.sidecar_path(video, "fr")
    File.mkdir_p!(outside)

    Application.put_env(:cinder, :filesystem_barrier, %{
      owner: self(),
      operation: :rename_exclusive,
      phase: :before,
      contains: ".cinder-subtitle-sync-cas-",
      once: true
    })

    expect(Cinder.Subtitles.ProviderMock, :search, fn _criteria -> {:ok, [result(1, "fr")]} end)

    expect(Cinder.Subtitles.ProviderMock, :download, fn 1 ->
      {:ok, "1\n00:00:01,000 --> 00:00:02,000\nsubtitle\n\n"}
    end)

    stub(Cinder.Library.MediaServerMock, :scan, fn _kind -> :ok end)

    task = Task.async(fn -> Subtitles.fetch_missing(%{imdb_id: "tt1"}, video, :movies) end)

    assert_receive {:filesystem_barrier, pid, ref, :rename_exclusive, _staged},
                   DiskTask.timeout_ms()

    File.rename!(parent, parent <> ".old")
    File.ln_s!(outside, parent)

    log =
      capture_log(fn ->
        send(pid, {ref, :continue})
        assert DiskTask.await(task) == :ok
      end)

    assert log =~ "subtitle write failed for"
    assert log =~ "{:error, :eloop}"
    assert File.ls!(outside) == []
    refute File.exists?(Path.join(parent <> ".old", Path.basename(target)))
  end

  test "subtitle rollback refuses an outside path after the library parent becomes a symlink",
       %{video: video, tmp_dir: tmp} do
    Application.put_env(:cinder, :filesystem, Cinder.Test.BarrierFilesystem)
    parent = Path.dirname(video)
    outside = Path.join(tmp, "outside")
    target = Subtitles.sidecar_path(video, "fr")
    outside_target = Path.join(outside, Path.basename(target))
    put!(outside_target, "outside subtitle")

    Application.put_env(:cinder, :filesystem_barrier, %{
      owner: self(),
      operation: :write_exclusive,
      contains: ".cinder-subtitle-manifest-"
    })

    expect(Cinder.Subtitles.ProviderMock, :search, fn _criteria -> {:ok, [result(1, "fr")]} end)

    expect(Cinder.Subtitles.ProviderMock, :download, fn 1 ->
      {:ok, "1\n00:00:01,000 --> 00:00:02,000\nnew subtitle\n\n"}
    end)

    deny(Cinder.Library.MediaServerMock, :scan, 1)

    task = Task.async(fn -> Subtitles.fetch_missing(%{imdb_id: "tt1"}, video, :movies) end)

    assert_receive {:filesystem_barrier, pid, ref, :write_exclusive, manifest_temporary},
                   DiskTask.timeout_ms()

    assert File.exists?(target)
    assert String.contains?(manifest_temporary, ".cinder-subtitle-manifest-")

    File.rename!(parent, parent <> ".old")
    File.ln_s!(outside, parent)

    log =
      capture_log(fn ->
        send(pid, {ref, :continue})
        assert DiskTask.await(task) == :ok
      end)

    assert log =~ "subtitle rollback failed for #{target}"
    assert log =~ "subtitle provenance write failed for"
    assert File.read!(outside_target) == "outside subtitle"
  end

  test "published sidecars are readable and a later sweep repairs restrictive modes", %{
    video: video
  } do
    Application.put_env(:cinder, :filesystem, Cinder.Test.BarrierFilesystem)
    target = Subtitles.sidecar_path(video, "fr")

    expect(Cinder.Subtitles.ProviderMock, :search, 2, fn _criteria -> {:ok, [result(1, "fr")]} end)

    expect(Cinder.Subtitles.ProviderMock, :download, fn 1 ->
      {:ok, "1\n00:00:01,000 --> 00:00:02,000\nsubtitle\n\n"}
    end)

    expect(Cinder.Library.MediaServerMock, :scan, fn :movies -> :ok end)

    assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, video, :movies)
    assert File.read!(target) == "1\n00:00:01,000 --> 00:00:02,000\nsubtitle\n\n"
    assert mode(target) == 0o644
    assert mode(Manifest.path(video)) == 0o600

    File.chmod!(target, 0o600)
    assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, video, :movies)
    assert mode(target) == 0o644
    assert File.read!(target) == "1\n00:00:01,000 --> 00:00:02,000\nsubtitle\n\n"
  end

  defp result(file_id, language, overrides \\ []) do
    Map.merge(
      %{
        file_id: file_id,
        language: language,
        downloads: 1,
        hearing_impaired: false,
        ai_translated: false,
        moviehash_match: false
      },
      Map.new(overrides)
    )
  end

  defp put!(path, content) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  defp put_manifest!(video, manifest), do: put!(Manifest.path(video), Jason.encode!(manifest))

  # A hash-verified French sidecar with a sync record, as a finished sweep leaves it. Returns the
  # manifest's bytes.
  defp put_verified_track!(video, moviehash) do
    put!(Subtitles.sidecar_path(video, "fr"), "1\n00:00:01,000 --> 00:00:02,000\nBonjour\n\n")

    sync = %{
      status: "aligned",
      method: "audio",
      moviehash: moviehash,
      source_sha256: String.duplicate("a", 64),
      applied_sha256: String.duplicate("b", 64),
      offset_ms: 1_000,
      rate: 1.0,
      score: 42.5,
      reason: nil
    }

    put_manifest!(video, %{
      video_moviehash: moviehash || "0123456789abcdef",
      tracks: %{"fr" => %{origin: "opensubtitles_hash", file: "M.fr.srt", sync: sync}}
    })

    File.read!(Manifest.path(video))
  end

  defp target(video), do: Subtitles.sidecar_path(video, "fr")

  # The moviehash `put_moviehash!(131_072)` gives the video.
  defp moviehash, do: Moviehash.compute(131_072, @zeros, @zeros)

  # A French embedded sidecar as a commit before #1072 left it. `recorded` holds what its entry
  # records besides its origin, file and hash: `source_moviehash`, `source_track`, a sync record.
  defp put_embedded!(video, content, recorded) do
    put!(target(video), content)

    entry =
      Map.merge(
        %{
          origin: "embedded",
          file: Path.basename(target(video)),
          managed_sha256: digest(content)
        },
        Map.new(recorded)
      )

    put_manifest!(video, %{
      video_moviehash: recorded[:source_moviehash],
      tracks: %{"fr" => entry}
    })
  end

  # A failing embedded sidecar from track 2, whose entry records the zero-byte backup container a
  # correction of an earlier sidecar in the language left, as `Manifest.put/8` carries it forward.
  # Track 2's rejection is stored. Returns the container's name and identity.
  defp put_tombstoned_embedded!(video) do
    name = ".M.fr.srt.cinder-sync-original"
    backup = Path.join(Path.dirname(video), name)
    put!(backup, "")
    %File.Stat{major_device: major, minor_device: minor, inode: inode} = File.stat!(backup)
    identity = [major, minor, inode]

    put_embedded!(video, @broken,
      source_moviehash: moviehash(),
      source_track: 2,
      backup_tombstone: %{identity: identity}
    )

    TrackRejection.reject(moviehash(), 2, :timing)
    %{name: name, identity: identity}
  end

  defp removal_log(video) do
    log =
      capture_log(fn ->
        assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, video, :movies)
      end)

    refute log =~ "crashed"
    log
  end

  # A final sync record with `method`; `:invalid` is one `Manifest` does not decode.
  defp sync_record(:invalid), do: %{status: "aligned", method: "manual"}

  defp sync_record(method) do
    %{
      version: 6,
      status: "aligned",
      method: Atom.to_string(method),
      moviehash: nil,
      source_sha256: String.duplicate("a", 64),
      applied_sha256: String.duplicate("b", 64),
      offset_ms: 500,
      rate: 1.0
    }
  end

  defp put_moviehash!(size) do
    stub(Cinder.Library.FilesystemMock, :moviehash_data, fn _ -> {:ok, {size, @zeros, @zeros}} end)
  end

  defp track(index, language, overrides \\ []) do
    Map.merge(
      %{index: index, language: language, default?: false, forced?: false, packet_count: 50},
      Map.new(overrides)
    )
  end

  # Long enough to be the video's own track (`Cinder.Subtitles.OwnTrack`).
  defp own_track(index, language, overrides \\ []),
    do: track(index, language, Keyword.put_new(overrides, :packet_count, 900))

  # The two whole-file reads, each reported to the test: listing the tracks (`probe`) and
  # extracting one (`contents` maps a track index to the extraction's result).
  defp stub_reads(video, probe, contents) do
    test = self()

    stub(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video ->
      send(test, :probe)
      probe
    end)

    stub(Cinder.Library.MediaInfoMock, :extract_subtitle, fn ^video, index ->
      send(test, {:extract, index})
      Map.fetch!(contents, index)
    end)
  end

  # As stub_reads/3, but each track's extractions return its `results` in turn, then the last one.
  defp stub_extractions(video, tracks, results) do
    test = self()
    results = start_supervised!({Agent, fn -> results end})
    stub_reads(video, {:ok, tracks}, %{})

    stub(Cinder.Library.MediaInfoMock, :extract_subtitle, fn ^video, index ->
      send(test, {:extract, index})
      Agent.get_and_update(results, &next_result(&1, index))
    end)
  end

  defp next_result(results, index) do
    case Map.fetch!(results, index) do
      [result] -> {result, results}
      [result | rest] -> {result, Map.put(results, index, rest)}
    end
  end

  # A file with no default track, or with one the SRT parser already rejected as a translation
  # source (`TrackRejection` `:srt`). Each leaves the sidecars as the only translation source.
  defp stub_default_track(video, :none), do: stub_reads(video, {:ok, []}, %{})

  defp stub_default_track(video, :rejected) do
    stub_reads(video, {:ok, [track(3, "eng", default?: true)]}, %{3 => {:ok, @broken}})
    TrackRejection.reject(Moviehash.compute(131_072, @zeros, @zeros), 3, :srt)
  end

  # `Cinder.Library.Sidecars` keeps the order the disk lists a folder in; this lists `path` first.
  defp list_first(path) do
    stub(Cinder.Library.FilesystemMock, :find_files, fn dir ->
      with {:ok, entries} <- Disk.find_files(dir),
           do: {:ok, Enum.sort_by(entries, fn {entry, _size} -> entry != path end)}
    end)
  end

  # A translation is reported, not denied: a mock that raises lands in fetch_one/6's rescue.
  defp stub_translate do
    test = self()

    stub(Cinder.Subtitles.TranslatorMock, :translate, fn lines, language ->
      send(test, {:translate, language})
      {:ok, lines}
    end)
  end

  # One sweep's fetch for `video`: the reads and media-server scans it made, in order. A crash
  # inside the fetch is logged and swallowed, so the log is checked for one.
  defp effects(criteria, video) do
    log = capture_log(fn -> assert :ok = Subtitles.fetch_missing(criteria, video, :movies) end)
    refute log =~ "crashed"
    drain_effects([])
  end

  # A timing rejection logs at info, below the test env's :warning level. The level comes back on
  # exit, which runs even for a test ExUnit killed.
  defp info_log(fun) do
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: :warning) end)
    capture_log(fun)
  end

  defp drain_effects(acc) do
    receive do
      :probe -> drain_effects([:probe | acc])
      {:extract, _index} = read -> drain_effects([read | acc])
      {:scan, _kind} = scan -> drain_effects([scan | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp fail_manifest_writes do
    stub(Cinder.Library.FilesystemMock, :write_exclusive, fn path, content ->
      if String.contains?(path, ".cinder-subtitle-manifest-"),
        do: {:error, :eio},
        else: Disk.write_exclusive(path, content)
    end)
  end

  defp next(calls, key),
    do:
      Agent.get_and_update(calls, &{Map.fetch!(&1, key), Map.update!(&1, key, fn n -> n + 1 end)})

  defp digest(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)
end
