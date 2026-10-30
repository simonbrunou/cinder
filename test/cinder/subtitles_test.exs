defmodule Cinder.SubtitlesTest do
  # Every test runs against a real movies library in a temp directory: `FilesystemMock` delegates
  # to `Disk` (`Mox.stub_with/2`), so a published sidecar goes through the real rooted helper,
  # and a test overrides only the call it is about (the video's moviehash, a failing write).
  use Cinder.DataCase, async: false

  import Mox
  import ExUnit.CaptureLog

  alias Cinder.Library.Filesystem.Disk
  alias Cinder.Subtitles
  alias Cinder.Subtitles.Manifest
  alias Cinder.Subtitles.Moviehash
  alias Cinder.Subtitles.Sync.Worker
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

      assert_receive {:manifest_read_ready, first}, 15_000
      refute_receive {:manifest_read_ready, _second}, 200

      # Each task reads the manifest twice inside its lock: the keep_verified? pre-check, then
      # Manifest.put's own read. The second task's first read must still only happen after the
      # first task released the lock — that's the serialization being proven.
      first_ref = Process.monitor(first)
      send(first, :continue_manifest_read)
      assert_receive {:manifest_read_ready, ^first}, 15_000
      send(first, :continue_manifest_read)

      assert_receive {:DOWN, ^first_ref, :process, ^first, :normal}, 15_000

      assert_receive {:manifest_read_ready, second}, 15_000
      second_ref = Process.monitor(second)
      send(second, :continue_manifest_read)
      assert_receive {:manifest_read_ready, ^second}, 15_000
      send(second, :continue_manifest_read)

      assert_receive {:DOWN, ^second_ref, :process, ^second, :normal}, 15_000

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

    expect(Cinder.Library.MediaInfoMock, :extract_subtitle, fn ^video, 3 ->
      {:ok, "1\n00:00:01,000 --> 00:00:02,000\nHello\n\n"}
    end)

    stub(Cinder.Subtitles.TranslatorMock, :translate, fn ["Hello"], "fr" ->
      {:ok, ["MACHINE-EN->FR: Hello"]}
    end)

    stub(Cinder.Library.MediaServerMock, :scan, fn :movies -> :ok end)

    assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, video, :movies)

    assert File.read!(target) == "1\n00:00:01,000 --> 00:00:02,000\nBonjour original\n\n"
    assert %{tracks: %{"fr" => %{origin: "release_sidecar"}}} = Manifest.read(video)
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

    assert_receive {:filesystem_barrier, pid, ref, :rename_exclusive, _staged}, 15_000
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

    assert_receive {:filesystem_barrier, pid, ref, :write_exclusive, manifest_temporary}, 15_000
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
