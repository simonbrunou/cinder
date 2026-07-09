defmodule Cinder.Catalog.Refresher do
  @moduledoc """
  Periodically re-fetches every monitored series from TMDB and reconciles its tree via
  `Cinder.Catalog.refresh_series/1`, so a late-filled `air_date` or a newly-announced
  episode/season becomes visible to the TV poller's wanted-episodes sweep. Runs on a long interval
  (12h by default) — household-scale TMDB load is trivial. `:start_poller`-gated like the pollers,
  so the suite doesn't auto-run it.

  Lifecycle is `Cinder.Download.PollerSkeleton` (`stateful: false`) (self-rescheduling, stateless, `:infinity` poll). The
  interval is module config: `config :cinder, #{inspect(__MODULE__)}, interval: <ms>`.
  """
  alias Cinder.Catalog

  @default_interval :timer.hours(12)
  use Cinder.Download.PollerSkeleton, log_prefix: "refresher", stateful: false

  defp do_poll do
    for series <- Catalog.list_series(), series.monitored do
      isolate("series #{series.id}", fn -> refresh_one(series) end)
    end

    :ok
  end

  defp refresh_one(series) do
    case Catalog.refresh_series(series) do
      {:ok, _} ->
        :ok

      # A {:error, reason} (TMDB 404/timeout/expired token) short-circuits before any write and
      # does NOT raise, so isolate/2 wouldn't surface it. Log it so a wedged refresh is visible.
      {:error, reason} ->
        Logger.warning("refresher: series #{series.id} refresh failed: #{inspect(reason)}")
    end
  end
end
