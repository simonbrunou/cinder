defmodule Cinder.BoundedCommandTest do
  # `run/4`'s own options, driven through stub executables in a tmp dir. The callers'
  # hung-binary tests (`MediaInfo.FfprobeTest`, `AudioProbe.FfprobeTest`, `BookArchive.RarTest`,
  # `DiskBoundedTest`, `EngineWorkspaceBoundedTest`) each prove their own call passes its timeout
  # through; this file proves what `run/4` does with it.
  use ExUnit.Case, async: true

  alias Cinder.BoundedCommand
  alias Cinder.Test.OsProcess

  @moduletag :tmp_dir

  describe "run/4 with :env" do
    test "the variables reach the child process", %{tmp_dir: tmp} do
      bin = stub!(tmp, ~S|printf '%s' "$CINDER_BOUNDED_TEST"|)

      assert BoundedCommand.run(bin, [], 1_000, env: [{"CINDER_BOUNDED_TEST", "from-env"}]) ==
               {:ok, "from-env", 0}
    end

    test "a non-string value raises before the command is ever spawned", %{tmp_dir: tmp} do
      marker = Path.join(tmp, "spawned")
      bin = stub!(tmp, "touch #{marker}")

      assert_raise FunctionClauseError, fn ->
        BoundedCommand.run(bin, [], 1_000, env: [{"CINDER_BOUNDED_TEST", nil}])
      end

      refute File.exists?(marker)
    end
  end

  describe "run/4 with :check" do
    test "a check that halts kills the OS process and returns its reason", %{tmp_dir: tmp} do
      pidfile = Path.join(tmp, "stub.pid")
      bin = hanging_stub!(tmp, pidfile)
      check = fn -> if File.exists?(pidfile), do: {:halt, :too_big}, else: :ok end

      t0 = System.monotonic_time(:millisecond)

      assert BoundedCommand.run(bin, [], 10_000, check: {20, check}) ==
               {:error, {:halted, :too_big}}

      # The window times the stub's start and pid write, one check interval, the kill's `/bin/sh`
      # fork and the reap of up to 200 ms. A loaded runner took 6425 ms (run 676, #1091), so the
      # ceiling is 9 s. The result pattern proves the check ended the call. Only this ceiling
      # fails a halt path that leaves the stub running until the call's 10 s timeout, which caps
      # the ceiling, or until the stub's own 30 s exit: `dead?/1` passes whichever ended the stub.
      assert System.monotonic_time(:millisecond) - t0 < 9_000
      assert OsProcess.dead?(read_pid!(pidfile))

      # The caller owns the port, and a poller GenServer has no catch-all `handle_info/2`.
      refute_receive {_port, {:data, _data}}, 200
      refute_receive {_port, {:exit_status, _status}}, 50
    end

    # #506: a check that only ran when `receive` sat idle would never run against a process that
    # writes without pause. The deadline is far off, so only the check can end this call.
    @tag timeout: 15_000
    test "continuous output cannot starve the check", %{tmp_dir: tmp} do
      bin = stub!(tmp, "while :; do printf spam; done")

      calls = :counters.new(1, [])

      check = fn ->
        :counters.add(calls, 1, 1)
        if :counters.get(calls, 1) == 3, do: {:halt, :third_check}, else: :ok
      end

      t0 = System.monotonic_time(:millisecond)

      assert BoundedCommand.run(bin, [], 10_000, check: {50, check}) ==
               {:error, {:halted, :third_check}}

      # The window times the stub's start, three 50 ms check intervals, the kill's `/bin/sh` fork
      # and the reap of up to 200 ms, which consumes the output the stub wrote meanwhile. A loaded
      # runner took 3496 ms (run 904, #1216), so the ceiling is 9 s. The result pattern alone
      # fails the #506 regression, a check that never runs, since the call then times out. Only
      # this ceiling fails a third check that comes late but before the call's 10 s timeout,
      # which caps the ceiling: a third check due after that timeout fails the result pattern.
      assert System.monotonic_time(:millisecond) - t0 < 9_000
    end

    test "a check interval longer than the timeout does not extend the deadline", %{
      tmp_dir: tmp
    } do
      bin = stub!(tmp, "exec sleep 30")
      check = fn -> {:halt, :checked_past_the_deadline} end

      t0 = System.monotonic_time(:millisecond)
      assert BoundedCommand.run(bin, [], 200, check: {10_000, check}) == {:error, {:timeout, ""}}

      # The window times the stub's start, the 200 ms deadline, the kill's `/bin/sh` fork and the
      # reap of up to 200 ms. A loaded runner took 5336 ms (run 900, #1216), so the ceiling is
      # 9 s. Only this ceiling fails a deadline that the check interval extends: the loop tests
      # the deadline before a due check, so such a call still returns this timeout, but no sooner
      # than the 10 s check interval after the port opens, which caps the ceiling.
      assert System.monotonic_time(:millisecond) - t0 < 9_000
    end

    test "a check that raises kills the OS process before the exception propagates", %{
      tmp_dir: tmp
    } do
      pidfile = Path.join(tmp, "stub.pid")
      bin = hanging_stub!(tmp, pidfile)
      check = fn -> if File.exists?(pidfile), do: raise("check failed"), else: :ok end

      assert_raise RuntimeError, "check failed", fn ->
        BoundedCommand.run(bin, [], 10_000, check: {20, check})
      end

      assert OsProcess.dead?(read_pid!(pidfile))
      refute_receive {_port, {:data, _data}}, 200
      refute_receive {_port, {:exit_status, _status}}, 50
    end

    test "a malformed check raises before the command is ever spawned", %{tmp_dir: tmp} do
      marker = Path.join(tmp, "spawned")
      bin = stub!(tmp, "touch #{marker}\nexec sleep 30")
      check = fn -> :ok end

      for bad <- [{check, 20}, {0, check}, {2.5, check}, {20, fn _arg -> :ok end}] do
        assert_raise ArgumentError, fn -> BoundedCommand.run(bin, [], 10_000, check: bad) end
      end

      refute File.exists?(marker)
    end

    test "a check returning anything but :ok or {:halt, reason} kills the OS process", %{
      tmp_dir: tmp
    } do
      pidfile = Path.join(tmp, "stub.pid")
      bin = hanging_stub!(tmp, pidfile)
      check = fn -> if File.exists?(pidfile), do: :halt, else: :ok end

      assert_raise CaseClauseError, fn ->
        BoundedCommand.run(bin, [], 10_000, check: {20, check})
      end

      assert OsProcess.dead?(read_pid!(pidfile))
    end
  end

  # #876: a halt or a timeout kills the command's whole process group, not only its pid. The
  # child sleeps 5 s, longer than the 1 s deadline, the 200 ms reap wait and
  # `OsProcess.dead?/1`'s 1 s poll together, so it can only be dead there if the kill reached it,
  # and a killed child writes nothing more.
  describe "run/4 kills what the command forked" do
    test "on a check halt", %{tmp_dir: tmp} do
      child_pidfile = Path.join(tmp, "child.pid")
      bin = forking_stub!(tmp, child_pidfile)
      check = fn -> if File.exists?(child_pidfile), do: {:halt, :too_big}, else: :ok end

      assert BoundedCommand.run(bin, [], 10_000, check: {20, check}) ==
               {:error, {:halted, :too_big}}

      assert OsProcess.dead?(read_pid!(child_pidfile))
    end

    test "on the deadline", %{tmp_dir: tmp} do
      child_pidfile = Path.join(tmp, "child.pid")
      bin = forking_stub!(tmp, child_pidfile)

      assert BoundedCommand.run(bin, [], 1_000) == {:error, {:timeout, ""}}

      # The kill must have had a child to reach, or this test proves nothing.
      assert File.exists?(child_pidfile), "the stub had not forked its child by the deadline"
      assert OsProcess.dead?(read_pid!(child_pidfile))
    end
  end

  # #976: the guard keeps `kill -KILL -1`, every process this user may signal, from ever running.
  # No test passes 1 or a negative pid, since a broken guard would then kill the test host. A pid
  # of 0 takes the same refusal, and if the guard let it through, its kill would reach only the
  # shell running it, which leads a process group of its own.
  describe "kill_os_process/1" do
    test "kills a running process" do
      port =
        Port.open({:spawn_executable, System.find_executable("sleep")}, [
          :exit_status,
          args: ["30"]
        ])

      {:os_pid, os_pid} = Port.info(port, :os_pid)

      assert BoundedCommand.kill_os_process(os_pid) == :ok
      assert_receive {^port, {:exit_status, _status}}, 5_000
    end

    test "runs no kill for anything but an integer above 1" do
      assert BoundedCommand.kill_os_process(0) == :ignored
      assert BoundedCommand.kill_os_process(nil) == :ignored
    end
  end

  # Forks a child that sleeps 5 s, writes the child's pid, then `exec`s into a long sleep. A
  # non-interactive shell has no job control, so the child stays in the stub's process group.
  defp forking_stub!(tmp, child_pidfile) do
    stub!(tmp, "sleep 5 &\n#{write_pid("$!", child_pidfile)}\nexec sleep 30")
  end

  # Writes its pid, then `exec`s into a long sleep under that same pid.
  defp hanging_stub!(tmp, pidfile) do
    stub!(tmp, "#{write_pid("$$", pidfile)}\nexec sleep 30")
  end

  # Through a rename, so a reader never sees a half-written file.
  defp write_pid(pid_var, pidfile),
    do: "echo #{pid_var} > #{pidfile}.tmp && mv #{pidfile}.tmp #{pidfile}"

  defp stub!(tmp, script) do
    path = Path.join(tmp, "stub-#{System.unique_integer([:positive])}")
    File.write!(path, "#!/bin/sh\n#{script}\n")
    File.chmod!(path, 0o755)
    path
  end

  # Every caller's check only fires once the pid file exists, so it is there to read.
  defp read_pid!(pidfile), do: pidfile |> File.read!() |> String.trim() |> String.to_integer()
end
