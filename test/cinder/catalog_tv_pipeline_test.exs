defmodule Cinder.CatalogTvPipelineTest do
  # async: false — create_grab/3 wraps a Repo.transaction; the SQLite sandbox needs shared
  # mode for nested transactions (same reason as catalog_series_test.exs).
  use Cinder.DataCase, async: false

  alias Cinder.Catalog
  alias Cinder.Catalog.{Episode, Grab, Season, Series}

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

  describe "grab lifecycle" do
    test "create_grab/3 links episodes, persists, and broadcasts" do
      {series, season} = series_with_season()
      e1 = episode(season, %{})
      e2 = episode(season, %{})
      series_id = series.id
      Catalog.subscribe_series()

      assert {:ok, grab} = Catalog.create_grab("HASH1", :torrent, [e1.id, e2.id])
      assert grab.download_id == "HASH1"
      assert grab.download_protocol == :torrent
      assert is_nil(grab.content_path)
      assert_receive {:series_updated, ^series_id}

      assert Repo.get(Episode, e1.id).grab_id == grab.id
      assert Repo.get(Episode, e2.id).grab_id == grab.id
    end

    test "mark_grab_downloaded/2 sets content_path and moves the grab between the lists" do
      {_series, season} = series_with_season()
      e1 = episode(season, %{})
      {:ok, grab} = Catalog.create_grab("HASH2", :usenet, [e1.id])

      assert [%Grab{id: id}] = Catalog.list_grabs_downloading()
      assert id == grab.id
      assert Catalog.list_grabs_downloaded() == []

      assert {:ok, grab} = Catalog.mark_grab_downloaded(grab, "/downloads/pack")
      assert grab.content_path == "/downloads/pack"
      assert Catalog.list_grabs_downloading() == []
      assert [%Grab{id: ^id}] = Catalog.list_grabs_downloaded()
    end

    test "delete_grab/1 removes the grab and nilifies its episodes' grab_id" do
      {series, season} = series_with_season()
      e1 = episode(season, %{})
      series_id = series.id
      {:ok, grab} = Catalog.create_grab("HASH3", :torrent, [e1.id])
      Catalog.subscribe_series()

      assert {:ok, _} = Catalog.delete_grab(grab)
      assert_receive {:series_updated, ^series_id}
      assert Repo.get(Grab, grab.id) == nil
      assert Repo.get(Episode, e1.id).grab_id == nil
    end
  end
end
