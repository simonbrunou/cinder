defmodule Cinder.CatalogRefreshTest do
  # async: false — refresh_series wraps a Repo.transaction; the SQLite sandbox needs shared mode
  # for nested transactions (same reason as catalog_tv_pipeline_test.exs).
  use Cinder.DataCase, async: false

  import Mox

  @moduletag :capture_log

  alias Cinder.Catalog
  alias Cinder.Catalog.{Episode, Season, Series}

  setup :verify_on_exit!

  @past ~D[2001-01-01]
  @future ~D[2099-01-01]

  defp series(strategy, attrs \\ %{}) do
    Repo.insert!(
      struct(
        %Series{
          tmdb_id: System.unique_integer([:positive]),
          title: "Show",
          year: 2008,
          monitored: strategy != :none,
          monitor_strategy: strategy
        },
        attrs
      )
    )
  end

  defp season(series, number) do
    Repo.insert!(%Season{series_id: series.id, season_number: number, monitored: true})
  end

  defp episode(season, attrs) do
    Repo.insert!(
      struct(
        %Episode{season_id: season.id, episode_number: 1, monitored: true, air_date: @past},
        attrs
      )
    )
  end

  # Stub TMDB to return the given seasons. `specs` is [{season_number, [episode_map]}].
  defp stub_tmdb(series, specs) do
    tmdb_id = series.tmdb_id
    season_numbers = for {n, _} <- specs, do: %{season_number: n}

    stub(Cinder.Catalog.TMDBMock, :get_series, fn ^tmdb_id ->
      {:ok,
       %{
         tmdb_id: tmdb_id,
         tvdb_id: nil,
         title: "Show",
         year: 2008,
         poster_path: nil,
         seasons: season_numbers
       }}
    end)

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

  test "a TMDB failure returns the error and writes nothing" do
    s = series(:all)
    sn = season(s, 1)
    ep = episode(sn, %{tmdb_episode_id: 570, episode_number: 1, title: "Original"})

    expect(Cinder.Catalog.TMDBMock, :get_series, fn _ -> {:error, :timeout} end)

    assert {:error, :timeout} = Catalog.refresh_series(s)
    assert Repo.get!(Episode, ep.id).title == "Original"
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
end
