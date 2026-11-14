defmodule CinderWeb.HealthControllerStaleTest do
  @moduledoc """
  /healthz's staleness check, exercised with `:start_poller` deliberately flipped on — the plain
  `health_controller_test.exs` covers the default (pollers disabled in test) 200 path. Each
  poller's `:persistent_term` last-tick stamp is set directly, so no real GenServer needs to run,
  except in the tests of a tick in flight, which run the movie poller with an indexer search that
  waits for the test to release it.
  async: false: `:start_poller` is a global Application env key, and the poller's process calls
  the global Mox mocks.
  """
  use CinderWeb.ConnCase, async: false

  import Cinder.ConfigCase
  import Cinder.PollerHelpers
  import Mox

  alias Cinder.Acquisition.IndexerMock
  alias Cinder.Catalog
  alias Cinder.Download.{BookPoller, Poller, PollerProgress, TvPoller}

  setup :set_mox_global

  setup do
    original_start_poller = Application.get_env(:cinder, :start_poller, true)
    Application.put_env(:cinder, :start_poller, true)
    erase_stamps()

    on_exit(fn ->
      Application.put_env(:cinder, :start_poller, original_start_poller)
      erase_stamps()
    end)

    :ok
  end

  defp erase_stamps do
    for module <- [Poller, TvPoller, BookPoller] do
      :persistent_term.erase({module, :last_run})
      :persistent_term.erase({module, :started_at})
      PollerProgress.reset(module)
    end
  end

  # The movie poller with an hour-long timer, so only the test starts its ticks. `/healthz` reads
  # the 100 ms interval from config, so the idle limit is 300 ms.
  defp start_movie_poller do
    put_env(Poller, interval: 100)
    start_supervised!({Poller, interval: :timer.hours(1), search_retry_after: 0})
  end

  defp request_movies(count) do
    for n <- 1..count do
      {:ok, movie} =
        Catalog.add_movie(%{tmdb_id: 94_000 + n, title: "Busy #{n}", imdb_id: "tt9400#{n}"})

      movie
    end
  end

  # Each movie search sends `{:searching, imdb_id, poller_pid}` and waits until the test sends the
  # poller `{:release, imdb_id}`. A released search finds nothing.
  defp hold_searches do
    test = self()
    stub(IndexerMock, :search_movie_query, fn _query, _opts -> {:ok, []} end)

    stub(IndexerMock, :search, fn imdb_id ->
      send(test, {:searching, imdb_id, self()})

      receive do
        {:release, ^imdb_id} -> {:ok, []}
      end
    end)
  end

  defp await_search(pid) do
    assert_receive {:searching, imdb_id, ^pid}, 5_000
    imdb_id
  end

  # Releases the held search and waits for the tick to end.
  defp finish_tick(pid, imdb_id) do
    send(pid, {:release, imdb_id})
    poll_until(fn -> not Poller.status().tick_in_flight? end, timeout: 10_000)
  end

  defp healthz(conn), do: get(conn, ~p"/healthz")

  defp eleven_minutes_ago, do: PollerProgress.now_ms() - :timer.minutes(11)

  test "returns 200 when every enabled poller has ticked recently", %{conn: conn} do
    :persistent_term.put({Poller, :last_run}, DateTime.utc_now())
    :persistent_term.put({TvPoller, :last_run}, DateTime.utc_now())
    :persistent_term.put({BookPoller, :last_run}, DateTime.utc_now())

    conn = get(conn, ~p"/healthz")

    assert response(conn, 200) == "ok"
  end

  test "returns 200 when a poller started recently but hasn't completed its first tick", %{
    conn: conn
  } do
    now = DateTime.utc_now()
    :persistent_term.put({Poller, :started_at}, now)
    :persistent_term.put({TvPoller, :started_at}, now)
    :persistent_term.put({BookPoller, :started_at}, now)

    conn = get(conn, ~p"/healthz")

    assert response(conn, 200) == "ok"
  end

  test "returns 200 before a poller has recorded a start time", %{conn: conn} do
    conn = get(conn, ~p"/healthz")

    assert response(conn, 200) == "ok"
  end

  # This is the first-tick blind spot: a worker that started but never completed a tick within the
  # grace window must report unhealthy, not "ok forever".
  test "returns 503 when a poller never completes its first tick within the grace window", %{
    conn: conn
  } do
    :persistent_term.put({Poller, :started_at}, DateTime.add(DateTime.utc_now(), -1_000, :second))
    :persistent_term.put({TvPoller, :started_at}, DateTime.utc_now())
    :persistent_term.put({BookPoller, :started_at}, DateTime.utc_now())
    :persistent_term.put({TvPoller, :last_run}, DateTime.utc_now())
    :persistent_term.put({BookPoller, :last_run}, DateTime.utc_now())

    conn = get(conn, ~p"/healthz")

    body = response(conn, 503)
    assert body =~ "Poller"
    assert body =~ "no tick since start"
  end

  test "returns 503 naming the poller whose last tick is stale", %{conn: conn} do
    stale_at = DateTime.add(DateTime.utc_now(), -1_000, :second)
    :persistent_term.put({Poller, :last_run}, stale_at)
    :persistent_term.put({TvPoller, :last_run}, DateTime.utc_now())
    :persistent_term.put({BookPoller, :last_run}, DateTime.utc_now())

    conn = get(conn, ~p"/healthz")

    body = response(conn, 503)
    assert body =~ "Poller"
    assert body =~ "stale"
    assert body =~ "last tick"
  end

  test "a stale poller is still 200 when polling is disabled", %{conn: conn} do
    Application.put_env(:cinder, :start_poller, false)
    stale_at = DateTime.add(DateTime.utc_now(), -1_000, :second)
    :persistent_term.put({Poller, :last_run}, stale_at)

    conn = get(conn, ~p"/healthz")

    assert response(conn, 200) == "ok"
  end

  describe "a tick in flight (#1294)" do
    @describetag :capture_log

    # The #1294 incident: a tick that searched re-queued movies one after another read stale for
    # minutes. Each search here lasts at least 200 ms, under the 300 ms idle limit, and the two
    # together pass it.
    test "searches that together pass the idle limit read 200 mid-tick", %{conn: conn} do
      pid = start_movie_poller()
      assert :ok = Poller.poll(pid)
      request_movies(3)
      hold_searches()

      send(pid, :poll)

      for _search <- 1..2 do
        imdb_id = await_search(pid)
        Process.sleep(200)
        send(pid, {:release, imdb_id})
      end

      imdb_id = await_search(pid)

      # The idle rule alone would answer 503 here: the last tick ended over 300 ms ago.
      assert DateTime.diff(DateTime.utc_now(), Poller.status().last_run_at, :millisecond) > 300
      assert response(healthz(conn), 200) == "ok"

      finish_tick(pid, imdb_id)
    end

    test "a first tick in flight more than 3 intervals after start reads 200 while it makes " <>
           "progress",
         %{conn: conn} do
      pid = start_movie_poller()
      request_movies(1)
      hold_searches()

      send(pid, :poll)
      imdb_id = await_search(pid)

      :persistent_term.put(
        {Poller, :started_at},
        DateTime.add(DateTime.utc_now(), -1_000, :second)
      )

      assert Poller.status().last_run_at == nil
      assert response(healthz(conn), 200) == "ok"

      finish_tick(pid, imdb_id)
    end

    test "a tick with no progress for over 10 minutes is 503 naming the poller, and 200 once " <>
           "its next unit starts",
         %{conn: conn} do
      pid = start_movie_poller()
      request_movies(2)
      hold_searches()

      send(pid, :poll)
      first = await_search(pid)
      PollerProgress.mark(Poller, PollerProgress.now_ms() - :timer.minutes(9))
      assert response(healthz(conn), 200) == "ok"

      PollerProgress.mark(Poller, eleven_minutes_ago())

      body = response(healthz(conn), 503)
      assert body =~ ~r/^Poller stuck: tick in flight with no progress for \d+ms/
      refute body =~ "last tick"

      send(pid, {:release, first})
      second = await_search(pid)
      assert response(healthz(conn), 200) == "ok"

      finish_tick(pid, second)
    end

    test "a poller restarted after a crash mid-tick is judged by the idle rule", %{conn: conn} do
      pid = start_movie_poller()
      request_movies(1)
      hold_searches()

      send(pid, :poll)
      await_search(pid)
      assert Poller.status().tick_in_flight?

      Process.exit(pid, :kill)
      new_pid = await_restart(Poller, pid)
      # The name registers before init/1 runs; this returns once init/1 has.
      :sys.get_state(new_pid)

      # The killed tick's last progress is fresh, so only the idle rule can fail the new worker.
      :persistent_term.put(
        {Poller, :started_at},
        DateTime.add(DateTime.utc_now(), -1_000, :second)
      )

      assert response(healthz(conn), 503) =~ ~r/^Poller stale: no tick since start/
    end

    test "a stuck tick is still 200 when polling is disabled", %{conn: conn} do
      PollerProgress.tick_started(Poller, eleven_minutes_ago())
      assert response(healthz(conn), 503) =~ "Poller stuck"

      Application.put_env(:cinder, :start_poller, false)

      assert response(healthz(conn), 200) == "ok"
    end

    test "a full database volume is 503 while a tick in flight makes progress", %{conn: conn} do
      PollerProgress.tick_started(Poller)
      assert response(healthz(conn), 200) == "ok"

      put_env(:disk_stats_stub, {:ok, %{free_bytes: 50_000_000, total_bytes: 10_000_000_000}})

      assert response(healthz(conn), 503) =~ "database volume low"
    end
  end
end
