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

  defp start_guard(tasks),
    do: start_supervised!({BoundedWalk, name: nil, task_supervisor: tasks})

  defp run(guard, root, fun),
    do: BoundedWalk.run(root, fun, server: guard, timeout_ms: @deadline)

  defp stuck(guard, root),
    do: BoundedWalk.run(root, stuck_walk(), server: guard, timeout_ms: @stuck_deadline)

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
