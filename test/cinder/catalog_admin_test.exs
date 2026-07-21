defmodule Cinder.CatalogAdminTest do
  # async: false — sibling tasks in this file exercise Repo.transaction (cancel/delete);
  # the single-connection SQLite Sandbox needs shared mode for nested transactions.
  use Cinder.DataCase, async: false

  import Mox
  import ExUnit.CaptureLog

  alias Cinder.Catalog
  alias Cinder.Catalog.{Movie, Series}
  alias Cinder.Requests.Request

  import Cinder.CatalogFixtures

  describe "update_movie/2" do
    test "edits metadata via Movie.changeset, leaving status untouched" do
      movie = movie_fixture(%{title: "Old", year: 2009})

      assert {:ok, %Movie{} = updated} =
               Catalog.update_movie(movie, %{title: "Inception", year: 2010})

      assert updated.title == "Inception"
      assert updated.year == 2010
      # status is not castable on Movie.changeset/2, so it stays put.
      assert updated.status == movie.status
      assert Repo.get!(Movie, movie.id).title == "Inception"
    end

    test "a status key in attrs is ignored (status stays in transition)" do
      movie = movie_fixture()
      assert {:ok, updated} = Catalog.update_movie(movie, %{title: "X", status: :available})
      assert updated.status == :requested
    end

    test "returns {:error, changeset} on a blank required title" do
      movie = movie_fixture()
      assert {:error, %Ecto.Changeset{}} = Catalog.update_movie(movie, %{title: ""})
    end

    test "broadcasts {:movie_updated, movie} so other sessions refresh" do
      movie = movie_fixture(%{title: "Old"})
      Catalog.subscribe()

      assert {:ok, updated} = Catalog.update_movie(movie, %{title: "New"})
      assert_receive {:movie_updated, %Movie{id: id, title: "New"}}
      assert id == updated.id
    end
  end

  describe "update_series/2" do
    setup do
      series =
        Repo.insert!(%Series{
          tmdb_id: System.unique_integer([:positive]),
          title: "Show",
          year: 2008,
          monitored: true,
          monitor_strategy: :none
        })

      season =
        Repo.insert!(%Cinder.Catalog.Season{
          series_id: series.id,
          season_number: 1,
          monitored: true
        })

      {:ok, series: series, season: season}
    end

    test "edits descriptive fields", %{series: series} do
      assert {:ok, %Series{} = updated} =
               Catalog.update_series(series, %{title: "New Title", year: 2009})

      assert updated.title == "New Title"
      assert updated.year == 2009
      assert Repo.get!(Series, series.id).title == "New Title"
    end

    test "does NOT cascade monitor_strategy to existing seasons/episodes", %{
      series: series,
      season: season
    } do
      assert {:ok, updated} = Catalog.update_series(series, %{monitor_strategy: :all, title: "Z"})
      # monitor_strategy is not castable on admin_changeset → preserved.
      assert updated.monitor_strategy == :none
      # the request flow's per-season monitored: true is not clobbered.
      assert Repo.get!(Cinder.Catalog.Season, season.id).monitored == true
    end

    test "returns {:error, changeset} on a blank title", %{series: series} do
      assert {:error, %Ecto.Changeset{}} = Catalog.update_series(series, %{title: ""})
    end

    test "broadcasts {:series_updated, id} so other sessions refresh", %{series: series} do
      Catalog.subscribe_series()
      sid = series.id

      assert {:ok, _updated} = Catalog.update_series(series, %{title: "Broadcast"})
      assert_receive {:series_updated, ^sid}
    end
  end

  describe "cancel_movie/2" do
    setup :verify_on_exit!

    test "an active movie with a download is cancelled and the client download removed" do
      actor = Cinder.AccountsFixtures.admin_fixture()

      movie =
        movie_fixture()
        |> then(
          &elem(
            Catalog.transition(&1, %{
              status: :downloading,
              download_id: "HASH-1",
              download_protocol: :torrent
            }),
            1
          )
        )

      expect(Cinder.Download.ClientMock, :remove, fn "HASH-1", opts ->
        assert Keyword.fetch!(opts, :delete_files) == true
        :ok
      end)

      assert {:ok, %Movie{status: :cancelled}} = Catalog.cancel_movie(movie, actor)
      assert Repo.get!(Movie, movie.id).status == :cancelled
    end

    test "a requested movie with no download is cancelled without touching the client" do
      actor = Cinder.AccountsFixtures.admin_fixture()
      movie = movie_fixture()
      # No expect/0 on the client → if cancel_movie called it, verify_on_exit! would fail.
      assert {:ok, %Movie{status: :cancelled}} = Catalog.cancel_movie(movie, actor)
    end

    test "a non-cancellable (terminal/available) movie returns {:error, :not_cancellable}" do
      actor = Cinder.AccountsFixtures.admin_fixture()
      movie = movie_fixture() |> then(&elem(Catalog.transition(&1, %{status: :available}), 1))
      assert {:error, :not_cancellable} = Catalog.cancel_movie(movie, actor)
      assert Repo.get!(Movie, movie.id).status == :available
    end

    test "writes an admin_audit row for the cancel (in-txn)" do
      actor = Cinder.AccountsFixtures.admin_fixture()
      movie = movie_fixture()
      assert {:ok, _} = Catalog.cancel_movie(movie, actor)

      audit = Repo.one!(Cinder.Audit.AdminAudit)
      assert audit.action == "cancel_movie"
      assert audit.entity_type == "Movie"
      assert audit.entity_id == movie.id
      assert audit.actor_id == actor.id
    end

    test "client remove failure does NOT block the cancel (best-effort)" do
      actor = Cinder.AccountsFixtures.admin_fixture()

      movie =
        movie_fixture()
        |> then(
          &elem(
            Catalog.transition(&1, %{
              status: :downloading,
              download_id: "HASH-DOWN",
              download_protocol: :torrent
            }),
            1
          )
        )

      # Client is down — cancel must still succeed and clear the movie.
      expect(Cinder.Download.ClientMock, :remove, fn "HASH-DOWN", _opts -> {:error, :down} end)

      assert {:ok, %Movie{status: :cancelled}} = Catalog.cancel_movie(movie, actor)
      assert Repo.get!(Movie, movie.id).status == :cancelled
    end

    test "a held normal policy verification cancel fences cleanup before clearing ownership" do
      actor = Cinder.AccountsFixtures.admin_fixture()
      movie = verification_held_movie(:download)

      expect(Cinder.Download.ClientMock, :remove, fn "HASH-HELD-download", _opts ->
        {:error, :down}
      end)

      assert {:ok, cancelled} = Catalog.cancel_movie(movie, actor)
      assert cancelled.status == :cancelled
      assert cancelled.download_id == nil
      assert cancelled.release_title == nil
      assert cancelled.release_policy_snapshot == nil
      assert cancelled.verification_hold_origin == nil
      assert cancelled.file_path == nil
      assert cancelled.content_path == nil

      assert Repo.get_by!(Cinder.Download.Intent,
               kind: :movie,
               target_id: movie.id
             ).status == :cleanup_pending
    end

    test "a held upgrade cancel fences cleanup and preserves the live library file" do
      movie = verification_held_movie(:upgrade)

      expect(Cinder.Download.ClientMock, :remove, fn "HASH-HELD-upgrade", _opts ->
        {:error, :down}
      end)

      assert {:ok, available} = Catalog.abort_upgrade(movie, nil)
      assert available.status == :available
      assert available.download_id == nil
      assert available.release_title == nil
      assert available.release_policy_snapshot == nil
      assert available.verification_hold_origin == nil
      assert available.file_path == "/library/Anime Movie.mkv"
      assert available.imported_resolution == "720p"
      assert available.imported_size == 1_234

      assert Repo.get_by!(Cinder.Download.Intent,
               kind: :movie,
               target_id: movie.id
             ).status == :cleanup_pending
    end

    test "a held cancel rejects a stale release snapshot without clearing the current hold" do
      actor = Cinder.AccountsFixtures.admin_fixture()
      stale = verification_held_movie(:download)

      assert {:ok, current} =
               Catalog.transition(stale, %{status: :import_failed, release_title: "Concurrent"},
                 expect: :import_failed
               )

      assert {:error, :stale_status} = Catalog.cancel_movie(stale, actor)
      assert Repo.reload!(current).release_title == "Concurrent"
      assert Repo.reload!(current).download_id == "HASH-HELD-download"
      assert Repo.reload!(current).verification_hold_origin == :download
    end
  end

  describe "download metrics" do
    test "direct cancel clears metrics" do
      movie = movie_fixture(%{status: :downloading})

      assert {:ok, movie} =
               Catalog.update_movie_download_metrics(movie, %{
                 download_progress: 0.42,
                 download_speed: 1_500_000,
                 download_eta: 90
               })

      assert {:ok, updated} = Catalog.cancel_movie(movie, Cinder.AccountsFixtures.admin_fixture())
      assert %{download_progress: nil, download_speed: nil, download_eta: nil} = updated
    end

    test "direct abort-upgrade clears metrics" do
      movie = movie_fixture(%{status: :upgrading})

      assert {:ok, movie} =
               Catalog.update_movie_download_metrics(movie, %{
                 download_progress: 0.42,
                 download_speed: 1_500_000,
                 download_eta: 90
               })

      assert {:ok, updated} = Catalog.abort_upgrade(movie, nil)
      assert %{download_progress: nil, download_speed: nil, download_eta: nil} = updated
    end

    test "a grab metric write broadcasts its series" do
      series = series_fixture()
      season = season_fixture(series)
      episode = episode_fixture(season)
      {:ok, grab} = Catalog.create_grab("METRICS-1", :torrent, [episode.id])
      series_id = series.id
      Catalog.subscribe_series()
      metrics = %{download_progress: 0.42, download_speed: 1_500_000, download_eta: 90}

      assert {:ok, updated} = Catalog.update_grab_download_metrics(grab, metrics)
      assert %{download_progress: 0.42, download_speed: 1_500_000, download_eta: 90} = updated
      assert_receive {:series_updated, ^series_id}
    end

    test "completion clears grab metrics and rejects a late metric write" do
      series = series_fixture()
      season = season_fixture(series)
      episode = episode_fixture(season)
      {:ok, grab} = Catalog.create_grab("METRICS-2", :torrent, [episode.id])
      metrics = %{download_progress: 0.42, download_speed: 1_500_000, download_eta: 90}

      assert {:ok, tracked} = Catalog.update_grab_download_metrics(grab, metrics)
      assert {:ok, completed} = Catalog.mark_grab_downloaded(tracked, "/downloads/pack")
      assert %{download_progress: nil, download_speed: nil, download_eta: nil} = completed

      assert {:error, :stale_grab} =
               Catalog.update_grab_download_metrics(tracked, %{
                 download_progress: 0.43,
                 download_speed: 1_600_000,
                 download_eta: 80
               })
    end

    test "completion rejects a stale equal grab metric snapshot" do
      series = series_fixture()
      season = season_fixture(series)
      episode = episode_fixture(season)
      {:ok, grab} = Catalog.create_grab("METRICS-4", :torrent, [episode.id])
      metrics = %{download_progress: 0.42, download_speed: 1_500_000, download_eta: 90}

      assert {:ok, tracked} = Catalog.update_grab_download_metrics(grab, metrics)
      assert {:ok, _} = Catalog.mark_grab_downloaded(tracked, "/downloads/pack")
      assert {:error, :stale_grab} = Catalog.update_grab_download_metrics(tracked, metrics)
    end

    test "a grab retry clears metrics" do
      series = series_fixture()
      season = season_fixture(series)
      episode = episode_fixture(season)
      {:ok, grab} = Catalog.create_grab("METRICS-3", :torrent, [episode.id])

      assert {:ok, tracked} =
               Catalog.update_grab_download_metrics(grab, %{
                 download_progress: 0.42,
                 download_speed: 1_500_000,
                 download_eta: 90
               })

      assert :ok = Catalog.increment_grab_attempts(tracked)

      assert %{download_progress: nil, download_speed: nil, download_eta: nil} =
               Repo.get!(Cinder.Catalog.Grab, tracked.id)
    end
  end

  describe "delete_movie/2" do
    setup :verify_on_exit!

    test "deletes an idle movie and broadcasts {:movie_deleted, id}" do
      actor = Cinder.AccountsFixtures.admin_fixture()
      movie = movie_fixture() |> then(&elem(Catalog.transition(&1, %{status: :available}), 1))
      id = movie.id
      Catalog.subscribe()

      assert {:ok, %Movie{}} = Catalog.delete_movie(movie, actor)
      assert_receive {:movie_deleted, ^id}
      assert Repo.get(Movie, id) == nil
    end

    test "an active movie with a download is cancelled (client-removed) before delete" do
      actor = Cinder.AccountsFixtures.admin_fixture()

      movie =
        movie_fixture()
        |> then(
          &elem(
            Catalog.transition(&1, %{
              status: :downloading,
              download_id: "HASH-2",
              download_protocol: :usenet
            }),
            1
          )
        )

      # usenet → SabnzbdClientMock.
      expect(Cinder.Download.SabnzbdClientMock, :remove, fn "HASH-2", _opts -> :ok end)

      id = movie.id
      assert {:ok, %Movie{}} = Catalog.delete_movie(movie, actor)
      assert Repo.get(Movie, id) == nil
    end

    test "a download attached after the caller snapshot is fenced and removed" do
      actor = Cinder.AccountsFixtures.admin_fixture()
      stale = movie_fixture(%{status: :available})

      assert {:ok, %Movie{status: :upgrading}} =
               Catalog.transition(
                 stale,
                 %{
                   status: :upgrading,
                   download_id: "HASH-LATE-ATTACH",
                   download_protocol: :torrent,
                   release_title: "Movie.Upgrade"
                 },
                 expect: :available
               )

      expect(Cinder.Download.ClientMock, :remove, fn "HASH-LATE-ATTACH", _opts -> :ok end)

      assert {:ok, %Movie{}} = Catalog.delete_movie(stale, actor)
      refute Repo.get(Movie, stale.id)

      refute Repo.get_by(Cinder.Download.Intent,
               kind: :movie,
               target_id: stale.id
             )
    end

    test "writes an admin_audit row for the delete" do
      actor = Cinder.AccountsFixtures.admin_fixture()
      movie = movie_fixture()
      assert {:ok, _} = Catalog.delete_movie(movie, actor)
      assert Repo.one!(Cinder.Audit.AdminAudit).action == "delete_movie"
    end

    test "client remove failure does NOT block the delete (best-effort)" do
      actor = Cinder.AccountsFixtures.admin_fixture()

      movie =
        movie_fixture()
        |> then(
          &elem(
            Catalog.transition(&1, %{
              status: :downloading,
              download_id: "HASH-DEL",
              download_protocol: :torrent
            }),
            1
          )
        )

      expect(Cinder.Download.ClientMock, :remove, fn "HASH-DEL", _opts -> {:error, :down} end)

      id = movie.id
      assert {:ok, %Movie{}} = Catalog.delete_movie(movie, actor)
      assert Repo.get(Movie, id) == nil
    end

    test "deleting a held upgrade leaves the live file and preserves failed remote cleanup" do
      movie = verification_held_movie(:upgrade)

      expect(Cinder.Download.ClientMock, :remove, fn "HASH-HELD-upgrade", _opts ->
        {:error, :down}
      end)

      assert {:ok, _deleted} = Catalog.delete_movie(movie, nil)
      refute Repo.get(Movie, movie.id)

      assert Repo.get_by!(Cinder.Download.Intent,
               kind: :movie,
               target_id: movie.id
             ).status == :cleanup_pending
    end

    test "held Retry rejects a stale snapshot without clearing preserved ownership" do
      stale = verification_held_movie(:download)

      assert {:ok, current} =
               Catalog.transition(stale, %{status: :import_failed, release_title: "Concurrent"},
                 expect: :import_failed
               )

      assert {:error, :stale_status} = Catalog.retry_movie(stale)
      assert Repo.reload!(current).download_id == "HASH-HELD-download"
      assert Repo.reload!(current).verification_hold_origin == :download
    end

    test "deleting an already-deleted movie returns {:error, :stale_entry} (no raise)" do
      actor = Cinder.AccountsFixtures.admin_fixture()
      movie = movie_fixture() |> then(&elem(Catalog.transition(&1, %{status: :available}), 1))
      # Another session already deleted the row.
      Repo.delete!(movie)

      assert {:error, :stale_entry} = Catalog.delete_movie(movie, actor)
    end

    test "delete_files: true unlinks the file, then deletes the row" do
      movie = movie_fixture(%{title: "Inception", year: 2010})

      {:ok, movie} =
        movie
        |> Ecto.Changeset.change(
          status: :available,
          file_path: "/tmp/cinder-test-library/Inception (2010)/Inception (2010).mkv"
        )
        |> Repo.update()

      expect(
        Cinder.Library.FilesystemMock,
        :rm,
        fn "/tmp/cinder-test-library/Inception (2010)/Inception (2010).mkv" -> :ok end
      )

      stub(Cinder.Library.FilesystemMock, :rmdir, fn _ -> {:error, :enotempty} end)

      assert {:ok, _} = Catalog.delete_movie(movie, nil, delete_files: true)
      refute Repo.get(Movie, movie.id)
    end

    test "without delete_files the file is left on disk (no FS calls)" do
      movie = movie_fixture(%{title: "Inception", year: 2010})

      {:ok, movie} =
        movie
        |> Ecto.Changeset.change(status: :available, file_path: "/tmp/x.mkv")
        |> Repo.update()

      # No FS expectations: verify_on_exit! fails if delete_file is reached.
      assert {:ok, _} = Catalog.delete_movie(movie, nil)
      refute Repo.get(Movie, movie.id)
    end

    test "delete_files: true still deletes the row when the unlink fails (best-effort)" do
      movie = movie_fixture(%{title: "Inception", year: 2010})

      {:ok, movie} =
        movie
        |> Ecto.Changeset.change(status: :available, file_path: "/tmp/locked.mkv")
        |> Repo.update()

      expect(Cinder.Library.FilesystemMock, :rm, fn _ -> {:error, :eacces} end)

      log =
        capture_log(fn ->
          assert {:ok, _} = Catalog.delete_movie(movie, nil, delete_files: true)
        end)

      assert log =~ ~s(library file delete failed for "/tmp/locked.mkv": :eacces)
      refute Repo.get(Movie, movie.id)
    end

    test "delete_files: true with no file_path makes no FS call" do
      movie = movie_fixture()
      assert {:ok, _} = Catalog.delete_movie(movie, nil, delete_files: true)
      refute Repo.get(Movie, movie.id)
    end
  end

  describe "cancel_series/2 and delete_series/2" do
    setup :verify_on_exit!

    alias Cinder.Catalog.{Episode, Grab, Season, Series}

    defp series_tree do
      series = series_fixture(%{monitor_strategy: :all})
      season = season_fixture(series)
      ep = episode_fixture(season, %{episode_number: 1})
      {series, season, ep}
    end

    test "cancel_series reaps all grabs (incl :downloaded), removes downloads, unmonitors" do
      actor = Cinder.AccountsFixtures.admin_fixture()
      {series, season, ep} = series_tree()

      # A downloading grab and a downloaded (content_path set) grab — both must be reaped.
      {:ok, _dl} = Catalog.create_grab("HASH-A", :torrent, [ep.id])

      ep2 =
        Repo.insert!(%Episode{
          season_id: season.id,
          episode_number: 2,
          monitored: true,
          air_date: ~D[2001-01-08]
        })

      {:ok, done} = Catalog.create_grab("HASH-B", :usenet, [ep2.id])
      {:ok, _} = Catalog.mark_grab_downloaded(done, "/downloads/pack")

      expect(Cinder.Download.ClientMock, :remove, fn "HASH-A", _opts -> :ok end)
      expect(Cinder.Download.SabnzbdClientMock, :remove, fn "HASH-B", _opts -> :ok end)

      sid = series.id
      Catalog.subscribe_series()

      assert {:ok, %Series{}} = Catalog.cancel_series(series, actor)
      assert_receive {:series_updated, ^sid}

      # Both grabs gone.
      assert Repo.all(Grab) == []
      # Season + episodes unmonitored so wanted_episodes won't re-grab.
      assert Repo.get!(Season, season.id).monitored == false
      assert Repo.get!(Episode, ep.id).monitored == false
      assert Repo.get!(Episode, ep2.id).monitored == false
      # The series itself survives a cancel.
      assert Repo.get(Series, sid)
    end

    test "cancel_series stops re-grab: wanted_episodes returns nothing afterward" do
      actor = Cinder.AccountsFixtures.admin_fixture()
      {series, _season, _ep} = series_tree()
      # Before: the aired, monitored, file-less, grab-less episode is wanted.
      assert series.id in Enum.map(Catalog.wanted_episodes(), & &1.season.series_id)

      assert {:ok, _} = Catalog.cancel_series(series, actor)
      refute series.id in Enum.map(Catalog.wanted_episodes(), & &1.season.series_id)
    end

    test "cancel_series writes an admin_audit row" do
      actor = Cinder.AccountsFixtures.admin_fixture()
      {series, _season, _ep} = series_tree()
      assert {:ok, _} = Catalog.cancel_series(series, actor)
      audit = Repo.one!(Cinder.Audit.AdminAudit)
      assert audit.action == "cancel_series"
      assert audit.entity_type == "Series"
      assert audit.entity_id == series.id
    end

    test "cancel_series leaves an atomic post-state: episodes unmonitored, grab_id nil, no grabs" do
      actor = Cinder.AccountsFixtures.admin_fixture()
      {series, season, ep} = series_tree()
      {:ok, _} = Catalog.create_grab("HASH-ATOM", :torrent, [ep.id])
      # Sanity: the grab linked the episode.
      assert Repo.get!(Episode, ep.id).grab_id

      expect(Cinder.Download.ClientMock, :remove, fn "HASH-ATOM", _opts -> :ok end)

      assert {:ok, _} = Catalog.cancel_series(series, actor)

      reaped_ep = Repo.get!(Episode, ep.id)
      assert reaped_ep.monitored == false
      assert reaped_ep.grab_id == nil
      assert Repo.get!(Season, season.id).monitored == false
      assert Repo.all(Grab) == []
    end

    test "cancel_series: client remove failure does NOT block the cancel (best-effort)" do
      actor = Cinder.AccountsFixtures.admin_fixture()
      {series, season, ep} = series_tree()
      {:ok, _} = Catalog.create_grab("HASH-CDOWN", :torrent, [ep.id])

      expect(Cinder.Download.ClientMock, :remove, fn "HASH-CDOWN", _opts -> {:error, :down} end)

      assert {:ok, %Series{}} = Catalog.cancel_series(series, actor)
      # Reaped + unmonitored despite the client being down.
      assert Repo.all(Grab) == []
      assert Repo.get!(Season, season.id).monitored == false
      assert Repo.get!(Episode, ep.id).monitored == false
    end

    test "delete_series reaps grabs first, then cascades seasons/episodes, broadcasts deleted" do
      actor = Cinder.AccountsFixtures.admin_fixture()
      {series, season, ep} = series_tree()
      {:ok, _grab} = Catalog.create_grab("HASH-C", :torrent, [ep.id])

      expect(Cinder.Download.ClientMock, :remove, fn "HASH-C", _opts -> :ok end)

      sid = series.id
      Catalog.subscribe_series()

      assert {:ok, %Series{}} = Catalog.delete_series(series, actor)
      assert_receive {:series_deleted, ^sid}

      assert Repo.get(Series, sid) == nil
      assert Repo.get(Season, season.id) == nil
      assert Repo.get(Episode, ep.id) == nil
      assert Repo.all(Grab) == []
    end

    test "delete_series writes an admin_audit row" do
      actor = Cinder.AccountsFixtures.admin_fixture()
      {series, _season, _ep} = series_tree()
      assert {:ok, _} = Catalog.delete_series(series, actor)
      assert Repo.one!(Cinder.Audit.AdminAudit).action == "delete_series"
    end

    test "delete_series: client remove failure does NOT block the delete (best-effort)" do
      actor = Cinder.AccountsFixtures.admin_fixture()
      {series, _season, ep} = series_tree()
      {:ok, _} = Catalog.create_grab("HASH-DDOWN", :torrent, [ep.id])

      expect(Cinder.Download.ClientMock, :remove, fn "HASH-DDOWN", _opts -> {:error, :down} end)

      sid = series.id
      assert {:ok, %Series{}} = Catalog.delete_series(series, actor)
      assert Repo.get(Series, sid) == nil
      assert Repo.all(Grab) == []
    end

    test "delete_series reaps an in-flight AND a downloaded-not-yet-imported grab, removing both" do
      actor = Cinder.AccountsFixtures.admin_fixture()
      {series, season, ep} = series_tree()

      ep2 =
        Repo.insert!(%Episode{
          season_id: season.id,
          episode_number: 2,
          monitored: true,
          air_date: ~D[2001-01-08]
        })

      {:ok, _downloading} = Catalog.create_grab("HASH-INFLIGHT", :torrent, [ep.id])
      {:ok, downloaded} = Catalog.create_grab("HASH-DONE", :usenet, [ep2.id])
      {:ok, _} = Catalog.mark_grab_downloaded(downloaded, "/downloads/pack")

      expect(Cinder.Download.ClientMock, :remove, fn "HASH-INFLIGHT", _opts -> :ok end)
      expect(Cinder.Download.SabnzbdClientMock, :remove, fn "HASH-DONE", _opts -> :ok end)

      sid = series.id
      Catalog.subscribe_series()

      assert {:ok, %Series{}} = Catalog.delete_series(series, actor)
      assert_receive {:series_deleted, ^sid}

      assert Repo.get(Series, sid) == nil
      assert Repo.all(Grab) == []
    end

    test "deleting an already-deleted series returns {:error, :stale_entry} (no raise)" do
      actor = Cinder.AccountsFixtures.admin_fixture()
      {series, _season, _ep} = series_tree()
      # Another session already deleted the row (cascades the tree).
      Repo.delete!(series)

      assert {:error, :stale_entry} = Catalog.delete_series(series, actor)
    end

    test "delete_files: true unlinks every episode file, then cascades the tree" do
      series =
        series_with_episode_file!(
          file_path: "/tmp/cinder-test-tv-library/Show (2010)/Season 01/Show (2010) - S01E01.mkv"
        )

      expect(
        Cinder.Library.FilesystemMock,
        :rm,
        fn "/tmp/cinder-test-tv-library/Show (2010)/Season 01/Show (2010) - S01E01.mkv" -> :ok end
      )

      stub(Cinder.Library.FilesystemMock, :rmdir, fn _ -> {:error, :enotempty} end)

      assert {:ok, _} = Catalog.delete_series(series, nil, delete_files: true)
      refute Repo.get(Series, series.id)
    end

    test "without delete_files the episode files are left (no FS calls)" do
      series = series_with_episode_file!(file_path: "/tmp/show.mkv")
      assert {:ok, _} = Catalog.delete_series(series, nil)
      refute Repo.get(Series, series.id)
    end

    defp series_with_episode_file!(file_path: path) do
      series =
        Repo.insert!(%Series{
          tmdb_id: System.unique_integer([:positive]),
          title: "Show",
          year: 2010
        })

      season = Repo.insert!(%Cinder.Catalog.Season{series_id: series.id, season_number: 1})

      Repo.insert!(%Cinder.Catalog.Episode{
        season_id: season.id,
        episode_number: 1,
        file_path: path
      })

      series
    end
  end

  describe "delete reaps orphaned :approved requests" do
    # A movie/series delete cascades every FK child, but `requests` is a polymorphic soft link
    # (target_id = tmdb_id, no FK), so its :approved rows would orphan and strand the requester on
    # a stale "Approved" badge. Catalog.delete_* reaps them in-transaction; pending/denied survive.
    defp request!(attrs) do
      user = attrs[:user] || Cinder.AccountsFixtures.user_fixture()

      Repo.insert!(%Request{
        user_id: user.id,
        target_type: Map.fetch!(attrs, :target_type),
        target_id: Map.fetch!(attrs, :target_id),
        season_number: attrs[:season_number],
        status: Map.get(attrs, :status, :approved),
        title: "T"
      })
    end

    test "delete_movie reaps the approved movie request, leaving pending, denied, and other titles" do
      actor = Cinder.AccountsFixtures.admin_fixture()
      movie = movie_fixture()

      approved = request!(%{target_type: "movie", target_id: movie.tmdb_id, status: :approved})
      pending = request!(%{target_type: "movie", target_id: movie.tmdb_id, status: :pending})
      denied = request!(%{target_type: "movie", target_id: movie.tmdb_id, status: :denied})
      # A different title's approved request must not be reaped (target_id scoping).
      other = request!(%{target_type: "movie", target_id: movie.tmdb_id + 1, status: :approved})

      assert {:ok, _} = Catalog.delete_movie(movie, actor)

      refute Repo.get(Request, approved.id)
      assert Repo.get(Request, pending.id)
      assert Repo.get(Request, denied.id)
      assert Repo.get(Request, other.id)
    end

    test "delete_movie reaps every approved request for the title (N requesters)" do
      actor = Cinder.AccountsFixtures.admin_fixture()
      movie = movie_fixture()
      a = request!(%{target_type: "movie", target_id: movie.tmdb_id, status: :approved})
      b = request!(%{target_type: "movie", target_id: movie.tmdb_id, status: :approved})

      assert {:ok, _} = Catalog.delete_movie(movie, actor)
      refute Repo.get(Request, a.id)
      refute Repo.get(Request, b.id)
    end

    test "a pending request survives the delete and creates no :requested movie (approval gate)" do
      actor = Cinder.AccountsFixtures.admin_fixture()
      movie = movie_fixture()
      pending = request!(%{target_type: "movie", target_id: movie.tmdb_id, status: :pending})

      assert {:ok, _} = Catalog.delete_movie(movie, actor)

      # The un-adjudicated ask survives untouched...
      assert Repo.get!(Request, pending.id).status == :pending
      # ...and no movie exists for the title until an admin approves (the gate is intact).
      assert Catalog.get_movie_by_tmdb_id(movie.tmdb_id) == nil
    end

    test "delete_series reaps approved series- AND season-scoped requests, leaving pending" do
      actor = Cinder.AccountsFixtures.admin_fixture()
      series = series_fixture()

      series_req =
        request!(%{target_type: "series", target_id: series.tmdb_id, status: :approved})

      season_req =
        request!(%{
          target_type: "season",
          target_id: series.tmdb_id,
          season_number: 1,
          status: :approved
        })

      pending_season =
        request!(%{
          target_type: "season",
          target_id: series.tmdb_id,
          season_number: 2,
          status: :pending
        })

      assert {:ok, _} = Catalog.delete_series(series, actor)

      refute Repo.get(Request, series_req.id)
      refute Repo.get(Request, season_req.id)
      assert Repo.get(Request, pending_season.id)
    end
  end

  describe "list_grabs/0" do
    test "lists all grabs newest-first with episode→season→series preloaded" do
      series =
        Repo.insert!(%Cinder.Catalog.Series{
          tmdb_id: System.unique_integer([:positive]),
          title: "S",
          monitored: true,
          monitor_strategy: :all
        })

      season = Repo.insert!(%Cinder.Catalog.Season{series_id: series.id, season_number: 1})

      ep =
        Repo.insert!(%Cinder.Catalog.Episode{
          season_id: season.id,
          episode_number: 1,
          air_date: ~D[2001-01-01]
        })

      {:ok, _} = Catalog.create_grab("H1", :torrent, [ep.id])

      assert [grab] = Catalog.list_grabs()
      assert [loaded_ep] = grab.episodes
      assert loaded_ep.season.series.id == series.id
    end
  end

  describe "delete_episode_file/3" do
    setup :verify_on_exit!

    defp episode_with_file!(path) do
      series =
        Repo.insert!(%Series{
          tmdb_id: System.unique_integer([:positive]),
          title: "Show",
          year: 2010
        })

      season = Repo.insert!(%Cinder.Catalog.Season{series_id: series.id, season_number: 1})

      ep =
        Repo.insert!(%Cinder.Catalog.Episode{
          season_id: season.id,
          episode_number: 1,
          monitored: true,
          file_path: path
        })

      {series, ep}
    end

    test "unlinks the file and clears file_path, leaving it monitored (re-grab parity)" do
      {_series, ep} = episode_with_file!("/tmp/ep.mkv")
      expect(Cinder.Library.FilesystemMock, :rm, fn "/tmp/ep.mkv" -> :ok end)
      stub(Cinder.Library.FilesystemMock, :rmdir, fn _ -> {:error, :enotempty} end)

      assert {:ok, updated} = Catalog.delete_episode_file(ep, nil)
      assert is_nil(updated.file_path)
      assert updated.monitored == true
    end

    test "clears every episode that shares the deleted multi-episode file" do
      {_series, ep} = episode_with_file!("/tmp/S01E01-E02.mkv")

      shared =
        Repo.insert!(%Cinder.Catalog.Episode{
          season_id: ep.season_id,
          episode_number: 2,
          monitored: true,
          file_path: ep.file_path
        })

      expect(Cinder.Library.FilesystemMock, :rm, fn "/tmp/S01E01-E02.mkv" -> :ok end)
      stub(Cinder.Library.FilesystemMock, :rmdir, fn _ -> {:error, :enotempty} end)

      assert {:ok, _updated} = Catalog.delete_episode_file(ep, nil)
      assert is_nil(Repo.get!(Cinder.Catalog.Episode, ep.id).file_path)
      assert is_nil(Repo.get!(Cinder.Catalog.Episode, shared.id).file_path)
    end

    test "unmonitor: true also clears monitored" do
      {_series, ep} = episode_with_file!("/tmp/ep.mkv")
      expect(Cinder.Library.FilesystemMock, :rm, fn _ -> :ok end)
      stub(Cinder.Library.FilesystemMock, :rmdir, fn _ -> {:error, :enotempty} end)

      assert {:ok, updated} = Catalog.delete_episode_file(ep, nil, unmonitor: true)
      assert is_nil(updated.file_path)
      assert updated.monitored == false
    end

    test "no file_path returns {:error, :no_file} and makes no FS call" do
      {_series, ep} = episode_with_file!(nil)
      assert {:error, :no_file} = Catalog.delete_episode_file(ep, nil)
    end

    test "a failed unlink surfaces the error and leaves file_path untouched" do
      {_series, ep} = episode_with_file!("/tmp/ep.mkv")
      expect(Cinder.Library.FilesystemMock, :rm, fn _ -> {:error, :eacces} end)

      assert {:error, :eacces} = Catalog.delete_episode_file(ep, nil)
      assert Repo.get(Cinder.Catalog.Episode, ep.id).file_path == "/tmp/ep.mkv"
    end

    test "broadcasts {:series_updated, series_id}" do
      {series, ep} = episode_with_file!("/tmp/ep.mkv")
      expect(Cinder.Library.FilesystemMock, :rm, fn _ -> :ok end)
      stub(Cinder.Library.FilesystemMock, :rmdir, fn _ -> {:error, :enotempty} end)
      Catalog.subscribe_series()

      assert {:ok, _} = Catalog.delete_episode_file(ep, nil)
      assert_receive {:series_updated, id}
      assert id == series.id
    end

    test "clears imported_resolution, imported_size, imported_language on delete" do
      {_series, ep} = episode_with_file!("/tmp/ep.mkv")

      {:ok, ep} =
        ep
        |> Ecto.Changeset.change(
          imported_resolution: "1080p",
          imported_size: 4_000_000_000,
          imported_language: "en",
          imported_source: "bluray"
        )
        |> Repo.update()

      expect(Cinder.Library.FilesystemMock, :rm, fn "/tmp/ep.mkv" -> :ok end)
      stub(Cinder.Library.FilesystemMock, :rmdir, fn _ -> {:error, :enotempty} end)

      assert {:ok, _updated} = Catalog.delete_episode_file(ep, nil)

      reloaded = Repo.get!(Cinder.Catalog.Episode, ep.id)
      assert is_nil(reloaded.file_path)
      assert is_nil(reloaded.imported_resolution)
      assert is_nil(reloaded.imported_size)
      assert is_nil(reloaded.imported_language)
      assert is_nil(reloaded.imported_source)
    end
  end

  describe "delete_season_files/3" do
    setup :verify_on_exit!

    defp season_with_files!(paths) do
      series =
        Repo.insert!(%Series{
          tmdb_id: System.unique_integer([:positive]),
          title: "Show",
          year: 2010
        })

      season = Repo.insert!(%Cinder.Catalog.Season{series_id: series.id, season_number: 1})

      eps =
        for {path, n} <- Enum.with_index(paths, 1) do
          Repo.insert!(%Cinder.Catalog.Episode{
            season_id: season.id,
            episode_number: n,
            monitored: true,
            file_path: path
          })
        end

      {series, season, eps}
    end

    test "clears file_path on every episode with a file, skips fileless ones, one broadcast" do
      {series, season, [e1, e2]} = season_with_files!(["/tmp/e1.mkv", nil])
      expect(Cinder.Library.FilesystemMock, :rm, fn "/tmp/e1.mkv" -> :ok end)
      stub(Cinder.Library.FilesystemMock, :rmdir, fn _ -> {:error, :enotempty} end)
      Catalog.subscribe_series()

      assert {:ok, 1, 0} = Catalog.delete_season_files(season, nil)
      assert is_nil(Repo.get(Cinder.Catalog.Episode, e1.id).file_path)
      assert is_nil(Repo.get(Cinder.Catalog.Episode, e2.id).file_path)
      assert_receive {:series_updated, id}
      assert id == series.id
      refute_received {:series_updated, ^id}
    end

    test "unmonitor: true clears monitored on the cleared episodes" do
      {_series, season, [e1]} = season_with_files!(["/tmp/e1.mkv"])
      expect(Cinder.Library.FilesystemMock, :rm, fn _ -> :ok end)
      stub(Cinder.Library.FilesystemMock, :rmdir, fn _ -> {:error, :enotempty} end)

      assert {:ok, 1, 0} = Catalog.delete_season_files(season, nil, unmonitor: true)
      assert Repo.get(Cinder.Catalog.Episode, e1.id).monitored == false
    end

    test "a per-file unlink failure leaves that episode's file_path (not cleared)" do
      {_series, season, [e1, e2]} = season_with_files!(["/tmp/ok.mkv", "/tmp/bad.mkv"])
      stub(Cinder.Library.FilesystemMock, :rmdir, fn _ -> {:error, :enotempty} end)
      # TWO rm calls (one per episode) -> expect/4 with an explicit count of 2. A bare 2-clause
      # expect/3 is ONE allowed call and the second rm would raise Mox.UnexpectedCallError. The
      # clauses dispatch in call order (e1 then e2, the Repo.all id order).
      expect(Cinder.Library.FilesystemMock, :rm, 2, fn
        "/tmp/ok.mkv" -> :ok
        "/tmp/bad.mkv" -> {:error, :eacces}
      end)

      log = capture_log(fn -> assert {:ok, 1, 1} = Catalog.delete_season_files(season, nil) end)

      assert log =~ ~s(library file delete failed for "/tmp/bad.mkv": :eacces)
      assert is_nil(Repo.get(Cinder.Catalog.Episode, e1.id).file_path)
      assert Repo.get(Cinder.Catalog.Episode, e2.id).file_path == "/tmp/bad.mkv"
    end

    test "all unlinks fail returns {:ok, 0, 1} and leaves file_path untouched" do
      {_series, season, [e1]} = season_with_files!(["/tmp/bad.mkv"])
      expect(Cinder.Library.FilesystemMock, :rm, fn "/tmp/bad.mkv" -> {:error, :eacces} end)

      log = capture_log(fn -> assert {:ok, 0, 1} = Catalog.delete_season_files(season, nil) end)

      assert log =~ ~s(library file delete failed for "/tmp/bad.mkv": :eacces)
      assert Repo.get(Cinder.Catalog.Episode, e1.id).file_path == "/tmp/bad.mkv"
    end
  end

  describe "delete_episode_file/3 stale entry" do
    setup :verify_on_exit!

    test "concurrent episode row deletion returns {:error, :stale_entry} (no raise)" do
      series =
        Repo.insert!(%Series{
          tmdb_id: System.unique_integer([:positive]),
          title: "Show",
          year: 2010
        })

      season = Repo.insert!(%Cinder.Catalog.Season{series_id: series.id, season_number: 1})

      ep =
        Repo.insert!(%Cinder.Catalog.Episode{
          season_id: season.id,
          episode_number: 1,
          monitored: true,
          file_path: "/tmp/ep.mkv"
        })

      # Simulate concurrent deletion of the episode row out-of-band.
      Repo.delete!(ep)

      # FS stub: unlink succeeds (the pre-txn step), but the DB update then raises StaleEntryError.
      stub(Cinder.Library.FilesystemMock, :rm, fn _ -> :ok end)
      stub(Cinder.Library.FilesystemMock, :rmdir, fn _ -> {:error, :enotempty} end)

      assert Catalog.delete_episode_file(ep, nil) == {:error, :stale_entry}
    end
  end

  defp verification_held_movie(origin) do
    file_path =
      if origin == :upgrade,
        do: "/library/Anime Movie.mkv",
        else: "/downloads/Anime Movie.mkv"

    # A real :download-origin hold has content_path set (the download source); an :upgrade-origin
    # hold's content_path stays nil the whole time (see poller.ex's finish_upgrade).
    content_path = if origin == :download, do: file_path, else: nil

    movie =
      movie_fixture(%{
        title: "Anime Movie",
        status: :import_failed,
        download_id: "HASH-HELD-#{origin}",
        download_protocol: :torrent,
        release_title: "[Group] Anime Movie",
        file_path: file_path,
        content_path: content_path,
        imported_resolution: "720p",
        imported_size: 1_234
      })

    {:ok, held} =
      Catalog.transition(movie, %{
        status: :import_failed,
        import_attempts: 10,
        verification_hold_origin: origin,
        release_policy_snapshot: %{
          "version" => 1,
          "required_audio_languages" => ["ja", "fr"],
          "required_embedded_subtitle_languages" => [],
          "release_group" => "group",
          "release_title" => movie.release_title
        }
      })

    Repo.reload!(held)
  end
end
