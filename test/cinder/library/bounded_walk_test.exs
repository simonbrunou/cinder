defmodule Cinder.Library.BoundedWalkTest do
  # Each test starts its own guard and task supervisor, so a walk a test leaves stuck never
  # refuses another test's.
  use ExUnit.Case, async: true

  import Cinder.BoundedWalkHelpers

  alias Cinder.Library.BoundedWalk

  # A stuck walk logs a warning; a raising one, its task's crash.
  @moduletag :capture_log

  # A walk meant to stick runs under @stuck_deadline. Every other walk gets @deadline, far above
  # what a loaded CI runner takes to start, run and crash a task: a 200 ms one missed it, and on a
  # dev host at load 60 a 10 s one did too (#1512).
  @stuck_deadline 300
  @deadline 30_000
  # Every wait on an answer from the guard, a call, `:sys.get_state/2` or a message the answer lets
  # through, has @wait: on that host the guard missed 5 s (#1512). The tests of a 100 ms
  # `:call_timeout_ms` time it out on purpose.
  @wait 20_000
  # Longer than `GenServer.call/2`'s 5 s default, which a guard call that ignored
  # `:call_timeout_ms` would wait.
  @past_default 6_000
  # A refusal meant to come at once ends within @refusal, under half of @deadline, so one that
  # waited the deadline out fails it.
  @refusal 10_000

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
    assert_receive {:walking, _pid}, @wait
  end

  test "a root with a stuck walk refuses a new walk at once, and other roots still walk", %{
    guard: guard
  } do
    assert {:error, :timeout} = stuck(guard, "/downloads")
    assert_receive {:walking, _pid}, @wait

    {elapsed, result} = :timer.tc(fn -> run(guard, "/downloads", spy_walk()) end, :millisecond)

    assert result == {:error, :timeout}
    assert elapsed < @refusal
    refute_received :spy_walked

    assert {:ok, []} = run(guard, "/usenet", spy_walk())
    assert_received :spy_walked
  end

  test "walks still running inside their deadline do not refuse one more", %{guard: guard} do
    held = stuck_walk()
    first = Task.async(fn -> run(guard, "/downloads", held) end)
    assert_receive {:walking, first_walk}, @wait

    assert {:ok, []} = run(guard, "/downloads", spy_walk())
    assert_received :spy_walked

    send(first_walk, :release)
    assert {:ok, []} = Task.await(first, @wait)
  end

  test "while the stuck-walk cap is reached, a walk under any root is refused at once, " <>
         "and walks work again once a stuck one returns",
       %{guard: guard} do
    assert {:error, :timeout} = stuck(guard, "/downloads")
    assert_receive {:walking, downloads_walk}, @wait
    assert {:error, :timeout} = stuck(guard, "/usenet")
    assert_receive {:walking, _usenet_walk}, @wait

    {elapsed, result} = :timer.tc(fn -> run(guard, "/books", spy_walk()) end, :millisecond)

    assert result == {:error, :timeout}
    assert elapsed < @refusal
    refute_received :spy_walked

    release_walk(downloads_walk, guard, timeout_ms: @wait)

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
    assert_receive {:walking, downloads_walk}, @wait
    assert {:error, :timeout} = stuck(guard, "/usenet")
    assert_receive {:walking, _usenet_walk}, @wait

    stop_supervised!(BoundedWalk)
    guard = start_guard(tasks)

    assert {:error, :timeout} = run(guard, "/books", spy_walk())
    refute_received :spy_walked

    release_walk(downloads_walk, guard, timeout_ms: @wait)

    assert {:ok, []} = run(guard, "/books", spy_walk())
    assert_received :spy_walked
  end

  test "a walk that returns after its deadline leaves no reply in the caller's mailbox", %{
    guard: guard
  } do
    assert {:error, :timeout} = stuck(guard, "/downloads")
    assert_receive {:walking, walk}, @wait

    release_walk(walk, guard, timeout_ms: @wait)

    refute_receive _late_reply, 100
  end

  test "a walk that raises raises in the caller", %{guard: guard} do
    assert_raise RuntimeError, "unexpected call", fn ->
      run(guard, "/downloads", fn -> raise "unexpected call" end)
    end
  end

  describe ":call_timeout_ms (#1512)" do
    test "bounds the caller's admission: a guard that does not answer in time exits the caller",
         %{guard: guard} do
      :sys.suspend(guard)

      reason =
        catch_exit(BoundedWalk.run("/downloads", spy_walk(), server: guard, call_timeout_ms: 100))

      :sys.resume(guard)

      assert {:timeout, {GenServer, :call, [^guard, {:admit, "/downloads"}, 100]}} = reason
      refute_received :spy_walked
    end

    test "bounds the walk's task's report that it started: a guard that does not answer it in " <>
           "time exits the caller",
         %{guard: guard} do
      test = self()
      relay = start_caller(fn -> relay(guard, test) end)

      assert {:timeout, {GenServer, :call, [^relay, {:started, "/downloads", ^test, _task}, 100]}} =
               held_start_exit(relay)

      refute_received :spy_walked
    end

    test "bounds the caller's report that its walk is stuck: the caller waits past the 5 s " <>
           "default for a guard that answers within it",
         %{guard: guard} do
      test = self()
      relay = start_caller(fn -> relay(guard, test, :stuck) end)
      walk = stuck_walk()

      caller =
        start_caller(fn ->
          result =
            BoundedWalk.run("/downloads", walk,
              server: relay,
              timeout_ms: @stuck_deadline,
              call_timeout_ms: @wait
            )

          send(test, {:result, result})
        end)

      ref = Process.monitor(caller)
      assert_receive {:held, :stuck}, @wait
      refute_receive {:DOWN, ^ref, :process, ^caller, _reason}, @past_default

      send(relay, :let_go)
      assert_receive {:result, {:error, :timeout}}, @wait
    end

    test "bounds the walk's task's report that it returned: the result waits past the 5 s " <>
           "default for a guard that answers within it",
         %{guard: guard} do
      test = self()
      relay = start_caller(fn -> relay(guard, test, :returned) end)
      walk = spy_walk()
      start_caller(fn -> send(test, {:result, run(relay, "/downloads", walk)}) end)

      assert_receive {:held, :returned}, @wait
      refute_receive {:result, _result}, @past_default

      send(relay, :let_go)
      assert_receive {:result, {:ok, []}}, @wait
      assert_received :spy_walked
    end
  end

  describe "a walk whose caller exits before the walk returns (#1168)" do
    test "counts as stuck once its caller is killed before the deadline: its root refuses a " <>
           "new walk at once, and other roots still walk",
         %{guard: guard} do
      orphan(guard, "/downloads")

      {elapsed, result} = :timer.tc(fn -> run(guard, "/downloads", spy_walk()) end, :millisecond)

      assert result == {:error, :timeout}
      assert elapsed < @refusal
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
      assert elapsed < @refusal
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

      assert_receive {:caller, caller}, @wait
      assert_receive {:walking, _walk}, @wait
      ref = Process.monitor(caller)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          send(owner, :close)
          assert_receive {:DOWN, ^ref, :process, ^caller, {:shutdown, :closed}}, @wait
          _ = :sys.get_state(guard, @wait)
        end)

      # #1361: the warning names the reason the guard's monitor on the caller gave.
      assert log =~ "(the caller's monitor reported {:shutdown, :closed})"

      assert {:error, :timeout} = run(guard, "/downloads", spy_walk())
      refute_received :spy_walked
    end

    test "logs a warning naming its root", %{guard: guard} do
      log = ExUnit.CaptureLog.capture_log(fn -> orphan(guard, "/downloads") end)

      assert log =~ ~s(directory walk under "/downloads")
      assert log =~ "its caller exited before reporting it past its deadline"
      assert log =~ "(the caller's monitor reported :killed)"
    end

    test "is admitted again under its root once it returns by itself", %{guard: guard} do
      walk = orphan(guard, "/downloads")

      release_walk(walk, guard, timeout_ms: @wait)

      assert {:ok, []} = run(guard, "/downloads", spy_walk())
      assert_received :spy_walked
    end

    test "is not counted, nor warned about, when its task already exited without returning", %{
      guard: guard
    } do
      walk = stuck_walk()
      caller = start_caller(fn -> run(guard, "/downloads", walk) end)
      assert_receive {:walking, hung}, @wait

      # The guard sees the caller's exit first, with the walk's task already dead.
      :sys.suspend(guard)
      kill(caller)
      kill(hung)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          :sys.resume(guard)
          :sys.get_state(guard, @wait)
        end)

      refute log =~ "its caller exited"
      assert {:ok, []} = run(guard, "/downloads", spy_walk())
      assert_received :spy_walked
    end

    test "names :noproc in its warning when its caller had exited before its task reached the " <>
           "guard (#1361)",
         %{guard: guard} do
      test = self()
      walk = stuck_walk()
      relay = start_caller(fn -> relay(guard, test) end)
      caller = start_caller(fn -> run(relay, "/downloads", walk) end)

      assert_receive {:held, :started}, @wait
      kill(caller)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          send(relay, :let_go)
          assert_receive {:walking, _hung}, @wait
          :sys.get_state(guard, @wait)
        end)

      assert log =~ "its caller exited before reporting it past its deadline"
      assert log =~ "(the caller's monitor reported :noproc)"
      assert {:error, :timeout} = run(guard, "/downloads", spy_walk())
      refute_received :spy_walked
    end

    test "is not warned about when its caller reported it stuck before its task reached the " <>
           "guard, and that caller then exits",
         %{guard: guard} do
      test = self()
      walk = stuck_walk()
      relay = start_caller(fn -> relay(guard, test) end)

      caller =
        start_caller(fn ->
          send(
            test,
            {:result,
             BoundedWalk.run("/downloads", walk,
               server: relay,
               timeout_ms: 10,
               call_timeout_ms: @wait
             )}
          )

          receive do
            :exit -> :ok
          end
        end)

      ref = Process.monitor(caller)
      assert_receive {:result, {:error, :timeout}}, @wait
      # A task that reaches the relay after `:let_go` would stay held (#1512).
      assert_receive {:held, :started}, @wait
      send(relay, :let_go)
      assert_receive {:walking, _hung}, @wait

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          send(caller, :exit)
          assert_receive {:DOWN, ^ref, :process, ^caller, :normal}, @wait
          :sys.get_state(guard, @wait)
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
      assert_receive {:walking, hung}, @wait

      # A guard that cannot answer holds the result back, so it cannot see the caller exit on the
      # result before it sees the walk return.
      :sys.suspend(guard)
      send(hung, :release)
      refute_receive {:result, _result}, 200

      :sys.resume(guard)
      assert_receive {:result, {:ok, []}}, @wait
      assert_receive {:DOWN, ^ref, :process, ^caller, :normal}, @wait
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
        assert_receive {:result, {:ok, []}}, @wait
        assert_receive {:DOWN, ^ref, :process, ^caller, _reason}, @wait

        assert {:ok, []} = run(guard, "/downloads", spy_walk())
        assert_received :spy_walked
      end
    end
  end

  describe "stuck_roots/1 (#948)" do
    test "reads no stuck walk from a guard with none", %{guard: guard} do
      assert {:ok, []} = run(guard, "/downloads", spy_walk())

      assert stuck_roots(guard) == %{roots: [], cap_reached?: false}
    end

    test "reads the root of each stuck walk, sorted, and whether the cap is reached; a walk " <>
           "that returns leaves it",
         %{guard: guard} do
      assert {:error, :timeout} = stuck(guard, "/usenet")
      assert_receive {:walking, _usenet_walk}, @wait

      assert stuck_roots(guard) == %{roots: ["/usenet"], cap_reached?: false}

      assert {:error, :timeout} = stuck(guard, "/downloads")
      assert_receive {:walking, downloads_walk}, @wait

      assert stuck_roots(guard) ==
               %{roots: ["/downloads", "/usenet"], cap_reached?: true}

      release_walk(downloads_walk, guard, timeout_ms: @wait)

      assert stuck_roots(guard) == %{roots: ["/usenet"], cap_reached?: false}
    end

    test "reads no walk still running inside its deadline under a living caller", %{
      guard: guard
    } do
      walk = stuck_walk()
      caller = Task.async(fn -> run(guard, "/downloads", walk) end)
      assert_receive {:walking, hung}, @wait

      assert stuck_roots(guard) == %{roots: [], cap_reached?: false}

      send(hung, :release)
      assert {:ok, []} = Task.await(caller, @wait)
    end

    test "reads the cap as reached until fewer than two walks stay stuck, not until one returns",
         %{guard: guard} do
      walk = stuck_walk()
      callers = for _caller <- 1..3, do: start_caller(fn -> run(guard, "/downloads", walk) end)

      hung =
        for _walk <- 1..3 do
          assert_receive {:walking, pid}, @wait
          pid
        end

      Enum.each(callers, &kill/1)
      _ = :sys.get_state(guard, @wait)

      assert %{roots: [_, _, _], cap_reached?: true} = stuck_roots(guard)

      release_walk(hd(hung), guard, timeout_ms: @wait)

      assert stuck_roots(guard) ==
               %{roots: ["/downloads", "/downloads"], cap_reached?: true}

      release_walk(List.last(hung), guard, timeout_ms: @wait)

      assert stuck_roots(guard) ==
               %{roots: ["/downloads"], cap_reached?: false}
    end

    test "reads a walk whose caller exited before its deadline (#1168)", %{guard: guard} do
      orphan(guard, "/downloads")

      assert stuck_roots(guard) ==
               %{roots: ["/downloads"], cap_reached?: false}
    end

    test "reads one entry per stuck walk, so two walks stuck under one root read twice", %{
      guard: guard
    } do
      walk = stuck_walk()
      callers = for _caller <- 1..2, do: start_caller(fn -> run(guard, "/downloads", walk) end)
      assert_receive {:walking, _first}, @wait
      assert_receive {:walking, _second}, @wait

      Enum.each(callers, &kill/1)
      _ = :sys.get_state(guard, @wait)

      assert stuck_roots(guard) ==
               %{roots: ["/downloads", "/downloads"], cap_reached?: true}
    end

    test "reads :unknown_root for a walk a restarted guard took over", %{
      guard: guard,
      tasks: tasks
    } do
      assert {:error, :timeout} = stuck(guard, "/downloads")
      assert_receive {:walking, walk}, @wait

      stop_supervised!(BoundedWalk)
      guard = start_guard(tasks)

      assert stuck_roots(guard) ==
               %{roots: [:unknown_root], cap_reached?: false}

      release_walk(walk, guard, timeout_ms: @wait)

      assert stuck_roots(guard) == %{roots: [], cap_reached?: false}
    end

    test "reads a walk a restarted guard took over under its root once its caller, still alive, " <>
           "reports it past its deadline",
         %{tasks: tasks} do
      # A named guard, as the app's is: the caller reaches the restarted one by the same name.
      stop_supervised!(BoundedWalk)
      name = :"bounded_walk_test_#{System.unique_integer([:positive])}"
      start_supervised!({BoundedWalk, name: name, task_supervisor: tasks})
      walk = stuck_walk()

      caller =
        Task.async(fn ->
          BoundedWalk.run("/downloads", walk,
            server: name,
            timeout_ms: 3_000,
            call_timeout_ms: @wait
          )
        end)

      assert_receive {:walking, hung}, @wait

      stop_supervised!(BoundedWalk)
      start_supervised!({BoundedWalk, name: name, task_supervisor: tasks})

      assert stuck_roots(name) ==
               %{roots: [:unknown_root], cap_reached?: false}

      assert {:error, :timeout} = Task.await(caller, @deadline)

      assert stuck_roots(name) ==
               %{roots: ["/downloads"], cap_reached?: false}

      # From then on its root refuses a new walk, as any other stuck walk's does.
      assert {:error, :timeout} = run(name, "/downloads", spy_walk())
      refute_received :spy_walked

      release_walk(hung, name, timeout_ms: @wait)
    end

    test "reads no stuck walk, with a warning, from a guard that is not running", %{
      guard: guard
    } do
      assert {:error, :timeout} = stuck(guard, "/downloads")
      assert_receive {:walking, _walk}, @wait
      stop_supervised!(BoundedWalk)

      for server <- [guard, :no_such_bounded_walk_guard] do
        {answer, log} =
          ExUnit.CaptureLog.with_log(fn -> stuck_roots(server) end)

        assert answer == %{roots: [], cap_reached?: false}
        assert log =~ "could not read the stuck directory walks"
      end
    end

    test "reads no stuck walk, with a warning, from a guard that does not answer in time, and " <>
           "its late answer never reaches the caller",
         %{guard: guard} do
      assert {:error, :timeout} = stuck(guard, "/downloads")
      assert_receive {:walking, _walk}, @wait
      :sys.suspend(guard)

      {answer, log} =
        ExUnit.CaptureLog.with_log(fn ->
          BoundedWalk.stuck_roots(server: guard, timeout_ms: 100)
        end)

      assert answer == %{roots: [], cap_reached?: false}
      assert log =~ "could not read the stuck directory walks"
      # The check that `:timeout_ms` reached the call: the 1 s default ends with the same answer
      # and the same warning, apart from this number.
      assert log =~ ~r/\{:timeout, \{GenServer, :call, \[#PID<[\d.]+>, :stuck_roots, 100\]\}\}/

      :sys.resume(guard)
      _ = :sys.get_state(guard, @wait)
      refute_receive _late_answer, 100
    end
  end

  defp start_guard(tasks),
    do: start_supervised!({BoundedWalk, name: nil, task_supervisor: tasks})

  defp run(guard, root, fun),
    do: BoundedWalk.run(root, fun, server: guard, timeout_ms: @deadline, call_timeout_ms: @wait)

  defp stuck(guard, root) do
    BoundedWalk.run(root, stuck_walk(),
      server: guard,
      timeout_ms: @stuck_deadline,
      call_timeout_ms: @wait
    )
  end

  defp stuck_roots(guard), do: BoundedWalk.stuck_roots(server: guard, timeout_ms: @wait)

  # Starts a walk under `root` that hangs, with a deadline its caller never reaches, kills the
  # caller, and returns the walk once the guard has seen the caller go.
  defp orphan(guard, root) do
    walk = stuck_walk()
    caller = start_caller(fn -> run(guard, root, walk) end)
    assert_receive {:walking, hung}, @wait
    kill(caller)
    _ = :sys.get_state(guard, @wait)
    hung
  end

  # Stands in for `guard` and passes each call on to it, which replies to the caller directly,
  # except each call whose request is tagged `hold`, such as a walk task's `{:started, ...}`: those
  # wait until the relay is sent `:let_go`, and the relay tells `test` it holds one with
  # `{:held, hold}`.
  defp relay(guard, test, hold \\ :started), do: relay(guard, test, hold, [])

  defp relay(guard, test, hold, held) do
    receive do
      {:"$gen_call", _from, request} = call when elem(request, 0) == hold ->
        send(test, {:held, hold})
        relay(guard, test, hold, [call | held])

      :let_go ->
        Enum.each(held, &send(guard, &1))
        relay(guard, test, hold, [])

      call ->
        send(guard, call)
        relay(guard, test, hold, held)
    end
  end

  # The exit reason of a walk run with a 100 ms `:call_timeout_ms` through `relay`, which holds its
  # task's `{:started, ...}`. Its admission has the same 100 ms, which a loaded host can miss before
  # the walk starts: the run then goes again, until @wait has passed (#1512).
  defp held_start_exit(relay),
    do: held_start_exit(relay, System.monotonic_time(:millisecond) + @wait)

  defp held_start_exit(relay, until) do
    reason =
      catch_exit(
        BoundedWalk.run("/downloads", spy_walk(),
          server: relay,
          timeout_ms: @deadline,
          call_timeout_ms: 100
        )
      )

    case reason do
      {:timeout, {GenServer, :call, [_relay, {:admit, _root}, _timeout]}} ->
        if System.monotonic_time(:millisecond) < until,
          do: held_start_exit(relay, until),
          else: reason

      reason ->
        reason
    end
  end

  # Unlinked from the test, so killing it leaves the test running.
  defp start_caller(fun), do: start_supervised!({Task, fun}, id: make_ref())

  defp kill(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, @wait
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
