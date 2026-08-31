defmodule CinderWeb.HealthControllerStaleTest do
  @moduledoc """
  /healthz's staleness check, exercised with `:start_poller` deliberately flipped on — the plain
  `health_controller_test.exs` covers the default (pollers disabled in test) 200 path. Each
  poller's `:persistent_term` last-tick stamp is set directly, so no real GenServer needs to run.
  async: false: `:start_poller` is a global Application env key.
  """
  use CinderWeb.ConnCase, async: false

  alias Cinder.Download.{BookPoller, Poller, TvPoller}

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
    for module <- [Poller, TvPoller, BookPoller], key <- [:last_run, :started_at] do
      :persistent_term.erase({module, key})
    end
  end

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
end
