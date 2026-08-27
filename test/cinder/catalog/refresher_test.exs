defmodule Cinder.Catalog.RefresherTest do
  use Cinder.DataCase, async: false

  import Mox
  import ExUnit.CaptureLog

  @moduletag :capture_log

  alias Cinder.Catalog
  alias Cinder.Catalog.{Episode, Movie, Season, Series}
  alias Cinder.Catalog.Refresher
  alias Cinder.Requests.Request
  alias Cinder.Settings

  import Cinder.AccountsFixtures

  @localization_resync_key "localization_resync_v1"
  @localization_trim_key "localization_trim_v1"

  # The Refresher runs in its own process, so the mock must be global; shared Sandbox
  # (async: false) lets that process use the test-owned DB connection.
  setup :set_mox_global
  setup :verify_on_exit!

  # A poll stamps last-run into process-global :persistent_term (PollerSkeleton.status/0); erase it
  # so a recorded run can't bleed into another suite that reads Cinder.Jobs.statuses/0.
  setup do
    on_exit(fn -> :persistent_term.erase({Refresher, :last_run}) end)
    :ok
  end

  setup do
    stub(Cinder.Catalog.TMDBMock, :get_series_alternative_titles, fn _ -> {:ok, []} end)
    stub(Cinder.Catalog.TMDBMock, :get_episode_groups, fn _ -> {:ok, []} end)
    Settings.put(@localization_resync_key, "true")
    :ok
  end

  test "poll refreshes globally monitored series and skips fully unmonitored ones" do
    monitored =
      Repo.insert!(%Series{tmdb_id: 8001, title: "M", monitored: true, monitor_strategy: :all})

    Repo.insert!(%Season{series_id: monitored.id, season_number: 1, monitored: true})

    Repo.insert!(%Series{
      tmdb_id: 8002,
      title: "U",
      monitored: false,
      monitor_strategy: :none,
      localizations: %{"fr" => %{"title" => "U"}}
    })

    owner = self()

    stub(Cinder.Catalog.TMDBMock, :get_series, fn
      8001 ->
        {:ok,
         %{
           tmdb_id: 8001,
           tvdb_id: nil,
           title: "M",
           year: nil,
           poster_path: nil,
           original_language: nil,
           seasons: [%{season_number: 1}]
         }}

      8002 ->
        send(owner, {:unexpected_refresh, 8002})
        {:error, :unexpected_refresh}
    end)

    expect(Cinder.Catalog.TMDBMock, :get_season, fn 8001, 1, "en" ->
      {:ok, %{season_number: 1, episodes: []}}
    end)

    stub(Cinder.Catalog.TMDBMock, :get_season, fn 8001, 1, "fr" ->
      {:ok, %{season_number: 1, episodes: []}}
    end)

    start_supervised!({Refresher, interval: 60_000})
    assert :ok = Refresher.poll()
    refute_receive {:unexpected_refresh, 8002}
  end

  test "poll refreshes a directly monitored episode under an unmonitored series" do
    series =
      Repo.insert!(%Series{
        tmdb_id: 8003,
        title: "Direct",
        monitored: false,
        monitor_strategy: :none,
        localizations: %{"fr" => %{"title" => "Direct"}}
      })

    season =
      Repo.insert!(%Season{series_id: series.id, season_number: 1, monitored: false})

    episode =
      Repo.insert!(%Episode{
        season_id: season.id,
        tmdb_episode_id: 80_031,
        episode_number: 1,
        title: "TBA",
        air_date: nil,
        monitored: true
      })

    skipped_series =
      Repo.insert!(%Series{
        tmdb_id: 8004,
        title: "Skipped",
        monitored: false,
        monitor_strategy: :none,
        localizations: %{"fr" => %{"title" => "Skipped"}}
      })

    skipped_season =
      Repo.insert!(%Season{
        series_id: skipped_series.id,
        season_number: 1,
        monitored: false
      })

    Repo.insert!(%Episode{
      season_id: skipped_season.id,
      tmdb_episode_id: 80_041,
      episode_number: 1,
      monitored: false
    })

    owner = self()

    stub(Cinder.Catalog.TMDBMock, :get_series, fn
      8003 ->
        {:ok,
         %{
           tmdb_id: 8003,
           tvdb_id: nil,
           title: "Direct",
           year: nil,
           poster_path: nil,
           original_language: nil,
           seasons: [%{season_number: 1}]
         }}

      8004 ->
        send(owner, {:unexpected_refresh, 8004})
        {:error, :unexpected_refresh}
    end)

    refute Enum.any?(Catalog.wanted_episodes(), &(&1.id == episode.id))

    expect(Cinder.Catalog.TMDBMock, :get_season, fn 8003, 1, "en" ->
      {:ok,
       %{
         season_number: 1,
         episodes: [
           %{
             tmdb_episode_id: 80_031,
             episode_number: 1,
             title: "Aired",
             air_date: ~D[2020-01-01]
           }
         ]
       }}
    end)

    stub(Cinder.Catalog.TMDBMock, :get_season, fn 8003, 1, "fr" ->
      {:ok, %{season_number: 1, episodes: []}}
    end)

    start_supervised!({Refresher, interval: 60_000})
    assert :ok = Refresher.poll()

    assert Repo.reload!(episode).air_date == ~D[2020-01-01]
    assert Enum.any?(Catalog.wanted_episodes(), &(&1.id == episode.id))
    refute Repo.reload!(series).monitored
    refute_receive {:unexpected_refresh, 8004}
  end

  test "poll refreshes an empty directly monitored season under an unmonitored series" do
    series =
      Repo.insert!(%Series{
        tmdb_id: 8005,
        title: "Empty season",
        monitored: false,
        monitor_strategy: :none,
        localizations: %{"fr" => %{"title" => "Empty season"}}
      })

    season =
      Repo.insert!(%Season{series_id: series.id, season_number: 1, monitored: true})

    expect(Cinder.Catalog.TMDBMock, :get_series, fn 8005 ->
      {:ok,
       %{
         tmdb_id: 8005,
         tvdb_id: nil,
         title: "Empty season",
         year: nil,
         poster_path: nil,
         original_language: nil,
         seasons: [%{season_number: 1}]
       }}
    end)

    expect(Cinder.Catalog.TMDBMock, :get_season, fn 8005, 1, "en" ->
      {:ok,
       %{
         season_number: 1,
         episodes: [
           %{
             tmdb_episode_id: 80_051,
             episode_number: 1,
             title: "New",
             air_date: ~D[2020-01-01]
           }
         ]
       }}
    end)

    stub(Cinder.Catalog.TMDBMock, :get_season, fn 8005, 1, "fr" ->
      {:ok, %{season_number: 1, episodes: []}}
    end)

    start_supervised!({Refresher, interval: 60_000})
    assert :ok = Refresher.poll()

    episode = Repo.get_by!(Episode, season_id: season.id, tmdb_episode_id: 80_051)
    assert episode.monitored
    assert episode.id in Enum.map(Catalog.wanted_episodes(), & &1.id)
    refute Repo.reload!(series).monitored
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
           original_language: nil,
           seasons: [%{season_number: 1}]
         }}
    end)

    stub(Cinder.Catalog.TMDBMock, :get_season, fn 8102, 1, _locale ->
      {:ok, %{season_number: 1, episodes: []}}
    end)

    start_supervised!({Refresher, interval: 60_000})
    # The raise on series A is isolated; the tick completes.
    assert :ok = Refresher.poll()
  end

  test "logs a warning when a series' refresh fails" do
    s = Repo.insert!(%Series{tmdb_id: 8201, title: "T", monitored: true, monitor_strategy: :all})

    # A {:error, reason} short-circuits before any write — it does not raise, so isolate/2
    # wouldn't catch it. do_poll must log it explicitly.
    stub(Cinder.Catalog.TMDBMock, :get_series, fn 8201 -> {:error, :timeout} end)

    start_supervised!({Refresher, interval: 60_000})

    log = capture_log(fn -> assert :ok = Refresher.poll() end)
    assert log =~ "refresh failed"
    assert log =~ "series #{s.id}"
  end

  test "a concurrent series cancellation keeps a newly announced season unmonitored" do
    series =
      Repo.insert!(%Series{
        tmdb_id: 8301,
        title: "T",
        monitored: true,
        monitor_strategy: :all
      })

    Repo.insert!(%Season{series_id: series.id, season_number: 1, monitored: true})
    owner = self()

    expect(Cinder.Catalog.TMDBMock, :get_series, fn 8301 ->
      send(owner, {:refresh_started, self()})

      receive do
        :continue ->
          {:ok,
           %{
             tmdb_id: 8301,
             tvdb_id: nil,
             title: "T",
             year: nil,
             poster_path: nil,
             original_language: nil,
             seasons: [%{season_number: 1}, %{season_number: 2}]
           }}
      end
    end)

    stub(Cinder.Catalog.TMDBMock, :get_season, fn 8301, season_number, locale ->
      {:ok,
       %{
         season_number: season_number,
         episodes: [
           %{
             tmdb_episode_id: 83_000 + season_number,
             episode_number: 1,
             title: if(locale == "en", do: "Episode", else: ""),
             air_date: ~D[2026-07-12]
           }
         ]
       }}
    end)

    start_supervised!({Refresher, interval: 60_000})
    refresh = Task.async(fn -> Refresher.poll() end)
    assert_receive {:refresh_started, refresher_pid}, 1_000
    assert {:ok, _} = Catalog.cancel_series(Repo.get!(Series, series.id), nil)
    send(refresher_pid, :continue)
    assert :ok = Task.await(refresh)

    cancelled = Repo.get!(Series, series.id)
    refute cancelled.monitored
    assert cancelled.monitor_strategy == :none

    season = Repo.get_by!(Season, series_id: series.id, season_number: 2)
    refute season.monitored
    refute Repo.get_by!(Episode, season_id: season.id, episode_number: 1).monitored
  end

  test "enriches empty movies, trims stored maps, and copies catalog localizations to requests" do
    movie = Repo.insert!(%Movie{tmdb_id: 8401, title: "Movie", localizations: %{}})

    series =
      Repo.insert!(%Series{
        tmdb_id: 8402,
        title: "Series",
        monitored: false,
        monitor_strategy: :none,
        localizations: %{
          "fr" => %{"title" => "Série"},
          "de" => %{"title" => "Serie"}
        }
      })

    request =
      Repo.insert!(%Request{
        user_id: user_fixture().id,
        target_type: "season",
        target_id: series.tmdb_id,
        season_number: 1,
        title: series.title,
        status: :pending,
        localizations: %{}
      })

    expect(Cinder.Catalog.TMDBMock, :get_movie, fn 8401 ->
      {:ok,
       %{
         tmdb_id: 8401,
         title: "Movie",
         localizations: %{"fr" => %{"title" => "Film"}}
       }}
    end)

    start_supervised!({Refresher, interval: 60_000})
    assert :ok = Refresher.poll()

    assert Repo.reload!(movie).localizations == %{"fr" => %{"title" => "Film"}}
    assert Repo.reload!(series).localizations == %{"fr" => %{"title" => "Série"}}
    assert Repo.reload!(request).localizations == %{"fr" => %{"title" => "Série"}}
  end

  test "one-time localization resync re-enriches non-empty movies before setting its flag" do
    Settings.delete(@localization_resync_key)

    movie =
      Repo.insert!(%Movie{
        tmdb_id: 8501,
        title: "Movie",
        localizations: %{"fr" => %{"title" => "Mauvais titre"}}
      })

    expect(Cinder.Catalog.TMDBMock, :get_movie, fn 8501 ->
      refute Settings.get(@localization_resync_key)

      {:ok,
       %{
         tmdb_id: 8501,
         title: "Movie",
         localizations: %{"fr" => %{"title" => "Titre français"}}
       }}
    end)

    start_supervised!({Refresher, interval: 60_000})
    assert :ok = Refresher.poll()

    assert Repo.reload!(movie).localizations == %{"fr" => %{"title" => "Titre français"}}
    assert Settings.get(@localization_resync_key) == "true"

    assert :ok = Refresher.poll()
    assert Enum.count(Settings.all(), &(&1.key == @localization_resync_key)) == 1
  end

  test "a raising TMDB during a localization backfill does not abort the tick" do
    # The shared setup marks the resync done, so enrich takes the cheap empty-map branch.
    empty_movie = Repo.insert!(%Movie{tmdb_id: 8601, title: "Boom", localizations: %{}})

    # A catalog movie whose translations a still-empty request should inherit. The copy pass runs
    # AFTER enrich in the tick, so its success proves the raising enrich pass was isolated (each
    # backfill pass is wrapped in isolate/2), not fatal to the whole tick.
    Repo.insert!(%Movie{
      tmdb_id: 8602,
      title: "Src",
      localizations: %{"fr" => %{"title" => "Fr"}}
    })

    request =
      Repo.insert!(%Request{
        user_id: user_fixture().id,
        target_type: "movie",
        target_id: 8602,
        title: "Src",
        status: :pending,
        localizations: %{}
      })

    stub(Cinder.Catalog.TMDBMock, :get_movie, fn 8601 -> raise "boom" end)

    start_supervised!({Refresher, interval: 60_000})
    assert :ok = Refresher.poll()

    # The enrich failure was contained: the movie is still empty.
    assert Repo.reload!(empty_movie).localizations == %{}
    # …and the tick continued to the copy pass.
    assert Repo.reload!(request).localizations == %{"fr" => %{"title" => "Fr"}}
  end

  test "the legacy-map trim runs once and then stops re-trimming every tick" do
    bloated =
      Repo.insert!(%Series{
        tmdb_id: 8701,
        title: "T",
        monitored: false,
        monitor_strategy: :none,
        localizations: %{"fr" => %{"title" => "Fr"}, "de" => %{"title" => "De"}}
      })

    refute Settings.get(@localization_trim_key)

    start_supervised!({Refresher, interval: 60_000})
    assert :ok = Refresher.poll()

    # First tick trims the legacy bloat and records the done-flag.
    assert Repo.reload!(bloated).localizations == %{"fr" => %{"title" => "Fr"}}
    assert Settings.get(@localization_trim_key) == "true"

    # A row that re-acquires a non-canonical locale after the flag is set is NOT re-trimmed — the
    # pass is gated, no longer a full-table scan every tick. (New writes never store such a locale,
    # so this can't happen in practice; the direct write here just proves the gate.) Reload first so
    # the changeset diffs off the now-trimmed row and actually persists the re-bloat.
    Repo.reload!(bloated)
    |> Ecto.Changeset.change(
      localizations: %{"fr" => %{"title" => "Fr"}, "de" => %{"title" => "De"}}
    )
    |> Repo.update!()

    assert :ok = Refresher.poll()

    assert Repo.reload!(bloated).localizations == %{
             "fr" => %{"title" => "Fr"},
             "de" => %{"title" => "De"}
           }
  end

  test "completed localization resync skips non-empty maps but keeps empty-map retries" do
    wrong =
      Repo.insert!(%Movie{
        tmdb_id: 8502,
        title: "Wrong",
        localizations: %{"fr" => %{"title" => "Mauvais titre"}}
      })

    empty = Repo.insert!(%Movie{tmdb_id: 8503, title: "Empty", localizations: %{}})

    expect(Cinder.Catalog.TMDBMock, :get_movie, fn 8503 ->
      {:ok,
       %{
         tmdb_id: 8503,
         title: "Empty",
         localizations: %{"fr" => %{"title" => "Titre français"}}
       }}
    end)

    start_supervised!({Refresher, interval: 60_000})
    assert :ok = Refresher.poll()

    assert Repo.reload!(wrong).localizations == %{"fr" => %{"title" => "Mauvais titre"}}
    assert Repo.reload!(empty).localizations == %{"fr" => %{"title" => "Titre français"}}
  end
end
