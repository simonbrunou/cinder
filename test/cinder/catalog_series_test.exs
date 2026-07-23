defmodule Cinder.CatalogSeriesTest do
  # async: false — add_series inserts the tree via cast_assoc, which wraps
  # a Repo.transaction; the SQLite sandbox needs shared mode (shared: not async) for a
  # nested transaction (same reason requests_test.exs is async: false).
  use Cinder.DataCase, async: false

  import Mox
  import Cinder.CatalogFixtures

  alias Cinder.Acquisition.{Anime, Release}
  alias Cinder.Catalog
  alias Cinder.Catalog.Episode
  alias Cinder.Catalog.Series

  setup :verify_on_exit!

  setup do
    stub(Cinder.Catalog.TMDBMock, :get_series_alternative_titles, fn _ -> {:ok, []} end)
    stub(Cinder.Catalog.TMDBMock, :get_episode_groups, fn _ -> {:ok, []} end)
    :ok
  end

  # Far-past / far-future / undated, so the :future assertions never depend on the
  # wall clock (Date.utc_today/0 sits safely between these).
  @past ~D[2001-01-01]
  @future ~D[2099-01-01]

  # A series with a specials season (0) and one regular season (1): one aired
  # episode, one un-aired, one undated (TBA).
  # Variant of stub_tmdb/1 that stubs tmdb_id=42 and allows overriding original_language.
  defp stub_tmdb_series(opts) do
    ol = Keyword.get(opts, :original_language, nil)
    french_title = Keyword.get(opts, :french_title, "")

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

    expect(Cinder.Catalog.TMDBMock, :get_season, 1, fn 42, 1, "en" ->
      {:ok,
       %{
         season_number: 1,
         episodes: [
           %{tmdb_episode_id: 101, episode_number: 1, title: "Ep1", air_date: @past}
         ]
       }}
    end)

    stub(Cinder.Catalog.TMDBMock, :get_season, fn 42, 1, "fr" ->
      {:ok,
       %{
         season_number: 1,
         episodes: [
           %{tmdb_episode_id: 101, episode_number: 1, title: french_title, air_date: @past}
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

    expect(Cinder.Catalog.TMDBMock, :get_season, 2, fn ^tmdb_id, n, "en" ->
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

    stub(Cinder.Catalog.TMDBMock, :get_season, fn ^tmdb_id, n, "fr" ->
      {:ok, %{season_number: n, episodes: blank_french_episodes(n)}}
    end)
  end

  defp blank_french_episodes(0),
    do: [%{tmdb_episode_id: 900, episode_number: 1, title: "", air_date: @past}]

  defp blank_french_episodes(1),
    do: for(id <- 101..103, do: %{tmdb_episode_id: id, title: ""})

  defp loaded(series_id) do
    Series |> Repo.get!(series_id) |> Repo.preload(seasons: :episodes)
  end

  defp episodes(series_id) do
    loaded(series_id).seasons |> Enum.flat_map(& &1.episodes)
  end

  describe "add_series/2 (Done when)" do
    test "persists the season/episode tree with monitor flags (:future)" do
      stub_tmdb(42)

      expect(Cinder.Catalog.TMDBMock, :get_series_alternative_titles, fn 42 ->
        {:ok, [%{title: "Test Alias", country_code: "JP", kind: :alternative}]}
      end)

      expect(Cinder.Catalog.TMDBMock, :get_episode_groups, fn 42 ->
        {:ok, [%{id: "absolute", type: 2, name: "Absolute"}]}
      end)

      expect(Cinder.Catalog.TMDBMock, :get_episode_group, fn "absolute" ->
        {:ok,
         %{
           id: "absolute",
           type: 2,
           name: "Absolute",
           entries: [
             %{
               tmdb_episode_id: 101,
               group_order: 0,
               order: 0,
               season_number: 1,
               episode_number: 1
             }
           ]
         }}
      end)

      assert {:ok, %Series{} = series} =
               Catalog.add_series(42, monitor_strategy: :future)

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

      assert [%{title: "Test Alias", source: "tmdb"}] = Catalog.list_title_aliases(series)
      assert [%{canonical_value: "1"}] = Catalog.list_episode_coordinates(series)
      assert Repo.get_by!(Episode, tmdb_episode_id: 900).classification == :story_special
    end

    test "stores non-canonical episode titles" do
      stub_tmdb_series(french_title: "Épisode un")

      assert {:ok, series} = Catalog.add_series(42, monitor_strategy: :all)

      assert %{localizations: %{"fr" => %{"title" => "Épisode un"}}} =
               hd(episodes(series.id))
    end

    test "creates the canonical tree when a non-canonical season fetch fails" do
      stub_tmdb_series([])

      stub(Cinder.Catalog.TMDBMock, :get_season, fn 42, 1, "fr" ->
        {:error, :timeout}
      end)

      assert {:ok, series} = Catalog.add_series(42, monitor_strategy: :all)
      assert [%{title: "Ep1", localizations: %{}}] = episodes(series.id)
    end
  end

  describe "monitor strategies" do
    test ":all monitors regular episodes but leaves provider-classified specials explicit" do
      stub_tmdb(43)
      {:ok, series} = Catalog.add_series(43, monitor_strategy: :all)

      assert series.monitored

      assert Enum.all?(episodes(series.id), fn episode ->
               episode.monitored == (episode.classification == :regular)
             end)
    end

    test ":none monitors nothing" do
      stub_tmdb(44)
      {:ok, series} = Catalog.add_series(44, monitor_strategy: :none)

      refute series.monitored
      assert Enum.all?(episodes(series.id), &(&1.monitored == false))
    end

    test ":future (the default) monitors only un-aired or undated episodes" do
      stub_tmdb(45)
      {:ok, series} = Catalog.add_series(45)

      assert series.monitor_strategy == :future
      assert Enum.count(episodes(series.id), & &1.monitored) == 2
    end

    test "set_series_monitor_strategy/2 re-applies a strategy over an already-added tree" do
      stub_tmdb(80)
      # Adopt with :none — nothing monitored (the library-migration entry point).
      {:ok, series} = Catalog.add_series(80, monitor_strategy: :none)
      refute series.monitored
      assert Enum.all?(episodes(series.id), &(&1.monitored == false))

      # Flip to :future — same distribution add_series(:future) produces (2 monitored:
      # un-aired + undated; the aired regular and the special stay off), series + seasons on.
      assert {:ok, series} = Catalog.set_series_monitor_strategy(series, :future)
      assert series.monitor_strategy == :future
      assert series.monitored
      assert Enum.all?(loaded(series.id).seasons, & &1.monitored)
      assert Enum.count(episodes(series.id), & &1.monitored) == 2
      assert Repo.get_by!(Episode, tmdb_episode_id: 900).monitored == false

      # Flip to :all — every regular monitored, specials still explicit-only.
      assert {:ok, series} = Catalog.set_series_monitor_strategy(series, :all)
      assert Enum.all?(episodes(series.id), &(&1.monitored == (&1.classification == :regular)))

      # Flip back to :none — whole tree off again.
      assert {:ok, series} = Catalog.set_series_monitor_strategy(series, :none)
      refute series.monitored
      refute Enum.any?(loaded(series.id).seasons, & &1.monitored)
      assert Enum.all?(episodes(series.id), &(&1.monitored == false))
    end

    test "set_series_monitor_strategy/2 rejects an unknown strategy" do
      stub_tmdb(81)
      {:ok, series} = Catalog.add_series(81, monitor_strategy: :none)

      assert {:error, :invalid_monitor_strategy} =
               Catalog.set_series_monitor_strategy(series, :bogus)
    end
  end

  describe "find-or-create + getters" do
    test "returns the existing series without re-fetching TMDB" do
      stub_tmdb(46)
      {:ok, first} = Catalog.add_series(46)

      # No further expect/3 — verify_on_exit! proves TMDB is not called again.
      assert {:ok, second} = Catalog.add_series(46)
      assert second.id == first.id
    end

    test "get_series_by_tmdb_id/1 and list_series/0" do
      stub_tmdb(47)
      {:ok, series} = Catalog.add_series(47)

      assert Catalog.get_series_by_tmdb_id(47).id == series.id
      assert Catalog.get_series_by_tmdb_id(-1) == nil
      assert [%Series{tmdb_id: 47}] = Catalog.list_series()
    end

    test "a failed TMDB fetch persists nothing" do
      expect(Cinder.Catalog.TMDBMock, :get_series, fn 48 -> {:error, :timeout} end)

      assert {:error, :timeout} = Catalog.add_series(48)
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

      expect(Cinder.Catalog.TMDBMock, :get_season, 2, fn 49, n, "en" ->
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

      assert {:error, :timeout} = Catalog.add_series(49)
      assert Catalog.get_series_by_tmdb_id(49) == nil
    end

    test "rejects an unknown monitor_strategy without calling TMDB" do
      # No expect/3 — verify_on_exit! proves TMDB is never reached.
      assert {:error, :invalid_monitor_strategy} =
               Catalog.add_series(50, monitor_strategy: :bogus)

      assert Catalog.get_series_by_tmdb_id(50) == nil
    end
  end

  describe "search_tv/1" do
    test "a blank/whitespace query short-circuits without calling TMDB" do
      # No expect/3 — verify_on_exit! proves search_tv is never reached.
      assert Catalog.search_tv("   ") == {:ok, []}
    end

    test "delegates a real query to the TMDB behaviour" do
      expect(Cinder.Catalog.TMDBMock, :search_tv, fn "the wire", "en" ->
        {:ok, [%{tmdb_id: 1}]}
      end)

      assert {:ok, [%{tmdb_id: 1}]} = Catalog.search_tv("the wire")
    end
  end

  describe "get_series_with_tree/1" do
    test "loads the series with seasons and episodes in order" do
      stub_tmdb(60)
      {:ok, series} = Catalog.add_series(60)

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
      {:ok, series} = Catalog.add_series(61, monitor_strategy: :none)
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
      {:ok, series} = Catalog.add_series(62, monitor_strategy: :none)
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
    test "add_series stores original_language and the chosen preferred_language" do
      stub_tmdb_series(original_language: "fr")

      {:ok, series} =
        Catalog.add_series(42,
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

      stub(Cinder.Catalog.TMDBMock, :get_season, fn 1399, n, locale ->
        {:ok,
         %{
           season_number: n,
           episodes: [
             %{
               tmdb_episode_id: n * 10 + 1,
               episode_number: 1,
               title: if(locale == "en", do: "e1", else: ""),
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

    test "an Anime series' Audio pick is release policy — a later requester pick never fills it" do
      {:ok, _} = Catalog.find_or_create_series_at_requested(1399, 1, "original", :anime)
      {:ok, series} = Catalog.find_or_create_series_at_requested(1399, 2, "french", :anime)
      assert series.preferred_language == "original"
    end

    test "a request converting an :auto series to Anime also establishes its pick" do
      {:ok, series} = Catalog.find_or_create_series_at_requested(1399, 1)
      assert series.media_profile == :auto
      assert series.preferred_language == "original"

      {:ok, series} = Catalog.find_or_create_series_at_requested(1399, 2, "french", :anime)
      assert series.media_profile == :anime
      assert series.preferred_language == "french"
    end
  end

  # Creates a series with one monitored, aired, file-less episode — i.e. a wanted episode.
  # Creates a series whose season has multiple wanted (monitored, aired, file-less) episodes.
  defp series_with_wanted_episodes(opts) do
    season_num = Keyword.get(opts, :season, 1)
    numbers = Keyword.get(opts, :numbers, [1])
    series = series_fixture(%{monitor_strategy: :all})
    season = season_fixture(series, %{season_number: season_num})
    Enum.each(numbers, fn n -> episode_fixture(season, %{episode_number: n}) end)
    series
  end

  # Creates a series whose season has all episodes with files — nothing wanted.
  defp series_with_available_season(opts) do
    season_num = Keyword.get(opts, :season, 1)
    series = series_fixture(%{monitor_strategy: :all})
    season = season_fixture(series, %{season_number: season_num})
    episode_fixture(season, %{episode_number: 1, file_path: "/media/ep1.mkv"})
    series
  end

  describe "available_season_keys/1" do
    test "a season is available only when every aired episode has a file" do
      series = series_fixture(%{monitor_strategy: :all})
      s1 = season_fixture(series, %{season_number: 1})
      episode_fixture(s1, %{episode_number: 1, file_path: "/media/s01e01.mkv"})
      episode_fixture(s1, %{episode_number: 2, file_path: "/media/s01e02.mkv"})
      s2 = season_fixture(series, %{season_number: 2})
      episode_fixture(s2, %{episode_number: 1, file_path: "/media/s02e01.mkv"})
      episode_fixture(s2, %{episode_number: 2})
      # A :future-style season: only the newest episode monitored+imported. The 90%-absent
      # season must NOT read Available (that would hide the Request affordance).
      s3 = season_fixture(series, %{season_number: 3})
      episode_fixture(s3, %{episode_number: 1, monitored: false})
      episode_fixture(s3, %{episode_number: 2, file_path: "/media/s03e02.mkv"})

      keys = Cinder.Catalog.available_season_keys()
      assert {series.tmdb_id, 1} in keys
      refute {series.tmdb_id, 2} in keys
      refute {series.tmdb_id, 3} in keys

      # The scoped variant returns the same keys for that series only.
      assert {series.tmdb_id, 1} in Cinder.Catalog.available_season_keys(series.tmdb_id)
    end

    test "count_wanted_episodes/2 scopes to one season" do
      series = series_fixture(%{monitor_strategy: :all})
      s1 = season_fixture(series, %{season_number: 1})
      episode_fixture(s1, %{episode_number: 1})
      episode_fixture(s1, %{episode_number: 2, file_path: "/media/have.mkv"})
      s2 = season_fixture(series, %{season_number: 2})
      episode_fixture(s2, %{episode_number: 1})

      assert Cinder.Catalog.count_wanted_episodes(series.id, 1) == 1
      assert Cinder.Catalog.count_episodes(series.id, 1) == 2
    end
  end

  describe "manual_grab_tv/3" do
    test "creates a grab over the season's still-wanted episodes the release covers" do
      series = series_with_wanted_episodes(season: 1, numbers: [1, 2, 3])

      release = %Cinder.Acquisition.Release{
        title: "S01 Pack",
        protocol: :torrent,
        season: 1,
        episodes: nil,
        download_url: "magnet:?x"
      }

      Cinder.Download.ClientMock |> expect(:add, fn _, _opts -> {:ok, "dl-tv"} end)

      assert {:ok, grab} = Cinder.Catalog.manual_grab_tv(series, 1, release)
      grab = Cinder.Repo.preload(grab, :episodes)
      assert Enum.map(grab.episodes, & &1.episode_number) |> Enum.sort() == [1, 2, 3]
    end

    test "resets search_attempts so the user-chosen release gets a fresh budget" do
      series = series_with_wanted_episodes(season: 1, numbers: [1])
      # Search-parked (at the cap) — a manual grab must still work and re-open the budget,
      # which also keeps the counter from ever exceeding the cap (the crossing check's ==).
      Cinder.Repo.update_all(Cinder.Catalog.Episode, set: [search_attempts: 10])

      release = %Cinder.Acquisition.Release{
        title: "S01E01",
        protocol: :torrent,
        season: 1,
        episodes: [1],
        download_url: "magnet:?x"
      }

      Cinder.Download.ClientMock |> expect(:add, fn _, _opts -> {:ok, "dl-tv-reset"} end)

      assert {:ok, grab} = Cinder.Catalog.manual_grab_tv(series, 1, release)
      grab = Cinder.Repo.preload(grab, :episodes)
      assert [%{search_attempts: 0}] = grab.episodes
    end

    test "returns :nothing_wanted when the season has no wanted episodes" do
      series = series_with_available_season(season: 1)

      release = %Cinder.Acquisition.Release{
        title: "S01",
        protocol: :torrent,
        season: 1,
        episodes: nil
      }

      assert Cinder.Catalog.manual_grab_tv(series, 1, release) == {:error, :nothing_wanted}
    end

    # FIX 3: client.add happens before create_grab. If a concurrent sweep grabs the episodes
    # during the add (create_grab rolls back :no_episodes_linked), the just-added download must be
    # removed so it isn't orphaned in the client. The mock's add callback simulates that race by
    # grabbing the episodes itself before returning.
    test "removes the just-added download when create_grab rolls back (:no_episodes_linked)" do
      series = series_with_wanted_episodes(season: 1, numbers: [1, 2, 3])

      release = %Cinder.Acquisition.Release{
        title: "S01 Pack",
        protocol: :torrent,
        season: 1,
        episodes: nil,
        download_url: "magnet:?x"
      }

      Cinder.Download.ClientMock
      |> expect(:add, fn _, _opts ->
        ids = Catalog.wanted_episodes() |> Enum.map(& &1.id)
        {:ok, _other} = Catalog.create_grab("H-concurrent", :torrent, ids)
        {:ok, "dl-tv"}
      end)
      |> expect(:remove, fn "dl-tv", _opts -> :ok end)

      assert Cinder.Catalog.manual_grab_tv(series, 1, release) == {:error, :no_episodes_linked}
    end

    test "Anime grabs use the candidate's exact version-2 stable IDs, including episode zero" do
      series = series_fixture(%{media_profile: :anime, monitor_strategy: :all})
      season = season_fixture(series, %{season_number: 0})

      episode_zero =
        episode_fixture(season, %{episode_number: 0, classification: :story_special})

      other_special =
        episode_fixture(season, %{episode_number: 1, classification: :story_special})

      context = Catalog.anime_series_acquisition_context(series)
      candidate = Release.new(%{title: "[Group] Show S00E00 [1080p]", download_url: "anime-0"})

      assert {:ok, %{assignments: [%{release: release}]}} =
               Anime.select_episodes(
                 [candidate],
                 context,
                 [episode_zero.id, other_special.id],
                 []
               )

      expect(Cinder.Download.ClientMock, :add, fn _, _opts -> {:ok, "anime-zero"} end)

      assert {:ok, grab} = Catalog.manual_grab_tv(series, 0, release)
      assert [linked] = grab |> Cinder.Repo.preload(:episodes) |> Map.fetch!(:episodes)
      assert linked.id == episode_zero.id
    end

    test "an unmarked Anime candidate is rejected before download client I/O" do
      series = series_fixture(%{media_profile: :anime, monitor_strategy: :all})
      season = season_fixture(series, %{season_number: 0})

      special =
        episode_fixture(season, %{episode_number: 0, classification: :story_special})

      release = %Release{
        title: "[Group] Show S00E00 [1080p]",
        protocol: :torrent,
        download_url: "unsafe",
        resolved_episode_ids: [special.id]
      }

      expect(Cinder.Download.ClientMock, :add, 0, fn _, _opts -> {:ok, "must-not-run"} end)

      assert {:error, :unsafe_anime_mapping} = Catalog.manual_grab_tv(series, 0, release)
    end

    test "a structurally invalid Anime snapshot is reported as unsafe before client I/O" do
      series = series_fixture(%{media_profile: :anime, monitor_strategy: :all})
      season = season_fixture(series, %{season_number: 0})

      special =
        episode_fixture(season, %{episode_number: 0, classification: :story_special})

      release = %Release{
        title: "[Group] Show S00E00 [1080p]",
        protocol: :torrent,
        download_url: "malformed",
        resolved_episode_ids: [special.id],
        mapping_snapshot: %{"version" => 2, "reserved_episode_ids" => [special.id]}
      }

      expect(Cinder.Download.ClientMock, :add, 0, fn _, _opts -> {:ok, "must-not-run"} end)

      assert {:error, :unsafe_anime_mapping} = Catalog.manual_grab_tv(series, 0, release)
    end

    test "a malformed Anime snapshot cannot reconcile an existing intent or reach client I/O" do
      series = series_fixture(%{media_profile: :anime, monitor_strategy: :all})
      season = season_fixture(series, %{season_number: 0})

      special =
        episode_fixture(season, %{episode_number: 0, classification: :story_special})

      context = Catalog.anime_series_acquisition_context(series)

      candidate =
        Release.new(%{title: "[Group] Show S00E00 [1080p]", download_url: "existing-anime"})

      assert {:ok, %{assignments: [%{release: valid_release}]}} =
               Anime.select_episodes([candidate], context, [special.id], [])

      assert {:ok, _intent} =
               Cinder.Download.reserve_intent(%{
                 kind: :episode,
                 target_id: special.id,
                 episode_ids: [special.id],
                 protocol: valid_release.protocol,
                 release: valid_release,
                 mapping_snapshot: valid_release.mapping_snapshot
               })

      malformed = %{
        valid_release
        | mapping_snapshot: %{"version" => 2, "reserved_episode_ids" => [special.id]}
      }

      expect(Cinder.Download.ClientMock, :find_by_operation_key, 0, fn _ -> :not_found end)
      expect(Cinder.Download.ClientMock, :add, 0, fn _, _opts -> {:ok, "must-not-run"} end)

      assert {:error, :unsafe_anime_mapping} = Catalog.manual_grab_tv(series, 0, malformed)
    end

    test "a marked Anime release cannot fall through the Standard whole-season manual path" do
      series = series_with_wanted_episodes(season: 1, numbers: [1, 2])

      release = %Release{
        title: "[Group] Stale Anime Pack",
        protocol: :torrent,
        episodes: nil,
        download_url: "stale-anime",
        mapping_snapshot: %{"version" => 2, "reserved_episode_ids" => [1, 2]}
      }

      expect(Cinder.Download.ClientMock, :add, 0, fn _, _opts -> {:ok, "must-not-run"} end)

      assert {:error, :unsafe_anime_mapping} = Catalog.manual_grab_tv(series, 1, release)
    end
  end

  describe "search_now" do
    test "search_season_now zeros search_attempts on that season's wanted episodes only" do
      series = series_fixture(%{monitor_strategy: :all})
      s1 = season_fixture(series, %{season_number: 1})
      s2 = season_fixture(series, %{season_number: 2})
      e1 = episode_fixture(s1, %{search_attempts: 9})
      e2 = episode_fixture(s2, %{search_attempts: 9})

      assert :ok = Catalog.search_season_now(s1)
      # Scoped: the other season's parked episode is untouched.
      assert Repo.get(Episode, e1.id).search_attempts == 0
      assert Repo.get(Episode, e2.id).search_attempts == 9
    end

    test "search_episode_now is a no-op on an episode that already has a file" do
      series = series_fixture(%{monitor_strategy: :all})
      season = season_fixture(series, %{season_number: 1})
      ep = episode_fixture(season, %{file_path: "/lib/x.mkv", search_attempts: 9})
      assert Catalog.search_episode_now(ep) in [:ok, {:ok, ep}]
      assert Repo.get(Episode, ep.id).search_attempts == 9
    end
  end
end
