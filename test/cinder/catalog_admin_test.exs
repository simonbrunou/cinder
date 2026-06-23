defmodule Cinder.CatalogAdminTest do
  # async: false — sibling tasks in this file exercise Repo.transaction (cancel/delete);
  # the single-connection SQLite Sandbox needs shared mode for nested transactions.
  use Cinder.DataCase, async: false

  import Mox

  alias Cinder.Catalog
  alias Cinder.Catalog.{Movie, Series}

  defp movie!(attrs \\ %{}) do
    {:ok, movie} =
      Catalog.add_to_watchlist(
        Map.merge(%{tmdb_id: System.unique_integer([:positive]), title: "Inception"}, attrs)
      )

    movie
  end

  describe "update_movie/2" do
    test "edits metadata via Movie.changeset, leaving status untouched" do
      movie = movie!(%{title: "Old", year: 2009})

      assert {:ok, %Movie{} = updated} =
               Catalog.update_movie(movie, %{title: "Inception", year: 2010})

      assert updated.title == "Inception"
      assert updated.year == 2010
      # status is not castable on Movie.changeset/2, so it stays put.
      assert updated.status == movie.status
      assert Repo.get!(Movie, movie.id).title == "Inception"
    end

    test "a status key in attrs is ignored (status stays in transition)" do
      movie = movie!()
      assert {:ok, updated} = Catalog.update_movie(movie, %{title: "X", status: :available})
      assert updated.status == :requested
    end

    test "returns {:error, changeset} on a blank required title" do
      movie = movie!()
      assert {:error, %Ecto.Changeset{}} = Catalog.update_movie(movie, %{title: ""})
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
  end

  describe "cancel_movie/2" do
    setup :verify_on_exit!

    test "an active movie with a download is cancelled and the client download removed" do
      import Mox
      actor = Cinder.AccountsFixtures.admin_fixture()

      movie =
        movie!()
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
      movie = movie!()
      # No expect/0 on the client → if cancel_movie called it, verify_on_exit! would fail.
      assert {:ok, %Movie{status: :cancelled}} = Catalog.cancel_movie(movie, actor)
    end

    test "a non-cancellable (terminal/available) movie returns {:error, :not_cancellable}" do
      actor = Cinder.AccountsFixtures.admin_fixture()
      movie = movie!() |> then(&elem(Catalog.transition(&1, %{status: :available}), 1))
      assert {:error, :not_cancellable} = Catalog.cancel_movie(movie, actor)
      assert Repo.get!(Movie, movie.id).status == :available
    end

    test "writes an admin_audit row for the cancel (in-txn)" do
      actor = Cinder.AccountsFixtures.admin_fixture()
      movie = movie!()
      assert {:ok, _} = Catalog.cancel_movie(movie, actor)

      audit = Repo.one!(Cinder.Audit.AdminAudit)
      assert audit.action == "cancel_movie"
      assert audit.entity_type == "Movie"
      assert audit.entity_id == movie.id
      assert audit.actor_id == actor.id
    end
  end

  describe "delete_movie/2" do
    setup :verify_on_exit!

    test "deletes an idle movie and broadcasts {:movie_deleted, id}" do
      actor = Cinder.AccountsFixtures.admin_fixture()
      movie = movie!() |> then(&elem(Catalog.transition(&1, %{status: :available}), 1))
      id = movie.id
      Catalog.subscribe()

      assert {:ok, %Movie{}} = Catalog.delete_movie(movie, actor)
      assert_receive {:movie_deleted, ^id}
      assert Repo.get(Movie, id) == nil
    end

    test "an active movie with a download is cancelled (client-removed) before delete" do
      import Mox
      actor = Cinder.AccountsFixtures.admin_fixture()

      movie =
        movie!()
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

    test "writes an admin_audit row for the delete" do
      actor = Cinder.AccountsFixtures.admin_fixture()
      movie = movie!()
      assert {:ok, _} = Catalog.delete_movie(movie, actor)
      assert Repo.one!(Cinder.Audit.AdminAudit).action == "delete_movie"
    end
  end

  describe "cancel_series/2 and delete_series/2" do
    setup :verify_on_exit!
    import Mox

    alias Cinder.Catalog.{Episode, Grab, Season, Series}

    defp series_tree do
      series =
        Repo.insert!(%Series{
          tmdb_id: System.unique_integer([:positive]),
          title: "Show",
          year: 2008,
          monitored: true,
          monitor_strategy: :all
        })

      season = Repo.insert!(%Season{series_id: series.id, season_number: 1, monitored: true})

      ep =
        Repo.insert!(%Episode{
          season_id: season.id,
          episode_number: 1,
          monitored: true,
          air_date: ~D[2001-01-01]
        })

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
end
