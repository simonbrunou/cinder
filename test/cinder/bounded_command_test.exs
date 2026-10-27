defmodule Cinder.BoundedCommandTest do
  # `run/4`'s own options, driven through stub executables in a tmp dir. The callers'
  # hung-binary tests (`MediaInfo.FfprobeTest`, `AudioProbe.FfprobeTest`, `BookArchive.RarTest`,
  # `DiskBoundedTest`, `EngineWorkspaceBoundedTest`) each prove their own call passes its timeout
  # through; this file proves what `run/4` does with it.
  use ExUnit.Case, async: true

  alias Cinder.BoundedCommand

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

      assert System.monotonic_time(:millisecond) - t0 < 3_000
      assert process_dead?(read_pid!(pidfile))

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

      assert System.monotonic_time(:millisecond) - t0 < 3_000
    end

    test "a check interval longer than the timeout does not extend the deadline", %{
      tmp_dir: tmp
    } do
      bin = stub!(tmp, "exec sleep 30")
      check = fn -> {:halt, :checked_past_the_deadline} end

      t0 = System.monotonic_time(:millisecond)
      assert BoundedCommand.run(bin, [], 200, check: {10_000, check}) == {:error, {:timeout, ""}}
      assert System.monotonic_time(:millisecond) - t0 < 3_000
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

      assert process_dead?(read_pid!(pidfile))
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

      assert process_dead?(read_pid!(pidfile))
    end
  end

  # #876: a halt or a timeout kills the command's whole process group, not only its pid. The
  # child sleeps 5 s, longer than the 1 s deadline, the 200 ms reap wait and `process_dead?/1`'s
  # 1 s poll together, so it can only be dead there if the kill reached it, and a killed child
  # writes nothing more.
  describe "run/4 kills what the command forked" do
    test "on a check halt", %{tmp_dir: tmp} do
      child_pidfile = Path.join(tmp, "child.pid")
      bin = forking_stub!(tmp, child_pidfile)
      check = fn -> if File.exists?(child_pidfile), do: {:halt, :too_big}, else: :ok end

      assert BoundedCommand.run(bin, [], 10_000, check: {20, check}) ==
               {:error, {:halted, :too_big}}

      assert process_dead?(read_pid!(child_pidfile))
    end

    test "on the deadline", %{tmp_dir: tmp} do
      child_pidfile = Path.join(tmp, "child.pid")
      bin = forking_stub!(tmp, child_pidfile)

      assert BoundedCommand.run(bin, [], 1_000) == {:error, {:timeout, ""}}

      # The kill must have had a child to reach, or this test proves nothing.
      assert File.exists?(child_pidfile), "the stub had not forked its child by the deadline"
      assert process_dead?(read_pid!(child_pidfile))
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

  # A SIGKILL is not instantaneous from here, so this polls a short bounded window. A forked
  # child whose parent died is reparented, and the CI job container's PID 1 may never reap it. A
  # zombie still answers `kill -0`, so this reads the process state instead: gone, zombie (`Z`) or
  # dead (`X`) all mean it runs no more code. A process reaped mid-read answers `:esrch`. The
  # command name in parentheses may hold spaces, so the state is the first field after the last
  # `)`.
  defp process_dead?(pid, attempts \\ 50)
  defp process_dead?(_pid, 0), do: false

  defp process_dead?(pid, attempts) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} ->
        state =
          stat |> String.split(")") |> List.last() |> String.trim_leading() |> String.first()

        if state in ["Z", "X"] do
          true
        else
          Process.sleep(20)
          process_dead?(pid, attempts - 1)
        end

      # Without `/proc` (not Linux) every pid would read as gone, and the test would prove
      # nothing.
      {:error, reason} when reason in [:enoent, :esrch] ->
        File.dir?("/proc/self") or flunk("process_dead?/2 reads /proc, which this host lacks")
    end
  end
end
