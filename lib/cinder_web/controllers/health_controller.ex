defmodule CinderWeb.HealthController do
  @moduledoc """
  Truthful liveness check, no DB call and fast (reads `:persistent_term` via each poller's
  `status/0`, plus one filesystem stat of the database volume). Returns 200 "ok" when every
  enabled poller has ticked recently (or polling is disabled) AND the database volume has room;
  otherwise 503 with a short plain-text reason. Two failure modes it catches that would otherwise
  read "ok": a wedged/crash-looping poller, and a FULL database volume — when the volume holding
  `cinder.db` + its `-wal` fills, every `Catalog.transition` write raises SQLITE_FULL, the
  pollers' `isolate` swallows it, and their ticks keep completing, so the staleness check alone
  would stay green while the pipeline is wedged.
  """

  use CinderWeb, :controller

  alias Cinder.Download.{Poller, TvPoller}

  @pollers [Poller, TvPoller]

  # A tick is "stale" once its last success is more than this many poll intervals old — generous
  # enough that one slow/errored tick doesn't flap the check, but a genuinely wedged poller
  # (crash-looping, or its process gone) still surfaces within a few intervals.
  @stale_multiplier 3

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
    %{last_run_at: last_run_at, started_at: started_at, interval: interval} = module.status()
    stale_if(last_run_at, started_at, interval, module)
  end

  # Completed at least one tick: stale once its last success is more than the limit old.
  defp stale_if(%DateTime{} = last_run_at, _started_at, interval, module),
    do: over_limit(last_run_at, interval, module, "last tick")

  # Never completed a tick, but the worker HAS started: healthy only within the first-tick grace
  # window (`@stale_multiplier` intervals since start). This is the fix for the first-tick blind
  # spot — a first tick that wedges or crash-loops before ever completing now surfaces as stale
  # instead of leaving the container healthy forever.
  defp stale_if(nil, %DateTime{} = started_at, interval, module),
    do: over_limit(started_at, interval, module, "no tick since start")

  # No start time recorded yet (the razor-thin window before `init/1` stamps it, or polling not
  # actually running) — nothing to judge; treat as healthy.
  defp stale_if(nil, nil, _interval, _module), do: nil

  defp over_limit(since, interval, module, label) do
    age_ms = DateTime.diff(DateTime.utc_now(), since, :millisecond)
    limit_ms = interval * @stale_multiplier

    if age_ms > limit_ms do
      name = module |> Module.split() |> List.last()
      "#{name} stale: #{label} #{age_ms}ms ago (limit #{limit_ms}ms)"
    end
  end
end
