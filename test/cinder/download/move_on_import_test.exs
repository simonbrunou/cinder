defmodule Cinder.Download.MoveOnImportTest do
  # async: false — drives the global pollers and toggles a global Application env key.
  use Cinder.DataCase, async: false

  import Mox

  # The remove paths log on {:error,_}/raise; capture so output stays pristine.
  @moduletag :capture_log

  alias Cinder.Catalog
  alias Cinder.Catalog.{Episode, Grab, Movie}
  alias Cinder.Download
  alias Cinder.Download.{Poller, TvPoller}
  alias Cinder.Repo

  import Cinder.CatalogFixtures
  import Cinder.LibraryStubs

  setup :set_mox_global

  # Default off; each test opts in. Restore the key so the overlay can't leak.
  #
  # explicit_import_roots is set here too: Library.delete_download_source/1 now requires an
  # EXPLICITLY configured import root (Settings.explicit_import_roots/0), never an inferred one
  # (issue #119 review) — this file's fixtures use both `/downloads` (movie) and `/dl` (TV) source
  # roots, so both are listed.
  setup do
    saved = Application.get_env(:cinder, :move_on_import)
    saved_roots = Application.get_env(:cinder, :explicit_import_roots)

    Application.put_env(:cinder, :explicit_import_roots, ["/downloads", "/dl"])

    on_exit(fn ->
      case saved do
        nil -> Application.delete_env(:cinder, :move_on_import)
        v -> Application.put_env(:cinder, :move_on_import, v)
      end

      case saved_roots do
        nil -> Application.delete_env(:cinder, :explicit_import_roots)
        v -> Application.put_env(:cinder, :explicit_import_roots, v)
      end
    end)

    :ok
  end

  defp enable, do: Application.put_env(:cinder, :move_on_import, true)

  defp echo_remove(mock) do
    parent = self()

    stub(mock, :remove, fn id, opts ->
      send(parent, {:removed, id, opts})
      :ok
    end)
  end

  # A safe default so tests that don't care about the exact rm_rf call don't have to stub it
  # themselves; tests asserting on the argument re-stub it with their own capture.
  defp stub_rm_rf, do: stub(Cinder.Library.FilesystemMock, :rm_rf, fn path -> {:ok, [path]} end)

  defp echo_rm_rf do
    parent = self()

    stub(Cinder.Library.FilesystemMock, :rm_rf, fn path ->
      send(parent, {:rm_rf, path})
      {:ok, [path]}
    end)
  end

  defp stub_single_file_import, do: stub_import_ok()

  defp usenet_movie(tmdb_id, download_id) do
    movie_fixture(%{
      tmdb_id: tmdb_id,
      title: "M",
      status: :downloading,
      download_id: download_id,
      download_protocol: :usenet
    })
  end

  defp drive_to_available(mock, download_id) do
    stub(mock, :status, fn ^download_id ->
      {:ok, %{state: :completed, content_path: "/downloads/M.mkv"}}
    end)

    stub_rm_rf()
    stub_single_file_import()
  end

  defp enable_media_info do
    saved = Application.get_env(:cinder, :media_info)
    Application.put_env(:cinder, :media_info, Cinder.Library.MediaInfoMock)

    on_exit(fn ->
      if saved,
        do: Application.put_env(:cinder, :media_info, saved),
        else: Application.delete_env(:cinder, :media_info)
    end)
  end

  defp release_policy_snapshot(release_title) do
    %{
      "version" => 1,
      "required_audio_languages" => ["ja", "fr"],
      "required_embedded_subtitle_languages" => [],
      "release_group" => "group",
      "release_title" => release_title
    }
  end

  # A :downloaded, usenet-protocol movie carrying a frozen release policy snapshot, so
  # Library.stage_movie/1 runs the post-download MediaInfo verification.
  defp usenet_policy_movie(tmdb_id, download_id, source) do
    movie =
      movie_fixture(%{
        tmdb_id: tmdb_id,
        title: "Anime Movie",
        status: :downloaded,
        download_id: download_id,
        download_protocol: :usenet,
        release_title: "[Group] Anime Movie [1080p]",
        file_path: source
      })

    {:ok, movie} =
      Catalog.transition(movie, %{
        status: :downloaded,
        release_policy_snapshot: release_policy_snapshot(movie.release_title)
      })

    movie
  end

  defp series_tree do
    series = series_fixture(%{tvdb_id: 99, monitor_strategy: :all})
    season = season_fixture(series)
    {series, season}
  end

  defp episode(season, ep_num) do
    episode_fixture(season, %{episode_number: ep_num})
  end

  # A resolved anime-mapping grab, so TvPoller's import path runs the reject-on-mismatch
  # branch (Library.stage_anime_episodes) instead of the standard-TV import. Mirrors
  # tv_poller_test.exs's anime_standard_snapshot/downloaded_policy_grab pattern.
  defp tv_policy_grab(episode, content_path, release_title) do
    canonical_value =
      "S01E#{episode.episode_number |> Integer.to_string() |> String.pad_leading(2, "0")}"

    snapshot = %{
      "version" => 2,
      "parser_context" => %{"title" => "Show", "aliases" => [], "year" => 2008},
      "mappings" => [
        %{
          "identity" => %{
            "source" => "cinder",
            "scheme" => "standard",
            "namespace" => "canonical",
            "canonical_value" => canonical_value
          },
          "precedence" => "manual",
          "episode_ids" => [episode.id],
          "evidence" => nil
        }
      ],
      "reserved_episode_ids" => [episode.id]
    }

    grab =
      Repo.insert!(%Grab{
        download_id: "nzo-tv-reject",
        download_protocol: :usenet,
        release_title: release_title,
        content_path: content_path,
        mapping_snapshot: snapshot,
        release_policy_snapshot: release_policy_snapshot(release_title),
        mapping_status: :resolved
      })

    Repo.update_all(from(e in Episode, where: e.id == ^episode.id), set: [grab_id: grab.id])
    grab
  end

  describe "Download.remove_after_import/3 (the client-remove side)" do
    test "removes a usenet download with delete_files when the toggle is on" do
      enable()
      echo_remove(Cinder.Download.SabnzbdClientMock)
      stub_rm_rf()

      assert :ok = Download.remove_after_import(:usenet, "nzo-x", nil)
      assert_receive {:removed, "nzo-x", opts}
      assert opts[:delete_files] == true
    end

    test "is a no-op when the toggle is off" do
      echo_remove(Cinder.Download.SabnzbdClientMock)
      assert :ok = Download.remove_after_import(:usenet, "nzo-x", nil)
      refute_receive {:removed, _, _}
    end

    test "is a no-op for torrents, unknown/nil protocol, and blank/nil id (fails safe)" do
      enable()
      echo_remove(Cinder.Download.SabnzbdClientMock)
      echo_remove(Cinder.Download.ClientMock)

      assert :ok = Download.remove_after_import(:torrent, "hash-x", nil)
      assert :ok = Download.remove_after_import(nil, "x", nil)
      assert :ok = Download.remove_after_import(:usenet, nil, "/downloads/x")
      assert :ok = Download.remove_after_import(:usenet, "", "/downloads/x")
      refute_receive {:removed, _, _}
    end

    test "a raising client cannot unwind the caller; still returns :ok" do
      enable()
      stub(Cinder.Download.SabnzbdClientMock, :remove, fn _id, _opts -> raise "client down" end)
      assert :ok = Download.remove_after_import(:usenet, "nzo-x", nil)
    end

    test "a client {:error,_} is swallowed; returns :ok" do
      enable()
      stub(Cinder.Download.SabnzbdClientMock, :remove, fn _id, _opts -> {:error, :boom} end)
      assert :ok = Download.remove_after_import(:usenet, "nzo-x", nil)
    end
  end

  describe "Download.remove_after_import/3 (the source-delete side, issue #115)" do
    test "toggle on + usenet -> deletes the whole per-operation/unpack dir via rm_rf regardless of the client" do
      enable()

      # The client has already evicted the job (a la SABnzbd short history_retention_number) — the
      # client-side remove is a no-op, but the source delete must still fire (that's the whole
      # point of #115: cleanup can't depend on the client still tracking the job).
      stub(Cinder.Download.SabnzbdClientMock, :remove, fn _id, _opts -> {:error, :not_found} end)
      echo_rm_rf()

      assert :ok = Download.remove_after_import(:usenet, "nzo-x", "/downloads/cinder-abc123")
      assert_receive {:rm_rf, "/downloads/cinder-abc123"}
    end

    test "toggle off -> does not delete the source" do
      stub(Cinder.Library.FilesystemMock, :rm_rf, fn _path ->
        flunk("rm_rf should not be called when move_on_import is off")
      end)

      assert :ok = Download.remove_after_import(:usenet, "nzo-x", "/downloads/cinder-abc123")
    end

    test "torrent protocol never deletes the source (seeding preserved)" do
      enable()

      stub(Cinder.Library.FilesystemMock, :rm_rf, fn _path ->
        flunk("rm_rf should not be called for torrents")
      end)

      assert :ok = Download.remove_after_import(:torrent, "hash-x", "/downloads/movie.mkv")
    end

    test "a missing/already-gone dir does not fail (rm_rf finds nothing)" do
      enable()
      echo_remove(Cinder.Download.SabnzbdClientMock)
      stub(Cinder.Library.FilesystemMock, :rm_rf, fn _path -> {:ok, []} end)

      assert :ok = Download.remove_after_import(:usenet, "nzo-x", "/downloads/cinder-gone")
    end

    test "a real rm_rf error is swallowed; still returns :ok" do
      enable()
      echo_remove(Cinder.Download.SabnzbdClientMock)
      stub(Cinder.Library.FilesystemMock, :rm_rf, fn path -> {:error, :eacces, path} end)

      assert :ok = Download.remove_after_import(:usenet, "nzo-x", "/downloads/cinder-locked")
    end
  end

  describe "movie poller" do
    test "usenet + toggle on → removes the download after import; movie :available" do
      enable()
      movie = usenet_movie(1, "nzo-1")
      drive_to_available(Cinder.Download.SabnzbdClientMock, "nzo-1")
      echo_remove(Cinder.Download.SabnzbdClientMock)
      start_supervised!({Poller, interval: 60_000})

      assert :ok = Poller.poll()
      imported = Repo.get!(Movie, movie.id)
      assert imported.status == :available
      # media_info off + single-file download → the capture columns land as [] (not left nil),
      # proving the poller threads q.audio_languages/embedded_subtitles/sidecar_subtitles through.
      assert imported.imported_audio_languages == []
      assert imported.imported_embedded_subtitles == []
      assert imported.imported_sidecar_subtitles == []
      assert_receive {:removed, "nzo-1", [delete_files: true]}
    end

    test "usenet + toggle on → also deletes the download-side source directly (issue #115)" do
      enable()
      movie = usenet_movie(11, "nzo-11")
      drive_to_available(Cinder.Download.SabnzbdClientMock, "nzo-11")
      echo_remove(Cinder.Download.SabnzbdClientMock)
      echo_rm_rf()
      start_supervised!({Poller, interval: 60_000})

      assert :ok = Poller.poll()
      assert %Movie{status: :available} = Repo.get!(Movie, movie.id)
      # movie.file_path (pre-import content_path) is what gets deleted, never the imported dest.
      assert_receive {:rm_rf, "/downloads/M.mkv"}
      refute_receive {:rm_rf, "/tmp/cinder-test-library/M {tmdb-11}/M {tmdb-11}.mkv"}
    end

    test "an already-gone download-side source doesn't fail the import; movie still :available" do
      enable()
      movie = usenet_movie(12, "nzo-12")
      drive_to_available(Cinder.Download.SabnzbdClientMock, "nzo-12")
      echo_remove(Cinder.Download.SabnzbdClientMock)
      stub(Cinder.Library.FilesystemMock, :rm_rf, fn _path -> {:ok, []} end)
      start_supervised!({Poller, interval: 60_000})

      assert :ok = Poller.poll()
      assert %Movie{status: :available} = Repo.get!(Movie, movie.id)
    end

    test "torrent + toggle on → no remove (seeding preserved)" do
      enable()
      {:ok, movie} = Catalog.add_movie(%{tmdb_id: 2, title: "M"})

      {:ok, movie} =
        Catalog.transition(movie, %{
          status: :downloading,
          download_id: "hash-2",
          download_protocol: :torrent
        })

      drive_to_available(Cinder.Download.ClientMock, "hash-2")
      echo_remove(Cinder.Download.ClientMock)
      start_supervised!({Poller, interval: 60_000})

      assert :ok = Poller.poll()
      assert %Movie{status: :available} = Repo.get!(Movie, movie.id)
      refute_receive {:removed, _, _}
    end

    test "toggle off (default) → no remove; movie still :available" do
      movie = usenet_movie(3, "nzo-3")
      drive_to_available(Cinder.Download.SabnzbdClientMock, "nzo-3")
      echo_remove(Cinder.Download.SabnzbdClientMock)
      start_supervised!({Poller, interval: 60_000})

      assert :ok = Poller.poll()
      assert %Movie{status: :available} = Repo.get!(Movie, movie.id)
      refute_receive {:removed, _, _}
    end

    test "a failed remove leaves the movie :available (no strand, no re-import)" do
      enable()
      movie = usenet_movie(4, "nzo-4")
      drive_to_available(Cinder.Download.SabnzbdClientMock, "nzo-4")
      stub(Cinder.Download.SabnzbdClientMock, :remove, fn _id, _opts -> {:error, :down} end)
      start_supervised!({Poller, interval: 60_000})

      assert :ok = Poller.poll()
      assert %Movie{status: :available} = Repo.get!(Movie, movie.id)
    end
  end

  describe "upgrade path (issue #115)" do
    test "usenet + toggle on → deletes the NEW download's source, never the old library file" do
      movie =
        movie_fixture(%{
          tmdb_id: 13,
          title: "M",
          status: :upgrading,
          download_id: "nzo-up",
          download_protocol: :usenet,
          release_title: "Better.1080p-GRP",
          file_path: "/lib/M (2020)/M (2020).mkv",
          imported_resolution: "720p"
        })

      enable()
      start_supervised!({Poller, interval: 60_000})

      stub(Cinder.Download.SabnzbdClientMock, :status, fn "nzo-up" ->
        {:ok, %{state: :completed, content_path: "/downloads/cinder-up/Better.1080p.mkv"}}
      end)

      stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)

      stub(Cinder.Library.FilesystemMock, :lstat, fn path ->
        if String.contains?(path, [".cinder-rollback-", ".cinder-stage-"]),
          do: {:error, :enoent},
          else: {:ok, %File.Stat{size: 1, inode: 1}}
      end)

      stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
      stub(Cinder.Library.FilesystemMock, :ln, fn _src, _dest -> {:error, :eexist} end)
      stub(Cinder.Library.FilesystemMock, :rm, fn _path -> :ok end)
      stub(Cinder.Library.MediaServerMock, :scan, fn _kind -> :ok end)
      echo_remove(Cinder.Download.SabnzbdClientMock)
      echo_rm_rf()

      assert :ok = Poller.poll()
      assert %Movie{status: :available} = Repo.get!(Movie, movie.id)
      assert_receive {:rm_rf, "/downloads/cinder-up/Better.1080p.mkv"}
      refute_receive {:rm_rf, "/lib/M (2020)/M (2020).mkv"}
    end
  end

  describe "movie poller reject path (issue #119 review — reject leaked the download source)" do
    test "a provable policy mismatch is a discard: deletes its download-side source" do
      enable()
      enable_media_info()
      source = "/downloads/cinder-reject/Anime.Movie.mkv"
      movie = usenet_policy_movie(21, "nzo-reject", source)

      expect(Cinder.Library.FilesystemMock, :dir?, fn ^source -> false end)

      expect(Cinder.Library.MediaInfoMock, :probe_policy, fn ^source ->
        {:ok, %{audio: ["ja"], subtitles: [], audio_unknown?: false, subtitle_unknown?: false}}
      end)

      echo_remove(Cinder.Download.SabnzbdClientMock)
      echo_rm_rf()
      start_supervised!({Poller, interval: 60_000})

      assert :ok = Poller.poll()

      assert %Movie{status: :requested, download_id: nil, release_title: nil} =
               Repo.get!(Movie, movie.id)

      assert_receive {:rm_rf, ^source}
      assert_receive {:removed, "nzo-reject", [delete_files: true]}
    end

    test "an unverdictable probe holds for verification and never deletes the source" do
      enable()
      enable_media_info()
      source = "/downloads/cinder-hold/Anime.Movie.mkv"
      movie = usenet_policy_movie(22, "nzo-hold", source)
      {:ok, movie} = Catalog.transition(movie, %{status: :downloaded, import_attempts: 9})

      expect(Cinder.Library.FilesystemMock, :dir?, fn ^source -> false end)
      expect(Cinder.Library.MediaInfoMock, :probe_policy, fn ^source -> {:error, :timeout} end)

      stub(Cinder.Library.FilesystemMock, :rm_rf, fn _path ->
        flunk("rm_rf should not be called for a verification hold")
      end)

      start_supervised!({Poller, interval: 60_000})
      assert :ok = Poller.poll()

      assert %Movie{status: :import_failed, verification_hold_origin: :download} =
               Repo.get!(Movie, movie.id)
    end
  end

  describe "tv poller" do
    test "usenet grab + toggle on → removes the download exactly once after finish_grab" do
      enable()
      {_series, season} = series_tree()
      e1 = episode(season, 3)
      {:ok, grab} = Catalog.create_grab("nzo-tv", :usenet, [e1.id])

      {:ok, counter} = Agent.start_link(fn -> 0 end)
      parent = self()

      stub(Cinder.Download.SabnzbdClientMock, :status, fn "nzo-tv" ->
        {:ok, %{state: :completed, content_path: "/dl/Show.S01E03.1080p.mkv"}}
      end)

      stub_single_file_import()
      stub_rm_rf()

      stub(Cinder.Download.SabnzbdClientMock, :remove, fn id, opts ->
        Agent.update(counter, &(&1 + 1))
        send(parent, {:removed, id, opts})
        :ok
      end)

      start_supervised!({TvPoller, interval: 60_000})

      assert :ok = TvPoller.poll()
      assert Repo.get(Grab, grab.id) == nil
      assert Repo.get!(Episode, e1.id).file_path =~ "S01E03"
      assert_receive {:removed, "nzo-tv", [delete_files: true]}
      assert Agent.get(counter, & &1) == 1
    end

    test "partial-match pack still removes (don't strand 9 episodes' clutter for 1); deletes the whole per-operation dir" do
      enable()
      {_series, season} = series_tree()
      e1 = episode(season, 1)
      e2 = episode(season, 2)
      {:ok, grab} = Catalog.create_grab("nzo-pack", :usenet, [e1.id, e2.id])
      {:ok, _} = Catalog.mark_grab_downloaded(grab, "/dl/pack")

      stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> true end)

      # Only E01 is present; E02 is unmatched and will re-search.
      stub(Cinder.Library.FilesystemMock, :find_files, fn _ ->
        {:ok, [{"/dl/pack/Show.S01E01.1080p.mkv", 3_000_000_000}]}
      end)

      stub(Cinder.Library.FilesystemMock, :lstat, fn path ->
        if String.contains?(path, ".cinder-stage-") or
             not String.starts_with?(path, "/tmp/cinder-test-tv-library/"),
           do: {:ok, %File.Stat{size: 3_000_000_000, inode: 1, major_device: 1}},
           else: {:error, :enoent}
      end)

      stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
      stub(Cinder.Library.FilesystemMock, :ln, fn _src, _dest -> :ok end)
      stub(Cinder.Library.FilesystemMock, :rename, fn _src, _dest -> :ok end)
      stub(Cinder.Library.FilesystemMock, :rm, fn _path -> :ok end)
      stub(Cinder.Library.MediaServerMock, :scan, fn _kind -> :ok end)
      echo_remove(Cinder.Download.SabnzbdClientMock)
      echo_rm_rf()

      start_supervised!({TvPoller, interval: 60_000})

      assert :ok = TvPoller.poll()
      imported = Repo.get!(Episode, e1.id)
      assert imported.file_path =~ "S01E01"

      # finish_grab's update_all lands the capture columns as [] (not nil), proving it threads them.
      assert imported.imported_audio_languages == []
      assert imported.imported_sidecar_subtitles == []
      assert is_nil(Repo.get!(Episode, e2.id).file_path)
      assert_receive {:removed, "nzo-pack", [delete_files: true]}
      # The whole per-operation/unpack directory is deleted, not just the matched file inside it.
      assert_receive {:rm_rf, "/dl/pack"}
    end

    test "a provable policy mismatch is a discard: deletes its download-side source" do
      enable()
      enable_media_info()
      {_series, season} = series_tree()
      e1 = episode(season, 1)
      source = "/dl/Show.S01E01.1080p.mkv"
      grab = tv_policy_grab(e1, source, "[Group] Show S01E01 [1080p]")

      stub(Cinder.Library.FilesystemMock, :dir?, fn ^source -> false end)

      stub(Cinder.Library.FilesystemMock, :lstat, fn ^source ->
        {:ok,
         %File.Stat{
           type: :regular,
           size: 2_000_000_000,
           major_device: 1,
           inode: 116,
           mtime: {{2026, 7, 13}, {12, 0, 0}}
         }}
      end)

      expect(Cinder.Library.MediaInfoMock, :probe_policy, fn ^source ->
        {:ok, %{audio: ["ja"], subtitles: [], audio_unknown?: false, subtitle_unknown?: false}}
      end)

      echo_remove(Cinder.Download.SabnzbdClientMock)
      echo_rm_rf()
      start_supervised!({TvPoller, interval: 60_000})

      assert :ok = TvPoller.poll()

      refute Repo.get(Grab, grab.id)
      assert Repo.reload!(e1).grab_id == nil

      assert_receive {:rm_rf, ^source}
      assert_receive {:removed, "nzo-tv-reject", [delete_files: true]}
    end
  end
end
