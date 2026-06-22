defmodule Cinder.Catalog.RefresherTest do
  use Cinder.DataCase, async: false

  import Mox

  @moduletag :capture_log

  alias Cinder.Catalog.Refresher
  alias Cinder.Catalog.{Season, Series}

  # The Refresher runs in its own process, so the mock must be global; shared Sandbox
  # (async: false) lets that process use the test-owned DB connection.
  setup :set_mox_global
  setup :verify_on_exit!

  test "poll refreshes every monitored series and skips unmonitored ones" do
    monitored =
      Repo.insert!(%Series{tmdb_id: 8001, title: "M", monitored: true, monitor_strategy: :all})

    Repo.insert!(%Season{series_id: monitored.id, season_number: 1, monitored: true})
    Repo.insert!(%Series{tmdb_id: 8002, title: "U", monitored: false, monitor_strategy: :none})

    # Only 8001 is fetched; a stray get_series(8002) would fail verify_on_exit! (no expectation).
    expect(Cinder.Catalog.TMDBMock, :get_series, fn 8001 ->
      {:ok,
       %{
         tmdb_id: 8001,
         tvdb_id: nil,
         title: "M",
         year: nil,
         poster_path: nil,
         seasons: [%{season_number: 1}]
       }}
    end)

    expect(Cinder.Catalog.TMDBMock, :get_season, fn 8001, 1 ->
      {:ok, %{season_number: 1, episodes: []}}
    end)

    start_supervised!({Refresher, interval: 60_000})
    assert :ok = Refresher.poll()
  end

  test "an error refreshing one series does not abort the tick" do
    Repo.insert!(%Series{tmdb_id: 8101, title: "A", monitored: true, monitor_strategy: :all})
    b = Repo.insert!(%Series{tmdb_id: 8102, title: "B", monitored: true, monitor_strategy: :all})
    Repo.insert!(%Season{series_id: b.id, season_number: 1, monitored: true})

    stub(Cinder.Catalog.TMDBMock, :get_series, fn
      8101 ->
        raise "boom"

      8102 ->
        {:ok,
         %{
           tmdb_id: 8102,
           tvdb_id: nil,
           title: "B",
           year: nil,
           poster_path: nil,
           seasons: [%{season_number: 1}]
         }}
    end)

    stub(Cinder.Catalog.TMDBMock, :get_season, fn 8102, 1 ->
      {:ok, %{season_number: 1, episodes: []}}
    end)

    start_supervised!({Refresher, interval: 60_000})
    # The raise on series A is isolated; the tick completes.
    assert :ok = Refresher.poll()
  end
end
