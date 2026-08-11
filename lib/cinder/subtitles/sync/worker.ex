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
    case Process.whereis(__MODULE__) do
      nil -> :ok
      _pid -> enqueue_units([%{video_path: video_path, label: Path.basename(video_path)}])
    end
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
  def handle_call({:enqueue, scope}, _from, state) do
    state = state.scan.(scope) |> add_units(state) |> start_next()
    {:reply, :ok, state}
  end

  def handle_call({:enqueue_units, units}, _from, state) do
    state = units |> add_units(state) |> start_next()
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:scan, state) do
    state = state.scan.(:library) |> add_units(state) |> start_next()
    schedule_scan(state.interval)
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

  def handle_info(_message, state), do: {:noreply, state}

  defp enqueue(scope, server) do
    GenServer.call(server, {:enqueue, scope})
  end

  defp add_units(units, state) do
    {queue, queued} =
      Enum.reduce(units, {state.queue, state.queued}, fn unit, {queue, queued} ->
        path = unit.video_path

        if MapSet.member?(queued, path) or current_path(state) == path do
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

  defp current_path(%{current: nil}), do: nil
  defp current_path(%{current: current}), do: current.video_path
  defp schedule_scan(interval), do: Process.send_after(self(), :scan, interval)
end
