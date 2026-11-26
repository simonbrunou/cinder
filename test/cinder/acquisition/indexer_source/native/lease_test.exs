defmodule Cinder.Acquisition.IndexerSource.Native.LeaseTest do
  # The per-indexer slot lease of `Cinder.Acquisition.IndexerSource.Native` (#1655), on a private
  # instance whose clock the test moves and whose config the test hands it, so the spacing rules
  # read their literal values without waiting them out (testing.md, the limit bullet). A
  # holder is a process that runs `Lease.run/4` and waits for the test's `:finish`, so the test
  # decides when each request ends.
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Cinder.Acquisition.IndexerSource.Native.Lease

  setup do
    %{clock: start_supervised!({Agent, fn -> 0 end})}
  end

  defp start_lease(clock, config) do
    start_supervised!(
      {Lease, name: nil, clock: fn -> Agent.get(clock, & &1) end, config: fn -> config end}
    )
  end

  defp set_clock(clock, ms), do: Agent.update(clock, fn _ms -> ms end)

  # Makes the lease look again at every indexer, as its timer would once the clock has moved.
  defp check(lease) do
    send(lease, :check)
    :sys.get_state(lease)
  end

  # Waits until the lease has seen a killed holder go: its `:DOWN` and the test's messages come
  # from different processes, so they reach the lease in no fixed order.
  defp await_freed(lease, key, rounds \\ 200) do
    case :sys.get_state(lease).indexers do
      %{^key => %{holder: nil}} ->
        :ok

      _held when rounds > 0 ->
        Process.sleep(5)
        await_freed(lease, key, rounds - 1)

      held ->
        flunk("the lease never freed #{inspect(key)}: #{inspect(held)}")
    end
  end

  defp far_deadline, do: System.monotonic_time(:millisecond) + 60_000

  # The process that holds `key`'s slot once the lease has looked at it again. A grant is sent
  # inside the lease process, so this answers it before the holder's own message can arrive.
  defp holder_pid(lease, key) do
    case check(lease).indexers do
      %{^key => %{holder: {pid, _ref, _monitor, _delay}}} -> pid
      _free -> nil
    end
  end

  # Waits until the lease holds `pid`'s request, as its holder or a waiter.
  defp await_seen(lease, pid, rounds \\ 200) do
    entries = Map.values(:sys.get_state(lease).indexers)

    seen? =
      Enum.any?(entries, fn entry ->
        waiters = :queue.to_list(entry.interactive) ++ :queue.to_list(entry.background)
        Enum.any?([entry.holder | waiters], &match?({^pid, _ref, _monitor, _delay}, &1))
      end)

    cond do
      seen? -> :ok
      rounds > 0 -> Process.sleep(5) && await_seen(lease, pid, rounds - 1)
      true -> flunk("the lease never saw #{inspect(pid)}'s request")
    end
  end

  # A process that asks `lease` for the slot of `key` and, once granted, tells the test
  # `{:running, tag}` and holds the slot until the test sends it `:finish`. The test then gets
  # `{:done, tag, answer}` with `Lease.run/4`'s answer. `await: false` skips the wait for the
  # lease to hold the request, for one the lease answers at once.
  defp holder(lease, key, tag, opts \\ []) do
    test_pid = self()
    {await?, opts} = Keyword.pop(opts, :await, true)
    opts = Keyword.put_new(opts, :deadline_at, far_deadline())

    pid =
      start_supervised!(
        {Task,
         fn ->
           answer =
             Lease.run(lease, key, opts, fn ->
               send(test_pid, {:running, tag})

               receive do
                 :finish -> tag
               end
             end)

           send(test_pid, {:done, tag, answer})
         end},
        id: make_ref()
      )

    # The request reaches the lease before the test goes on, so queue order is the test's order.
    if await?, do: await_seen(lease, pid)
    pid
  end

  defp finish(pid, tag) do
    send(pid, :finish)
    assert_receive {:done, ^tag, {:ran, ^tag}}
  end

  describe "spacing" do
    test "with no spacing set, the next request starts 2 s after the previous one ended", %{
      clock: clock
    } do
      lease = start_lease(clock, [])
      first = holder(lease, 1, :first)
      assert_receive {:running, :first}
      _second = holder(lease, 1, :second)

      set_clock(clock, 10_000)
      finish(first, :first)

      set_clock(clock, 11_999)
      assert holder_pid(lease, 1) == nil

      set_clock(clock, 12_000)
      check(lease)
      assert_receive {:running, :second}
    end

    test "the spacing_ms config key shortens the spacing", %{clock: clock} do
      lease = start_lease(clock, spacing_ms: 10)
      first = holder(lease, 1, :first)
      assert_receive {:running, :first}
      _second = holder(lease, 1, :second)
      finish(first, :first)

      set_clock(clock, 9)
      assert holder_pid(lease, 1) == nil

      set_clock(clock, 10)
      check(lease)
      assert_receive {:running, :second}
    end

    test "a per-indexer delay of 5 s spaces that indexer's requests 5 s apart", %{clock: clock} do
      lease = start_lease(clock, [])
      first = holder(lease, 1, :first, delay_ms: 5_000)
      assert_receive {:running, :first}
      _second = holder(lease, 1, :second, delay_ms: 5_000)
      finish(first, :first)

      set_clock(clock, 4_999)
      assert holder_pid(lease, 1) == nil

      set_clock(clock, 5_000)
      check(lease)
      assert_receive {:running, :second}
    end

    test "a per-indexer delay shorter than the spacing leaves the spacing", %{clock: clock} do
      lease = start_lease(clock, [])
      first = holder(lease, 1, :first, delay_ms: 500)
      assert_receive {:running, :first}
      _second = holder(lease, 1, :second, delay_ms: 500)
      finish(first, :first)

      set_clock(clock, 1_999)
      assert holder_pid(lease, 1) == nil

      set_clock(clock, 2_000)
      check(lease)
      assert_receive {:running, :second}
    end

    test "the first request to an indexer starts at once", %{clock: clock} do
      lease = start_lease(clock, [])
      _first = holder(lease, 1, :first)
      assert_receive {:running, :first}
    end

    test "the spacing's timer grants the next request with no other event" do
      lease = start_supervised!({Lease, name: nil, config: fn -> [spacing_ms: 500] end})
      first = holder(lease, 1, :first)
      assert_receive {:running, :first}
      second = holder(lease, 1, :second)
      finish(first, :first)

      assert holder_pid(lease, 1) == nil
      assert_receive {:running, :second}, 2_000
      assert holder_pid(lease, 1) == second
    end
  end

  describe "one request at a time" do
    test "a second request to one indexer waits for the first to end", %{clock: clock} do
      lease = start_lease(clock, spacing_ms: 0)
      first = holder(lease, 1, :first)
      assert_receive {:running, :first}
      _second = holder(lease, 1, :second)

      assert holder_pid(lease, 1) == first

      finish(first, :first)
      assert_receive {:running, :second}
    end

    test "two indexers never wait for each other", %{clock: clock} do
      lease = start_lease(clock, [])
      _first = holder(lease, 1, :first)
      _other = holder(lease, 2, :other)

      assert_receive {:running, :first}
      assert_receive {:running, :other}
    end
  end

  describe "priority" do
    test "an interactive request queued behind a background one is granted first", %{
      clock: clock
    } do
      lease = start_lease(clock, [])
      running = holder(lease, 1, :running)
      assert_receive {:running, :running}
      background = holder(lease, 1, :background, priority: :background)
      interactive = holder(lease, 1, :interactive, priority: :interactive)

      finish(running, :running)
      set_clock(clock, 2_000)
      check(lease)

      assert_receive {:running, :interactive}
      assert holder_pid(lease, 1) == interactive

      set_clock(clock, 2_100)
      finish(interactive, :interactive)
      set_clock(clock, 4_100)
      check(lease)
      assert_receive {:running, :background}
      finish(background, :background)
    end

    test "requests of one class are granted in the order they came", %{clock: clock} do
      lease = start_lease(clock, spacing_ms: 0)
      running = holder(lease, 1, :running)
      assert_receive {:running, :running}
      first = holder(lease, 1, :first, priority: :interactive)
      _second = holder(lease, 1, :second, priority: :interactive)

      finish(running, :running)
      assert_receive {:running, :first}
      assert holder_pid(lease, 1) == first
      finish(first, :first)
      assert_receive {:running, :second}
    end

    test "an interactive request does not cut a background request already running", %{
      clock: clock
    } do
      lease = start_lease(clock, spacing_ms: 0)
      background = holder(lease, 1, :background, priority: :background)
      assert_receive {:running, :background}
      _interactive = holder(lease, 1, :interactive, priority: :interactive)

      assert holder_pid(lease, 1) == background
      assert Process.alive?(background)

      finish(background, :background)
      assert_receive {:running, :interactive}
    end
  end

  describe "a process that dies" do
    test "a holder killed while it holds the slot releases it", %{clock: clock} do
      lease = start_lease(clock, spacing_ms: 0)
      first = holder(lease, 1, :first)
      assert_receive {:running, :first}
      _second = holder(lease, 1, :second)

      Process.exit(first, :kill)

      assert_receive {:running, :second}
    end

    test "a killed holder's slot still waits out the spacing", %{clock: clock} do
      lease = start_lease(clock, [])
      first = holder(lease, 1, :first)
      assert_receive {:running, :first}
      _second = holder(lease, 1, :second)

      Process.exit(first, :kill)
      await_freed(lease, 1)
      assert holder_pid(lease, 1) == nil

      set_clock(clock, 2_000)
      check(lease)
      assert_receive {:running, :second}
    end

    test "a raise in the holder's function frees the slot and reaches the caller", %{
      clock: clock
    } do
      lease = start_lease(clock, spacing_ms: 0)
      deadline_at = far_deadline()

      assert_raise RuntimeError, "boom", fn ->
        Lease.run(lease, 1, [deadline_at: deadline_at], fn -> raise "boom" end)
      end

      _next = holder(lease, 1, :next)
      assert_receive {:running, :next}
    end

    test "a waiter killed in the queue leaves it", %{clock: clock} do
      lease = start_lease(clock, spacing_ms: 0)
      first = holder(lease, 1, :first)
      assert_receive {:running, :first}
      gone = holder(lease, 1, :gone)
      _third = holder(lease, 1, :third)

      Process.exit(gone, :kill)
      finish(first, :first)

      assert_receive {:running, :third}
      refute_received {:running, :gone}
    end
  end

  describe "the deadline" do
    test "a request still queued at the deadline never runs and reads as skipped by it", %{
      clock: clock
    } do
      lease = start_lease(clock, spacing_ms: 0)
      first = holder(lease, 1, :first)
      assert_receive {:running, :first}
      deadline_at = System.monotonic_time(:millisecond) + 100
      _late = holder(lease, 1, :late, deadline_at: deadline_at)

      assert_receive {:done, :late, {:not_run, {:skipped, :deadline}}}, 2_000
      assert System.monotonic_time(:millisecond) >= deadline_at

      _next = holder(lease, 1, :next)
      finish(first, :first)

      assert_receive {:running, :next}
      refute_received {:running, :late}
    end

    test "a grant that reaches the waiter only after its deadline runs nothing", %{clock: clock} do
      lease = start_lease(clock, spacing_ms: 0)
      first = holder(lease, 1, :first)
      assert_receive {:running, :first}
      deadline_at = System.monotonic_time(:millisecond) + 200
      late = holder(lease, 1, :late, deadline_at: deadline_at)

      # The waiter sleeps through its deadline with the grant already in its mailbox.
      :erlang.suspend_process(late)
      finish(first, :first)
      assert {:messages, [{Lease, _ref, :granted}]} = Process.info(late, :messages)
      Process.sleep(300)
      :erlang.resume_process(late)

      assert_receive {:done, :late, {:not_run, {:skipped, :deadline}}}
      refute_received {:running, :late}

      # The slot it was granted is free again.
      _next = holder(lease, 1, :next)
      assert_receive {:running, :next}
    end

    test "a deadline already past sends nothing, even with the slot free", %{clock: clock} do
      lease = start_lease(clock, [])
      past = System.monotonic_time(:millisecond) - 1
      _late = holder(lease, 1, :late, deadline_at: past, await: false)

      assert_receive {:done, :late, {:not_run, {:skipped, :deadline}}}
      refute_received {:running, :late}

      # The slot was never taken: the next request starts at once.
      _next = holder(lease, 1, :next)
      assert_receive {:running, :next}
    end
  end

  describe "the gate after the grant" do
    test "a gate that says no runs nothing, answers its outcome and keeps the spacing as it was",
         %{clock: clock} do
      lease = start_lease(clock, [])
      until = ~U[2026-11-26 12:01:00Z]
      first = holder(lease, 1, :first)
      assert_receive {:running, :first}
      _gated = holder(lease, 1, :gated, gate: fn -> {:skipped, {:backoff, until}} end)
      finish(first, :first)

      set_clock(clock, 2_000)
      check(lease)
      assert_receive {:done, :gated, {:not_run, {:skipped, {:backoff, ^until}}}}
      refute_received {:running, :gated}

      # Nothing was sent, so the next request may start at once: the spacing still counts from
      # the first request's end.
      _next = holder(lease, 1, :next)
      assert_receive {:running, :next}
    end

    test "a gate that says :ask runs the request", %{clock: clock} do
      lease = start_lease(clock, [])
      first = holder(lease, 1, :first, gate: fn -> :ask end)
      assert_receive {:running, :first}
      finish(first, :first)
    end
  end

  describe "a lease that is not there" do
    test "answers never started and runs nothing" do
      lease = start_supervised!({Lease, name: nil})
      stop_supervised!(Lease)
      test_pid = self()

      assert {:not_run, {:skipped, :deadline}} =
               Lease.run(lease, 1, [deadline_at: far_deadline()], fn ->
                 send(test_pid, :ran)
               end)

      refute_received :ran
    end

    test "a lease that dies with a waiter queued answers that waiter never started", %{
      clock: clock
    } do
      lease = start_lease(clock, spacing_ms: 0)
      _first = holder(lease, 1, :first)
      assert_receive {:running, :first}
      _waiter = holder(lease, 1, :waiter)

      stop_supervised!(Lease)

      assert_receive {:done, :waiter, {:not_run, {:skipped, :deadline}}}
      refute_received {:running, :waiter}
    end
  end

  test "an indexer idle past its spacing leaves the lease's state", %{clock: clock} do
    lease = start_lease(clock, [])
    first = holder(lease, 1, :first)
    assert_receive {:running, :first}
    finish(first, :first)

    set_clock(clock, 2_000)
    assert check(lease).indexers == %{}
  end
end
