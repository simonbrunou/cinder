defmodule Cinder.SubtitlesTest do
  use Cinder.DataCase, async: false

  import Mox
  import ExUnit.CaptureLog

  alias Cinder.Subtitles
  alias Cinder.Subtitles.Manifest
  alias Cinder.Subtitles.Moviehash
  alias Cinder.Subtitles.Sync.Worker

  @video "/lib/M/M.mkv"
  setup :verify_on_exit!

  setup do
    saved_provider = Application.get_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, [])
    saved_media_info = Application.get_env(:cinder, :media_info)

    on_exit(fn ->
      Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, saved_provider)
      Application.put_env(:cinder, :media_info, saved_media_info)
    end)

    Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, languages: "fr")
    Application.put_env(:cinder, :media_info, nil)

    fs = start_supervised!({Agent, fn -> %{} end})

    stub(Cinder.Library.FilesystemMock, :moviehash_data, fn _ -> :too_small end)

    stub(Cinder.Library.FilesystemMock, :read, fn path ->
      send(self(), {:read, path})

      Agent.get(fs, fn files ->
        case files do
          %{^path => content} -> {:ok, content}
          _ -> {:error, :enoent}
        end
      end)
    end)

    stub(Cinder.Library.FilesystemMock, :write, fn path, content ->
      Agent.update(fs, &Map.put(&1, path, IO.iodata_to_binary(content)))
      :ok
    end)

    stub(Cinder.Library.FilesystemMock, :chmod, fn _path, _mode -> :ok end)

    stub(Cinder.Library.FilesystemMock, :write_exclusive, fn path, content ->
      Agent.update(fs, &Map.put(&1, path, IO.iodata_to_binary(content)))
      :ok
    end)

    stub(Cinder.Library.FilesystemMock, :rename, fn source, dest ->
      Agent.get_and_update(fs, fn files ->
        {{:ok, Map.fetch!(files, source)},
         files |> Map.delete(source) |> Map.put(dest, Map.fetch!(files, source))}
      end)
      |> elem(0)
    end)

    stub(Cinder.Library.FilesystemMock, :lstat, fn path ->
      if Agent.get(fs, &Map.has_key?(&1, path)), do: {:ok, %File.Stat{}}, else: {:error, :enoent}
    end)

    {:ok, fs: fs}
  end

  test "wanted_languages/0 parses csv and is [] when blank" do
    Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, languages: "en, FR")
    assert Subtitles.wanted_languages() == ["en", "fr"]

    Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, languages: "  ")
    assert Subtitles.wanted_languages() == []
  end

  test "sidecar_path/2 preserves the normal video.lang.srt name" do
    assert Subtitles.sidecar_path(@video, "fr") == "/lib/M/M.fr.srt"
  end

  test "a current hash manifest re-searches when its target sidecar is missing", %{fs: fs} do
    zeros = <<0::size(65_536 * 8)>>
    moviehash = Moviehash.compute(131_072, zeros, zeros)
    manifest = Manifest.path(@video)

    Agent.update(fs, fn files ->
      Map.put(
        files,
        manifest,
        Jason.encode!(%{
          video_moviehash: moviehash,
          tracks: %{"fr" => %{origin: "opensubtitles_hash"}}
        })
      )
    end)

    expect(Cinder.Library.FilesystemMock, :moviehash_data, fn @video ->
      {:ok, {131_072, zeros, zeros}}
    end)

    expect(Cinder.Subtitles.ProviderMock, :search, fn %{languages: ["fr"]} ->
      {:ok,
       [
         %{
           file_id: 1,
           language: "fr",
           downloads: 1,
           hearing_impaired: false,
           ai_translated: false,
           moviehash_match: true
         }
       ]}
    end)

    expect(Cinder.Subtitles.ProviderMock, :download, fn 1 ->
      {:ok, "1\n00:00:01,000 --> 00:00:02,000\nHASH SRT\n\n"}
    end)

    expect(Cinder.Library.MediaServerMock, :scan, fn :movies -> :ok end)

    assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, @video, :movies)

    assert Agent.get(fs, &Map.get(&1, Subtitles.sidecar_path(@video, "fr"))) ==
             "1\n00:00:01,000 --> 00:00:02,000\nHASH SRT\n\n"
  end

  test "a malformed provider language does not hide a valid later candidate", %{fs: fs} do
    expect(Cinder.Subtitles.ProviderMock, :search, fn %{languages: ["fr"]} ->
      {:ok,
       [
         %{
           file_id: 1,
           language: nil,
           downloads: 10,
           hearing_impaired: false,
           ai_translated: false,
           moviehash_match: false
         },
         %{
           file_id: 2,
           language: "fr",
           downloads: 1,
           hearing_impaired: false,
           ai_translated: false,
           moviehash_match: false
         }
       ]}
    end)

    expect(Cinder.Subtitles.ProviderMock, :download, fn 2 ->
      {:ok, "1\n00:00:01,000 --> 00:00:02,000\nFR SRT\n\n"}
    end)

    expect(Cinder.Library.MediaServerMock, :scan, fn :movies -> :ok end)

    assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, @video, :movies)

    assert Agent.get(fs, &Map.get(&1, Subtitles.sidecar_path(@video, "fr"))) ==
             "1\n00:00:01,000 --> 00:00:02,000\nFR SRT\n\n"
  end

  test "a successful OpenSubtitles download enqueues synchronization", %{fs: fs} do
    parent = self()

    start_supervised!(
      {Worker,
       initial_scan: false,
       analyze: fn video ->
         send(parent, {:analyzed, video})
         []
       end}
    )

    expect(Cinder.Subtitles.ProviderMock, :search, fn _ ->
      {:ok,
       [
         %{
           file_id: 1,
           language: "fr",
           downloads: 1,
           hearing_impaired: false,
           ai_translated: false,
           moviehash_match: false
         }
       ]}
    end)

    expect(Cinder.Subtitles.ProviderMock, :download, fn 1 ->
      {:ok, "1\n00:00:01,000 --> 00:00:02,000\nFR SRT\n\n"}
    end)

    expect(Cinder.Library.MediaServerMock, :scan, fn :movies -> :ok end)

    assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, @video, :movies)
    assert_receive {:analyzed, @video}

    assert Agent.get(fs, &Map.get(&1, Subtitles.sidecar_path(@video, "fr"))) ==
             "1\n00:00:01,000 --> 00:00:02,000\nFR SRT\n\n"

    track = Manifest.read(@video).tracks["fr"]
    assert track.file == "M.fr.srt"

    assert track.managed_sha256 ==
             "1\n00:00:01,000 --> 00:00:02,000\nFR SRT\n\n"
             |> then(&:crypto.hash(:sha256, &1))
             |> Base.encode16(case: :lower)
  end

  test "a committed subtitle rename is verified before provenance is written", %{fs: fs} do
    target = Subtitles.sidecar_path(@video, "fr")

    stub(Cinder.Library.FilesystemMock, :rename, fn source, destination ->
      Agent.get_and_update(fs, fn files ->
        content = Map.fetch!(files, source)
        files = files |> Map.delete(source) |> Map.put(destination, content)

        if destination == target and not Map.get(files, :committed_rename_reported, false) do
          error =
            {:error,
             {:effect_committed, "rename", %{"phase" => "post_effect", "reason" => "EIO"}}}

          {error, Map.put(files, :committed_rename_reported, true)}
        else
          {:ok, files}
        end
      end)
    end)

    stub(Cinder.Library.FilesystemMock, :rm, fn path ->
      Agent.update(fs, &Map.delete(&1, path))
      :ok
    end)

    expect(Cinder.Subtitles.ProviderMock, :search, fn _ ->
      {:ok,
       [
         %{
           file_id: 1,
           language: "fr",
           downloads: 1,
           hearing_impaired: false,
           ai_translated: false,
           moviehash_match: false
         }
       ]}
    end)

    expect(Cinder.Subtitles.ProviderMock, :download, fn 1 ->
      {:ok, "1\n00:00:01,000 --> 00:00:02,000\nFR SRT\n\n"}
    end)

    expect(Cinder.Library.MediaServerMock, :scan, fn :movies -> :ok end)

    assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, @video, :movies)

    assert Agent.get(fs, &Map.fetch!(&1, target)) ==
             "1\n00:00:01,000 --> 00:00:02,000\nFR SRT\n\n"

    assert Manifest.read(@video).tracks["fr"].file == "M.fr.srt"
  end

  test "concurrent release-sidecar manifests serialize by video", %{fs: fs} do
    set_mox_global()
    Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, languages: "")

    fr_target = Subtitles.sidecar_path(@video, "fr")
    en_target = Subtitles.sidecar_path(@video, "en")
    parent = self()

    Agent.update(fs, fn files ->
      files
      |> Map.put(fr_target, "1\n00:00:01,000 --> 00:00:02,000\nFR SRT\n\n")
      |> Map.put(en_target, "1\n00:00:01,000 --> 00:00:02,000\nEN SRT\n\n")
      |> Map.put(:manifest_read_barrier, true)
    end)

    manifest = Manifest.path(@video)

    stub(Cinder.Library.FilesystemMock, :read, fn path ->
      result =
        Agent.get(fs, fn files ->
          case files do
            %{^path => content} -> {:ok, content}
            _ -> {:error, :enoent}
          end
        end)

      if path == manifest and Agent.get(fs, &Map.get(&1, :manifest_read_barrier)) do
        waiter = self()

        Agent.update(fs, fn files ->
          Map.update(files, :manifest_waiters, [waiter], fn waiters -> [waiter | waiters] end)
        end)

        send(parent, {:manifest_read_ready, waiter})

        receive do
          :continue_manifest_read -> result
        end
      else
        result
      end
    end)

    try do
      assert :ok = Subtitles.fetch_after_import(fn -> %{} end, @video, :movies, ["fr"])
      assert :ok = Subtitles.fetch_after_import(fn -> %{} end, @video, :movies, ["en"])

      assert_receive {:manifest_read_ready, first}, 1_000
      refute_receive {:manifest_read_ready, _second}, 200

      # Each task reads the manifest twice inside its lock: the keep_verified? pre-check, then
      # Manifest.put's own read. The second task's first read must still only happen after the
      # first task released the lock — that's the serialization being proven.
      first_ref = Process.monitor(first)
      send(first, :continue_manifest_read)
      assert_receive {:manifest_read_ready, ^first}, 1_000
      send(first, :continue_manifest_read)

      assert_receive {:DOWN, ^first_ref, :process, ^first, :normal}, 1_000

      assert_receive {:manifest_read_ready, second}, 1_000
      second_ref = Process.monitor(second)
      send(second, :continue_manifest_read)
      assert_receive {:manifest_read_ready, ^second}, 1_000
      send(second, :continue_manifest_read)

      assert_receive {:DOWN, ^second_ref, :process, ^second, :normal}, 1_000

      Agent.update(fs, &Map.delete(&1, :manifest_read_barrier))

      assert %{
               tracks: %{
                 "en" => %{origin: "release_sidecar"},
                 "fr" => %{origin: "release_sidecar"}
               }
             } = Manifest.read(@video)
    after
      fs
      |> Agent.get(&Map.get(&1, :manifest_waiters, []))
      |> Enum.each(&send(&1, :continue_manifest_read))
    end
  end

  test "an ID result is provisional and a later hash result replaces it", %{fs: fs} do
    video = @video
    target = "/lib/M/M.fr.srt"
    zeros = <<0::size(65_536 * 8)>>

    expect(Cinder.Library.FilesystemMock, :moviehash_data, 2, fn ^video ->
      case Agent.get_and_update(fs, fn files ->
             count = Map.get(files, :hash_reads, 0)
             {count, Map.put(files, :hash_reads, count + 1)}
           end) do
        0 -> :too_small
        1 -> {:ok, {131_072, zeros, zeros}}
      end
    end)

    expect(Cinder.Subtitles.ProviderMock, :search, 2, fn %{languages: ["fr"]} ->
      case Agent.get_and_update(fs, fn files ->
             count = Map.get(files, :searches, 0)
             {count, Map.put(files, :searches, count + 1)}
           end) do
        0 ->
          {:ok,
           [
             %{
               file_id: 1,
               language: "fr",
               downloads: 1,
               hearing_impaired: false,
               ai_translated: false,
               moviehash_match: false
             }
           ]}

        1 ->
          {:ok,
           [
             %{
               file_id: 2,
               language: "fr",
               downloads: 1,
               hearing_impaired: false,
               ai_translated: false,
               moviehash_match: true
             }
           ]}
      end
    end)

    expect(Cinder.Subtitles.ProviderMock, :download, 2, fn
      1 -> {:ok, "1\n00:00:01,000 --> 00:00:02,000\nID SRT\n\n"}
      2 -> {:ok, "1\n00:00:01,000 --> 00:00:02,000\nHASH SRT\n\n"}
    end)

    expect(Cinder.Library.MediaServerMock, :scan, 2, fn :movies -> :ok end)

    assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, @video, :movies)

    assert %{tracks: %{"fr" => %{origin: "opensubtitles_id", file: "M.fr.srt"}}} =
             Manifest.read(@video)

    assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, @video, :movies)

    assert %{tracks: %{"fr" => %{origin: "opensubtitles_hash", file: "M.fr.srt"}}} =
             Manifest.read(@video)

    assert Agent.get(fs, &Map.fetch!(&1, target)) ==
             "1\n00:00:01,000 --> 00:00:02,000\nHASH SRT\n\n"
  end

  test "a transient moviehash read failure preserves a verified sibling's provenance", %{
    fs: fs
  } do
    video = @video
    target_en = "/lib/M/M.en.srt"
    target_fr = "/lib/M/M.fr.srt"
    zeros = <<0::size(65_536 * 8)>>
    moviehash = Moviehash.compute(131_072, zeros, zeros)
    manifest = Manifest.path(@video)
    en_bytes = "1\n00:00:01,000 --> 00:00:02,000\nHello\n\n"

    Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, languages: "en,fr")

    Agent.update(fs, fn files ->
      files
      |> Map.put(target_en, en_bytes)
      |> Map.put(
        manifest,
        Jason.encode!(%{
          video_moviehash: moviehash,
          tracks: %{"en" => %{origin: "opensubtitles_hash"}}
        })
      )
    end)

    expect(Cinder.Library.FilesystemMock, :moviehash_data, fn ^video -> {:error, :eio} end)

    expect(Cinder.Subtitles.ProviderMock, :search, 2, fn
      %{languages: ["en"]} ->
        {:ok,
         [
           %{
             file_id: 9,
             language: "en",
             downloads: 1,
             hearing_impaired: false,
             ai_translated: false,
             moviehash_match: false
           }
         ]}

      %{languages: ["fr"]} ->
        {:ok,
         [
           %{
             file_id: 1,
             language: "fr",
             downloads: 1,
             hearing_impaired: false,
             ai_translated: false,
             moviehash_match: false
           }
         ]}
    end)

    stub(Cinder.Subtitles.ProviderMock, :download, fn
      1 -> {:ok, "1\n00:00:01,000 --> 00:00:02,000\nBonjour\n\n"}
      9 -> {:ok, "1\n00:00:01,000 --> 00:00:02,000\nDOWNGRADED EN\n\n"}
    end)

    stub(Cinder.Library.MediaServerMock, :scan, fn :movies -> :ok end)

    assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, @video, :movies)

    assert Agent.get(fs, &Map.fetch!(&1, target_en)) == en_bytes

    assert Agent.get(fs, &Map.fetch!(&1, target_fr)) ==
             "1\n00:00:01,000 --> 00:00:02,000\nBonjour\n\n"

    assert %{
             video_moviehash: ^moviehash,
             tracks: %{
               "en" => %{origin: "opensubtitles_hash"},
               "fr" => %{origin: "opensubtitles_id"}
             }
           } = Manifest.read(@video)

    assert Manifest.stable?(Manifest.read(@video), moviehash, "en")
  end

  test "an HTML provider body does not clobber an existing good sidecar", %{fs: fs} do
    target = Subtitles.sidecar_path(@video, "fr")
    manifest = Manifest.path(@video)
    good_content = "1\n00:00:01,000 --> 00:00:02,000\nGOOD SRT\n\n"
    good_sha256 = good_content |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

    Agent.update(fs, fn files ->
      files
      |> Map.put(target, good_content)
      |> Map.put(
        manifest,
        Jason.encode!(%{
          video_moviehash: nil,
          tracks: %{
            "fr" => %{origin: "opensubtitles_hash", file: "M.fr.srt", managed_sha256: good_sha256}
          }
        })
      )
    end)

    stub(Cinder.Library.FilesystemMock, :moviehash_data, fn @video ->
      {:ok, {131_072, <<0::size(65_536 * 8)>>, <<0::size(65_536 * 8)>>}}
    end)

    expect(Cinder.Subtitles.ProviderMock, :search, fn _ ->
      {:ok,
       [
         %{
           file_id: 1,
           language: "fr",
           downloads: 1,
           hearing_impaired: false,
           ai_translated: false,
           moviehash_match: true
         }
       ]}
    end)

    expect(Cinder.Subtitles.ProviderMock, :download, fn 1 ->
      {:ok, "<html><body>Cloudflare interstitial</body></html>"}
    end)

    deny(Cinder.Library.MediaServerMock, :scan, 1)

    log =
      capture_log(fn ->
        assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, @video, :movies)
      end)

    assert log =~ "failed validation"

    assert Agent.get(fs, &Map.fetch!(&1, target)) == good_content

    assert %{tracks: %{"fr" => %{origin: "opensubtitles_hash", managed_sha256: ^good_sha256}}} =
             Manifest.read(@video)
  end

  test "a manifest failure restores the previous managed sidecar", %{fs: fs} do
    target = Subtitles.sidecar_path(@video, "fr")
    manifest = Manifest.path(@video)

    Agent.update(fs, fn files ->
      files
      |> Map.put(target, "1\n00:00:01,000 --> 00:00:02,000\nOLD SRT\n\n")
      |> Map.put(
        manifest,
        Jason.encode!(%{
          video_moviehash: nil,
          tracks: %{"fr" => %{origin: "opensubtitles_id"}}
        })
      )
    end)

    stub(Cinder.Library.FilesystemMock, :moviehash_data, fn @video ->
      {:ok, {131_072, <<0::size(65_536 * 8)>>, <<0::size(65_536 * 8)>>}}
    end)

    stub(Cinder.Library.FilesystemMock, :write_exclusive, fn path, content ->
      if String.contains?(path, ".cinder-subtitle-manifest-") do
        {:error, :eio}
      else
        Agent.update(fs, &Map.put(&1, path, IO.iodata_to_binary(content)))
        :ok
      end
    end)

    expect(Cinder.Subtitles.ProviderMock, :search, fn _ ->
      {:ok,
       [
         %{
           file_id: 1,
           language: "fr",
           downloads: 1,
           hearing_impaired: false,
           ai_translated: false,
           moviehash_match: true
         }
       ]}
    end)

    expect(Cinder.Subtitles.ProviderMock, :download, fn 1 ->
      {:ok, "1\n00:00:01,000 --> 00:00:02,000\nNEW SRT\n\n"}
    end)

    deny(Cinder.Library.MediaServerMock, :scan, 1)

    log =
      capture_log(fn ->
        assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, @video, :movies)
      end)

    assert log =~ "subtitle provenance write failed for /lib/M/M.mkv (fr): {:error, :eio}"

    assert Agent.get(fs, &Map.fetch!(&1, target)) ==
             "1\n00:00:01,000 --> 00:00:02,000\nOLD SRT\n\n"

    assert %{tracks: %{"fr" => %{origin: "opensubtitles_id"}}} = Manifest.read(@video)
  end

  test "a manifest failure removes a newly written sidecar", %{fs: fs} do
    target = Subtitles.sidecar_path(@video, "fr")

    stub(Cinder.Library.FilesystemMock, :moviehash_data, fn @video ->
      {:ok, {131_072, <<0::size(65_536 * 8)>>, <<0::size(65_536 * 8)>>}}
    end)

    stub(Cinder.Library.FilesystemMock, :write_exclusive, fn path, content ->
      if String.contains?(path, ".cinder-subtitle-manifest-") do
        {:error, :eio}
      else
        Agent.update(fs, &Map.put(&1, path, IO.iodata_to_binary(content)))
        :ok
      end
    end)

    expect(Cinder.Library.FilesystemMock, :rm, fn ^target ->
      Agent.update(fs, &Map.delete(&1, target))
      :ok
    end)

    expect(Cinder.Subtitles.ProviderMock, :search, fn _ ->
      {:ok,
       [
         %{
           file_id: 1,
           language: "fr",
           downloads: 1,
           hearing_impaired: false,
           ai_translated: false,
           moviehash_match: true
         }
       ]}
    end)

    expect(Cinder.Subtitles.ProviderMock, :download, fn 1 ->
      {:ok, "1\n00:00:01,000 --> 00:00:02,000\nNEW SRT\n\n"}
    end)

    deny(Cinder.Library.MediaServerMock, :scan, 1)

    log =
      capture_log(fn ->
        assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, @video, :movies)
      end)

    assert log =~ "subtitle provenance write failed for /lib/M/M.mkv (fr): {:error, :eio}"
    refute Agent.get(fs, &Map.has_key?(&1, target))
  end

  test "a provider failure does not call an embedded source or LibreTranslate" do
    expect(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:error, :down} end)

    log =
      capture_log(fn ->
        assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, @video, :movies)
      end)

    assert log =~ "subtitle fetch for /lib/M/M.mkv (fr) failed: :down"
  end

  test "an empty provider result extracts an exact embedded target track", %{fs: fs} do
    video = @video
    Application.put_env(:cinder, :media_info, Cinder.Library.MediaInfoMock)

    expect(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)

    expect(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video ->
      {:ok, [%{index: 2, language: "fr", default?: false, forced?: false}]}
    end)

    expect(Cinder.Library.MediaInfoMock, :extract_subtitle, fn ^video, 2 ->
      {:ok, "1\n00:00:01,000 --> 00:00:02,000\nFR SRT\n\n"}
    end)

    expect(Cinder.Library.MediaServerMock, :scan, fn :movies -> :ok end)

    assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, @video, :movies)

    assert Agent.get(fs, &Map.fetch!(&1, "/lib/M/M.fr.srt")) ==
             "1\n00:00:01,000 --> 00:00:02,000\nFR SRT\n\n"

    assert %{tracks: %{"fr" => %{origin: "embedded"}}} = Manifest.read(@video)
  end

  test "a forced exact embedded track falls through to a default non-forced translation", %{
    fs: fs
  } do
    video = @video
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

    assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, @video, :movies)
    assert Agent.get(fs, &Map.fetch!(&1, "/lib/M/M.fr.srt")) =~ "Bonjour"
    assert %{tracks: %{"fr" => %{origin: "translated"}}} = Manifest.read(@video)
  end

  test "a default embedded track translates each still-missing target", %{fs: fs} do
    video = @video
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

    assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, @video, :movies)
    assert Agent.get(fs, &Map.fetch!(&1, "/lib/M/M.fr.srt")) =~ "Bonjour"
    assert %{tracks: %{"fr" => %{origin: "translated"}}} = Manifest.read(@video)
  end

  test "an SRT sidecar supplies the translation source when no embedded track is usable", %{
    fs: fs
  } do
    video = @video
    Application.put_env(:cinder, :media_info, Cinder.Library.MediaInfoMock)
    source = "/lib/M/M.en.srt"

    Agent.update(fs, &Map.put(&1, source, "1\n00:00:01,000 --> 00:00:02,000\nHello\n\n"))

    expect(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)
    expect(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video -> {:ok, []} end)
    expect(Cinder.Library.FilesystemMock, :dir?, fn "/lib/M" -> true end)

    expect(Cinder.Library.FilesystemMock, :find_files, fn "/lib/M" ->
      {:ok, [{@video, 1}, {source, 1}]}
    end)

    expect(Cinder.Subtitles.TranslatorMock, :translate, fn ["Hello"], "fr" ->
      {:ok, ["Bonjour"]}
    end)

    expect(Cinder.Library.MediaServerMock, :scan, fn :movies -> :ok end)

    assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, @video, :movies)
    assert_received {:read, ^source}
    assert Agent.get(fs, &Map.fetch!(&1, "/lib/M/M.fr.srt")) =~ "Bonjour"
  end

  test "an unmarked target sidecar is never overwritten even when a provider candidate exists", %{
    fs: fs
  } do
    target = "/lib/M/M.fr.srt"
    Agent.update(fs, &Map.put(&1, target, "manual"))

    expect(Cinder.Subtitles.ProviderMock, :search, fn _ ->
      {:ok,
       [
         %{
           file_id: 1,
           language: "fr",
           downloads: 1,
           hearing_impaired: false,
           ai_translated: false,
           moviehash_match: false
         }
       ]}
    end)

    deny(Cinder.Library.FilesystemMock, :write, 2)
    deny(Cinder.Library.FilesystemMock, :rename, 2)

    assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, @video, :movies)
    assert Agent.get(fs, &Map.fetch!(&1, target)) == "manual"
  end

  test "a default embedded track never replaces an existing release-sidecar target", %{fs: fs} do
    video = @video
    Application.put_env(:cinder, :media_info, Cinder.Library.MediaInfoMock)
    target = "/lib/M/M.fr.srt"
    manifest = Manifest.path(@video)

    Agent.update(fs, fn files ->
      files
      |> Map.put(target, "1\n00:00:01,000 --> 00:00:02,000\nBonjour original\n\n")
      |> Map.put(
        manifest,
        Jason.encode!(%{
          video_moviehash: nil,
          tracks: %{"fr" => %{origin: "release_sidecar"}}
        })
      )
    end)

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

    assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, @video, :movies)

    assert Agent.get(fs, &Map.fetch!(&1, target)) ==
             "1\n00:00:01,000 --> 00:00:02,000\nBonjour original\n\n"

    assert %{tracks: %{"fr" => %{origin: "release_sidecar"}}} = Manifest.read(@video)
  end

  test "sidecar_source never reclassifies the canonical target as its own translation source",
       %{fs: fs} do
    video = @video
    Application.put_env(:cinder, :media_info, Cinder.Library.MediaInfoMock)
    target = "/lib/M/M.fr.srt"
    manifest = Manifest.path(@video)

    Agent.update(fs, fn files ->
      files
      |> Map.put(target, "1\n00:00:01,000 --> 00:00:02,000\nProvider FR\n\n")
      |> Map.put(
        manifest,
        Jason.encode!(%{
          video_moviehash: nil,
          tracks: %{"fr" => %{origin: "opensubtitles_id"}}
        })
      )
    end)

    expect(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)
    expect(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video -> {:ok, []} end)
    expect(Cinder.Library.FilesystemMock, :dir?, fn "/lib/M" -> true end)

    expect(Cinder.Library.FilesystemMock, :find_files, fn "/lib/M" ->
      {:ok, [{video, 1}, {target, 1}]}
    end)

    stub(Cinder.Library.MediaServerMock, :scan, fn :movies -> :ok end)

    assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, @video, :movies)

    assert Agent.get(fs, &Map.fetch!(&1, target)) ==
             "1\n00:00:01,000 --> 00:00:02,000\nProvider FR\n\n"

    assert %{tracks: %{"fr" => %{origin: "opensubtitles_id"}}} = Manifest.read(@video)
  end

  test "fetch_missing/2 remains a movies wrapper" do
    Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, languages: "")
    assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, @video)
  end

  test "fetch_missing/3 stops after the provider reports quota" do
    Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, languages: "en,fr")

    expect(Cinder.Subtitles.ProviderMock, :search, fn %{languages: ["en"]} ->
      {:ok,
       [
         %{
           file_id: 1,
           language: "en",
           downloads: 1,
           hearing_impaired: false,
           ai_translated: false,
           moviehash_match: false
         }
       ]}
    end)

    expect(Cinder.Subtitles.ProviderMock, :download, fn 1 -> {:error, :quota_exceeded} end)

    assert :quota_exceeded = Subtitles.fetch_missing(%{imdb_id: "tt1"}, @video, :movies)
  end

  @tag :tmp_dir
  test "subtitle rename rejects a library parent replaced by a symlink after the temp write", %{
    tmp_dir: tmp
  } do
    saved = configure_real_policy(tmp)
    on_exit(fn -> restore_env(saved) end)
    movies = Application.fetch_env!(:cinder, :movies_library_path)
    parent = Path.join(movies, "Movie")
    video = Path.join(parent, "Movie.mkv")
    outside = Path.join(tmp, "outside")
    target = Subtitles.sidecar_path(video, "fr")
    File.mkdir_p!(parent)
    File.mkdir_p!(outside)
    File.write!(video, "video")

    Application.put_env(:cinder, :filesystem_barrier, %{
      owner: self(),
      operation: :write,
      contains: ".cinder-subtitle-",
      excludes: "manifest"
    })

    expect(Cinder.Subtitles.ProviderMock, :search, fn _criteria ->
      {:ok,
       [
         %{
           file_id: 1,
           language: "fr",
           downloads: 1,
           hearing_impaired: false,
           ai_translated: false,
           moviehash_match: false
         }
       ]}
    end)

    expect(Cinder.Subtitles.ProviderMock, :download, fn 1 ->
      {:ok, "1\n00:00:01,000 --> 00:00:02,000\nsubtitle\n\n"}
    end)

    stub(Cinder.Library.MediaServerMock, :scan, fn _kind -> :ok end)

    task = Task.async(fn -> Subtitles.fetch_missing(%{imdb_id: "tt1"}, video, :movies) end)

    assert_receive {:filesystem_barrier, pid, ref, :write, temporary}, 1_000
    replace_parent(parent, outside, temporary)
    send(pid, {ref, :continue})

    log = capture_log(fn -> assert Task.await(task) == :ok end)

    assert log =~ "subtitle write failed for"
    assert log =~ "{:error, :eloop}"
    refute File.exists?(Path.join(outside, Path.basename(target)))
  end

  @tag :tmp_dir
  test "subtitle rollback refuses an outside unlink after the library parent becomes a symlink",
       %{
         tmp_dir: tmp
       } do
    saved = configure_real_policy(tmp)
    on_exit(fn -> restore_env(saved) end)
    movies = Application.fetch_env!(:cinder, :movies_library_path)
    parent = Path.join(movies, "Movie")
    video = Path.join(parent, "Movie.mkv")
    outside = Path.join(tmp, "outside")
    target = Subtitles.sidecar_path(video, "fr")
    outside_target = Path.join(outside, Path.basename(target))
    File.mkdir_p!(parent)
    File.mkdir_p!(outside)
    File.write!(video, "video")
    File.write!(outside_target, "outside subtitle")

    Application.put_env(:cinder, :filesystem_barrier, %{
      owner: self(),
      operation: :write_exclusive,
      contains: ".cinder-subtitle-manifest-"
    })

    expect(Cinder.Subtitles.ProviderMock, :search, fn _criteria ->
      {:ok,
       [
         %{
           file_id: 1,
           language: "fr",
           downloads: 1,
           hearing_impaired: false,
           ai_translated: false,
           moviehash_match: false
         }
       ]}
    end)

    expect(Cinder.Subtitles.ProviderMock, :download, fn 1 ->
      {:ok, "1\n00:00:01,000 --> 00:00:02,000\nnew subtitle\n\n"}
    end)

    deny(Cinder.Library.MediaServerMock, :scan, 1)

    task = Task.async(fn -> Subtitles.fetch_missing(%{imdb_id: "tt1"}, video, :movies) end)

    assert_receive {:filesystem_barrier, pid, ref, :write_exclusive, manifest_temporary}, 1_000
    assert File.exists?(target)
    assert String.contains?(manifest_temporary, ".cinder-subtitle-manifest-")

    File.rename!(parent, parent <> ".old")
    File.ln_s!(outside, parent)
    send(pid, {ref, :continue})

    log = capture_log(fn -> assert Task.await(task) == :ok end)

    assert log =~ "subtitle rollback rejected: {:error, :unsafe_delete}"
    assert log =~ "subtitle provenance write failed for"
    assert File.read!(outside_target) == "outside subtitle"
  end

  @tag :tmp_dir
  test "published sidecars are readable and a later sweep repairs restrictive modes", %{
    tmp_dir: tmp
  } do
    saved = configure_real_policy(tmp)
    on_exit(fn -> restore_env(saved) end)
    video = Path.join(Application.fetch_env!(:cinder, :movies_library_path), "Movie/Movie.mkv")
    target = Subtitles.sidecar_path(video, "fr")
    File.mkdir_p!(Path.dirname(video))
    File.write!(video, "video")

    result = %{
      file_id: 1,
      language: "fr",
      downloads: 1,
      hearing_impaired: false,
      ai_translated: false,
      moviehash_match: false
    }

    expect(Cinder.Subtitles.ProviderMock, :search, 2, fn _criteria -> {:ok, [result]} end)

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

  defp configure_real_policy(tmp) do
    keys = [:filesystem, :path_policy, :movies_library_path, :tv_library_path]
    saved = Map.new(keys, &{&1, Application.get_env(:cinder, &1)})
    Application.put_env(:cinder, :filesystem, Cinder.Test.BarrierFilesystem)
    Application.put_env(:cinder, :path_policy, Cinder.Library.PathPolicy)
    Application.put_env(:cinder, :movies_library_path, Path.join(tmp, "movies"))
    Application.put_env(:cinder, :tv_library_path, Path.join(tmp, "tv"))
    saved
  end

  defp restore_env(saved) do
    Application.delete_env(:cinder, :filesystem_barrier)

    Enum.each(saved, fn
      {key, nil} -> Application.delete_env(:cinder, key)
      {key, value} -> Application.put_env(:cinder, key, value)
    end)
  end

  defp replace_parent(parent, outside, temporary) do
    backup = parent <> ".old"
    File.rename!(parent, backup)
    File.ln_s!(outside, parent)

    File.rename!(
      Path.join(backup, Path.basename(temporary)),
      Path.join(outside, Path.basename(temporary))
    )
  end

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)
end
