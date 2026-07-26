defmodule Cinder.Download.PollerSkeleton do
  @moduledoc """
  Shared GenServer skeleton for the household's periodic, stateless background workers.
  Each holds no in-flight state — every tick re-derives its work from the DB/filesystem
  and reschedules itself — so it recovers cleanly after a crash. This injects that
  identical lifecycle (`start_link`/`poll`/`init`/`handle_*`/`schedule`/`config_interval`)
  plus the per-unit `isolate/2` guard.

  Two flavours, selected by `:stateful`:

  - The pipeline pollers (`Cinder.Download.Poller`, `Cinder.Download.TvPoller`) use
    `stateful: true` (the default): a `do_poll/1` pass receiving the state, the search
    backoff `search_due?/2` fed by `@search_retry_after`, a shared `@max_attempts` bound,
    and the `finish_stage/2` + `reject_release/4` helpers their (structurally identical)
    import-stage-cleanup and release-policy-mismatch paths share — `reject_release/4`
    takes the Catalog reject function (`&Catalog.reject_movie_release/2` vs
    `&Catalog.reject_grab_release/2`) as its last argument since that's the one thing
    that differs between the two pollers.

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
  feeds `/healthz` (`CinderWeb.HealthController`), which treats a poller whose last tick
  is more than ~3 intervals old as unhealthy.

  The interval is module config (`config :cinder, <module>, interval: <ms>`), not a
  `/settings` field — there's no string→int coercion seam there.
  """
  defmacro __using__(opts) do
    prefix = Keyword.fetch!(opts, :log_prefix)
    stateful = Keyword.get(opts, :stateful, true)
    first_interval = Keyword.get(opts, :first_interval)

    lifecycle =
      if stateful do
        quote do
          @max_attempts 10

          @doc "Runs one poll pass synchronously. The scheduled timer path is asynchronous."
          def poll(server \\ __MODULE__), do: GenServer.call(server, :poll, :infinity)

          @doc """
          Non-blocking last-successful-tick snapshot for `CinderWeb.HealthController`. Reads
          `:persistent_term` (never the busy worker process), so it returns instantly even
          mid-tick. `last_run_at` is `nil` until the first tick completes.
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
            retry_after = Keyword.get(opts, :search_retry_after, @search_retry_after)
            {:ok, %{interval: interval, search_retry_after: retry_after}, {:continue, :schedule}}
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

          # Stamp completion so `status/0` (and /healthz) can see a fresh tick without
          # calling the busy process. A raise here would still crash-loop the GenServer —
          # do_poll/1 is expected to isolate its own units (and preamble) so this only ever
          # sees a genuinely successful tick.
          defp run(state) do
            result = emit_tick(fn -> do_poll(state) end)
            :persistent_term.put({__MODULE__, :last_run}, DateTime.utc_now())
            result
          end

          # Fresh units (search_attempts == 0) attempt immediately; failed ones back off to once per
          # `retry_after` seconds (external services — don't hammer). retry_after 0 (test) = all due.
          defp search_due?(_unit, 0), do: true
          defp search_due?(%{search_attempts: 0}, _retry_after), do: true

          defp search_due?(unit, retry_after),
            do: DateTime.diff(DateTime.utc_now(), unit.updated_at) >= retry_after

          # --- shared pipeline helpers (movie + TV pollers) --------------------------------------

          # The download client's `:error` status may carry a human-facing `:reason` (SABnzbd's
          # paused state or fail_message). Surface it as the park detail while keeping
          # `:download_error` as the classifying code the blocklist/membership checks key on —
          # `reason_code/1` unwraps it back to that atom at the park sites.
          defp download_error_reason(%{reason: detail}) when is_binary(detail) and detail != "",
            do: {:download_error, detail}

          defp download_error_reason(_status), do: :download_error

          defp reason_code({code, _detail}), do: code
          defp reason_code(code), do: code

          # A terminal-park write's stage cleanup: commit finalizes the staged import file at its
          # destination, rollback removes it. Best-effort — a cleanup failure is logged, never
          # raised, so it can't re-open a decision the caller's transition already committed.
          defp finish_stage(stage, action) do
            result =
              case action do
                :commit -> Cinder.Library.commit_stage(stage)
                :rollback -> Cinder.Library.rollback_stage(stage)
              end

            if match?({:error, _}, result),
              do: Logger.warning("#{unquote(prefix)} import stage cleanup remains pending")

            result
          end

          # A provable release-policy mismatch: reject via the caller's Catalog function (movie
          # vs grab — the one thing that differs between the two pollers, passed as
          # `reject_fun`), then best-effort remove the now-unneeded download source.
          # `:stale_release` means the item moved on concurrently — nothing left to reject.
          defp reject_release(item, evidence, content_path, reject_fun) do
            case reject_fun.(item, evidence) do
              {:ok, _item} ->
                Cinder.Download.remove_after_import(item.download_protocol, nil, content_path)
                :ok

              {:error, :stale_release} ->
                :ok

              {:error, reason} ->
                {:error, reason}
            end
          end
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
