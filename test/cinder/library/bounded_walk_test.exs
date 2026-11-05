defmodule Cinder.Library.BoundedWalkTest do
  # Each test starts its own guard and task supervisor, so a walk a test leaves stuck never
  # refuses another test's.
  use ExUnit.Case, async: true

  import Cinder.BoundedWalkHelpers

  alias Cinder.Library.BoundedWalk

  # A stuck walk logs a warning; a raising one, its task's crash.
  @moduletag :capture_log

  # A walk meant to stick runs under @stuck_deadline. Every other walk gets @deadline, far above
  # what a loaded CI runner takes to start, run and crash a task: a 200 ms one missed it.
  @stuck_deadline 300
  @deadline 10_000

  setup do
    tasks = start_supervised!(Task.Supervisor)
    %{guard: start_guard(tasks), tasks: tasks}
  end

  test "a walk that finishes in time returns its result", %{guard: guard} do
    assert {:ok, [{"/downloads/a.mkv", 1}]} =
             run(guard, "/downloads", fn -> {:ok, [{"/downloads/a.mkv", 1}]} end)
  end

  test "a walk that never returns ends with {:error, :timeout} at the deadline", %{guard: guard} do
    {elapsed, result} = :timer.tc(fn -> stuck(guard, "/downloads") end, :millisecond)

    assert result == {:error, :timeout}
    assert elapsed >= @stuck_deadline
    assert elapsed < @stuck_deadline + 2_000
    assert_receive {:walking, _pid}
  end

  test "a root with a stuck walk refuses a new walk at once, and other roots still walk", %{
    guard: guard
  } do
    assert {:error, :timeout} = stuck(guard, "/downloads")
    assert_receive {:walking, _pid}

    {elapsed, result} = :timer.tc(fn -> run(guard, "/downloads", spy_walk()) end, :millisecond)

    assert result == {:error, :timeout}
    assert elapsed < 1_000
    refute_received :spy_walked

    assert {:ok, []} = run(guard, "/usenet", spy_walk())
    assert_received :spy_walked
  end

  test "walks still running inside their deadline do not refuse one more", %{guard: guard} do
    held = stuck_walk()
    first = Task.async(fn -> run(guard, "/downloads", held) end)
    assert_receive {:walking, first_walk}

    assert {:ok, []} = run(guard, "/downloads", spy_walk())
    assert_received :spy_walked

    send(first_walk, :release)
    assert {:ok, []} = Task.await(first)
  end

  test "while the stuck-walk cap is reached, a walk under any root is refused at once, " <>
         "and walks work again once a stuck one returns",
       %{guard: guard} do
    assert {:error, :timeout} = stuck(guard, "/downloads")
    assert_receive {:walking, downloads_walk}
    assert {:error, :timeout} = stuck(guard, "/usenet")
    assert_receive {:walking, _usenet_walk}

    {elapsed, result} = :timer.tc(fn -> run(guard, "/books", spy_walk()) end, :millisecond)

    assert result == {:error, :timeout}
    assert elapsed < 1_000
    refute_received :spy_walked

    release_walk(downloads_walk, guard)

    assert {:ok, []} = run(guard, "/books", spy_walk())
    assert_received :spy_walked
    assert {:ok, []} = run(guard, "/downloads", spy_walk())
    assert_received :spy_walked
    assert {:error, :timeout} = run(guard, "/usenet", spy_walk())
    refute_received :spy_walked
  end

  test "a restarted guard counts the walks still running as stuck until they return", %{
    guard: guard,
    tasks: tasks
  } do
    assert {:error, :timeout} = stuck(guard, "/downloads")
    assert_receive {:walking, downloads_walk}
    assert {:error, :timeout} = stuck(guard, "/usenet")
    assert_receive {:walking, _usenet_walk}

    stop_supervised!(BoundedWalk)
    guard = start_guard(tasks)

    assert {:error, :timeout} = run(guard, "/books", spy_walk())
    refute_received :spy_walked

    release_walk(downloads_walk, guard)

    assert {:ok, []} = run(guard, "/books", spy_walk())
    assert_received :spy_walked
  end

  test "a walk that returns after its deadline leaves no reply in the caller's mailbox", %{
    guard: guard
  } do
    assert {:error, :timeout} = stuck(guard, "/downloads")
    assert_receive {:walking, walk}

    release_walk(walk, guard)

    refute_receive _late_reply, 100
  end

  test "a walk that raises raises in the caller", %{guard: guard} do
    assert_raise RuntimeError, "unexpected call", fn ->
      run(guard, "/downloads", fn -> raise "unexpected call" end)
    end
  end

  describe "a walk whose caller exits before the walk returns (#1168)" do
    test "counts as stuck once its caller is killed before the deadline: its root refuses a " <>
           "new walk at once, and other roots still walk",
         %{guard: guard} do
      orphan(guard, "/downloads")

      {elapsed, result} = :timer.tc(fn -> run(guard, "/downloads", spy_walk()) end, :millisecond)

      assert result == {:error, :timeout}
      assert elapsed < 1_000
      refute_received :spy_walked

      assert {:ok, []} = run(guard, "/usenet", spy_walk())
      assert_received :spy_walked
    end

    test "counts towards the cap: with two such walks, a walk under a third root is refused at " <>
           "once",
         %{guard: guard} do
      orphan(guard, "/downloads")
      orphan(guard, "/usenet")

      {elapsed, result} = :timer.tc(fn -> run(guard, "/books", spy_walk()) end, :millisecond)

      assert result == {:error, :timeout}
      assert elapsed < 1_000
      refute_received :spy_walked
    end

    test "counts as stuck when its caller is a task linked to an owner that stops with " <>
           "{:shutdown, :closed}, as a LiveView does when its socket closes",
         %{guard: guard} do
      test = self()
      walk = stuck_walk()

      owner =
        start_caller(fn ->
          {:ok, caller} = Task.start_link(fn -> run(guard, "/downloads", walk) end)
          send(test, {:caller, caller})

          receive do
            :close -> exit({:shutdown, :closed})
          end
        end)

      assert_receive {:caller, caller}
      assert_receive {:walking, _walk}
      ref = Process.monitor(caller)
      send(owner, :close)
      assert_receive {:DOWN, ^ref, :process, ^caller, {:shutdown, :closed}}
      _ = :sys.get_state(guard)

      assert {:error, :timeout} = run(guard, "/downloads", spy_walk())
      refute_received :spy_walked
    end

    test "logs a warning naming its root", %{guard: guard} do
      log = ExUnit.CaptureLog.capture_log(fn -> orphan(guard, "/downloads") end)

      assert log =~ ~s(directory walk under "/downloads")
      assert log =~ "its caller exited before reporting it past its deadline"
    end

    test "is admitted again under its root once it returns by itself", %{guard: guard} do
      walk = orphan(guard, "/downloads")

      release_walk(walk, guard)

      assert {:ok, []} = run(guard, "/downloads", spy_walk())
      assert_received :spy_walked
    end

    test "is not counted, nor warned about, when its task already exited without returning", %{
      guard: guard
    } do
      walk = stuck_walk()
      caller = start_caller(fn -> run(guard, "/downloads", walk) end)
      assert_receive {:walking, hung}

      # The guard sees the caller's exit first, with the walk's task already dead.
      :sys.suspend(guard)
      kill(caller)
      kill(hung)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          :sys.resume(guard)
          :sys.get_state(guard)
        end)

      refute log =~ "its caller exited"
      assert {:ok, []} = run(guard, "/downloads", spy_walk())
      assert_received :spy_walked
    end

    test "is not warned about when its caller reported it stuck before its task reached the " <>
           "guard, and that caller then exits",
         %{guard: guard} do
      test = self()
      walk = stuck_walk()
      relay = start_caller(fn -> relay(guard, []) end)

      caller =
        start_caller(fn ->
          send(
            test,
            {:result, BoundedWalk.run("/downloads", walk, server: relay, timeout_ms: 10)}
          )

          receive do
            :exit -> :ok
          end
        end)

      ref = Process.monitor(caller)
      assert_receive {:result, {:error, :timeout}}
      send(relay, :let_start)
      assert_receive {:walking, _hung}

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          send(caller, :exit)
          assert_receive {:DOWN, ^ref, :process, ^caller, :normal}
          :sys.get_state(guard)
        end)

      refute log =~ "its caller exited"
      assert {:error, :timeout} = run(guard, "/downloads", spy_walk())
      refute_received :spy_walked
    end

    test "reaches its caller only once the guard has stopped watching the caller", %{
      guard: guard
    } do
      test = self()
      walk = stuck_walk()
      caller = start_caller(fn -> send(test, {:result, run(guard, "/downloads", walk)}) end)
      ref = Process.monitor(caller)
      assert_receive {:walking, hung}

      # A guard that cannot answer holds the result back, so it cannot see the caller exit on the
      # result before it sees the walk return.
      :sys.suspend(guard)
      send(hung, :release)
      refute_receive {:result, _result}, 200

      :sys.resume(guard)
      assert_receive {:result, {:ok, []}}
      assert_receive {:DOWN, ^ref, :process, ^caller, :normal}
      assert {:ok, []} = run(guard, "/downloads", spy_walk())
      assert_received :spy_walked
    end

    test "leaves nothing counted when its caller got the result and exits normally", %{
      guard: guard
    } do
      test = self()

      for _round <- 1..100 do
        caller =
          start_caller(fn ->
            send(test, {:result, run(guard, "/downloads", fn -> {:ok, []} end)})
          end)

        # The caller may be gone before the monitor starts: `:noproc` then.
        ref = Process.monitor(caller)
        assert_receive {:result, {:ok, []}}
        assert_receive {:DOWN, ^ref, :process, ^caller, _reason}

        assert {:ok, []} = run(guard, "/downloads", spy_walk())
        assert_received :spy_walked
      end
    end
  end

  defp start_guard(tasks),
    do: start_supervised!({BoundedWalk, name: nil, task_supervisor: tasks})

  defp run(guard, root, fun),
    do: BoundedWalk.run(root, fun, server: guard, timeout_ms: @deadline)

  defp stuck(guard, root),
    do: BoundedWalk.run(root, stuck_walk(), server: guard, timeout_ms: @stuck_deadline)

  # Starts a walk under `root` that hangs, with a deadline its caller never reaches, kills the
  # caller, and returns the walk once the guard has seen the caller go.
  defp orphan(guard, root) do
    walk = stuck_walk()
    caller = start_caller(fn -> run(guard, root, walk) end)
    assert_receive {:walking, hung}
    kill(caller)
    _ = :sys.get_state(guard)
    hung
  end

  # Stands in for `guard` and passes each call on to it, which replies to the caller directly,
  # except a walk task's `{:started, ...}`: that waits until the relay is sent `:let_start`.
  defp relay(guard, held) do
    receive do
      {:"$gen_call", _from, {:started, _root, _caller, _task}} = call ->
        relay(guard, [call | held])

      :let_start ->
        Enum.each(held, &send(guard, &1))
        relay(guard, [])

      call ->
        send(guard, call)
        relay(guard, held)
    end
  end

  # Unlinked from the test, so killing it leaves the test running.
  defp start_caller(fun), do: start_supervised!({Task, fun}, id: make_ref())

  defp kill(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
  end

  defp stuck_walk do
    test = self()
    fn -> hang_walk(test) end
  end

  # A healthy walk that reports it ran.
  defp spy_walk do
    test = self()

    fn ->
      send(test, :spy_walked)
      {:ok, []}
    end
  end
end
