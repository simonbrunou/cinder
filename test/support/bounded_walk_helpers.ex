defmodule Cinder.BoundedWalkHelpers do
  @moduledoc """
  A directory walk stuck the way a read on a wedged mount is, for `Cinder.Library.BoundedWalk`
  and the pollers behind it (#779).
  """

  import ExUnit.Assertions

  alias Cinder.Library.BoundedWalk

  # `hang_walk/1` stores here, in the walk's process dictionary, when it sent `{:walking, pid}`.
  @walking_since {__MODULE__, :walking_since}

  @doc """
  Hangs the calling process, a walk, the way a read on a wedged mount does: reports
  `{:walking, pid}` to `test`, then waits until sent `:release` or until `test` ends. Returns
  `{:ok, []}`, an empty walk.
  """
  def hang_walk(test) do
    ref = Process.monitor(test)
    Process.put(@walking_since, System.monotonic_time(:millisecond))
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

  The scan is the head of the walk's `$callers`. When it exits with another reason, or had
  already exited before the page closed, the helper fails at once with a message saying so (#1361).
  The second message says whether the LiveView was still alive then, and how long after `walk`
  sent `{:walking, walk}`, in a walk `hang_walk/1` holds.

  The helper waits `:timeout_ms` for the scan's `:DOWN`, by default ExUnit's
  `assert_receive_timeout`. Past it, it fails with a message saying whether the LiveView had
  exited and, when the scan is still alive, its status, current stacktrace and mailbox length
  (#1463).
  """
  def close_page_during_walk(live_view, walk, opts \\ []) do
    timeout_ms =
      Keyword.get_lazy(opts, :timeout_ms, fn ->
        Application.fetch_env!(:ex_unit, :assert_receive_timeout)
      end)

    {:dictionary, dictionary} = Process.info(walk, :dictionary)
    [scan | _callers] = Keyword.fetch!(dictionary, :"$callers")
    ref = Process.monitor(scan)
    # What the helper saw when it monitored the scan, for the message on `:noproc`.
    seen = %{live_view_alive?: Process.alive?(live_view), at: System.monotonic_time(:millisecond)}
    Process.flag(:trap_exit, true)
    Process.exit(live_view, {:shutdown, :closed})

    reason =
      receive do
        {:DOWN, ^ref, :process, ^scan, reason} -> reason
      after
        timeout_ms -> flunk(scan_stuck_message(scan, live_view, timeout_ms))
      end

    # Also before the failures below, so the guard's warning about the scan lands in the test's
    # captured log.
    _ = :sys.get_state(BoundedWalk)

    case reason do
      {:shutdown, :closed} ->
        :ok

      :noproc ->
        flunk(scan_gone_message(scan, live_view, seen, walk, dictionary))

      other ->
        flunk(
          "close_page_during_walk/2: the scan #{inspect(scan)} exited with #{inspect(other)}, " <>
            "not {:shutdown, :closed}, when the page closed."
        )
    end
  end

  # The scan's `:DOWN` had not arrived `timeout_ms` after the helper sent the LiveView its exit.
  defp scan_stuck_message(scan, live_view, timeout_ms) do
    scan_state =
      case Process.info(scan, [:status, :current_stacktrace, :message_queue_len]) do
        nil -> "had exited by then, its :DOWN not yet received"
        info -> "is alive, #{inspect(info)}"
      end

    live_view_state = if Process.alive?(live_view), do: "is still alive", else: "had exited"

    "close_page_during_walk/2: no :DOWN for the scan #{inspect(scan)} arrived within " <>
      "#{timeout_ms} ms after the helper sent the LiveView exit {:shutdown, :closed}. " <>
      "The scan #{scan_state}. " <>
      "The LiveView #{inspect(live_view)} #{live_view_state}."
  end

  # The scan was gone when the helper monitored it, before the helper stopped the LiveView.
  defp scan_gone_message(scan, live_view, seen, walk, dictionary) do
    live_view_state = if seen.live_view_alive?, do: "was still alive", else: "had already exited"

    since =
      case List.keyfind(dictionary, @walking_since, 0) do
        {_key, sent_at} ->
          ", #{seen.at - sent_at} ms after the walk sent " <>
            "{:walking, #{inspect(walk)}}"

        nil ->
          ""
      end

    "close_page_during_walk/2: the scan #{inspect(scan)} had already exited before the page " <>
      "closed (its monitor answered :noproc). The LiveView #{inspect(live_view)} " <>
      "#{live_view_state} at that point#{since}. The guard's warning in the log, when logged, " <>
      "names the reason its own monitor on the scan reported."
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
