defmodule Cinder.CatalogSeriesTest do
  # async: false — add_series_to_watchlist inserts the tree via cast_assoc, which wraps
  # a Repo.transaction; the SQLite sandbox needs shared mode (shared: not async) for a
  # nested transaction (same reason requests_test.exs is async: false).
  use Cinder.DataCase, async: false

  import Mox

  alias Cinder.Catalog
  alias Cinder.Catalog.Series

  setup :verify_on_exit!

  # Far-past / far-future / undated, so the :future assertions never depend on the
  # wall clock (Date.utc_today/0 sits safely between these).
  @past ~D[2001-01-01]
  @future ~D[2099-01-01]

  # A series with a specials season (0) and one regular season (1): one aired
  # episode, one un-aired, one undated (TBA).
  # Variant of stub_tmdb/1 that stubs tmdb_id=42 and allows overriding original_language.
  defp stub_tmdb_series(opts) do
    ol = Keyword.get(opts, :original_language, nil)

    expect(Cinder.Catalog.TMDBMock, :get_series, fn 42 ->
      {:ok,
       %{
         tmdb_id: 42,
         tvdb_id: 999,
         title: "Test Show",
         year: 2001,
         poster_path: "/p.jpg",
         original_language: ol,
         seasons: [%{season_number: 1}]
       }}
    end)

    expect(Cinder.Catalog.TMDBMock, :get_season, 1, fn 42, 1 ->
      {:ok,
       %{
         season_number: 1,
         episodes: [
           %{tmdb_episode_id: 101, episode_number: 1, title: "Ep1", air_date: @past}
         ]
       }}
    end)
  end

  defp stub_tmdb(tmdb_id) do
    expect(Cinder.Catalog.TMDBMock, :get_series, fn ^tmdb_id ->
      {:ok,
       %{
         tmdb_id: tmdb_id,
         tvdb_id: 999,
         title: "Test Show",
         year: 2001,
         poster_path: "/p.jpg",
         seasons: [%{season_number: 0}, %{season_number: 1}]
       }}
    end)

    expect(Cinder.Catalog.TMDBMock, :get_season, 2, fn ^tmdb_id, n ->
      episodes =
        case n do
          0 ->
            [%{tmdb_episode_id: 900, episode_number: 1, title: "Special", air_date: @past}]

          1 ->
            [
              %{tmdb_episode_id: 101, episode_number: 1, title: "Aired", air_date: @past},
              %{tmdb_episode_id: 102, episode_number: 2, title: "Unaired", air_date: @future},
              %{tmdb_episode_id: 103, episode_number: 3, title: "TBA", air_date: nil}
            ]
        end

      {:ok, %{season_number: n, episodes: episodes}}
    end)
  end

  defp loaded(series_id) do
    Series |> Repo.get!(series_id) |> Repo.preload(seasons: :episodes)
  end

  defp episodes(series_id) do
    loaded(series_id).seasons |> Enum.flat_map(& &1.episodes)
  end

  describe "add_series_to_watchlist/2 (Done when)" do
    test "persists the season/episode tree with monitor flags (:future)" do
      stub_tmdb(42)

      assert {:ok, %Series{} = series} =
               Catalog.add_series_to_watchlist(42, monitor_strategy: :future)

      assert series.tmdb_id == 42
      assert series.tvdb_id == 999
      assert series.monitor_strategy == :future
      assert series.monitored

      # Re-query + preload — prove persistence, not the in-memory insert struct.
      series = loaded(series.id)
      assert [s0, s1] = Enum.sort_by(series.seasons, & &1.season_number)
      assert s0.season_number == 0
      assert s1.season_number == 1
      # Season-level monitored flag persists (strategy != :none ⇒ true).
      assert s0.monitored
      assert s1.monitored
      assert length(s1.episodes) == 3

      by_num = fn season -> Map.new(season.episodes, &{&1.episode_number, &1}) end
      s1_eps = by_num.(s1)

      assert s1_eps[1].tmdb_episode_id == 101
      refute s1_eps[1].monitored, "aired episode is not monitored under :future"
      assert s1_eps[2].monitored, "un-aired episode is monitored under :future"
      assert s1_eps[3].monitored, "undated/TBA episode is monitored under :future"

      assert by_num.(s0)[1].monitored == false
    end
  end

  describe "monitor strategies" do
    test ":all monitors every episode, specials included" do
      stub_tmdb(43)
      {:ok, series} = Catalog.add_series_to_watchlist(43, monitor_strategy: :all)

      assert series.monitored
      assert Enum.all?(episodes(series.id), & &1.monitored)
    end

    test ":none monitors nothing" do
      stub_tmdb(44)
      {:ok, series} = Catalog.add_series_to_watchlist(44, monitor_strategy: :none)

      refute series.monitored
      assert Enum.all?(episodes(series.id), &(&1.monitored == false))
    end

    test ":future (the default) monitors only un-aired or undated episodes" do
      stub_tmdb(45)
      {:ok, series} = Catalog.add_series_to_watchlist(45)

      assert series.monitor_strategy == :future
      assert Enum.count(episodes(series.id), & &1.monitored) == 2
    end
  end

  describe "find-or-create + getters" do
    test "returns the existing series without re-fetching TMDB" do
      stub_tmdb(46)
      {:ok, first} = Catalog.add_series_to_watchlist(46)

      # No further expect/3 — verify_on_exit! proves TMDB is not called again.
      assert {:ok, second} = Catalog.add_series_to_watchlist(46)
      assert second.id == first.id
    end

    test "get_series_by_tmdb_id/1, get_series_by_id/1 and list_series/0" do
      stub_tmdb(47)
      {:ok, series} = Catalog.add_series_to_watchlist(47)

      assert Catalog.get_series_by_tmdb_id(47).id == series.id
      assert Catalog.get_series_by_id(series.id).tmdb_id == 47
      assert Catalog.get_series_by_tmdb_id(-1) == nil
      assert [%Series{tmdb_id: 47}] = Catalog.list_series()
    end

    test "a failed TMDB fetch persists nothing" do
      expect(Cinder.Catalog.TMDBMock, :get_series, fn 48 -> {:error, :timeout} end)

      assert {:error, :timeout} = Catalog.add_series_to_watchlist(48)
      assert Catalog.get_series_by_tmdb_id(48) == nil
    end

    test "a get_season failure mid-tree persists nothing (no partial tree)" do
      # get_series succeeds with two seasons; the second get_season fails. The whole
      # add must short-circuit with the error and leave no series/season/episode rows.
      expect(Cinder.Catalog.TMDBMock, :get_series, fn 49 ->
        {:ok,
         %{
           tmdb_id: 49,
           tvdb_id: nil,
           title: "Half-fetched",
           year: 2010,
           poster_path: nil,
           seasons: [%{season_number: 1}, %{season_number: 2}]
         }}
      end)

      expect(Cinder.Catalog.TMDBMock, :get_season, 2, fn 49, n ->
        case n do
          1 ->
            {:ok,
             %{
               season_number: 1,
               episodes: [%{tmdb_episode_id: 1, episode_number: 1, title: "E", air_date: @past}]
             }}

          2 ->
            {:error, :timeout}
        end
      end)

      assert {:error, :timeout} = Catalog.add_series_to_watchlist(49)
      assert Catalog.get_series_by_tmdb_id(49) == nil
    end

    test "rejects an unknown monitor_strategy without calling TMDB" do
      # No expect/3 — verify_on_exit! proves TMDB is never reached.
      assert {:error, :invalid_monitor_strategy} =
               Catalog.add_series_to_watchlist(50, monitor_strategy: :bogus)

      assert Catalog.get_series_by_tmdb_id(50) == nil
    end
  end

  describe "search_tv/1" do
    test "a blank/whitespace query short-circuits without calling TMDB" do
      # No expect/3 — verify_on_exit! proves search_tv is never reached.
      assert Catalog.search_tv("   ") == {:ok, []}
    end

    test "delegates a real query to the TMDB behaviour" do
      expect(Cinder.Catalog.TMDBMock, :search_tv, fn "the wire" -> {:ok, [%{tmdb_id: 1}]} end)
      assert {:ok, [%{tmdb_id: 1}]} = Catalog.search_tv("the wire")
    end
  end

  describe "get_series_with_tree/1" do
    test "loads the series with seasons and episodes in order" do
      stub_tmdb(60)
      {:ok, series} = Catalog.add_series_to_watchlist(60)

      tree = Catalog.get_series_with_tree(series.id)
      assert Enum.map(tree.seasons, & &1.season_number) == [0, 1]

      s1 = Enum.find(tree.seasons, &(&1.season_number == 1))
      assert Enum.map(s1.episodes, & &1.episode_number) == [1, 2, 3]
    end

    test "returns nil for a missing id" do
      assert Catalog.get_series_with_tree(-1) == nil
    end
  end

  describe "monitor toggles" do
    test "set_episode_monitored/2 flips the flag, persists, and broadcasts" do
      stub_tmdb(61)
      {:ok, series} = Catalog.add_series_to_watchlist(61, monitor_strategy: :none)
      series_id = series.id
      Catalog.subscribe_series()

      ep = hd(episodes(series.id))
      refute ep.monitored

      assert {:ok, ep} = Catalog.set_episode_monitored(ep, true)
      assert ep.monitored
      assert_receive {:series_updated, ^series_id}
      assert Enum.find(episodes(series.id), &(&1.id == ep.id)).monitored
    end

    test "set_season_monitored/2 cascades to every episode in the season and broadcasts" do
      stub_tmdb(62)
      {:ok, series} = Catalog.add_series_to_watchlist(62, monitor_strategy: :none)
      series_id = series.id
      Catalog.subscribe_series()

      season = Enum.find(loaded(series.id).seasons, &(&1.season_number == 1))
      refute season.monitored

      assert {:ok, season} = Catalog.set_season_monitored(season, true)
      assert season.monitored
      assert_receive {:series_updated, ^series_id}

      eps = Enum.find(loaded(series.id).seasons, &(&1.id == season.id)).episodes
      assert Enum.all?(eps, & &1.monitored)
    end
  end

  describe "language fields" do
    test "add_series_to_watchlist stores original_language and the chosen preferred_language" do
      stub_tmdb_series(original_language: "fr")

      {:ok, series} =
        Catalog.add_series_to_watchlist(42,
          monitor_strategy: :future,
          preferred_language: "french"
        )

      assert series.original_language == "fr"
      assert series.preferred_language == "french"
    end
  end

  describe "FK cascade (foreign_keys: :on)" do
    test "deleting a series cascade-deletes its seasons and episodes" do
      series = Repo.insert!(%Series{tmdb_id: 8001, title: "Cascade Show"})
      season = Repo.insert!(%Cinder.Catalog.Season{series_id: series.id, season_number: 1})

      episode =
        Repo.insert!(%Cinder.Catalog.Episode{
          season_id: season.id,
          episode_number: 1,
          monitored: true
        })

      assert {:ok, _} = Repo.delete(series)
      refute Repo.get(Cinder.Catalog.Season, season.id)
      refute Repo.get(Cinder.Catalog.Episode, episode.id)
    end
  end

  describe "find_or_create_series_at_requested/2" do
    setup do
      stub(Cinder.Catalog.TMDBMock, :get_series, fn 1399 ->
        {:ok,
         %{
           tmdb_id: 1399,
           tvdb_id: 121_361,
           title: "GoT",
           year: 2011,
           poster_path: nil,
           seasons: [%{season_number: 1}, %{season_number: 2}]
         }}
      end)

      stub(Cinder.Catalog.TMDBMock, :get_season, fn 1399, n ->
        {:ok,
         %{
           season_number: n,
           episodes: [
             %{
               tmdb_episode_id: n * 10 + 1,
               episode_number: 1,
               title: "e1",
               air_date: ~D[2011-01-01]
             }
           ]
         }}
      end)

      :ok
    end

    test "creates the series and monitors only the requested season" do
      assert {:ok, series} = Catalog.find_or_create_series_at_requested(1399, 2)

      tree = Catalog.get_series_with_tree(series.id)
      assert tree.monitored
      s1 = Enum.find(tree.seasons, &(&1.season_number == 1))
      s2 = Enum.find(tree.seasons, &(&1.season_number == 2))
      refute s1.monitored
      assert s2.monitored
      assert Enum.all?(s2.episodes, & &1.monitored)
      refute Enum.any?(s1.episodes, & &1.monitored)
    end

    test "is idempotent and additive across seasons (S1 then S2 leaves both monitored)" do
      {:ok, series} = Catalog.find_or_create_series_at_requested(1399, 1)
      {:ok, ^series} = Catalog.find_or_create_series_at_requested(1399, 2)

      tree = Catalog.get_series_with_tree(series.id)
      assert Enum.find(tree.seasons, &(&1.season_number == 1)).monitored
      assert Enum.find(tree.seasons, &(&1.season_number == 2)).monitored
    end

    test "an existing default-language series adopts a requester's non-default pick (fill-if-default)" do
      {:ok, _} = Catalog.find_or_create_series_at_requested(1399, 1)
      {:ok, series} = Catalog.find_or_create_series_at_requested(1399, 2, "french")
      assert series.preferred_language == "french"
    end

    test "a series already customized keeps its language against a later requester pick" do
      {:ok, _} = Catalog.find_or_create_series_at_requested(1399, 1, "french")
      {:ok, series} = Catalog.find_or_create_series_at_requested(1399, 2, "any")
      assert series.preferred_language == "french"
    end
  end
end
