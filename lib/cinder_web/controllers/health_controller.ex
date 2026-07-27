defmodule CinderWeb.HealthController do
  @moduledoc """
  Truthful liveness check, dependency-free and fast (no DB call — reads `:persistent_term` via
  each poller's `status/0`). Returns 200 "ok" whenever polling is disabled (`:start_poller` off,
  the default in test — a deploy where polling is intentionally off must never fail here) or
  every enabled poller has ticked recently; otherwise 503 with a short plain-text reason naming
  the stale poller, so an operator's health probe can actually catch a wedged/crash-looping
  pipeline instead of always reporting "ok".
  """

  use CinderWeb, :controller

  alias Cinder.Download.{Poller, TvPoller}

  @pollers [Poller, TvPoller]

  # A tick is "stale" once its last success is more than this many poll intervals old — generous
  # enough that one slow/errored tick doesn't flap the check, but a genuinely wedged poller
  # (crash-looping, or its process gone) still surfaces within a few intervals.
  @stale_multiplier 3

  def show(conn, _params) do
    if Application.get_env(:cinder, :start_poller, true) do
      case stale_reason() do
        nil -> text(conn, "ok")
        reason -> conn |> put_status(503) |> text(reason)
      end
    else
      text(conn, "ok")
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
