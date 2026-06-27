defmodule Cinder.CatalogRefreshTest do
  # async: false — refresh_series wraps a Repo.transaction; the SQLite sandbox needs shared mode
  # for nested transactions (same reason as catalog_tv_pipeline_test.exs).
  use Cinder.DataCase, async: false

  import Mox

  @moduletag :capture_log

  alias Cinder.Catalog
  alias Cinder.Catalog.{Episode, Season, Series}

  import Cinder.CatalogFixtures

  setup :verify_on_exit!

  @past ~D[2001-01-01]
  @future ~D[2099-01-01]

  defp series(strategy, attrs \\ %{}) do
    series_fixture(Map.merge(%{monitored: strategy != :none, monitor_strategy: strategy}, attrs))
  end

  defp season(series, number) do
    season_fixture(series, %{season_number: number})
  end

  defp episode(season, attrs) do
    episode_fixture(season, Map.merge(%{episode_number: 1}, attrs))
  end

  # Stub TMDB to return the given seasons. `specs` is [{season_number, [episode_map]}].
  # `info_overrides` lets a test override the get_series fields (e.g. tvdb_id/title/year).
  defp stub_tmdb(series, specs, info_overrides \\ %{}) do
    tmdb_id = series.tmdb_id
    season_numbers = for {n, _} <- specs, do: %{season_number: n}

    info =
      Map.merge(
        %{
          tmdb_id: tmdb_id,
          tvdb_id: nil,
          title: "Show",
          year: 2008,
          poster_path: nil,
          original_language: nil,
          seasons: season_numbers
        },
        info_overrides
      )

    stub(Cinder.Catalog.TMDBMock, :get_series, fn ^tmdb_id -> {:ok, info} end)

    by_number = Map.new(specs)

    stub(Cinder.Catalog.TMDBMock, :get_season, fn ^tmdb_id, n ->
      {:ok, %{season_number: n, episodes: Map.fetch!(by_number, n)}}
    end)
  end

  test "fills a late air_date on a matched episode, preserving monitored" do
    s = series(:future)
    sn = season(s, 1)
    ep = episode(sn, %{tmdb_episode_id: 500, episode_number: 1, air_date: nil, monitored: true})

    stub_tmdb(s, [
      {1, [%{tmdb_episode_id: 500, episode_number: 1, title: "Now Dated", air_date: @past}]}
    ])

    assert {:ok, _} = Catalog.refresh_series(s)

    r = Repo.get!(Episode, ep.id)
    assert r.air_date == @past
    assert r.title == "Now Dated"
    assert r.monitored
    assert is_nil(r.file_path)
  end

  test "updates title/air_date in place but preserves file_path and monitored on a match" do
    s = series(:all)
    sn = season(s, 1)

    ep =
      episode(sn, %{
        tmdb_episode_id: 510,
        episode_number: 1,
        title: "Old",
        monitored: false,
        file_path: "/lib/x.mkv"
      })

    stub_tmdb(s, [
      {1, [%{tmdb_episode_id: 510, episode_number: 1, title: "New", air_date: ~D[2002-02-02]}]}
    ])

    assert {:ok, _} = Catalog.refresh_series(s)
    r = Repo.get!(Episode, ep.id)
    assert r.title == "New"
    assert r.air_date == ~D[2002-02-02]
    assert r.file_path == "/lib/x.mkv"
    refute r.monitored
  end

  test "renumbers a matched episode in place (by tmdb_episode_id), no duplicate row" do
    s = series(:all)
    sn = season(s, 1)
    ep = episode(sn, %{tmdb_episode_id: 520, episode_number: 2})

    # Same tmdb episode, now numbered 5 (no existing E5 → no collision).
    stub_tmdb(s, [
      {1, [%{tmdb_episode_id: 520, episode_number: 5, title: "Moved", air_date: @past}]}
    ])

    assert {:ok, _} = Catalog.refresh_series(s)
    assert Repo.get!(Episode, ep.id).episode_number == 5
    assert Repo.aggregate(from(e in Episode, where: e.season_id == ^sn.id), :count) == 1
  end

  test "inserts a genuinely new episode, applying the series monitor_strategy" do
    s = series(:future)
    sn = season(s, 1)
    episode(sn, %{tmdb_episode_id: 530, episode_number: 1, monitored: false})

    stub_tmdb(s, [
      {1,
       [
         %{tmdb_episode_id: 530, episode_number: 1, title: "Aired", air_date: @past},
         %{tmdb_episode_id: 531, episode_number: 2, title: "Future", air_date: @future}
       ]}
    ])

    assert {:ok, _} = Catalog.refresh_series(s)
    new = Repo.get_by!(Episode, tmdb_episode_id: 531)
    assert new.episode_number == 2
    assert new.monitored, "a future episode is monitored under :future"
  end

  test "inserts a new season and its episodes" do
    s = series(:all)
    s1 = season(s, 1)
    episode(s1, %{tmdb_episode_id: 540, episode_number: 1})

    stub_tmdb(s, [
      {1, [%{tmdb_episode_id: 540, episode_number: 1, title: "E1", air_date: @past}]},
      {2, [%{tmdb_episode_id: 550, episode_number: 1, title: "S2E1", air_date: @future}]}
    ])

    assert {:ok, _} = Catalog.refresh_series(s)
    s2 = Repo.get_by!(Season, series_id: s.id, season_number: 2)
    assert s2.monitored
    assert Repo.get_by!(Episode, tmdb_episode_id: 550).season_id == s2.id
  end

  test "leaves a row that vanished from TMDB untouched" do
    s = series(:all)
    sn = season(s, 1)
    keep = episode(sn, %{tmdb_episode_id: 560, episode_number: 1})
    gone = episode(sn, %{tmdb_episode_id: 561, episode_number: 2, file_path: "/lib/gone.mkv"})

    stub_tmdb(s, [
      {1, [%{tmdb_episode_id: 560, episode_number: 1, title: "Kept", air_date: @past}]}
    ])

    assert {:ok, _} = Catalog.refresh_series(s)
    assert Repo.get!(Episode, gone.id).file_path == "/lib/gone.mkv"
    assert Repo.get!(Episode, keep.id).title == "Kept"
  end

  test "does NOT renumber an episode with an in-flight grab (would mislabel its files)" do
    s = series(:all)
    sn = season(s, 1)
    ep = episode(sn, %{tmdb_episode_id: 800, episode_number: 2})
    {:ok, _grab} = Catalog.create_grab("dl-1", :torrent, [ep.id])

    # TMDB renumbers tmdb 800 from E2 to E5, but it's mid-download — leave it put this pass.
    stub_tmdb(s, [
      {1, [%{tmdb_episode_id: 800, episode_number: 5, title: "Moved", air_date: @past}]}
    ])

    assert {:ok, _} = Catalog.refresh_series(s)

    r = Repo.get!(Episode, ep.id)
    assert r.episode_number == 2, "a grab-owning episode is not renumbered mid-flight"
    refute is_nil(r.grab_id)
    # The skipped episode is not re-inserted as a "new" row.
    assert Repo.aggregate(from(e in Episode, where: e.season_id == ^sn.id), :count) == 1
  end

  test "a TMDB failure returns the error and writes nothing" do
    s = series(:all)
    sn = season(s, 1)
    ep = episode(sn, %{tmdb_episode_id: 570, episode_number: 1, title: "Original"})

    expect(Cinder.Catalog.TMDBMock, :get_series, fn _ -> {:error, :timeout} end)

    assert {:error, :timeout} = Catalog.refresh_series(s)
    assert Repo.get!(Episode, ep.id).title == "Original"
  end

  test "applies a within-season swap cleanly (E1<->E2, both exist)" do
    s = series(:all)
    sn = season(s, 1)
    a = episode(sn, %{tmdb_episode_id: 1, episode_number: 1})
    b = episode(sn, %{tmdb_episode_id: 2, episode_number: 2})

    # tmdb 1 → number 2, tmdb 2 → number 1 (a within-season swap).
    stub_tmdb(s, [
      {1,
       [
         %{tmdb_episode_id: 1, episode_number: 2, title: "A", air_date: @past},
         %{tmdb_episode_id: 2, episode_number: 1, title: "B", air_date: @past}
       ]}
    ])

    assert {:ok, _} = Catalog.refresh_series(s)

    assert Repo.get!(Episode, a.id).episode_number == 2
    assert Repo.get!(Episode, b.id).episode_number == 1
    assert Repo.aggregate(from(e in Episode, where: e.season_id == ^sn.id), :count) == 2
  end

  test "applies a mid-season insertion shift" do
    s = series(:all)
    sn = season(s, 1)
    e10 = episode(sn, %{tmdb_episode_id: 10, episode_number: 1})
    e11 = episode(sn, %{tmdb_episode_id: 11, episode_number: 2})
    e12 = episode(sn, %{tmdb_episode_id: 12, episode_number: 3})

    # Insert a new E2 (tmdb 99); 11 and 12 shift up to 3 and 4.
    stub_tmdb(s, [
      {1,
       [
         %{tmdb_episode_id: 10, episode_number: 1, title: "E1", air_date: @past},
         %{tmdb_episode_id: 99, episode_number: 2, title: "New", air_date: @past},
         %{tmdb_episode_id: 11, episode_number: 3, title: "E3", air_date: @past},
         %{tmdb_episode_id: 12, episode_number: 4, title: "E4", air_date: @past}
       ]}
    ])

    assert {:ok, _} = Catalog.refresh_series(s)

    assert Repo.get!(Episode, e10.id).episode_number == 1
    assert Repo.get!(Episode, e11.id).episode_number == 3
    assert Repo.get!(Episode, e12.id).episode_number == 4
    new = Repo.get_by!(Episode, tmdb_episode_id: 99)
    assert new.episode_number == 2

    numbers =
      Repo.all(from e in Episode, where: e.season_id == ^sn.id, select: e.episode_number)

    assert Enum.sort(numbers) == [1, 2, 3, 4]
  end

  test "backfills the series row (tvdb_id/title/year/poster) from TMDB, preserving monitor fields" do
    s = series(:future, %{tvdb_id: nil, title: "Old", monitored: true, monitor_strategy: :future})
    season(s, 1)

    stub_tmdb(s, [{1, []}], %{tvdb_id: 555, title: "New", year: 2021, poster_path: "/n.jpg"})

    assert {:ok, _} = Catalog.refresh_series(s)

    r = Repo.get!(Series, s.id)
    assert r.tvdb_id == 555
    assert r.title == "New"
    assert r.year == 2021
    assert r.poster_path == "/n.jpg"
    assert r.monitor_strategy == :future
    assert r.monitored
  end

  test "refreshes original_language from TMDB but preserves the user's preferred_language" do
    s = series(:future, %{original_language: "en", preferred_language: "french"})
    season(s, 1)

    stub_tmdb(s, [{1, []}], %{original_language: "ja"})

    assert {:ok, _} = Catalog.refresh_series(s)

    r = Repo.get!(Series, s.id)
    assert r.original_language == "ja"
    assert r.preferred_language == "french"
  end

  # --- Per-season request: monitor_strategy :none + one monitored season ---

  test "new episode in a monitored season is monitored:true even when series strategy is :none" do
    # Mirror what find_or_create_series_at_requested does: series added with :none strategy,
    # then only the requested season flipped to monitored: true.
    s = series(:none)
    sn = Repo.insert!(%Season{series_id: s.id, season_number: 1, monitored: true})
    # One existing episode so the season already exists in DB; TMDB adds a second (new) episode.
    episode(sn, %{tmdb_episode_id: 700, episode_number: 1, monitored: true, air_date: @past})

    stub_tmdb(s, [
      {1,
       [
         %{tmdb_episode_id: 700, episode_number: 1, title: "E1", air_date: @past},
         %{tmdb_episode_id: 701, episode_number: 2, title: "E2", air_date: @past}
       ]}
    ])

    assert {:ok, _} = Catalog.refresh_series(s)

    new_ep = Repo.get_by!(Episode, tmdb_episode_id: 701)
    assert new_ep.monitored, "new episode in a monitored season must be monitored: true"
    wanted_ids = Catalog.wanted_episodes() |> Enum.map(& &1.id)
    assert new_ep.id in wanted_ids, "monitored past-aired episode must appear in wanted_episodes"
  end

  test "new episode in an unmonitored season stays monitored:false (strategy :none, season not flipped)" do
    s = series(:none)
    # Season 1 monitored, season 2 not monitored (never requested).
    _sn1 = Repo.insert!(%Season{series_id: s.id, season_number: 1, monitored: true})
    sn2 = Repo.insert!(%Season{series_id: s.id, season_number: 2, monitored: false})
    episode(sn2, %{tmdb_episode_id: 710, episode_number: 1, monitored: false, air_date: @past})

    stub_tmdb(s, [
      {1, []},
      {2,
       [
         %{tmdb_episode_id: 710, episode_number: 1, title: "S2E1", air_date: @past},
         %{tmdb_episode_id: 711, episode_number: 2, title: "S2E2", air_date: @past}
       ]}
    ])

    assert {:ok, _} = Catalog.refresh_series(s)

    new_ep = Repo.get_by!(Episode, tmdb_episode_id: 711)
    refute new_ep.monitored, "new episode in an unmonitored season must stay monitored: false"
    wanted_ids = Catalog.wanted_episodes() |> Enum.map(& &1.id)
    refute new_ep.id in wanted_ids, "unmonitored episode must not appear in wanted_episodes"
  end

  test "new episode in a monitored season under :all/:future strategy is still monitored (regression)" do
    # Confirms the fix doesn't break the pre-existing :all/:future behavior.
    s = series(:all)
    sn = season(s, 1)
    episode(sn, %{tmdb_episode_id: 720, episode_number: 1, monitored: true, air_date: @past})

    stub_tmdb(s, [
      {1,
       [
         %{tmdb_episode_id: 720, episode_number: 1, title: "E1", air_date: @past},
         %{tmdb_episode_id: 721, episode_number: 2, title: "E2", air_date: @past}
       ]}
    ])

    assert {:ok, _} = Catalog.refresh_series(s)

    new_ep = Repo.get_by!(Episode, tmdb_episode_id: 721)
    assert new_ep.monitored
    wanted_ids = Catalog.wanted_episodes() |> Enum.map(& &1.id)
    assert new_ep.id in wanted_ids
  end

  test "broadcasts {:series_updated, id} on success" do
    s = series(:all)
    season(s, 1)
    stub_tmdb(s, [{1, []}])
    Catalog.subscribe_series()
    id = s.id

    assert {:ok, _} = Catalog.refresh_series(s)
    assert_receive {:series_updated, ^id}
  end

  test "moves a matched episode to a new season in place (cross-season renumber)" do
    s = series(:all)
    s1 = season(s, 1)

    # The episode currently lives in season 1; TMDB now lists it (same tmdb_episode_id) in season 2.
    ep =
      episode(s1, %{
        tmdb_episode_id: 1,
        episode_number: 1,
        title: "Moved",
        file_path: "/lib/m.mkv"
      })

    stub_tmdb(s, [
      {1, []},
      {2, [%{tmdb_episode_id: 1, episode_number: 1, title: "Moved", air_date: @past}]}
    ])

    assert {:ok, _} = Catalog.refresh_series(s)

    s2 = Repo.get_by!(Season, series_id: s.id, season_number: 2)
    r = Repo.get!(Episode, ep.id)
    # Same row, moved across seasons (no duplicate, file_path preserved through park→finalize).
    assert r.season_id == s2.id
    assert r.episode_number == 1
    assert r.file_path == "/lib/m.mkv"
    assert Repo.aggregate(from(e in Episode, where: e.season_id == ^s2.id), :count) == 1
  end

  test "a finalize collision with a vanished row's slot restores the original number (never -id)" do
    s = series(:all)
    sn = season(s, 1)
    # A is renumbered into B's slot (2); B vanished from TMDB so its row still holds (sn, 2).
    a = episode(sn, %{tmdb_episode_id: 1, episode_number: 1, monitored: true, air_date: @past})
    b = episode(sn, %{tmdb_episode_id: 2, episode_number: 2})

    stub_tmdb(s, [
      {1, [%{tmdb_episode_id: 1, episode_number: 2, title: "A", air_date: @past}]}
    ])

    assert {:ok, _} = Catalog.refresh_series(s)

    ra = Repo.get!(Episode, a.id)
    rb = Repo.get!(Episode, b.id)
    # A can't take slot 2 (held by vanished B), so it is restored to its original 1 — NOT the
    # negative park sentinel. B is left untouched.
    assert ra.episode_number == 1
    assert rb.episode_number == 2
    # A stays a valid, grab-able wanted episode (positive number leaks nothing into the poller).
    assert a.id in Enum.map(Catalog.wanted_episodes(), & &1.id)
  end
end
