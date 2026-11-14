defmodule Cinder.Download.PollerSkeletonTest do
  use ExUnit.Case, async: true

  import Cinder.PollerHelpers
  import ExUnit.CaptureLog

  alias Cinder.Download.PollerProgress

  defmodule TestPoller do
    @default_interval :timer.hours(1)
    use Cinder.Download.PollerSkeleton, log_prefix: "test poller", stateful: false

    defp do_poll, do: :ok

    # Reproduces #139's clause error at runtime. The offending term is routed through the process
    # dictionary (typed `term()`) so the compiler can't statically flag the mismatch.
    def isolate_raise do
      Process.put(:bad_arg, :not_a_binary)
      isolate("unit 1", fn -> String.trim(Process.get(:bad_arg)) end)
    end

    def isolate_throw, do: isolate("unit 2", fn -> throw(:bail) end)
  end

  # Issue #139: a bare Exception.message left an intermittent clause error undiagnosable —
  # the log must carry the stacktrace so the failing call site self-identifies.
  test "isolate/2 logs the stacktrace on a raise" do
    log = capture_log(fn -> TestPoller.isolate_raise() end)

    assert log =~ "test poller skipped unit 1"
    assert log =~ "no function clause matching in String.trim/1"
    assert log =~ "poller_skeleton_test.exs"
  end

  test "isolate/2 logs the stacktrace on a throw" do
    log = capture_log(fn -> TestPoller.isolate_throw() end)

    assert log =~ "test poller skipped unit 2"
    assert log =~ ":bail"
    assert log =~ "poller_skeleton_test.exs"
  end

  # A `stateful: true` poller (`Cinder.Download.Poller`, `TvPoller`, `BookPoller`) — models the
  # do_poll/1 shape the real pollers use: a preamble wrapped in isolate/2, then further work.
  defmodule StatefulPreambleTestPoller do
    @default_interval :timer.hours(1)
    @search_retry_after 60
    use Cinder.Download.PollerSkeleton, log_prefix: "stateful test poller"

    # Exposes the private do_poll/1 for a synchronous, in-process call (mirrors
    # TestPoller.isolate_raise/0 above) — no GenServer needed to exercise the preamble wrap.
    def run_tick(state), do: do_poll(state)

    defp do_poll(_state) do
      isolate("preamble", fn -> raise "preamble boom" end)
      Process.put(:tick_continued, true)
      :ok
    end
  end

  test "a preamble raise does not prevent the rest of the tick from running" do
    Process.delete(:tick_continued)

    log =
      capture_log(fn ->
        assert :ok = StatefulPreambleTestPoller.run_tick(%{search_retry_after: 60})
      end)

    assert log =~ "stateful test poller skipped preamble"
    assert log =~ "preamble boom"
    assert Process.get(:tick_continued) == true
  end

  test "a stateful poller stamps :persistent_term with its last successful tick" do
    :persistent_term.erase({StatefulPreambleTestPoller, :last_run})
    :persistent_term.erase({StatefulPreambleTestPoller, :started_at})
    PollerProgress.reset(StatefulPreambleTestPoller)

    on_exit(fn ->
      :persistent_term.erase({StatefulPreambleTestPoller, :last_run})
      :persistent_term.erase({StatefulPreambleTestPoller, :started_at})
      PollerProgress.reset(StatefulPreambleTestPoller)
    end)

    refute StatefulPreambleTestPoller.status().last_run_at
    refute StatefulPreambleTestPoller.status().started_at

    pid = start_supervised!({StatefulPreambleTestPoller, interval: :timer.hours(1)})

    # init/1 stamps started_at (the /healthz first-tick guard reads it) before any tick completes.
    assert %DateTime{} = StatefulPreambleTestPoller.status().started_at

    capture_log(fn -> assert :ok = StatefulPreambleTestPoller.poll(pid) end)

    assert %DateTime{} = last_run_at = StatefulPreambleTestPoller.status().last_run_at
    assert DateTime.diff(DateTime.utc_now(), last_run_at) < 5
  end

  # Runs the steps the test puts in its state: `{:unit, label, fun}` through isolate/2, and
  # `{:bare, fun}` outside any unit, as the real pollers' list queries run between units.
  defmodule SteppedTestPoller do
    @default_interval :timer.hours(1)
    @search_retry_after 60
    use Cinder.Download.PollerSkeleton, log_prefix: "stepped test poller"

    # A unit nested in another, called from a step that runs in the poller's process.
    def nested(label, fun), do: isolate(label, fun)

    defp do_poll(state) do
      Enum.each(Map.get(state, :steps, []), &run_step/1)
      :ok
    end

    defp run_step({:unit, label, fun}), do: isolate(label, fun)
    defp run_step({:bare, fun}), do: fun.()
  end

  @tag :capture_log
  test "each unit's start and finish stamps progress, nested and raising units included" do
    PollerProgress.reset(SteppedTestPoller)

    on_exit(fn ->
      :persistent_term.erase({SteppedTestPoller, :last_run})
      :persistent_term.erase({SteppedTestPoller, :started_at})
      PollerProgress.reset(SteppedTestPoller)
    end)

    pid = start_supervised!({SteppedTestPoller, interval: :timer.hours(1)})
    test = self()

    hold = fn tag ->
      send(test, {:held, tag})

      receive do
        :go -> :ok
      end
    end

    steps = [
      {:unit, "first", fn -> hold.(:in_first) end},
      {:bare, fn -> hold.(:after_first) end},
      {:unit, "raising",
       fn ->
         hold.(:in_raising)
         raise "Database busy"
       end},
      {:bare, fn -> hold.(:after_raising) end},
      {:unit, "outer",
       fn ->
         hold.(:before_inner)
         SteppedTestPoller.nested("inner", fn -> hold.(:in_inner) end)
         hold.(:after_inner)
       end}
    ]

    :sys.replace_state(pid, &Map.put(&1, :steps, steps))
    send(pid, :poll)

    # At each hold the stamp is newer than the old one the test left at the hold before, so a
    # unit's start or finish stamped it in between: the step names which one.
    old = PollerProgress.now_ms() - :timer.minutes(11)

    for tag <-
          [:in_first, :after_first, :in_raising, :after_raising] ++
            [:before_inner, :in_inner, :after_inner] do
      assert_receive {:held, ^tag}, 5_000
      assert %{tick_in_flight?: true, last_progress_at: at} = SteppedTestPoller.status()
      assert at > old, "no progress stamped before #{tag}"

      PollerProgress.mark(SteppedTestPoller, old)
      assert SteppedTestPoller.status().last_progress_at == old
      send(pid, :go)
    end

    poll_until(fn -> not SteppedTestPoller.status().tick_in_flight? end, timeout: 10_000)
    assert %{last_progress_at: nil, last_run_at: %DateTime{}} = SteppedTestPoller.status()
  end

  test "a (re)started stateful poller clears the in-flight state a killed process left" do
    on_exit(fn ->
      :persistent_term.erase({SteppedTestPoller, :last_run})
      :persistent_term.erase({SteppedTestPoller, :started_at})
      PollerProgress.reset(SteppedTestPoller)
    end)

    PollerProgress.tick_started(SteppedTestPoller)
    assert SteppedTestPoller.status().tick_in_flight?

    start_supervised!({SteppedTestPoller, interval: :timer.hours(1)})

    assert %{tick_in_flight?: false, last_progress_at: nil} = SteppedTestPoller.status()
  end

  test "poll/1 emits [:cinder, :poller, :tick] with the poller module and a duration" do
    start_supervised!({TestPoller, interval: :timer.hours(1)})

    {result, events} =
      Cinder.TelemetryHelpers.capture([:cinder, :poller, :tick], fn -> TestPoller.poll() end)

    assert result == :ok
    assert [{%{duration: duration}, %{poller: TestPoller}}] = events
    assert is_integer(duration) and duration >= 0
  end
end
