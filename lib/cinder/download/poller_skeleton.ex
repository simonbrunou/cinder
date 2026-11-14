defmodule Cinder.Download.PollerSkeleton do
  @moduledoc """
  Shared GenServer skeleton for the household's periodic, stateless background workers.
  Each holds no in-flight state — every tick re-derives its work from the DB/filesystem
  and reschedules itself — so it recovers cleanly after a crash. This injects that
  identical lifecycle (`start_link`/`poll`/`init`/`handle_*`/`schedule`/`config_interval`)
  plus the per-unit `isolate/2` guard.

  Two flavours, selected by `:stateful`:

  - The pipeline pollers (`Cinder.Download.Poller`, `Cinder.Download.TvPoller`,
    `Cinder.Download.BookPoller`) use `stateful: true` (the default): a `do_poll/1` pass
    receiving the state, `warn_throttled/2`, and the search backoff `search_due?/2` fed by
    `@search_retry_after` (the movie and TV pollers; `BookPoller` has no search pass). The
    failure budget and what a failure does stay with each pipeline: `TvPoller` and
    `BookPoller` each define their own `@max_attempts`, and the movie poller hands both to
    `Cinder.Catalog.MovieLifecycle`.

        @default_interval 5_000
        @search_retry_after 60
        use Cinder.Download.PollerSkeleton, log_prefix: "tv poller"

  - The slow sweeps (`Cinder.Catalog.Refresher`, `Cinder.Subtitles.Sweeper`) use
    `stateful: false`: a no-arg `do_poll/0` pass, no backoff, and an `:infinity`
    `poll/1` call timeout — a pass can issue many external calls (1 + N TMDB fetches,
    or a whole library of subtitle lookups) and exceed the default 5s call timeout.

        @default_interval :timer.hours(12)
        use Cinder.Download.PollerSkeleton, log_prefix: "refresher", stateful: false

  Both flavours stamp their completion time into `:persistent_term` after each pass,
  exposed non-blocking via `status/0` — the one piece of state here that is not
  DB-derived (VM-global, so it survives a crash but is *not* per-test isolated; a test
  that runs `poll/1` should erase `{module, :last_run}`). The stateless flavour's
  `status/0` feeds the `/activity` sweeps view (`Cinder.Jobs`); the stateful flavour's
  feeds `/healthz` (`CinderWeb.HealthController`). The stateful flavour also records its
  tick in flight in `Cinder.Download.PollerProgress`: `run/1` flags the tick from its start to
  its end, and `isolate/2` stamps progress as each unit starts and finishes, nested and raising
  units included. `/healthz` judges a tick in flight by that progress (unhealthy after
  10 minutes with none), and an idle poller by its last tick (unhealthy once it ended more than
  3 intervals ago). `init/1` clears the in-flight state on every (re)start, so a poller killed
  mid-tick falls back to the idle rule. A test that erases `{module, :last_run}` and
  `{module, :started_at}` for `/healthz` also calls `PollerProgress.reset/1`.

  The interval is module config (`config :cinder, <module>, interval: <ms>`), not a
  `/settings` field — there's no string→int coercion seam there.
  """
  alias Cinder.Download.PollerProgress

  defmacro __using__(opts) do
    prefix = Keyword.fetch!(opts, :log_prefix)
    stateful = Keyword.get(opts, :stateful, true)
    first_interval = Keyword.get(opts, :first_interval)

    # Only a stateful poller's tick is judged by /healthz, so only its units record progress.
    mark_progress =
      if stateful,
        do: quote(do: PollerProgress.mark(__MODULE__)),
        else: :ok

    lifecycle =
      if stateful do
        quote do
          # A per-tick condition (a full disk) warns at most once per this window instead of every
          # tick. Deduped in the long-lived poller process dictionary (see warn_throttled/2).
          @warn_throttle_ms :timer.minutes(10)

          @doc "Runs one poll pass synchronously. The scheduled timer path is asynchronous."
          def poll(server \\ __MODULE__), do: GenServer.call(server, :poll, :infinity)

          @doc """
          Non-blocking health snapshot for `CinderWeb.HealthController`. Reads `:persistent_term`
          and `Cinder.Download.PollerProgress` (never the busy worker process), so it returns
          instantly even mid-tick. `last_run_at` is `nil` until the first tick completes;
          `started_at` is stamped in `init/1`, so a worker that wedges or crash-loops before ever
          completing a tick still has a start time the controller can bound against (rather than
          reporting healthy forever). `tick_in_flight?` is true from a tick's start to its end, and
          `last_progress_at` is then the `PollerProgress.now_ms/0` stamp of its last progress
          (`nil` while idle).
          """
          def status do
            # The in-flight state first: a tick writes `:last_run` before it clears the flag, so a
            # reader that sees the tick idle reads that tick's `:last_run` below.
            progress = PollerProgress.read(__MODULE__)

            %{
              module: __MODULE__,
              last_run_at: :persistent_term.get({__MODULE__, :last_run}, nil),
              started_at: :persistent_term.get({__MODULE__, :started_at}, nil),
              tick_in_flight?: progress.in_flight?,
              last_progress_at: progress.progress_at,
              interval: config_interval()
            }
          end

          @impl true
          def init(opts) do
            interval = Keyword.get(opts, :interval, config_interval())
            retry_after = Keyword.get(opts, :search_retry_after, @search_retry_after)
            # Stamp the (re)start time so /healthz can catch a first tick that never completes. A
            # supervisor restart re-runs init and re-stamps, giving each fresh worker its own
            # first-tick grace window.
            :persistent_term.put({__MODULE__, :started_at}, DateTime.utc_now())
            # A process killed mid-tick never cleared its in-flight flag: drop it, so /healthz
            # judges this fresh worker by the idle rule until its own first tick starts.
            PollerProgress.reset(__MODULE__)
            {:ok, %{interval: interval, search_retry_after: retry_after}, {:continue, :schedule}}
          end

          # Time-throttled Logger.warning keyed by an arbitrary term, deduped in the (long-lived)
          # poller process dictionary so a per-tick condition warns at most once per
          # @warn_throttle_ms instead of every tick. Resets on a crash/restart — fine for a warning.
          defp warn_throttled(key, message) do
            now = System.monotonic_time(:millisecond)
            last = Process.get({:warn_throttled, key})

            if is_nil(last) or now - last >= @warn_throttle_ms do
              Process.put({:warn_throttled, key}, now)
              Logger.warning(message)
            end

            :ok
          end

          @impl true
          def handle_info(:poll, state) do
            run(state)
            schedule(state.interval)
            {:noreply, state}
          end

          @impl true
          def handle_call(:poll, _from, state) do
            run(state)
            {:reply, :ok, state}
          end

          # Flag the tick in flight, then stamp completion, so `status/0` (and /healthz) can see
          # both without calling the busy process. `:last_run` goes before the flag clears (see
          # `status/0`). A raise here would still crash-loop the GenServer — do_poll/1 is
          # expected to isolate its own units (and preamble) so this only ever sees a genuinely
          # successful tick; the restart's `init/1` clears the flag the crash left.
          defp run(state) do
            PollerProgress.tick_started(__MODULE__)
            result = emit_tick(fn -> do_poll(state) end)
            :persistent_term.put({__MODULE__, :last_run}, DateTime.utc_now())
            PollerProgress.tick_finished(__MODULE__)
            result
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

          @doc """
          Non-blocking last-run + schedule snapshot for the activity view. Reads
          `:persistent_term` (never the busy worker process), so it returns instantly even mid-
          sweep. `last_run_at` is `nil` until the first pass completes.
          """
          def status do
            %{
              module: __MODULE__,
              last_run_at: :persistent_term.get({__MODULE__, :last_run}, nil),
              interval: config_interval()
            }
          end

          @impl true
          def init(opts) do
            interval = Keyword.get(opts, :interval, config_interval())
            {:ok, %{interval: interval}, {:continue, :schedule}}
          end

          @impl true
          def handle_info(:poll, state) do
            run()
            schedule(state.interval)
            {:noreply, state}
          end

          @impl true
          def handle_call(:poll, _from, state) do
            run()
            {:reply, :ok, state}
          end

          # Stamp completion so `status/0` can show "last run" without calling the busy process.
          defp run do
            result = emit_tick(fn -> do_poll() end)
            :persistent_term.put({__MODULE__, :last_run}, DateTime.utc_now())
            result
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
        schedule(unquote(first_interval) || state.interval)
        {:noreply, state}
      end

      # Per-unit isolation: an unexpected raise OR exit (e.g. a DBConnection checkout timeout under
      # two-poller write contention — not rescue-able) skips that one unit (leaving it for next-tick
      # retry) instead of crashing the whole tick.
      # Full Exception.format (message + stacktrace) so an intermittent failure names its
      # call site from a single occurrence (issue #139).
      # The stateful flavour stamps progress as each unit starts and finishes, raise or not, so
      # /healthz reads a long tick that keeps moving as healthy (Cinder.Download.PollerProgress).
      defp isolate(label, fun) do
        unquote(mark_progress)
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
      after
        unquote(mark_progress)
      end

      # `[:cinder, :poller, :tick]` fires once per tick (scheduled or the synchronous `poll/1`
      # test path alike), timing the whole do_poll pass — never inside it, so instrumentation
      # can't drift as either flavor's pass grows.
      defp emit_tick(fun) do
        started_at = System.monotonic_time()
        result = fun.()

        :telemetry.execute(
          [:cinder, :poller, :tick],
          %{duration: System.monotonic_time() - started_at},
          %{poller: __MODULE__}
        )

        result
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
