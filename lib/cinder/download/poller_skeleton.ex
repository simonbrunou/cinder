defmodule Cinder.Download.PollerSkeleton do
  @moduledoc """
  Shared GenServer skeleton for the two pipeline pollers (`Cinder.Download.Poller` and
  `Cinder.Download.TvPoller`). Both hold no in-flight state — each tick re-derives its work
  from the DB and reschedules itself — so they recover cleanly after a crash. This injects
  that identical lifecycle (`start_link`/`poll`/`init`/`handle_*`/`schedule`/`config_interval`),
  the per-unit `isolate/2` guard, and the search backoff `search_due?/2`. The using module
  supplies only `@default_interval`, `@search_retry_after`, and a `do_poll/1` pass:

      use Cinder.Download.PollerSkeleton, log_prefix: "tv poller"

  (`Cinder.Catalog.Refresher` mirrors the same shape but diverges — `:infinity` poll timeout,
  no search backoff, a no-arg pass — so it keeps its own lifecycle rather than bending this.)
  """
  defmacro __using__(opts) do
    prefix = Keyword.fetch!(opts, :log_prefix)

    quote do
      use GenServer

      require Logger

      def start_link(opts \\ []) do
        GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
      end

      @doc "Runs one poll pass synchronously. The scheduled timer path is asynchronous."
      def poll(server \\ __MODULE__), do: GenServer.call(server, :poll)

      @impl true
      def init(opts) do
        interval = Keyword.get(opts, :interval, config_interval())
        retry_after = Keyword.get(opts, :search_retry_after, @search_retry_after)
        {:ok, %{interval: interval, search_retry_after: retry_after}, {:continue, :schedule}}
      end

      @impl true
      def handle_continue(:schedule, state) do
        schedule(state.interval)
        {:noreply, state}
      end

      @impl true
      def handle_info(:poll, state) do
        do_poll(state)
        schedule(state.interval)
        {:noreply, state}
      end

      @impl true
      def handle_call(:poll, _from, state) do
        do_poll(state)
        {:reply, :ok, state}
      end

      # Fresh units (search_attempts == 0) attempt immediately; failed ones back off to once per
      # `retry_after` seconds (external services — don't hammer). retry_after 0 (test) = all due.
      defp search_due?(_unit, 0), do: true
      defp search_due?(%{search_attempts: 0}, _retry_after), do: true

      defp search_due?(unit, retry_after),
        do: DateTime.diff(DateTime.utc_now(), unit.updated_at) >= retry_after

      # Per-unit isolation: an unexpected raise OR exit (e.g. a DBConnection checkout timeout under
      # two-poller write contention — not rescue-able) skips that one unit (leaving it for next-tick
      # retry) instead of crashing the whole tick.
      defp isolate(label, fun) do
        fun.()
      rescue
        e -> Logger.error("#{unquote(prefix)} skipped #{label}: #{Exception.message(e)}")
      catch
        kind, value ->
          Logger.error("#{unquote(prefix)} skipped #{label}: #{inspect({kind, value})}")
      end

      defp schedule(interval), do: Process.send_after(self(), :poll, interval)

      defp config_interval do
        :cinder
        |> Application.get_env(__MODULE__, [])
        |> Keyword.get(:interval, @default_interval)
      end
    end
  end
end
