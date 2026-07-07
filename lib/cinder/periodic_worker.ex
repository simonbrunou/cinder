defmodule Cinder.PeriodicWorker do
  @moduledoc """
  Shared GenServer skeleton for the household's periodic, stateless background workers
  (`Cinder.Catalog.Refresher`, `Cinder.Subtitles.Sweeper`). Each holds no in-flight state — every
  tick re-derives its work from the DB/filesystem and reschedules itself — so it recovers cleanly
  after a crash. This injects that identical lifecycle (`start_link`/`poll`/`init`/`handle_*`/
  `schedule`/`config_interval`) plus the per-unit `isolate/2` guard. The using module supplies only
  `@default_interval` (before the `use`) and a no-arg `do_poll/0` pass:

      @default_interval :timer.hours(12)
      use Cinder.PeriodicWorker, log_prefix: "refresher"

  `poll/1` waits `:infinity` — a pass can issue many external calls (1 + N TMDB fetches, or a whole
  library of subtitle lookups) and exceed the default 5s call timeout; the caller (tests) is fine to
  wait. The interval is module config (`config :cinder, <module>, interval: <ms>`), not a `/settings`
  field — there's no string→int coercion seam there, and one interval doesn't justify adding one.

  The two pipeline pollers diverge — a 5s tick, a search backoff, a stateful `do_poll(state)` pass —
  so they keep their own `Cinder.Download.PollerSkeleton` rather than bending this.
  """
  defmacro __using__(opts) do
    prefix = Keyword.fetch!(opts, :log_prefix)

    quote do
      use GenServer

      require Logger

      def start_link(opts \\ []) do
        GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
      end

      @doc "Runs one pass synchronously (tests). The scheduled timer path is asynchronous."
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

      # Per-unit isolation: a raise OR exit (e.g. a DBConnection checkout timeout under write
      # contention — not rescue-able) skips that one unit, leaving it for the next tick, instead of
      # crashing the whole pass.
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
