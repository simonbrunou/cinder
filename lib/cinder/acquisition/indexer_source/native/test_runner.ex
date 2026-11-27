defmodule Cinder.Acquisition.IndexerSource.Native.TestRunner do
  @moduledoc """
  Runs the per-indexer Test (`Cinder.Acquisition.IndexerSource.Native.test_indexer/1`) outside
  the page that asks for it (#1660, #1625 point 11), so closing the tab does not cancel it. The
  indexers table in `/settings` and `/setup` (#1663) starts it from its Test button and from a
  save in its Add and Edit dialogs (#1661), and `Cinder.Indexers.ProwlarrImport.commit/3` (#1673)
  starts it for each enabled indexer it created, through `start/1`.

  This process holds the pending mark: each Test runs in a child of
  `Cinder.Acquisition.IndexerSource.Native.TestRunner.TaskSupervisor`, unlinked and monitored,
  under the search processes' heap cap (`Native.max_heap_size/0`, #1678),
  and the mark of its indexer stays until the task answers or exits, a raise or a kill included.
  `start/1` while the mark is held starts nothing. Should this process itself die, its marks go
  with it. Its restart ends every task its supervisor still holds, so no Test runs without a
  mark, then broadcasts `:reset`; an ended task sends no finish.

  Each start and each end is broadcast on `topic/0` of `Cinder.PubSub`:

  - `{#{inspect(__MODULE__)}, :started, id}`;
  - `{#{inspect(__MODULE__)}, :finished, id, result}`, sent once the mark has cleared, where
    `result` is `Native.test_indexer/1`'s answer, or `{:error, :crashed}` for a task that exited;
  - `{#{inspect(__MODULE__)}, :reset}` when the runner starts, holding no mark.

  `Native.test_indexer/1` drops the answer of a Test whose indexer was edited
  (`config_version`) or deleted while it ran; the finish is still broadcast.
  """
  use GenServer

  alias Cinder.Acquisition.IndexerSource.Native

  @topic "native_indexer_tests"

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Starts the Test of the configured indexer `id`, with `opts` as `Native.test_indexer/2` takes
  them (a captcha answer, #1681): `:ok`, or `{:error, :running}` when a Test of that indexer
  still runs, which starts nothing.
  """
  @spec start(pos_integer(), keyword()) :: :ok | {:error, :running}
  def start(id, opts \\ []) when is_integer(id) and is_list(opts),
    do: GenServer.call(__MODULE__, {:start, id, opts})

  @doc "The ids of the configured indexers whose Test runs now."
  @spec running() :: MapSet.t(pos_integer())
  def running, do: GenServer.call(__MODULE__, :running)

  @doc "The `Cinder.PubSub` topic of the start and finish messages."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Subscribes the calling process to `topic/0`."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Cinder.PubSub, @topic)

  @impl true
  def init(_opts) do
    for pid <- Task.Supervisor.children(__MODULE__.TaskSupervisor),
        do: Task.Supervisor.terminate_child(__MODULE__.TaskSupervisor, pid)

    broadcast({__MODULE__, :reset})
    {:ok, %{}}
  end

  # The state maps each running task's monitor ref to its indexer id.
  @impl true
  def handle_call({:start, id, opts}, _from, tasks) do
    if id in Map.values(tasks) do
      {:reply, {:error, :running}, tasks}
    else
      task = Task.Supervisor.async_nolink(__MODULE__.TaskSupervisor, fn -> test(id, opts) end)

      broadcast({__MODULE__, :started, id})
      {:reply, :ok, Map.put(tasks, task.ref, id)}
    end
  end

  def handle_call(:running, _from, tasks), do: {:reply, MapSet.new(Map.values(tasks)), tasks}

  @impl true
  def handle_info({ref, result}, tasks) when is_map_key(tasks, ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish(tasks, ref, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, tasks) when is_map_key(tasks, ref),
    do: {:noreply, finish(tasks, ref, {:error, :crashed})}

  def handle_info(_message, tasks), do: {:noreply, tasks}

  # The Test parses its answer in this task, a Cardigann JSON or XML page included (#1678), so it
  # runs under the search processes' heap cap: a kill reads as `{:error, :crashed}`.
  defp test(id, opts) do
    Process.flag(:max_heap_size, Native.max_heap_size())
    Native.test_indexer(id, opts)
  end

  # The mark clears before the finish goes out, so a subscriber that asks `running/0` on the
  # finish no longer finds the id.
  defp finish(tasks, ref, result) do
    {id, tasks} = Map.pop!(tasks, ref)
    broadcast({__MODULE__, :finished, id, result})
    tasks
  end

  defp broadcast(message), do: Phoenix.PubSub.broadcast(Cinder.PubSub, @topic, message)
end
