defmodule Cinder.Library.BoundedWalk do
  @moduledoc """
  Runs a poller's directory walk under a wall-clock deadline (issue #779).

  `Cinder.Library.safe_walk/1`, the walk every importer and the completion content check run in
  their tick, goes through `run/3`. The walk runs in a task under
  `Cinder.Library.BoundedWalk.TaskSupervisor`. One that has not returned within the deadline
  (30 s) answers `{:error, :timeout}`. The three download pollers hold the import on it without
  spending the retry budget, as they do on a full disk, and the completion content check takes it
  as no opinion, like any walk that cannot run.

  A walk past its deadline is never killed. Its read may still sit in the kernel on a wedged
  mount, holding one of the VM's dirty I/O scheduler threads (10 by default, which the SQLite
  driver runs on too), and killing the process does not free that thread. So this guard counts
  each such walk as stuck until it returns by itself, and while it is stuck:

  - a new walk under the same root is refused at once with `{:error, :timeout}`, so the next poll
    does not stack a second stuck walk on the same mount;
  - once two walks are stuck in total, under any roots, every new walk is refused the same way.

  A refused walk never starts. The cap gates admissions: walks already running when the first one
  crosses its deadline can still end up stuck, at most one more per caller walking at that moment.
  Walks that are only running, not stuck, never refuse one another. A restarted guard has lost its
  count, so it takes every walk still running under its task supervisor as stuck until it returns.
  Those count towards the total cap only, since their roots are unknown.

  The deadline alone would not be enough, because the reads behind
  `Cinder.Library.PathPolicy.walk/2` used to go through the VM's one file server: a read stuck
  there blocked every `File` call in the app. `Cinder.Library.Filesystem.Disk` now answers
  `ls/1` and `lstat/1` with raw calls that skip it.
  """
  use GenServer

  require Logger

  @timeout_ms 30_000
  @max_stuck 2

  @doc false
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Runs `fun`, a walk under `root`, and returns its result, or `{:error, :timeout}` when it misses
  its deadline or the guard refuses it. A raise in `fun` raises in the caller.

  `root` is the key the guard counts a stuck walk against: the import root the walk reads under.
  Options, for tests: `:server` (the guard) and `:timeout_ms` (the deadline).
  """
  @spec run(term(), (-> result), keyword()) :: result | {:error, :timeout} when result: term()
  def run(root, fun, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    timeout_ms = Keyword.get_lazy(opts, :timeout_ms, &timeout_ms/0)

    # Started from the caller, not the guard, so the task inherits the caller's `$callers`.
    with {:ok, task_supervisor} <- GenServer.call(server, {:admit, root}) do
      task = Task.Supervisor.async_nolink(task_supervisor, fun)

      # `Task.ignore/1` still hands back a result that landed right at the deadline.
      case Task.yield(task, timeout_ms) || Task.ignore(task) do
        {:ok, result} -> result
        {:exit, reason} -> reraise_in_caller(reason)
        nil -> mark_stuck(server, root, task.pid, timeout_ms)
      end
    end
  end

  # Before #779 the walk ran in the caller, so a raise or an exit reached it directly.
  defp reraise_in_caller({exception, stacktrace}) when is_exception(exception),
    do: reraise(exception, stacktrace)

  defp reraise_in_caller(reason), do: exit(reason)

  defp mark_stuck(server, root, pid, timeout_ms) do
    :ok = GenServer.call(server, {:stuck, root, pid})

    Logger.warning(
      "directory walk under #{inspect(root)} did not return within #{timeout_ms} ms; " <>
        "a mount may be wedged. New walks under it fail until it returns."
    )

    {:error, :timeout}
  end

  # A test seam, like `Cinder.Library.Filesystem.Disk`'s `:disk_subprocess_timeout_ms`:
  # production never sets it.
  defp timeout_ms, do: Application.get_env(:cinder, :walk_timeout_ms, @timeout_ms)

  @impl true
  def init(opts) do
    task_supervisor = Keyword.get(opts, :task_supervisor, __MODULE__.TaskSupervisor)

    # Empty at boot. After a restart, a walk still running may be a stuck one this guard no longer
    # knows, so it counts towards the cap, under no root, until it returns.
    stuck =
      Map.new(Task.Supervisor.children(task_supervisor), fn pid ->
        Process.monitor(pid)
        {pid, :unknown_root}
      end)

    {:ok, %{task_supervisor: task_supervisor, stuck: stuck}}
  end

  @impl true
  def handle_call({:admit, root}, _from, state) do
    if root in Map.values(state.stuck) or map_size(state.stuck) >= @max_stuck,
      do: {:reply, {:error, :timeout}, state},
      else: {:reply, {:ok, state.task_supervisor}, state}
  end

  # A pid that already exited answers the monitor with `:noproc` at once, which frees its slot.
  def handle_call({:stuck, root, pid}, _from, state) do
    Process.monitor(pid)
    {:reply, :ok, put_in(state.stuck[pid], root)}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state),
    do: {:noreply, update_in(state.stuck, &Map.delete(&1, pid))}
end
