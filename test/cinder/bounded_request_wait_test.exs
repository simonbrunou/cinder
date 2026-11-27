defmodule Cinder.Test.BoundedRequestWaitTest do
  # Not async: each test checks that `:telemetry.list_handlers/1` lists no handler of
  # `BoundedRequestWait`, and `Cinder.HTTPPolicyTest`, which is async, attaches one of its own.
  use ExUnit.Case, async: false

  alias Cinder.HTTPPolicy
  alias Cinder.Test.BoundedRequestWait

  @event [:cinder, :http, :request_task]
  @timeout_ms 100
  # The suspended-wait test's timeout, how long it suspends the test process during the wait, and
  # how many waits it runs at most to catch one with the suspension.
  @suspend_timeout_ms 1_000
  @suspended_ms 2_000
  @suspend_attempts 3

  test "returns the task's reply when it comes in time" do
    Req.Test.stub(Cinder.BoundedRequestWaitAnswerStub, fn conn ->
      Req.Test.json(conn, %{ok: true})
    end)

    watch = BoundedRequestWait.watch()
    # The control for each `assert_detached/0`: the handler is listed while attached.
    assert watch.id in handler_ids()

    task = Task.async(fn -> request(Cinder.BoundedRequestWaitAnswerStub) end)

    assert {:ok, %{status: 200, body: %{"ok" => true}}} =
             BoundedRequestWait.await(watch, task, 10_000)

    assert_detached()
    # The caller task sent its event before its reply, and the wait took both.
    refute_received {BoundedRequestWait, _metadata}
  end

  test "detaches its handler when the test ends, for a test that never calls await/3" do
    # ExUnit runs `on_exit` callbacks in the reverse order of their registration, so this one
    # runs after the one `watch/0` registers.
    on_exit(fn -> assert_detached() end)
    watch = BoundedRequestWait.watch()
    assert watch.id in handler_ids()
  end

  test "exits as Task.await/2 does when the task exits before it replies" do
    watch = BoundedRequestWait.watch()
    task = Task.async(fn -> exit(:normal) end)

    assert catch_exit(BoundedRequestWait.await(watch, task, 10_000)) ==
             {:normal, {BoundedRequestWait, :await, [task, 10_000]}}

    assert_detached()
  end

  test "fails after its timeout naming where the task and each of its request tasks wait, in " <>
         "order, and no other process's request task" do
    test = self()
    stub_reports_pid(Cinder.BoundedRequestWaitAnswerStub, test)

    Req.Test.stub(Cinder.BoundedRequestWaitBlockStub, fn _conn ->
      send(test, {:request_task, self()})
      receive do: (:never_sent -> :ok)
    end)

    watch = BoundedRequestWait.watch()

    # Another process's request, whose event the handler also forwards.
    other = Task.async(fn -> request(Cinder.BoundedRequestWaitAnswerStub) end)
    assert {:ok, _response} = Task.await(other, 10_000)
    assert_receive {:request_task, other_request}

    task =
      Task.async(fn ->
        {:ok, _response} = request(Cinder.BoundedRequestWaitAnswerStub)
        request(Cinder.BoundedRequestWaitBlockStub)
      end)

    assert_receive {:request_task, answered}
    assert_receive {:request_task, blocked}
    await_down(answered)

    {message, elapsed_bounds} = await_timeout(watch, task)

    assert message =~
             "BoundedRequestWait.await/3: no reply from the task #{inspect(task.pid)} within " <>
               "#{@timeout_ms} ms; the wait took "

    assert_elapsed(message, elapsed_bounds)
    assert message =~ "The task is alive, [status: "
    assert message =~ "{Cinder.HTTPPolicy, :bounded_request, 3,"

    assert message =~
             ~r/The request task #{Regex.escape(inspect(answered))} had exited\. The request task #{Regex.escape(inspect(blocked))} is alive, \[status: /

    assert message =~ "{Req.Steps, :run_plug, 1,"
    assert message =~ ~r/message_queue_len: \d+\]/
    refute message =~ inspect(other_request)
    refute message =~ "No request task event"
    assert_detached()
  end

  test "says when the task never started a request task" do
    watch = BoundedRequestWait.watch()
    task = Task.async(fn -> receive do: (:never_sent -> :ok) end)

    {message, elapsed_bounds} = await_timeout(watch, task)

    assert_elapsed(message, elapsed_bounds)
    assert message =~ "The task is alive, [status: "

    assert message =~
             "No request task event: no #{inspect(@event)} event names the task as its " <>
               "caller, so the task had not yet reached the point where bounded_request/2,3 " <>
               "starts " <>
               "its request task."

    refute message =~ "The request task"
    assert_detached()
  end

  test "says when the task had exited with its reply not yet received" do
    stub_reports_pid(Cinder.BoundedRequestWaitAnswerStub, self())
    watch = BoundedRequestWait.watch()

    task =
      Task.async(fn ->
        {:ok, _response} = request(Cinder.BoundedRequestWaitAnswerStub)
        receive do: (:exit -> :replied)
      end)

    assert_receive {:request_task, request_task}
    # The task's reply and `:DOWN` then never reach the test: the task has exited and the wait
    # has nothing to receive, as when the test process woke too late to receive them.
    Process.demonitor(task.ref, [:flush])
    send(task.pid, :exit)
    await_down(task.pid)

    {message, elapsed_bounds} = await_timeout(watch, task)

    assert_elapsed(message, elapsed_bounds)
    assert message =~ "The task had exited, its reply not yet received."
    assert message =~ "The request task #{inspect(request_task)} had exited."
    refute message =~ "is alive"
    assert_detached()
  end

  test "reports the whole wait, past its timeout, when the calling process could not run " <>
         "during it" do
    {message, {_floor, ceiling}} = suspended_wait(@suspend_attempts)

    assert_elapsed(message, {@suspended_ms, ceiling})
    assert_detached()
  end

  defp request(stub) do
    HTTPPolicy.bounded_request([url: "https://public.example/data", plug: {Req.Test, stub}], 64)
  end

  # A stub that answers and sends `test` the pid of the request task it runs in.
  defp stub_reports_pid(stub, test) do
    Req.Test.stub(stub, fn conn ->
      send(test, {:request_task, self()})
      Req.Test.json(conn, %{ok: true})
    end)
  end

  defp await_down(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
  end

  # Runs `await/3` under `timeout_ms` on a task that does not reply in time, and returns its
  # failure message with the clock reads around the call.
  defp await_timeout(watch, task, timeout_ms \\ @timeout_ms) do
    before = System.monotonic_time(:millisecond)

    error =
      assert_raise ExUnit.AssertionError, fn ->
        BoundedRequestWait.await(watch, task, timeout_ms)
      end

    {error.message, {timeout_ms, System.monotonic_time(:millisecond) - before}}
  end

  # Runs `await/3` under `@suspend_timeout_ms` on a task that never replies, with the test process
  # suspended for `@suspended_ms` during the wait, and returns what `await_timeout/3` returns. A
  # suspender that runs only after the wait ended, as on a loaded host, misses it: the test then
  # runs another wait, up to `attempts` in all.
  defp suspended_wait(attempts) do
    test = self()
    watch = BoundedRequestWait.watch()
    task = Task.async(fn -> receive do: (:never_sent -> :ok) end)
    suspender = Task.async(fn -> suspend_during_wait(test, @suspended_ms) end)
    result = await_timeout(watch, task, @suspend_timeout_ms)

    case {Task.await(suspender, 30_000), attempts} do
      {:suspended_in_wait, _attempts} ->
        result

      {missed, 1} ->
        flunk("no suspension landed in the wait in #{@suspend_attempts} waits: #{missed}")

      {_missed, _attempts} ->
        suspended_wait(attempts - 1)
    end
  end

  # Suspends `test` for `suspended_ms` once it waits in `Task.yield/2`, and answers whether `test`
  # was still in that wait once suspended. The wait then lasts at least `suspended_ms`: with a 1 s
  # timeout and a 2 s suspension starting 52 ms into the wait, one run's wait took 3002 ms. Answers
  # `:never_in_wait` when it saw no such wait within 10 s.
  defp suspend_during_wait(test, suspended_ms) do
    if poll_until_in_wait(test, System.monotonic_time(:millisecond) + 10_000) do
      :erlang.suspend_process(test)
      in_wait? = in_wait?(test)
      Process.sleep(suspended_ms)
      :erlang.resume_process(test)
      if in_wait?, do: :suspended_in_wait, else: :suspended_past_wait
    else
      :never_in_wait
    end
  end

  defp poll_until_in_wait(test, deadline) do
    cond do
      in_wait?(test) -> true
      System.monotonic_time(:millisecond) > deadline -> false
      true -> poll_after_a_millisecond(test, deadline)
    end
  end

  defp poll_after_a_millisecond(test, deadline) do
    Process.sleep(1)
    poll_until_in_wait(test, deadline)
  end

  defp in_wait?(test) do
    {:current_stacktrace, stack} = Process.info(test, :current_stacktrace)
    match?([{Task, :yield_receive, 3, _location} | _rest], stack)
  end

  defp assert_elapsed(message, {floor, ceiling}) do
    assert [_match, elapsed] = Regex.run(~r/; the wait took (\d+) ms\./, message)
    # Two comparisons, not `in floor..ceiling`: with `ceiling < floor` that range counts down and
    # holds values below `floor`.
    elapsed = String.to_integer(elapsed)
    assert elapsed >= floor and elapsed <= ceiling, "#{elapsed} ms not in #{floor}..#{ceiling}"
  end

  defp assert_detached do
    assert for({BoundedRequestWait, _ref} = id <- handler_ids(), do: id) == []
  end

  defp handler_ids, do: for(%{id: id} <- :telemetry.list_handlers(@event), do: id)
end
