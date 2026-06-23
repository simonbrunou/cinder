defmodule Cinder.CatalogAdminTest do
  # async: false — sibling tasks in this file exercise Repo.transaction (cancel/delete);
  # the single-connection SQLite Sandbox needs shared mode for nested transactions.
  use Cinder.DataCase, async: false

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
end
