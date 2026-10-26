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
