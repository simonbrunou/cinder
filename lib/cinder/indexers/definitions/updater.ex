defmodule Cinder.Indexers.Definitions.Updater do
  @moduledoc """
  The definitions update job (#1669, part of #1610; #1616 points 9, 11 and 12): one worker under
  `Cinder.PollerSupervisor` that keeps the mirror of the upstream indexer definitions current.
  `Cinder.Jobs` lists it, so `/activity` shows it.

  ## A run

  Each run calls `Cinder.Indexers.Definitions.Source.fetch/1` with the commit of the set the
  mirror holds, nil before the first load, so it always asks for the whole upstream set:

  - `:unchanged` is a success;
  - a new set goes to `Cinder.Indexers.Definitions.apply_set/2`. Only an applied set is a
    success; a refusal is recorded by the state it left (`:cinder_too_old`, `:shrank`,
    `:first_too_small`) and counts as a failure;
  - a fetch error is a failure, recorded as its closed tag. So is a run that raised or exited
    (`:crashed`), an apply refused by its audit row included.

  The run writes the one row of `Cinder.Indexers.Definitions.UpdateRun`, then the worker
  broadcasts `{:definitions_update, outcome}` on `topic/0`, the outcome being `:applied`,
  `:unchanged`, a refusal's state, or `{:failed, tag}`. Logs carry closed tags and counts, never
  a URL or a body: a raise is logged by its exception's module and the function it reached.

  ## The schedule

  The worker starts with the boot re-check: `Definitions.stale_copies/0` through
  `check_copies/2` into `store_results/1`, which also tries to decide every configured indexer's
  copies again, with no network call. Then the boot run. The next run comes 24 hours after a run
  ends, or, after a failure while the mirror holds no set or the worker could not read whether it
  holds one, 1, 5, 15 and 30 minutes after it, then every 60 minutes until a success. A restart
  starts that count over with the boot run.

  `update_now/1` returns at once: `{:ok, :joined}` during a run, which starts no second fetch,
  and `{:ok, :started}` otherwise, which starts a run now and drops the armed one, so the next
  comes 24 hours after this one ends.

  The re-check and the run happen in a task linked to the worker, which traps exits, so a
  raise, an exit or a slow run never reaches the worker or delays the boot.

  Options, for tests: `:name` (default this module), `:check` (the load check, as
  `Definitions.apply_set/2` takes it), `:clock` (a 0-arity function returning the
  `DateTime` a run's times are stamped with) and `:schedule` (a 2-arity function given the delay
  in ms and the message to send the worker then).
  """

  use GenServer

  require Logger

  alias Cinder.Indexers.Definitions
  alias Cinder.Indexers.Definitions.{Archive, Source, UpdateRun}
  alias Cinder.Repo

  @interval :timer.hours(24)
  @retry_minutes [1, 5, 15, 30, 60]
  @topic "indexer_definitions_update"
  @refusals [:cinder_too_old, :shrank, :first_too_small]

  @type outcome ::
          :applied | :unchanged | :cinder_too_old | :shrank | :first_too_small | {:failed, term()}

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "The PubSub topic each run's outcome is broadcast on."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Subscribes the caller to `topic/0` on `Cinder.PubSub`."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Cinder.PubSub, @topic)

  @doc """
  Starts a run now, or joins the run in progress. `{:error, :not_running}` when no worker runs,
  as with `:start_poller` off.
  """
  @spec update_now(GenServer.server()) :: {:ok, :started | :joined} | {:error, :not_running}
  def update_now(server \\ __MODULE__) do
    GenServer.call(server, :update_now)
  catch
    :exit, {:noproc, _call} -> {:error, :not_running}
  end

  @doc """
  Whether a run is in progress, asked of the worker, which answers while its run goes on in a
  task. False when no worker runs.
  """
  @spec running?(GenServer.server()) :: boolean()
  def running?(server \\ __MODULE__) do
    GenServer.call(server, :running?)
  catch
    :exit, {:noproc, _call} -> false
  end

  @doc """
  The tag of each error a failed run records: the source's (`Source.error_tags/0`, where
  `:http_status` stands for `{:http_status, status}`), the zip reader's
  (`Cinder.Indexers.Definitions.Archive.reasons/0`) and `:crashed`.
  """
  @spec error_tags() :: [atom()]
  def error_tags, do: Enum.uniq(Source.error_tags() ++ Archive.reasons() ++ [:crashed])

  @doc """
  The `Cinder.Jobs` snapshot, read from `:persistent_term`, never from the worker: the end of the
  last run (nil before the first) and the delay armed after it (24 hours before the first).
  """
  def status do
    stamp = :persistent_term.get({__MODULE__, :status}, %{last_run_at: nil, interval: @interval})
    Map.put(stamp, :module, __MODULE__)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      check: Keyword.get(opts, :check),
      clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
      schedule: Keyword.get(opts, :schedule, &schedule/2),
      run: nil,
      timer: nil,
      failures: 0
    }

    {:ok, state, {:continue, :boot}}
  end

  @impl true
  def handle_continue(:boot, state), do: {:noreply, start_run(state, true)}

  @impl true
  def handle_call(:update_now, _from, %{run: nil} = state),
    do: {:reply, {:ok, :started}, state |> cancel_timer() |> start_run(false)}

  def handle_call(:update_now, _from, state), do: {:reply, {:ok, :joined}, state}

  def handle_call(:running?, _from, state), do: {:reply, state.run != nil, state}

  @impl true
  def handle_info({:scheduled_run, tag}, %{run: nil, timer: {tag, _timer}} = state),
    do: {:noreply, start_run(%{state | timer: nil}, false)}

  # A run that Update now started already replaced this timer.
  def handle_info({:scheduled_run, _tag}, state), do: {:noreply, state}

  def handle_info({ref, result}, %{run: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish(state, result)}
  end

  # The run task died without answering, as when it is killed.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{run: %Task{ref: ref}} = state) do
    Logger.error("indexer definitions update run crashed: exit")
    now = state.clock.()
    loaded? = record({:failed, :crashed}, nil, now, now)
    {:noreply, finish(state, {{:failed, :crashed}, now, loaded?})}
  end

  # The run task's exit signal, which the monitor above already handles.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  defp start_run(state, recheck?) do
    %{check: check, clock: clock} = state
    %{state | run: Task.async(fn -> run(recheck?, check, clock) end)}
  end

  # The task's body: no raise or exit leaves it.
  defp run(recheck?, check, clock) do
    if recheck?, do: guarded("re-check", fn -> recheck(check) end)

    started_at = clock.()

    outcome =
      case guarded("run", fn -> fetch_and_apply(check) end) do
        {:ok, outcome} -> outcome
        :crashed -> {{:failed, :crashed}, nil}
      end

    {outcome, commit} = outcome
    ended_at = clock.()
    {outcome, ended_at, record(outcome, commit, started_at, ended_at)}
  end

  defp recheck(check) do
    results = Definitions.check_copies(Definitions.stale_copies(), check_opts(check))

    case Definitions.store_results(results) do
      :ok -> :ok
      {:error, _changeset} -> Logger.warning("indexer definitions re-check: audit refused")
    end
  end

  defp fetch_and_apply(check) do
    stored = Definitions.loaded()

    case Source.fetch(stored && stored.commit) do
      :unchanged -> {:unchanged, stored.commit}
      {:ok, commit, set} -> {apply_outcome(Definitions.apply_set(set, check_opts(check))), commit}
      {:error, tag} -> {{:failed, tag}, nil}
    end
  end

  defp apply_outcome({:ok, {:loaded, _loaded}}), do: :applied
  defp apply_outcome({:error, {state, _fields}}) when state in @refusals, do: state

  defp check_opts(nil), do: []
  defp check_opts(check), do: [check: check]

  # Overwrites the run row, then answers whether the mirror holds a set. A row that fails to
  # write leaves that answer as it is, so a loaded set still waits 24 hours.
  defp record(outcome, commit, started_at, ended_at) do
    guarded("record", fn -> write_row(outcome, commit, started_at, ended_at) end)

    case guarded("set read", fn -> Definitions.loaded() != nil end) do
      {:ok, loaded?} -> loaded?
      :crashed -> false
    end
  end

  defp write_row(outcome, commit, started_at, ended_at) do
    {:ok, _row} =
      Repo.transact(fn ->
        previous = Repo.get(UpdateRun, UpdateRun.id())
        ended_at = DateTime.truncate(ended_at, :second)
        success? = success?(outcome)

        row = [
          started_at: DateTime.truncate(started_at, :second),
          ended_at: ended_at,
          outcome: code(outcome),
          commit: commit,
          error: UpdateRun.encode_error(outcome),
          last_success_at: if(success?, do: ended_at, else: previous && previous.last_success_at),
          first_failure_at: first_failure_at(success?, previous, ended_at)
        ]

        {:ok,
         Repo.insert!(struct(UpdateRun, [id: UpdateRun.id()] ++ row),
           on_conflict: [set: row],
           conflict_target: :id
         )}
      end)
  end

  defp first_failure_at(true, _previous, _ended_at), do: nil
  defp first_failure_at(false, %UpdateRun{first_failure_at: %DateTime{} = at}, _ended_at), do: at
  defp first_failure_at(false, _previous, ended_at), do: ended_at

  defp success?(outcome), do: outcome in [:applied, :unchanged]

  defp code({:failed, _tag}), do: :failed
  defp code(outcome), do: outcome

  defp finish(state, {outcome, ended_at, loaded?}) do
    log(outcome)
    failures = if success?(outcome), do: 0, else: state.failures + 1
    delay = next_delay(success?(outcome) or loaded?, failures)
    :persistent_term.put({__MODULE__, :status}, %{last_run_at: ended_at, interval: delay})
    Phoenix.PubSub.broadcast(Cinder.PubSub, @topic, {:definitions_update, outcome})
    arm(%{state | run: nil, failures: failures}, delay)
  end

  defp next_delay(true, _failures), do: @interval

  defp next_delay(false, failures),
    do: :timer.minutes(Enum.at(@retry_minutes, min(failures, length(@retry_minutes)) - 1))

  defp arm(state, delay) do
    tag = make_ref()
    %{state | timer: {tag, state.schedule.(delay, {:scheduled_run, tag})}}
  end

  defp cancel_timer(%{timer: {_tag, timer}} = state) do
    if is_reference(timer), do: Process.cancel_timer(timer)
    %{state | timer: nil}
  end

  defp cancel_timer(state), do: state

  defp schedule(delay, message), do: Process.send_after(self(), message, delay)

  defp log(:applied), do: Logger.info("indexer definitions update: applied")
  defp log(:unchanged), do: Logger.info("indexer definitions update: unchanged")

  defp log({:failed, tag}),
    do: Logger.warning("indexer definitions update failed: #{inspect(tag)}")

  defp log(state), do: Logger.warning("indexer definitions update refused: #{state}")

  # Runs `fun`; a raise, throw or exit is logged by its kind, its exception's module and the
  # function it reached, never its message, which can hold a URL.
  defp guarded(label, fun) do
    {:ok, fun.()}
  rescue
    exception ->
      log_crash(label, inspect(exception.__struct__), __STACKTRACE__)
      :crashed
  catch
    kind, _value ->
      log_crash(label, Atom.to_string(kind), __STACKTRACE__)
      :crashed
  end

  defp log_crash(label, what, stacktrace),
    do:
      Logger.error(
        "indexer definitions update #{label} crashed: #{what} in #{location(stacktrace)}"
      )

  defp location([{module, function, args, _info} | _rest]) when is_list(args),
    do: Exception.format_mfa(module, function, length(args))

  defp location([{module, function, arity, _info} | _rest]),
    do: Exception.format_mfa(module, function, arity)

  defp location(_stacktrace), do: "an unknown function"
end
