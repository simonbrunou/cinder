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
    %{last_run_at: last_run_at, interval: interval} = module.status()
    stale_if(last_run_at, interval, module)
  end

  # No tick yet (fresh boot, still waiting for its first schedule) is not stale — only a poller
  # that ticked once and then stopped ticking is.
  defp stale_if(nil, _interval, _module), do: nil

  defp stale_if(%DateTime{} = last_run_at, interval, module) do
    age_ms = DateTime.diff(DateTime.utc_now(), last_run_at, :millisecond)
    limit_ms = interval * @stale_multiplier

    if age_ms > limit_ms do
      name = module |> Module.split() |> List.last()
      "#{name} stale: last tick #{age_ms}ms ago (limit #{limit_ms}ms)"
    end
  end
end
