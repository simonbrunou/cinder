defmodule Cinder.Subtitles.Sync.Worker do
  @moduledoc """
  Serial background queue for CPU-heavy subtitle synchronization.

  The queue itself is intentionally ephemeral: initial and periodic catalog scans re-derive work
  from manifests and the filesystem after every restart.

  Work is held in two queues. Routine library scans append to the background queue; an explicit
  operator request for a movie, series, season or episode goes to the priority queue, promoting
  any matching unit already waiting in the background queue. The in-flight analysis is never
  interrupted — promotion only decides what runs next.
  """
  use GenServer

  require Logger

  alias Cinder.Subtitles.Sync

  @status_key {__MODULE__, :status}
  @topic "subtitle_sync:status"
  @default_interval :timer.hours(12)
  @empty_counts %{aligned: 0, corrected: 0, review: 0, failed: 0}

  # How long background work waits for an outstanding explicit scan to produce its units. The
  # hold exists so an operator's click keeps the next slot; it is bounded so a scan that hangs
  # (rather than raises — run_scan/2 only rescues) degrades to plain background processing
  # instead of parking the queue forever.
  @explicit_scan_hold :timer.seconds(30)

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Current non-blocking worker snapshot for Activity and subtitle-sync pages."
  def status do
    :persistent_term.get(
      @status_key,
      snapshot(%{
        current: nil,
        queue: :queue.new(),
        priority: :queue.new(),
        counts: @empty_counts,
        recent: []
      })
    )
  end

  @doc "Subscribes the caller to status updates."
  def subscribe, do: Phoenix.PubSub.subscribe(Cinder.PubSub, @topic)

  @doc "Video paths whose latest analysis found managed sidecars."
  def managed_video_paths(server \\ __MODULE__) do
    if worker_alive?(server), do: GenServer.call(server, :managed_video_paths), else: :unavailable
  end

  @doc "Enqueues all pending videos in the library."
  def enqueue_library(server \\ __MODULE__), do: enqueue(:library, server)
  def enqueue_movie(id, server \\ __MODULE__), do: enqueue({:movie, id}, server)
  def enqueue_series(id, server \\ __MODULE__), do: enqueue({:series, id}, server)
  def enqueue_season(id, server \\ __MODULE__), do: enqueue({:season, id}, server)
  def enqueue_episode(id, server \\ __MODULE__), do: enqueue({:episode, id}, server)

  @doc "Enqueues one freshly downloaded sidecar's video when the supervised worker is enabled."
  def enqueue_after_download(video_path, server \\ __MODULE__) do
    if worker_alive?(server) do
      unit =
        Enum.find(
          Sync.units(:library),
          %{video_path: video_path, label: Path.basename(video_path)},
          &(&1.video_path == video_path)
        )

      GenServer.cast(server, {:enqueue_units, [unit]})
    end

    :ok
  end

  @doc false
  def enqueue_units(units, server \\ __MODULE__) do
    GenServer.call(server, {:enqueue_units, units})
  end

  @impl true
  def init(opts) do
    {:ok, task_supervisor} = Task.Supervisor.start_link()

    state = %{
      queue: :queue.new(),
      queued: MapSet.new(),
      priority: :queue.new(),
      prioritized: MapSet.new(),
      current: nil,
      task: nil,
      scan_task: nil,
      pending_scans: [],
      task_supervisor: task_supervisor,
      scan: Keyword.get(opts, :scan, &Sync.units/1),
      analyze: Keyword.get(opts, :analyze, &Sync.analyze_video/1),
      interval: Keyword.get(opts, :interval, @default_interval),
      hold: Keyword.get(opts, :explicit_scan_hold, @explicit_scan_hold),
      hold_until: nil,
      hold_gen: 0,
      counts: @empty_counts,
      recent: [],
      managed_video_paths: MapSet.new()
    }

    publish(state)

    if Keyword.get(opts, :initial_scan, true),
      do: send(self(), :scan),
      else: schedule_scan(state.interval)

    {:ok, state}
  end

  @impl true
  def handle_call(:managed_video_paths, _from, state) do
    {:reply, state.managed_video_paths, state}
  end

  def handle_call({:enqueue_units, units}, _from, state) do
    {:reply, :ok, enqueue_valid_units(units, state)}
  end

  @impl true
  def handle_cast({:enqueue, scope}, state),
    do: {:noreply, state |> hold_explicitly(scope) |> start_scan(scope)}

  def handle_cast({:enqueue_units, units}, state),
    do: {:noreply, enqueue_valid_units(units, state)}

  @impl true
  def handle_info(:scan, state) do
    schedule_scan(state.interval)
    {:noreply, start_scan(state, :library)}
  end

  # The hold window elapsed: re-evaluate so background work can proceed. A timer that lands a hair
  # early is rescheduled for the remaining time rather than dropped, or nothing would be left to
  # wake the queue. The generation tag means only the current hold's timer is ever live: a timer
  # from a superseded hold is discarded instead of accumulating alongside the new one.
  def handle_info({:release_hold, gen}, %{hold_gen: gen, hold_until: hold_until} = state)
      when not is_nil(hold_until) do
    remaining = hold_until - System.monotonic_time(:millisecond)

    if remaining > 0 do
      Process.send_after(self(), {:release_hold, gen}, remaining)
      {:noreply, state}
    else
      {:noreply, start_next(state)}
    end
  end

  def handle_info({:release_hold, _gen}, state), do: {:noreply, state}

  def handle_info(
        {reference, {:scan_ok, units}},
        %{scan_task: %{ref: reference, scope: scope}} = state
      ) do
    Process.demonitor(reference, [:flush])

    state = Map.put(state, :scan_task, nil)
    state = units |> add_units(state, mode(scope)) |> start_next() |> start_pending_scan()

    {:noreply, state}
  end

  def handle_info({reference, {:scan_error, reason}}, %{scan_task: %{ref: reference}} = state) do
    Process.demonitor(reference, [:flush])

    state =
      state
      |> Map.put(:scan_task, nil)
      |> finish_scan_failure(reason)
      |> start_next()
      |> start_pending_scan()

    {:noreply, state}
  end

  def handle_info({reference, results}, %{task: %{ref: reference}} = state) do
    Process.demonitor(reference, [:flush])
    state = state |> finish(results) |> start_next()
    {:noreply, state}
  end

  def handle_info({:DOWN, reference, :process, _pid, reason}, %{task: %{ref: reference}} = state) do
    failed = [%{status: :failed, label: state.current.label, reason: inspect(reason)}]
    state = state |> finish(failed) |> start_next()
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, reference, :process, _pid, reason},
        %{scan_task: %{ref: reference}} = state
      ) do
    state =
      state
      |> Map.put(:scan_task, nil)
      |> finish_scan_failure(reason)
      |> start_next()
      |> start_pending_scan()

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp enqueue(scope, server) do
    GenServer.cast(server, {:enqueue, scope})
    :ok
  end

  # Enqueued units are caller-supplied, so they are held to the same shape as scan-produced ones
  # (validate_scan_units/1). Dropping a malformed unit keeps the queue: raising here would take
  # the worker down and discard it until the next periodic scan. The scan path records its
  # rejection as a failed unit; here the caller is answered with :ok either way, so the log is
  # the only trace that something was thrown away.
  defp enqueue_valid_units(units, state) do
    {valid, dropped} = split_valid_units(units)
    log_dropped_units(dropped)

    valid
    |> add_units(state, :background)
    |> start_next()
  end

  # Walked by hand rather than with Enum: is_list/1 accepts an improper list, so Enum would crash
  # on the tail of one such as [unit | :junk]. Stopping at any non-list tail keeps the valid prefix
  # and drops the junk; the same clause absorbs a payload that is not a list at all. Body-recursive
  # is fine here: an enqueue carries a handful of units, not unbounded input.
  defp split_valid_units([unit | rest]) do
    {valid, dropped} = split_valid_units(rest)

    if valid_unit?(unit),
      do: {[unit | valid], dropped},
      else: {valid, [unit | dropped]}
  end

  defp split_valid_units([]), do: {[], []}
  defp split_valid_units(tail), do: {[], [tail]}

  defp log_dropped_units([]), do: :ok

  defp log_dropped_units(dropped) do
    Logger.warning(
      "dropped #{length(dropped)} malformed subtitle sync unit(s): " <>
        inspect(dropped, limit: 3, printable_limit: 80)
    )
  end

  defp mode(:library), do: :background
  defp mode(_scope), do: :priority

  defp add_units(units, state, :background) do
    {queue, queued} =
      Enum.reduce(units, {state.queue, state.queued}, fn unit, {queue, queued} ->
        path = unit.video_path

        if MapSet.member?(queued, path) or MapSet.member?(state.prioritized, path) do
          {queue, queued}
        else
          {:queue.in(unit, queue), MapSet.put(queued, path)}
        end
      end)

    publish(%{state | queue: queue, queued: queued})
  end

  defp add_units(units, state, :priority) do
    acc = {state.priority, state.prioritized, MapSet.new()}
    {priority, prioritized, promoted} = Enum.reduce(units, acc, &prioritize(&1, &2, state.queued))

    publish(%{
      state
      | priority: priority,
        prioritized: prioritized,
        queue: drop_promoted(state.queue, promoted),
        queued: MapSet.difference(state.queued, promoted)
    })
  end

  defp prioritize(unit, {priority, prioritized, promoted}, queued) do
    path = unit.video_path

    if MapSet.member?(prioritized, path) do
      {priority, prioritized, promoted}
    else
      promoted = if MapSet.member?(queued, path), do: MapSet.put(promoted, path), else: promoted
      {:queue.in(unit, priority), MapSet.put(prioritized, path), promoted}
    end
  end

  defp drop_promoted(queue, promoted) do
    if MapSet.size(promoted) == 0,
      do: queue,
      else: :queue.filter(&(not MapSet.member?(promoted, &1.video_path)), queue)
  end

  defp start_next(%{task: nil} = state) do
    state = sync_hold(state)

    case next_unit(state) do
      {unit, state} ->
        task =
          Task.Supervisor.async_nolink(state.task_supervisor, fn ->
            state.analyze.(unit.video_path)
          end)

        publish(%{state | current: unit, task: task})

      :empty ->
        publish(state)
    end
  end

  defp start_next(state), do: publish(sync_hold(state))

  defp next_unit(state) do
    case :queue.out(state.priority) do
      {{:value, unit}, priority} ->
        {unit,
         %{
           state
           | priority: priority,
             prioritized: MapSet.delete(state.prioritized, unit.video_path)
         }}

      {:empty, _priority} ->
        next_background_unit(state)
    end
  end

  # An explicit request is only known to the queue once its scan returns. Starting background work
  # in that window would hand the operator's slot to an unrelated title, so background work waits
  # for the outstanding explicit scan to land. A scan failure or crash clears scan_task, and the
  # wait is capped at @explicit_scan_hold so a scan that hangs cannot park the queue indefinitely.
  defp next_background_unit(state) do
    if explicit_scan_outstanding?(state) do
      :empty
    else
      case :queue.out(state.queue) do
        {{:value, unit}, queue} ->
          {unit, %{state | queue: queue, queued: MapSet.delete(state.queued, unit.video_path)}}

        {:empty, _queue} ->
          :empty
      end
    end
  end

  defp explicit_scan_outstanding?(%{hold_until: nil}), do: false
  defp explicit_scan_outstanding?(state), do: explicit_pending?(state)

  defp explicit_pending?(state) do
    scanning_explicitly?(state.scan_task) or
      Enum.any?(state.pending_scans, &(mode(&1) == :priority))
  end

  # Single owner of the deadline's lifetime. Once no explicit scan is outstanding, or the window
  # has elapsed, the hold has done its job: clearing it lets a later request arm a fresh window
  # instead of inheriting a stale one, and lets background work resume after a hung scan.
  defp sync_hold(%{hold_until: nil} = state), do: state

  defp sync_hold(state) do
    if explicit_pending?(state) and System.monotonic_time(:millisecond) < state.hold_until,
      do: state,
      else: %{state | hold_until: nil}
  end

  defp scanning_explicitly?(%{scope: scope}), do: mode(scope) == :priority
  defp scanning_explicitly?(nil), do: false

  # The hold starts when the operator asks, not when the scan happens to be dequeued, so an
  # explicit scope waiting behind a slow or hung library scan is covered by the same deadline.
  defp hold_explicitly(state, :library), do: state

  defp hold_explicitly(state, _scope) do
    # sync_hold/1 first: an expired deadline whose release message has not been processed yet must
    # not suppress a fresh hold for this request.
    state = sync_hold(state)

    if is_nil(state.hold_until) do
      gen = state.hold_gen + 1
      Process.send_after(self(), {:release_hold, gen}, state.hold)

      %{
        state
        | hold_until: System.monotonic_time(:millisecond) + state.hold,
          hold_gen: gen
      }
    else
      state
    end
  end

  defp start_scan(%{scan_task: nil} = state, scope) do
    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        run_scan(state.scan, scope)
      end)

    %{state | scan_task: %{ref: task.ref, scope: scope}}
  end

  defp start_scan(state, scope) do
    if scope == state.scan_task.scope or scope in state.pending_scans,
      do: state,
      else: %{state | pending_scans: state.pending_scans ++ [scope]}
  end

  defp run_scan(scan, scope) do
    case scan.(scope) do
      units when is_list(units) -> validate_scan_units(units)
      other -> {:scan_error, {:invalid_scan_result, other}}
    end
  rescue
    error -> {:scan_error, Exception.format(:error, error, __STACKTRACE__)}
  catch
    kind, reason -> {:scan_error, Exception.format(kind, reason, __STACKTRACE__)}
  end

  defp validate_scan_units(units) do
    if Enum.all?(units, &valid_unit?/1),
      do: {:scan_ok, units},
      else: {:scan_error, {:invalid_scan_result, units}}
  end

  defp valid_unit?(%{video_path: path, label: label}),
    do: is_binary(path) and path != "" and is_binary(label) and label != ""

  defp valid_unit?(_unit), do: false

  defp start_pending_scan(%{pending_scans: [scope | rest]} = state),
    do: start_scan(%{state | pending_scans: rest}, scope)

  defp start_pending_scan(state), do: state

  defp finish(state, results) do
    results = results |> well_formed() |> tag_results(state.current)

    managed_video_paths =
      if results == [],
        do: MapSet.delete(state.managed_video_paths, state.current.video_path),
        else: MapSet.put(state.managed_video_paths, state.current.video_path)

    counts =
      Enum.reduce(results, state.counts, fn result, counts ->
        Map.update!(counts, result.status, &(&1 + 1))
      end)

    recent = Enum.take(results ++ state.recent, 20)

    %{
      state
      | current: nil,
        task: nil,
        counts: counts,
        recent: recent,
        managed_video_paths: managed_video_paths
    }
  end

  # The analyzer is a seam, so a malformed result is dropped here rather than carried: `counts` and
  # `recent` are folded from the same list and must never drift, since the subtitle-sync view
  # derives its cursor into `recent` from the counts sum.
  defp well_formed(results) when is_list(results), do: Enum.filter(results, &well_formed?/1)
  defp well_formed(_results), do: []

  defp well_formed?(%{status: status}), do: status in [:aligned, :corrected, :review, :failed]
  defp well_formed?(_result), do: false

  defp tag_results(results, %{scopes: scopes}),
    do: Enum.map(results, &Map.put(&1, :scopes, scopes))

  defp tag_results(results, _unit), do: results

  defp finish_scan_failure(state, reason) do
    failure = %{status: :failed, label: "Library scan", reason: inspect(reason)}

    state
    |> Map.update!(:counts, &Map.update!(&1, :failed, fn count -> count + 1 end))
    |> Map.update!(:recent, &Enum.take([failure | &1], 20))
    |> publish()
  end

  defp publish(state) do
    status = snapshot(state)
    :persistent_term.put(@status_key, status)
    Phoenix.PubSub.broadcast(Cinder.PubSub, @topic, {:subtitle_sync_status, status})
    state
  rescue
    ArgumentError -> state
  end

  defp snapshot(state) do
    %{
      state: if(state.current, do: :running, else: :idle),
      queued: :queue.len(state.priority) + :queue.len(state.queue),
      current: state.current,
      counts: state.counts,
      recent: state.recent,
      review_items: Enum.filter(state.recent, &(&1.status in [:review, :failed]))
    }
  end

  defp schedule_scan(interval), do: Process.send_after(self(), :scan, interval)

  defp worker_alive?(server) when is_pid(server), do: Process.alive?(server)
  defp worker_alive?(server) when is_atom(server), do: not is_nil(Process.whereis(server))
end
