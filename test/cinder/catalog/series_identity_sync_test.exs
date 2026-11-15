defmodule Cinder.Catalog.SeriesIdentitySyncTest do
  # #830 moved the identity sync out of SeriesCatalog and SceneNumbering into
  # Cinder.Catalog.SeriesIdentitySync. These tests hold the two rules the move had to keep on
  # every caller's path: each TMDB call runs before the caller's transaction opens, and the
  # interactive save runs the episode lookup only when it writes scene coordinates.
  use Cinder.DataCase, async: true

  import Mox
  import Cinder.CatalogFixtures

  alias Cinder.Catalog
  alias Cinder.Catalog.TMDBMock

  @moduletag :capture_log

  setup :verify_on_exit!

  @tmdb_episode_id 83_001

  describe "TMDB calls" do
    setup do
      parent = self()
      record = fn fun -> send(parent, {:tmdb_call, fun, Repo.in_transaction?()}) end

      stub(TMDBMock, :get_series, fn tmdb_id ->
        record.(:get_series)
        {:ok, series_info(tmdb_id)}
      end)

      stub(TMDBMock, :get_season, fn _tmdb_id, 1, _locale ->
        record.(:get_season)
        {:ok, season_info()}
      end)

      stub(TMDBMock, :get_series_alternative_titles, fn _tmdb_id ->
        record.(:get_series_alternative_titles)
        {:ok, [%{title: "Alias", country_code: "JP"}]}
      end)

      stub(TMDBMock, :get_episode_groups, fn _tmdb_id ->
        record.(:get_episode_groups)
        {:ok, [episode_group(id: "absolute", type: 2)]}
      end)

      stub(TMDBMock, :get_episode_group, fn group_id ->
        record.({:get_episode_group, group_id})
        {:ok, group_detail(group_id)}
      end)

      :ok
    end

    test "series creation, request approval, the refresh and the scene save call TMDB outside " <>
           "any transaction" do
      assert {:ok, added} = Catalog.add_series(System.unique_integer([:positive]))

      assert_calls_outside_transaction([
        :get_series,
        :get_season,
        {:get_episode_group, "absolute"}
      ])

      assert {:ok, _requested} =
               Catalog.find_or_create_series_at_requested(System.unique_integer([:positive]), 1)

      assert_calls_outside_transaction([:get_series, :get_season, :get_episode_groups])

      assert {:ok, saved} = Catalog.set_scene_numbering_group(added, "scene")
      assert_calls_outside_transaction([{:get_episode_group, "scene"}])

      assert {:ok, _refreshed} = Catalog.refresh_series(saved)

      assert_calls_outside_transaction([
        :get_series,
        :get_series_alternative_titles,
        {:get_episode_group, "scene"}
      ])

      # The writes these calls fed landed: the TMDB alias, then the scene coordinate.
      assert Enum.any?(Catalog.list_title_aliases(saved), &(&1.title == "Alias"))

      assert Enum.any?(
               Catalog.list_episode_coordinates(saved),
               &(&1.scheme == "scene" and &1.namespace == "scene")
             )
    end
  end

  describe "the scene save's episode lookup" do
    test "runs once when the save writes scene coordinates, and not when it clears the group" do
      series = series_fixture(scene_numbering_group_id: nil)
      season = season_fixture(series)
      episode_fixture(season, tmdb_episode_id: @tmdb_episode_id)

      {{:ok, saved}, writes} =
        count_episode_lookup_queries(fn ->
          Catalog.set_scene_numbering_group(series, "scene", detail: group_detail("scene"))
        end)

      assert writes == 1
      assert Enum.any?(Catalog.list_episode_coordinates(saved), &(&1.scheme == "scene"))

      {{:ok, cleared}, clears} =
        count_episode_lookup_queries(fn -> Catalog.set_scene_numbering_group(saved, nil) end)

      assert clears == 0
      assert cleared.scene_numbering_group_id == nil
      refute Enum.any?(Catalog.list_episode_coordinates(cleared), &(&1.scheme == "scene"))
    end
  end

  # Drains every recorded TMDB call, asserts none ran inside a transaction, and asserts each of
  # `expected` was among them, so a path that stopped calling TMDB cannot pass on no calls.
  defp assert_calls_outside_transaction(expected) do
    calls = drain_calls([])
    inside = for {fun, true} <- calls, do: fun

    assert inside == [], "TMDB called inside a transaction: #{inspect(inside)}"

    for fun <- expected do
      assert Enum.any?(calls, &(elem(&1, 0) == fun)), "no #{inspect(fun)} call recorded"
    end
  end

  defp drain_calls(acc) do
    receive do
      {:tmdb_call, fun, in_transaction?} -> drain_calls([{fun, in_transaction?} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # Counts the identity sync's episode lookup by its SQL, as `Cinder.CatalogRefreshTest` does.
  defp count_episode_lookup_queries(fun) do
    counter = :counters.new(1, [])
    ref = make_ref()
    parent = self()

    :telemetry.attach(
      ref,
      [:cinder, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if self() == parent and is_binary(metadata.query) and
             String.contains?(metadata.query, ~s(SELECT e0."tmdb_episode_id", e0."id")) do
          :counters.add(counter, 1, 1)
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(ref) end)

    result = fun.()
    :telemetry.detach(ref)
    {result, :counters.get(counter, 1)}
  end

  defp series_info(tmdb_id) do
    %{
      tmdb_id: tmdb_id,
      tvdb_id: nil,
      title: "Identity Sync Show",
      year: 2020,
      poster_path: nil,
      original_language: "ja",
      overview: nil,
      genres: nil,
      vote_average: nil,
      first_air_date: nil,
      seasons: [%{season_number: 1}]
    }
  end

  defp season_info do
    %{
      season_number: 1,
      episodes: [
        %{
          tmdb_episode_id: @tmdb_episode_id,
          episode_number: 1,
          title: "Pilot",
          air_date: ~D[2020-01-01]
        }
      ]
    }
  end

  defp group_detail(group_id) do
    episode_group(
      id: group_id,
      type: if(group_id == "absolute", do: 2, else: 6),
      entries: [
        %{
          tmdb_episode_id: @tmdb_episode_id,
          group_name: "Season 2",
          group_order: 2,
          order: 0,
          season_number: 1,
          episode_number: 1
        }
      ]
    )
  end
end
