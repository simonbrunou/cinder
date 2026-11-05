defmodule Cinder.BoundedWalkHelpers do
  @moduledoc """
  A directory walk stuck the way a read on a wedged mount is, for `Cinder.Library.BoundedWalk`
  and the pollers behind it (#779).
  """

  import ExUnit.Assertions

  alias Cinder.Library.BoundedWalk

  @doc """
  Hangs the calling process, a walk, the way a read on a wedged mount does: reports
  `{:walking, pid}` to `test`, then waits until sent `:release` or until `test` ends. Returns
  `{:ok, []}`, an empty walk.
  """
  def hang_walk(test) do
    ref = Process.monitor(test)
    send(test, {:walking, self()})

    receive do
      :release -> {:ok, []}
      {:DOWN, ^ref, :process, _pid, _reason} -> {:ok, []}
    end
  end

  @doc """
  Runs `fun` in a task while the VM's one file server (`:file_server_2`) is suspended, and returns
  `Task.yield/2`'s answer, or `nil` when `fun` was still blocked after `timeout_ms`. Call `fun`
  once beforehand, so the blocked run loads no code.
  """
  def yield_while_file_server_blocked(fun, timeout_ms \\ 2_000) do
    :ok = :sys.suspend(:file_server_2)

    try do
      task = Task.async(fun)
      Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill)
    after
      :sys.resume(:file_server_2)
    end
  end

  @doc """
  Releases a walk `hang_walk/1` holds and returns once `guard` has seen it return, so the guard
  admits walks under its root again.
  """
  def release_walk(walk, guard \\ BoundedWalk) do
    ref = Process.monitor(walk)
    send(walk, :release)
    assert_receive {:DOWN, ^ref, :process, ^walk, _reason}
    _ = :sys.get_state(guard)
    :ok
  end

  @doc """
  Releases a walk `hang_walk/1` holds when the test ends, pass or fail, and waits until the app's
  guard has seen it return, so no later test finds its root refused.
  """
  def release_walk_on_exit(walk) do
    ExUnit.Callbacks.on_exit(fn ->
      ref = Process.monitor(walk)
      send(walk, :release)

      receive do
        {:DOWN, ^ref, :process, ^walk, _reason} -> :sys.get_state(BoundedWalk)
      end
    end)

    walk
  end

  @doc """
  Stops `live_view`, a LiveView pid, the way a closed or reloaded tab does, with
  `{:shutdown, :closed}`, while `walk`, a walk its scan started, hangs. Returns once the app's
  guard has seen the scan exit (#1168). Traps exits in the test, which is linked to the test client
  proxy that stops with the LiveView.

  A LiveView that stops on its own socket's close waits up to 5 s for its async tasks in a test
  (`await_asyncs_on_graceful_shutdown`), never in production: this one stops at once, as in
  production.
  """
  def close_page_during_walk(live_view, walk) do
    {:dictionary, dictionary} = Process.info(walk, :dictionary)
    [scan | _callers] = Keyword.fetch!(dictionary, :"$callers")
    ref = Process.monitor(scan)
    Process.flag(:trap_exit, true)
    Process.exit(live_view, {:shutdown, :closed})
    assert_receive {:DOWN, ^ref, :process, ^scan, {:shutdown, :closed}}
    _ = :sys.get_state(BoundedWalk)
    :ok
  end

  @doc """
  Leaves a walk stuck under `root` in the app's guard, so every walk under `root` answers
  `{:error, :timeout}` at once until the test ends (`release_walk_on_exit/1`).
  """
  def wedge_walks_under(root) do
    test = self()

    {result, _warning} =
      ExUnit.CaptureLog.with_log(fn ->
        BoundedWalk.run(root, fn -> hang_walk(test) end, timeout_ms: 10)
      end)

    assert result == {:error, :timeout}
    assert_receive {:walking, walk}
    release_walk_on_exit(walk)
  end
end
