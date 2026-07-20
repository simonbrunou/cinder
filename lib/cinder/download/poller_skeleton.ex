defmodule Cinder.Download.PollerSkeleton do
  @moduledoc """
  Shared GenServer skeleton for the household's periodic, stateless background workers.
  Each holds no in-flight state — every tick re-derives its work from the DB/filesystem
  and reschedules itself — so it recovers cleanly after a crash. This injects that
  identical lifecycle (`start_link`/`poll`/`init`/`handle_*`/`schedule`/`config_interval`)
  plus the per-unit `isolate/2` guard.

  Two flavours, selected by `:stateful`:

  - The pipeline pollers (`Cinder.Download.Poller`, `Cinder.Download.TvPoller`) use
    `stateful: true` (the default): a `do_poll/1` pass receiving the state, plus the
    search backoff `search_due?/2` fed by `@search_retry_after`.

        @default_interval 5_000
        @search_retry_after 60
        use Cinder.Download.PollerSkeleton, log_prefix: "tv poller"

  - The slow sweeps (`Cinder.Catalog.Refresher`, `Cinder.Subtitles.Sweeper`) use
    `stateful: false`: a no-arg `do_poll/0` pass, no backoff, and an `:infinity`
    `poll/1` call timeout — a pass can issue many external calls (1 + N TMDB fetches,
    or a whole library of subtitle lookups) and exceed the default 5s call timeout.

        @default_interval :timer.hours(12)
        use Cinder.Download.PollerSkeleton, log_prefix: "refresher", stateful: false

  The interval is module config (`config :cinder, <module>, interval: <ms>`), not a
  `/settings` field — there's no string→int coercion seam there.
  """
  defmacro __using__(opts) do
    prefix = Keyword.fetch!(opts, :log_prefix)
    stateful = Keyword.get(opts, :stateful, true)

    lifecycle =
      if stateful do
        quote do
          @doc "Runs one poll pass synchronously. The scheduled timer path is asynchronous."
          def poll(server \\ __MODULE__), do: GenServer.call(server, :poll, :infinity)

          @impl true
          def init(opts) do
            interval = Keyword.get(opts, :interval, config_interval())
            retry_after = Keyword.get(opts, :search_retry_after, @search_retry_after)
            {:ok, %{interval: interval, search_retry_after: retry_after}, {:continue, :schedule}}
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
        end
      else
        quote do
          @doc "Runs one pass synchronously (tests). The scheduled timer path is asynchronous."
          def poll(server \\ __MODULE__), do: GenServer.call(server, :poll, :infinity)

          @impl true
          def init(opts) do
            interval = Keyword.get(opts, :interval, config_interval())
            {:ok, %{interval: interval}, {:continue, :schedule}}
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
        end
      end

    quote do
      use GenServer

      require Logger

      def start_link(opts \\ []) do
        GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
      end

      unquote(lifecycle)

      @impl true
      def handle_continue(:schedule, state) do
        schedule(state.interval)
        {:noreply, state}
      end

      # Per-unit isolation: an unexpected raise OR exit (e.g. a DBConnection checkout timeout under
      # two-poller write contention — not rescue-able) skips that one unit (leaving it for next-tick
      # retry) instead of crashing the whole tick.
      # Full Exception.format (message + stacktrace) so an intermittent failure names its
      # call site from a single occurrence (issue #139).
      defp isolate(label, fun) do
        fun.()
      rescue
        e ->
          Logger.error(
            "#{unquote(prefix)} skipped #{label}: #{Exception.format(:error, e, __STACKTRACE__)}"
          )
      catch
        kind, value ->
          Logger.error(
            "#{unquote(prefix)} skipped #{label}: #{Exception.format(kind, value, __STACKTRACE__)}"
          )
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
