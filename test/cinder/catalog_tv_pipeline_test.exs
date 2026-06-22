defmodule Cinder.CatalogTvPipelineTest do
  # async: false — create_grab/3 wraps a Repo.transaction; the SQLite sandbox needs shared
  # mode for nested transactions (same reason as catalog_series_test.exs).
  use Cinder.DataCase, async: false

  alias Cinder.Catalog
  # Grab is added to this alias in Task 3 (first used by the grab-lifecycle tests).
  alias Cinder.Catalog.{Episode, Season, Series}

  @past ~D[2001-01-01]

  defp series_with_season do
    series =
      Repo.insert!(%Series{
        tmdb_id: System.unique_integer([:positive]),
        title: "Show",
        year: 2008,
        monitored: true,
        monitor_strategy: :all
      })

    season = Repo.insert!(%Season{series_id: series.id, season_number: 1, monitored: true})
    {series, season}
  end

  defp episode(season, attrs) do
    Repo.insert!(
      struct(
        %Episode{
          season_id: season.id,
          episode_number: System.unique_integer([:positive]),
          monitored: true,
          air_date: @past
        },
        attrs
      )
    )
  end

  describe "transition_episode/2" do
    test "sets a pipeline field, persists, and broadcasts {:series_updated, series_id}" do
      {series, season} = series_with_season()
      ep = episode(season, %{})
      series_id = series.id
      Catalog.subscribe_series()

      assert {:ok, ep} = Catalog.transition_episode(ep, %{file_path: "/library/x.mkv"})
      assert ep.file_path == "/library/x.mkv"
      assert_receive {:series_updated, ^series_id}
      assert Repo.get(Episode, ep.id).file_path == "/library/x.mkv"
    end
  end
end
