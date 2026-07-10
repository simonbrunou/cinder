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
  setup do
    saved = Application.get_env(:cinder, :move_on_import)

    on_exit(fn ->
      case saved do
        nil -> Application.delete_env(:cinder, :move_on_import)
        v -> Application.put_env(:cinder, :move_on_import, v)
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

  # Echoes the authoritative source deletion (rm_rf of content_path). Returns {:ok, _} like File.rm_rf.
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

    stub_single_file_import()
  end

  defp series_tree do
    series = series_fixture(%{tvdb_id: 99, monitor_strategy: :all})
    season = season_fixture(series)
    {series, season}
  end

  defp episode(season, ep_num) do
    episode_fixture(season, %{episode_number: ep_num})
  end

  describe "Download.remove_after_import/3 (the gate)" do
    test "usenet + toggle on: drops the client job AND deletes the source directly" do
      enable()
      echo_remove(Cinder.Download.SabnzbdClientMock)
      echo_rm_rf()

      assert :ok = Download.remove_after_import(:usenet, "nzo-x", "/downloads/complete/M")
      assert_receive {:removed, "nzo-x", opts}
      assert opts[:delete_files] == true

      # The authoritative cleanup: content_path is rm_rf'd regardless of the client's history state.
      assert_receive {:rm_rf, "/downloads/complete/M"}
    end

    test "is a no-op when the toggle is off" do
      echo_remove(Cinder.Download.SabnzbdClientMock)
      echo_rm_rf()
      assert :ok = Download.remove_after_import(:usenet, "nzo-x", "/downloads/complete/M")
      refute_receive {:removed, _, _}
      refute_receive {:rm_rf, _}
    end

    test "is a no-op for torrents and unknown/nil protocol (seeding + fail-safe)" do
      enable()
      echo_remove(Cinder.Download.SabnzbdClientMock)
      echo_remove(Cinder.Download.ClientMock)
      echo_rm_rf()

      assert :ok = Download.remove_after_import(:torrent, "hash-x", "/dl/x")
      assert :ok = Download.remove_after_import(nil, "x", "/dl/x")
      refute_receive {:removed, _, _}
      refute_receive {:rm_rf, _}
    end

    test "usenet with a blank/nil id: skips the client remove but STILL deletes the source" do
      # The whole point of #81: the source cleanup must not depend on the client remembering the job.
      enable()
      echo_remove(Cinder.Download.SabnzbdClientMock)
      echo_rm_rf()

      assert :ok = Download.remove_after_import(:usenet, nil, "/dl/M")
      assert :ok = Download.remove_after_import(:usenet, "", "/dl/M2")
      refute_receive {:removed, _, _}
      assert_receive {:rm_rf, "/dl/M"}
      assert_receive {:rm_rf, "/dl/M2"}
    end

    test "never rm_rf a blank, root, or relative content_path (data-loss guard)" do
      enable()
      # id present, so the client remove still fires each call — but rm_rf must not.
      echo_remove(Cinder.Download.SabnzbdClientMock)
      echo_rm_rf()

      for bad <- [nil, "", "/", ".", "relative/path"] do
        assert :ok = Download.remove_after_import(:usenet, "nzo", bad)
      end

      refute_receive {:rm_rf, _}
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

    test "a failing source delete (rm_rf error or raise) is swallowed; still :ok" do
      enable()
      echo_remove(Cinder.Download.SabnzbdClientMock)
      stub(Cinder.Library.FilesystemMock, :rm_rf, fn _ -> {:error, :eacces, "/dl/M"} end)
      assert :ok = Download.remove_after_import(:usenet, "nzo-x", "/dl/M")

      stub(Cinder.Library.FilesystemMock, :rm_rf, fn _ -> raise "fs down" end)
      assert :ok = Download.remove_after_import(:usenet, "nzo-x", "/dl/M")
    end
  end

  describe "movie poller" do
    test "usenet + toggle on → removes the download after import; movie :available" do
      enable()
      movie = usenet_movie(1, "nzo-1")
      drive_to_available(Cinder.Download.SabnzbdClientMock, "nzo-1")
      echo_remove(Cinder.Download.SabnzbdClientMock)
      echo_rm_rf()
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

      # The pre-import content_path (SAB's completed folder) is deleted directly — the poller passes
      # movie.file_path (still the source at this point) as content_path.
      assert_receive {:rm_rf, "/downloads/M.mkv"}
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
      echo_rm_rf()
      start_supervised!({Poller, interval: 60_000})

      assert :ok = Poller.poll()
      assert %Movie{status: :available} = Repo.get!(Movie, movie.id)
      refute_receive {:removed, _, _}
      # Torrents are never touched — no client remove and no source deletion (seeding survives).
      refute_receive {:rm_rf, _}
    end

    test "toggle off (default) → no remove; movie still :available" do
      movie = usenet_movie(3, "nzo-3")
      drive_to_available(Cinder.Download.SabnzbdClientMock, "nzo-3")
      echo_remove(Cinder.Download.SabnzbdClientMock)
      echo_rm_rf()
      start_supervised!({Poller, interval: 60_000})

      assert :ok = Poller.poll()
      assert %Movie{status: :available} = Repo.get!(Movie, movie.id)
      refute_receive {:removed, _, _}
      refute_receive {:rm_rf, _}
    end

    test "a failed remove (client AND source delete) leaves the movie :available (no strand)" do
      enable()
      movie = usenet_movie(4, "nzo-4")
      drive_to_available(Cinder.Download.SabnzbdClientMock, "nzo-4")
      stub(Cinder.Download.SabnzbdClientMock, :remove, fn _id, _opts -> {:error, :down} end)

      stub(Cinder.Library.FilesystemMock, :rm_rf, fn _ ->
        {:error, :eacces, "/downloads/M.mkv"}
      end)

      start_supervised!({Poller, interval: 60_000})

      assert :ok = Poller.poll()
      assert %Movie{status: :available} = Repo.get!(Movie, movie.id)
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

      stub(Cinder.Download.SabnzbdClientMock, :remove, fn id, opts ->
        Agent.update(counter, &(&1 + 1))
        send(parent, {:removed, id, opts})
        :ok
      end)

      echo_rm_rf()

      start_supervised!({TvPoller, interval: 60_000})

      assert :ok = TvPoller.poll()
      assert Repo.get(Grab, grab.id) == nil
      assert Repo.get!(Episode, e1.id).file_path =~ "S01E03"
      assert_receive {:removed, "nzo-tv", [delete_files: true]}
      # The grab's content_path (the downloaded pack/file) is deleted directly.
      assert_receive {:rm_rf, "/dl/Show.S01E03.1080p.mkv"}
      assert Agent.get(counter, & &1) == 1
    end

    test "partial-match pack still removes (don't strand 9 episodes' clutter for 1)" do
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

      stub(Cinder.Library.FilesystemMock, :lstat, fn _ ->
        {:ok, %File.Stat{size: 3_000_000_000, inode: 1}}
      end)

      stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
      stub(Cinder.Library.FilesystemMock, :ln, fn _src, _dest -> :ok end)
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
      # The whole pack folder is removed once, even for a partial match.
      assert_receive {:rm_rf, "/dl/pack"}
    end
  end
end
