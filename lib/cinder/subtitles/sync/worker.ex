defmodule Cinder.Subtitles.Sync.Worker do
  @moduledoc """
  Serial background queue for CPU-heavy subtitle synchronization.

  The queue itself is intentionally ephemeral: initial and periodic catalog scans re-derive work
  from manifests and the filesystem after every restart.
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
      snapshot(%{current: nil, queue: :queue.new(), counts: @empty_counts, recent: []})
    )
  end

  @doc "Subscribes the caller to status updates."
  def subscribe, do: Phoenix.PubSub.subscribe(Cinder.PubSub, @topic)

  @doc "Enqueues all pending videos in the library."
  def enqueue_library(server \\ __MODULE__), do: enqueue(:library, server)
  def enqueue_movie(id, server \\ __MODULE__), do: enqueue({:movie, id}, server)
  def enqueue_series(id, server \\ __MODULE__), do: enqueue({:series, id}, server)
  def enqueue_season(id, server \\ __MODULE__), do: enqueue({:season, id}, server)
  def enqueue_episode(id, server \\ __MODULE__), do: enqueue({:episode, id}, server)

  @doc "Enqueues one freshly downloaded sidecar's video when the supervised worker is enabled."
  def enqueue_after_download(video_path) do
    GenServer.cast(__MODULE__, {
      :enqueue_units,
      [%{video_path: video_path, label: Path.basename(video_path)}]
    })

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
      current: nil,
      task: nil,
      scan_task: nil,
      pending_scans: [],
      task_supervisor: task_supervisor,
      scan: Keyword.get(opts, :scan, &Sync.units/1),
      analyze: Keyword.get(opts, :analyze, &Sync.analyze_video/1),
      interval: Keyword.get(opts, :interval, @default_interval),
      counts: @empty_counts,
      recent: []
    }

    publish(state)

    if Keyword.get(opts, :initial_scan, true),
      do: send(self(), :scan),
      else: schedule_scan(state.interval)

    {:ok, state}
  end

  @impl true
  def handle_call({:enqueue_units, units}, _from, state) do
    state = units |> add_units(state) |> start_next()
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:enqueue, scope}, state), do: {:noreply, start_scan(state, scope)}

  def handle_cast({:enqueue_units, units}, state),
    do: {:noreply, units |> add_units(state) |> start_next()}

  @impl true
  def handle_info(:scan, state) do
    schedule_scan(state.interval)
    {:noreply, start_scan(state, :library)}
  end

  def handle_info({reference, {:scan_ok, units}}, %{scan_task: %{ref: reference}} = state) do
    Process.demonitor(reference, [:flush])

    state = Map.put(state, :scan_task, nil)
    state = units |> add_units(state) |> start_next() |> start_pending_scan()

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
      |> start_pending_scan()

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp enqueue(scope, server) do
    GenServer.cast(server, {:enqueue, scope})
    :ok
  end

  defp add_units(units, state) do
    {queue, queued} =
      Enum.reduce(units, {state.queue, state.queued}, fn unit, {queue, queued} ->
        path = unit.video_path

        if MapSet.member?(queued, path) do
          {queue, queued}
        else
          {:queue.in(unit, queue), MapSet.put(queued, path)}
        end
      end)

    publish(%{state | queue: queue, queued: queued})
  end

  defp start_next(%{task: nil} = state) do
    case :queue.out(state.queue) do
      {{:value, unit}, queue} ->
        task =
          Task.Supervisor.async_nolink(state.task_supervisor, fn ->
            state.analyze.(unit.video_path)
          end)

        publish(%{
          state
          | queue: queue,
            queued: MapSet.delete(state.queued, unit.video_path),
            current: unit,
            task: task
        })

      {:empty, _queue} ->
        publish(state)
    end
  end

  defp start_next(state), do: publish(state)

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
    %{state | current: nil, task: nil, counts: counts, recent: recent}
  end

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
      queued: :queue.len(state.queue),
      current: state.current,
      counts: state.counts,
      recent: state.recent,
      review_items: Enum.filter(state.recent, &(&1.status in [:review, :failed]))
    }
  end

  defp schedule_scan(interval), do: Process.send_after(self(), :scan, interval)
end
