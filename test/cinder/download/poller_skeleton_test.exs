defmodule Cinder.Download.PollerSkeletonTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

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

  # A `stateful: true` poller (`Cinder.Download.Poller`, `Cinder.Download.TvPoller`) — models the
  # do_poll/1 shape both real pollers use: a preamble wrapped in isolate/2, then further work.
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
    on_exit(fn -> :persistent_term.erase({StatefulPreambleTestPoller, :last_run}) end)

    refute StatefulPreambleTestPoller.status().last_run_at

    pid = start_supervised!({StatefulPreambleTestPoller, interval: :timer.hours(1)})
    capture_log(fn -> assert :ok = StatefulPreambleTestPoller.poll(pid) end)

    assert %DateTime{} = last_run_at = StatefulPreambleTestPoller.status().last_run_at
    assert DateTime.diff(DateTime.utc_now(), last_run_at) < 5
  end
end
