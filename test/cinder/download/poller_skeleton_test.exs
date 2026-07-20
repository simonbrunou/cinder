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
end
