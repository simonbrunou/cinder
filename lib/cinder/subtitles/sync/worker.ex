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

  alias Cinder.Subtitles.Sync

  @status_key {__MODULE__, :status}
  @topic "subtitle_sync:status"
  @default_interval :timer.hours(12)
  @empty_counts %{aligned: 0, corrected: 0, review: 0, failed: 0}

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
    state = units |> add_units(state, :background) |> start_next()
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:enqueue, scope}, state), do: {:noreply, start_scan(state, scope)}

  def handle_cast({:enqueue_units, units}, state),
    do: {:noreply, units |> add_units(state, :background) |> start_next()}

  @impl true
  def handle_info(:scan, state) do
    schedule_scan(state.interval)
    {:noreply, start_scan(state, :library)}
  end

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
      |> start_pending_scan()

    {:noreply, state}
  end

  def handle_info({reference, results}, %{task: %{ref: reference}} = state) do
    Process.demonitor(reference, [:flush])
    state = state |> finish(tag_results(results, state.current)) |> start_next()
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
      |> start_pending_scan()

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp enqueue(scope, server) do
    GenServer.cast(server, {:enqueue, scope})
    :ok
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

  defp start_next(state), do: publish(state)

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
        case :queue.out(state.queue) do
          {{:value, unit}, queue} ->
            {unit, %{state | queue: queue, queued: MapSet.delete(state.queued, unit.video_path)}}

          {:empty, _queue} ->
            :empty
        end
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
    results = if is_list(results), do: results, else: []

    managed_video_paths =
      if results == [],
        do: MapSet.delete(state.managed_video_paths, state.current.video_path),
        else: MapSet.put(state.managed_video_paths, state.current.video_path)

    counts =
      Enum.reduce(results, state.counts, fn result, counts ->
        case Map.get(result, :status) do
          status when status in [:aligned, :corrected, :review, :failed] ->
            Map.update!(counts, status, &(&1 + 1))

          _ ->
            counts
        end
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

  defp tag_results(results, %{scopes: scopes}) when is_list(results),
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
