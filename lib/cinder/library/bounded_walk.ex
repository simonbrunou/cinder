defmodule Cinder.Library.BoundedWalk do
  @moduledoc """
  Runs a directory walk under a wall-clock deadline (issues #779, #944).

  `docs/agents/architecture.md` ("Background work is supervised and bounded") lists the walks
  that go through `run/3`. Each caller's own docs say what it does with a timeout.

  The walk runs in a task under `Cinder.Library.BoundedWalk.TaskSupervisor`. One that has not
  returned within the deadline (30 s unless the caller passes `:timeout_ms`) answers
  `{:error, :timeout}`.

  A walk past its deadline is never killed. Its read may still sit in the kernel on a wedged
  mount, holding one of the VM's dirty I/O scheduler threads (10 by default, which the SQLite
  driver runs on too), and killing the process does not free that thread. So this guard counts
  each such walk as stuck until it returns by itself, and while it is stuck:

  - a new walk under the same root is refused at once with `{:error, :timeout}`, so the next poll
    does not stack a second stuck walk on the same mount;
  - once two walks are stuck in total, under any roots, every new walk is refused the same way.

  A walk also counts as stuck, before its deadline, once its caller exits while it still runs,
  since no caller is left to report the deadline (#1168). A page's scan exits that way when the
  page is closed or reloaded: `start_async` links it to the LiveView. So a reload no longer starts
  one more walk on a wedged mount, at a cost: a healthy walk whose page closes mid-walk counts as
  stuck until it finishes, and the guard logs a warning for it.

  A refused walk never starts. The cap gates admissions: walks already running when the first one
  crosses its deadline can still end up stuck, at most one more per caller walking at that moment.
  Walks running inside their deadline under a living caller never refuse one another. A restarted
  guard has lost its count, so it takes every walk still running under its task supervisor as
  stuck until it returns. Those count towards the total cap only, since their roots are unknown,
  until a caller still alive reports one past its deadline: from then on, it refuses its root too.

  `stuck_roots/1` reads the walks the guard counts as stuck, so a page can show them (#948).

  The deadline alone would not be enough, because the reads behind
  `Cinder.Library.PathPolicy.walk/2` used to go through the VM's one file server: a read stuck
  there blocked every `File` call in the app. `Cinder.Library.Filesystem.Disk` now answers
  `ls/1`, `lstat/1` and `dir?/1` with raw calls that skip it.
  """
  use GenServer

  require Logger

  alias Cinder.Library.PathPolicy

  @timeout_ms 30_000
  @max_stuck 2
  @read_timeout_ms 1_000

  @doc false
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  The `root` key for a walk of `path` confined to `roots`: the deepest of `roots` holding `path`,
  else `path` itself, which such a walk refuses before any read.
  """
  @spec walk_root(String.t(), [String.t()]) :: String.t()
  def walk_root(path, roots), do: PathPolicy.deepest_root(path, roots) || Path.expand(path)

  @doc """
  Runs `fun`, a walk under `root`, and returns its result, or `{:error, :timeout}` when it misses
  its deadline or the guard refuses it. A raise in `fun` raises in the caller.

  `root` is the key the guard counts a stuck walk against: the root the walk reads under.

  Options: `:timeout_ms`, the deadline, 30 s by default; and, for tests, `:server`, the guard.
  """
  @spec run(term(), (-> result), keyword()) :: result | {:error, :timeout} when result: term()
  def run(root, fun, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    timeout_ms = Keyword.get_lazy(opts, :timeout_ms, &timeout_ms/0)
    caller = self()

    # Started from the caller, not the guard, so the task inherits the caller's `$callers`.
    with {:ok, task_supervisor} <- GenServer.call(server, {:admit, root}) do
      task =
        Task.Supervisor.async_nolink(task_supervisor, fn -> walk(server, root, caller, fun) end)

      # `Task.ignore/1` still hands back a result that landed right at the deadline.
      case Task.yield(task, timeout_ms) || Task.ignore(task) do
        {:ok, result} -> result
        {:exit, reason} -> reraise_in_caller(reason)
        nil -> mark_stuck(server, root, task.pid, timeout_ms)
      end
    end
  end

  @doc """
  The walks the guard counts as stuck, read from its state (#948). `roots` holds the root of each
  one, sorted, with `:unknown_root` for a walk a restarted guard took over, until a caller still
  alive reports it past its deadline: one entry per walk, so a root can appear twice.
  `cap_reached?` is true while the guard refuses every new walk.

  A guard that is not running, or does not answer within `:timeout_ms` (1 s by default), reads as
  no stuck walk, with a warning in the log, so a page that shows this never waits longer or
  crashes.

  Options: `:timeout_ms`; and, for tests, `:server`, the guard.
  """
  @spec stuck_roots(keyword()) :: %{roots: [term()], cap_reached?: boolean()}
  def stuck_roots(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, :stuck_roots, Keyword.get(opts, :timeout_ms, @read_timeout_ms))
  catch
    :exit, reason ->
      Logger.warning("could not read the stuck directory walks: #{inspect(reason)}")
      %{roots: [], cap_reached?: false}
  end

  # The walk's task, not its caller, tells the guard that the walk started and that it returned,
  # so the guard watches the caller and learns when it exits first (#1168). The guard monitors a
  # caller that already exited with an at-once `:noproc`, so no start goes unwatched. Both calls
  # wait for the guard's reply, and the return call runs before the task replies: by the time the
  # caller can see the result, a raise or an exit, the guard no longer watches it.
  defp walk(server, root, caller, fun) do
    :ok = GenServer.call(server, {:started, root, caller, self()})

    try do
      fun.()
    after
      returned(server)
    end
  end

  # A guard that stopped after this walk started has nothing left to forget, and a restarted one
  # learns the return from the walk's exit. The result still reaches the caller.
  defp returned(server) do
    GenServer.call(server, {:returned, self()})
  catch
    :exit, _reason -> :ok
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

  # The default deadline's test seam, like `Cinder.Library.Filesystem.Disk`'s
  # `:disk_subprocess_timeout_ms`: production never sets it.
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

    # `walks` holds each walk running inside its deadline, task pid to its root and the monitor
    # on its caller; `stuck`, each stuck walk, task pid to its root.
    {:ok, %{task_supervisor: task_supervisor, stuck: stuck, walks: %{}}}
  end

  @impl true
  def handle_call({:admit, root}, _from, state) do
    if root in Map.values(state.stuck) or capped?(state),
      do: {:reply, {:error, :timeout}, state},
      else: {:reply, {:ok, state.task_supervisor}, state}
  end

  def handle_call(:stuck_roots, _from, state) do
    stuck = %{roots: state.stuck |> Map.values() |> Enum.sort(), cap_reached?: capped?(state)}
    {:reply, stuck, state}
  end

  # A walk its caller already reported stuck, before the task got here, is monitored and counted
  # already: its caller has nothing left to report.
  def handle_call({:started, root, caller, task}, _from, state) do
    if Map.has_key?(state.stuck, task) do
      {:reply, :ok, state}
    else
      Process.monitor(task)
      walk = %{root: root, caller: Process.monitor(caller)}
      {:reply, :ok, put_in(state.walks[task], walk)}
    end
  end

  def handle_call({:returned, task}, _from, state), do: {:reply, :ok, forget(state, task)}

  # From a living caller whose walk missed its deadline. A task that has not registered yet, or has
  # already returned, is monitored here; one that already exited answers with `:noproc` at once,
  # which frees its slot.
  def handle_call({:stuck, root, task}, _from, state) do
    {walk, walks} = Map.pop(state.walks, task)

    if walk,
      do: Process.demonitor(walk.caller, [:flush]),
      else: Process.monitor(task)

    {:reply, :ok, %{state | walks: walks, stuck: Map.put(state.stuck, task, root)}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Enum.find(state.walks, fn {_task, walk} -> walk.caller == ref end) do
      {task, walk} -> {:noreply, orphan(state, task, walk.root)}
      nil -> {:noreply, forget(state, pid)}
    end
  end

  # The walk's caller exited before it reported the walk stuck, so nobody will: the walk counts as
  # stuck now, healthy or not, until it returns (#1168). A task that already exited without
  # returning, such as a killed one, is not counted: its own `:DOWN` is on its way.
  defp orphan(state, task, root) do
    state = %{state | walks: Map.delete(state.walks, task)}

    if Process.alive?(task) do
      Logger.warning(
        "directory walk under #{inspect(root)} still runs, but its caller exited before " <>
          "reporting it past its deadline; a mount may be wedged. New walks under it fail " <>
          "until it returns."
      )

      put_in(state.stuck[task], root)
    else
      state
    end
  end

  # Every new walk is refused while this holds, under any root.
  defp capped?(state), do: map_size(state.stuck) >= @max_stuck

  defp forget(state, task) do
    {walk, walks} = Map.pop(state.walks, task)
    if walk, do: Process.demonitor(walk.caller, [:flush])
    %{state | walks: walks, stuck: Map.delete(state.stuck, task)}
  end
end
