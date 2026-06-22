defmodule Cinder.Catalog.Refresher do
  @moduledoc """
  Periodically re-fetches every monitored series from TMDB and reconciles its tree via
  `Cinder.Catalog.refresh_series/1`, so a late-filled `air_date` or a newly-announced
  episode/season becomes visible to the TV poller's wanted-episodes sweep. Mirrors the poller
  skeleton (self-rescheduling `Process.send_after`) but on a long interval (12h by default) —
  household-scale TMDB load is trivial. Holds no state; each tick re-derives its work from the
  DB, so it recovers cleanly after a crash. `:start_poller`-gated like the pollers, so the suite
  doesn't auto-run it.

  The interval is module config, not a `/settings` field (no string→int coercion seam exists in
  `Cinder.Settings`, and one interval doesn't justify adding one):
  `config :cinder, #{inspect(__MODULE__)}, interval: <ms>`.
  """
  use GenServer

  require Logger

  alias Cinder.Catalog

  @default_interval :timer.hours(12)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Runs one refresh pass synchronously. The scheduled timer path is asynchronous."
  # :infinity — a full refresh issues 1 + N TMDB calls per series and can exceed the default
  # 5s call timeout on a large library; the caller (tests) is fine to wait.
  def poll(server \\ __MODULE__), do: GenServer.call(server, :poll, :infinity)

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, config_interval())
    {:ok, %{interval: interval}, {:continue, :schedule}}
  end

  @impl true
  def handle_continue(:schedule, state) do
    schedule(state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(:poll, state) do
    do_poll()
    schedule(state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_call(:poll, _from, state) do
    do_poll()
    {:reply, :ok, state}
  end

  defp do_poll do
    for series <- Catalog.list_series(), series.monitored do
      isolate("series #{series.id}", fn -> Catalog.refresh_series(series) end)
    end

    :ok
  end

  # Per-series isolation: a raise OR exit (e.g. a TMDB-layer crash, or a DBConnection checkout
  # timeout under write contention — not rescue-able) skips that series instead of the whole tick.
  defp isolate(label, fun) do
    fun.()
  rescue
    e -> Logger.error("refresher skipped #{label}: #{Exception.message(e)}")
  catch
    kind, value -> Logger.error("refresher skipped #{label}: #{inspect({kind, value})}")
  end

  defp schedule(interval), do: Process.send_after(self(), :poll, interval)

  defp config_interval do
    :cinder
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:interval, @default_interval)
  end
end
