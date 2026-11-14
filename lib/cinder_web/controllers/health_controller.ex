defmodule CinderWeb.HealthController do
  @moduledoc """
  Truthful liveness check, no DB call and fast (reads `:persistent_term` and each poller's
  progress store via its `status/0`, plus one filesystem stat of the database volume). Returns
  200 "ok" when every enabled poller is healthy (or polling is disabled) AND the database volume
  has room; otherwise 503 with a short plain-text reason. A poller is judged by one of two rules:

  - While a tick is in flight: healthy as long as the tick made progress within the last
    10 minutes. Progress is a unit (`isolate/2`, nested ones included) starting or finishing, or
    an HTTP request of the tick starting or ending (`Cinder.Download.PollerProgress`). Past that,
    503 "<poller> stuck: tick in flight with no progress ...". One tick that searches many titles
    one after another runs for minutes, so the end of the last tick says nothing about a tick
    that keeps moving (#1294).
  - While idle between ticks: 503 "<poller> stale: last tick ..." once its last tick ended more
    than 3 poll intervals ago, or "<poller> stale: no tick since start ..." once it started more
    than 3 intervals ago and no tick has ended since. A (re)started poller clears the in-flight
    state its killed process left, so a crash-looping poller falls under this rule.

  Two failure modes it catches that would otherwise read "ok": a wedged/crash-looping poller, and
  a FULL database volume — when the volume holding `cinder.db` + its `-wal` fills, every pipeline
  status write raises SQLITE_FULL, the pollers' `isolate` swallows it, and their ticks keep
  completing, so the staleness check alone would stay green while the pipeline is wedged.
  """

  use CinderWeb, :controller

  alias Cinder.Download.{BookPoller, Poller, PollerProgress, TvPoller}

  @pollers [Poller, TvPoller, BookPoller]

  # An idle poller is "stale" once its last tick ended more than this many poll intervals ago —
  # generous enough that one errored tick doesn't flap the check, but a crash-looping poller, or
  # one whose process is gone, still surfaces within a few intervals. A long tick is judged by its
  # progress instead (@stuck_after_ms).
  @stale_multiplier 3

  # A tick in flight is "stuck" once no unit or HTTP request of it has started or finished for this
  # long. Each HTTP request ends within its 60 s deadline (`Cinder.HTTPPolicy.bounded_request/2`),
  # so only a call with no deadline, such as a cross-filesystem staging copy, gets this far.
  @stuck_after_ms :timer.minutes(10)

  # Hard floor of free space on the database volume. Below it, SQLite writes are about to start
  # failing with SQLITE_FULL, so report unhealthy. Fixed here (not a /settings field) so the probe
  # never depends on the very DB it is guarding.
  @db_floor_bytes 100 * 1024 * 1024

  def show(conn, _params) do
    case unhealthy_reason() do
      nil -> text(conn, "ok")
      reason -> conn |> put_status(503) |> text(reason)
    end
  end

  # Poller staleness is gated on `:start_poller` (a deploy with polling intentionally off must not
  # fail on it); the database-volume floor runs regardless — a full DB volume wedges web writes too.
  defp unhealthy_reason, do: poller_reason() || db_volume_reason()

  defp poller_reason do
    if Application.get_env(:cinder, :start_poller, true), do: stale_reason()
  end

  # Fail OPEN on any uncertainty (unknown path, unreadable `df`): only a positive low-space reading
  # trips the check, so a probe glitch never flaps the container's health.
  defp db_volume_reason do
    case Cinder.Disk.db_free_bytes() do
      {:ok, free} when free < @db_floor_bytes ->
        "database volume low: #{free} bytes free (floor #{@db_floor_bytes})"

      _ ->
        nil
    end
  end

  defp stale_reason, do: Enum.find_value(@pollers, &poller_stale_reason/1)

  defp poller_stale_reason(module) do
    case module.status() do
      %{tick_in_flight?: true, last_progress_at: progress_at} ->
        stuck_if(progress_at, module)

      %{last_run_at: last_run_at, started_at: started_at, interval: interval} ->
        stale_if(last_run_at, started_at, interval, module)
    end
  end

  # A tick in flight: healthy while it keeps making progress, whatever its length.
  defp stuck_if(progress_at, module) do
    age_ms = PollerProgress.now_ms() - progress_at

    if age_ms > @stuck_after_ms do
      "#{poller_name(module)} stuck: tick in flight with no progress for #{age_ms}ms " <>
        "(limit #{@stuck_after_ms}ms)"
    end
  end

  # Idle, and completed at least one tick: stale once its last success is more than the limit old.
  defp stale_if(%DateTime{} = last_run_at, _started_at, interval, module),
    do: over_limit(last_run_at, interval, module, "last tick")

  # Idle, never completed a tick, but the worker HAS started: healthy only within the first-tick
  # grace window (`@stale_multiplier` intervals since start). A first tick that wedges or
  # crash-loops before ever completing surfaces as stale instead of leaving the container healthy
  # forever; one still in flight is judged by `stuck_if/2` above.
  defp stale_if(nil, %DateTime{} = started_at, interval, module),
    do: over_limit(started_at, interval, module, "no tick since start")

  # No start time recorded yet (the razor-thin window before `init/1` stamps it, or polling not
  # actually running) — nothing to judge; treat as healthy.
  defp stale_if(nil, nil, _interval, _module), do: nil

  defp over_limit(since, interval, module, label) do
    age_ms = DateTime.diff(DateTime.utc_now(), since, :millisecond)
    limit_ms = interval * @stale_multiplier

    if age_ms > limit_ms do
      "#{poller_name(module)} stale: #{label} #{age_ms}ms ago (limit #{limit_ms}ms)"
    end
  end

  defp poller_name(module), do: module |> Module.split() |> List.last()
end
