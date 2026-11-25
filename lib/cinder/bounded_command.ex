defmodule Cinder.BoundedCommand do
  @moduledoc """
  Bounded external-command execution via a supervised `Port` + `SIGKILL` (#447, #510, #590).
  `System.cmd/3` has no `:timeout` option at all, so any caller shelling out through it runs
  unbounded; `Task.shutdown(:brutal_kill)` only kills the *Elixir* side of a port, not a child OS
  process that never reads stdin (ffprobe, ffmpeg, unrar).

  The kill goes to the command's whole process group, then to its pid (#876). A port's command
  leads its own group, and a process it forks joins that group, so a wrapper script that runs
  the real tool without `exec` stops with it instead of writing on after `run/4` returns. A
  descendant that leaves the group (`setsid`, `setpgid`) is not reached. The reap that follows
  waits only for the command's own exit, not for the rest of its group.

  `run/4` callers: `MediaInfo.Ffprobe`, `AudioProbe.Ffprobe`, `BookArchive.Rar` (listing and
  extraction), `Filesystem.Disk`'s rooted-helper, directory-sync and `mv --exchange` fallback
  calls, `Subtitles.Sync.EngineWorkspace`'s seal call, and `Indexers.ParserWorker`, one call per
  worker with `:input`, `:max_output_bytes` and a one-arity `:check`. A port the caller keeps
  open across calls (`Filesystem.Disk`'s rooted port, `EngineWorkspace`'s holder) closes through
  `kill_and_close/1` instead. Two commands run outside both: `Cinder.Disk.CommandProbe` is a
  GenServer that owns its port across messages, though its timeout kills the same way through
  `kill_os_process/1` (#976), and `Subtitles.Sync.Ffsubsync` runs under coreutils
  `timeout --kill-after`, with `ionice` and `nice` inside it (#954).

  The caller owns the port, so every port message is consumed or drained before `run/4` returns,
  timeout or not. A stray `{port, {:data, _}}`/`{port, {:exit_status, _}}` surviving past the
  return would crash a caller with no catch-all `handle_info/2` (the poller GenServers).
  """

  # Bounded wait for a killed process to actually exit before giving up on it and closing the
  # port out from under it regardless.
  @reap_wait_ms 200

  @doc """
  Resolves `bin` on `PATH` with `find_executable/1` (`Port.open/2` does no lookup for
  `:spawn_executable`, unlike `System.cmd/3`), runs it as a supervised `Port`, and kills its
  process group if it is still running at `timeout_ms`.

  Returns `{:ok, output, status}` on a normal exit — the same `{output, status}` shape
  `System.cmd/3` itself returns, so a caller's existing zero/non-zero-exit handling is unchanged
  — or `{:error, {:timeout, output}}` with whatever output had already accumulated when the
  bound fired (usually none: a hang is a blocking syscall before the subprocess ever writes
  anything). A missing binary returns `{:error, %ErlangError{original: :enoent}}`, reproducing
  `System.cmd/3`'s own raised shape as a plain return value instead.

  Options:

    * `stderr_to_stdout: true` mirrors `System.cmd/3`'s option of the same name.
    * `env: [{"KEY", "value"}]` adds string variables to the child's environment.
    * `check: {interval_ms, fun}` calls `fun` in the caller's process every `interval_ms` (a
      positive integer) while the command runs, first at `interval_ms` after start. A zero-arity
      `fun` gets no argument, a one-arity `fun` gets the command's OS pid, read when the port
      opened. `fun` returns `:ok` to continue or `{:halt, reason}` to kill the command, which makes
      `run/4` return `{:error, {:halted, reason}}`. No check starts at or after the deadline, but
      a running check is not interrupted: keep `fun` cheap and non-blocking, since a slow check
      delays the timeout by its own duration. If `fun` raises (or returns anything else), the
      command is killed before the exception propagates. `BookArchive.Rar` uses this to measure
      the extraction directory against its expanded-size ceiling while `unrar x` runs, and
      `Cinder.Indexers.ParserWorker` to read its worker's resident memory.
    * `input: binary` writes `binary` to the command's stdin, from a separate process so that a
      command that never reads cannot hold the caller past the deadline. A command that exits
      before reading all of it closes the pipe, and the port then exits with `:epipe` and sends no
      exit status; `run/4` returns `{:error, {:port_exit, reason}}` after killing the command's
      group by the OS pid read at the open. While such a call runs, the caller traps exits, so the
      port's exit cannot kill it. When the caller did not trap exits already, an exit signal
      from another linked process meanwhile kills the command and then exits the caller with
      that reason, as the signal would have, a `:normal` one aside.
    * `max_output_bytes: n` (a positive integer) kills the command once its output passes `n`
      bytes, and `run/4` returns `{:error, :output_too_large}`.

  A malformed `:check`, `:env`, `:input` or `:max_output_bytes` raises `ArgumentError` (or
  `FunctionClauseError`) before the command is spawned.
  """
  @spec run(String.t(), [String.t()], non_neg_integer(), keyword()) ::
          {:ok, binary(), non_neg_integer()}
          | {:error, {:timeout, binary()}}
          | {:error, {:halted, term()}}
          | {:error, :output_too_large}
          | {:error, {:port_exit, term()}}
          | {:error, Exception.t()}
          | {:error, {:port_open_failed, term()}}
  def run(bin, args, timeout_ms, opts \\ []) do
    case find_executable(bin) do
      nil -> {:error, %ErlangError{original: :enoent}}
      exe -> open_and_supervise(exe, args, timeout_ms, opts)
    end
  end

  @doc """
  Resolves `program` as `System.find_executable/1` does, reading `PATH` at the time of the call,
  but without the VM's one file server (`:file_server_2`): `System.find_executable/1` stats each
  candidate through that server, so a write hung there on a wedged mount would hold every lookup
  until the mount answers (#1146). Returns the absolute or `PATH`-joined name, or `nil`.

  As in `:os.find_executable/1` on Unix, an absolute `program` is checked as it is, and any other
  is joined to each `PATH` element in turn, an empty element meaning `.` and a double-quoted one
  losing its quotes. The first candidate that is a regular file, after following symlinks, with
  any execute bit set wins.
  """
  @spec find_executable(String.t()) :: String.t() | nil
  def find_executable(program) when is_binary(program) do
    if String.contains?(program, <<0>>) do
      raise ArgumentError,
            "cannot execute #{inspect(__MODULE__)}.find_executable/1 for path with null byte, " <>
              "got: #{inspect(program)}"
    end

    name = String.to_charlist(program)

    found =
      case :filename.pathtype(name) do
        :relative ->
          :os.getenv(~c"PATH", ~c"")
          |> path_elements()
          |> Enum.find_value(&executable(:filename.join(&1, name)))

        _absolute ->
          executable(name)
      end

    found && List.to_string(found)
  end

  defp path_elements(path), do: path |> :string.split(~c":", :all) |> Enum.map(&path_element/1)

  defp path_element([]), do: ~c"."

  defp path_element([?" | rest] = element) do
    case Enum.reverse(rest) do
      [?" | inner] -> Enum.reverse(inner)
      _unquoted -> element
    end
  end

  defp path_element(element), do: element

  defp executable(candidate) do
    case File.stat(candidate, [:raw]) do
      {:ok, %File.Stat{type: :regular, mode: mode}} when Bitwise.band(mode, 0o111) != 0 ->
        candidate

      _other ->
        nil
    end
  end

  @doc """
  Kills the OS process behind an already-open `port`, with its process group, waits briefly for
  it to actually exit, closes the port, and drains anything left in its mailbox — for a port whose
  lifecycle is otherwise managed by the caller (e.g.
  `Cinder.Library.Filesystem.Disk.close_rooted_port/1`), unlike one opened and fully supervised
  by `run/4`. Always returns `:ok`: closing an already-managed port is best-effort cleanup, not a
  new failure mode for the caller to handle.
  """
  @spec kill_and_close(port()) :: :ok
  def kill_and_close(port) do
    kill(port)
    reap(port, System.monotonic_time(:millisecond) + @reap_wait_ms)
    close_port(port)
    drain_immediate(port)
    :ok
  end

  @doc """
  Sends `SIGKILL` to the process group of the port command whose OS pid is `os_pid`, then to
  `os_pid` itself (#876). `run/4` and `kill_and_close/1` kill through it, and so does
  `Cinder.Disk.CommandProbe`, which owns its port across messages (#976). Returns `:ok` once the
  kill ran, failed or not, or `:ignored`, without running it, for anything but an integer above 1.
  """
  @spec kill_os_process(term()) :: :ok | :ignored
  # OTP's port spawner (`erl_child_setup`) calls `setsid` in the child, so the command leads its
  # own process group, whose id is its pid. `kill -KILL -<pid>` reaches every process in that
  # group, so a child the command forked stops writing too. The group is named by the pid, never
  # looked up: if the command leads no group, that kill fails and the pid kill after it still
  # lands, so the kill is never weaker than a pid-only one. dash, the `/bin/sh` of the Debian
  # image and of CI, refuses `kill -KILL -- -<pid>`; `kill -KILL -<pid>` works in dash, bash and
  # busybox `sh` alike. A pid of 1 would make it `-1`, every process this user may signal, so the
  # guard refuses it; no port child has that pid. Like the pid kill before it, the group kill
  # could reach an unrelated process only if the command exited and its pid was reused in the
  # moment before this runs.
  def kill_os_process(os_pid) when is_integer(os_pid) and os_pid > 1 do
    System.cmd(
      "/bin/sh",
      ["-c", ~S|kill -KILL -"$1"; kill -KILL "$1"|, "kill", Integer.to_string(os_pid)],
      stderr_to_stdout: true
    )

    :ok
  catch
    _kind, _reason -> :ok
  end

  def kill_os_process(_os_pid), do: :ignored

  defp open_and_supervise(exe, args, timeout_ms, opts) do
    # They raise on a malformed option, before anything is spawned: a raise once the process runs
    # would leave it alive and its port messages headed for the caller.
    check = check_option(opts)
    input = input_option(opts)
    max_output = max_output_option(opts)
    port_options = port_options(args, opts)
    trap = if input, do: Process.flag(:trap_exit, true)

    try do
      case open_port(exe, port_options) do
        {:ok, port} ->
          started_at = System.monotonic_time(:millisecond)

          state = %{
            port: port,
            os_pid: os_pid(port),
            deadline: started_at + timeout_ms,
            check: schedule(check, started_at),
            acc: [],
            size: 0,
            max_output: max_output,
            trap: trap
          }

          writer = input && write_input(port, input)

          try do
            supervise(state)
          after
            if writer do
              Process.exit(writer, :kill)
              unlink_and_flush(port)
            end
          end

        {:error, _reason} = error ->
          error
      end
    after
      if input, do: restore_trap(trap)
    end
  end

  # A caller that trapped exits before keeps every message. For one that did not, the exit
  # messages that came in meanwhile are the signals it would have got: a `:normal` one, such as
  # that of the port `kill_os_process/1` runs, is dropped, and any other exits the caller with its
  # reason once the flag is back.
  defp restore_trap(true), do: :ok

  defp restore_trap(false) do
    receive do
      {:EXIT, _from, :normal} ->
        restore_trap(false)

      {:EXIT, _from, reason} ->
        Process.flag(:trap_exit, false)
        exit(reason)
    after
      0 -> Process.flag(:trap_exit, false)
    end
  end

  defp os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      nil -> nil
    end
  end

  # `Port.command/2` suspends its caller while the port is busy, which a command that never reads
  # keeps it, so an unlinked process writes and the caller keeps watching the deadline. Once the
  # port closes, the write raises and the writer ends.
  defp write_input(port, input) do
    spawn(fn ->
      try do
        Port.command(port, input)
      catch
        _kind, _reason -> :ok
      end
    end)
  end

  # Only `Port.open/2` itself is guarded here: anything raised later, once the process is
  # running, must not be reported as a failed open with the process left alive.
  defp open_port(exe, port_options) do
    {:ok, Port.open({:spawn_executable, exe}, port_options)}
  catch
    :error, reason -> {:error, {:port_open_failed, reason}}
  end

  # A zero interval would make every pass of `supervise/1` run the check and never read the port.
  defp check_option(opts) do
    case Keyword.get(opts, :check) do
      nil ->
        nil

      {interval_ms, fun} = check
      when is_integer(interval_ms) and interval_ms > 0 and
             (is_function(fun, 0) or is_function(fun, 1)) ->
        check

      other ->
        raise ArgumentError,
              "expected :check to be {interval_ms, fun} with a positive integer interval " <>
                "and a zero- or one-arity fun, got: #{inspect(other)}"
    end
  end

  defp input_option(opts) do
    case Keyword.get(opts, :input) do
      nil -> nil
      input when is_binary(input) -> input
      other -> raise ArgumentError, "expected :input to be a binary, got: #{inspect(other)}"
    end
  end

  defp max_output_option(opts) do
    case Keyword.get(opts, :max_output_bytes) do
      nil ->
        nil

      max when is_integer(max) and max > 0 ->
        max

      other ->
        raise ArgumentError,
              "expected :max_output_bytes to be a positive integer, got: #{inspect(other)}"
    end
  end

  defp port_options(args, opts) do
    base = [:binary, :exit_status, :use_stdio, args: args]

    base =
      if Keyword.get(opts, :stderr_to_stdout, false), do: [:stderr_to_stdout | base], else: base

    case Keyword.get(opts, :env) do
      nil -> base
      env -> [{:env, charlist_env(env)} | base]
    end
  end

  # `Port.open`'s `:env` option wants `{charlist, charlist}` pairs, unlike `System.cmd/3`'s own
  # `:env` option (which accepts plain strings).
  defp charlist_env(env) do
    Enum.map(env, fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)
  end

  defp schedule(nil, _started_at), do: nil
  defp schedule({interval_ms, fun}, started_at), do: {fun, interval_ms, started_at + interval_ms}

  # Accumulates stdout exactly like `System.cmd/3` returns it (iodata built up, then flattened),
  # bounded by an ABSOLUTE deadline, and runs the check on its own absolute schedule, both
  # compared against the clock before every `receive`. A fixed `after` timer restarts on every
  # matched message, so a subprocess emitting `:data` faster than the tick interval would starve
  # the `after` clause forever and neither the deadline nor the check would ever fire (#506).
  defp supervise(%{port: port} = state) do
    now = System.monotonic_time(:millisecond)

    cond do
      now >= state.deadline ->
        kill_and_reap(port, {:timeout, output(state.acc)})

      check_due?(state.check, now) ->
        run_check(state)

      true ->
        receive do
          {^port, {:data, data}} ->
            take_data(state, data)

          {^port, {:exit_status, status}} ->
            # No further messages for this port should exist, since every `:data` message was
            # already consumed above in send order before `:exit_status` — drained defensively
            # regardless, so a trapless caller can never see a stray message past this return.
            drain_immediate(port)
            {:ok, output(state.acc), status}

          {:EXIT, ^port, reason} when state.trap != nil ->
            kill_os_process(state.os_pid)
            drain_immediate(port)
            {:error, {:port_exit, reason}}

          {:EXIT, _from, reason} when state.trap == false and reason != :normal ->
            kill_and_close(port)
            unlink_and_flush(port)
            restore_trap(false)
            exit(reason)
        after
          wait_ms(state.deadline, state.check, now) -> supervise(state)
        end
    end
  end

  defp take_data(%{max_output: max} = state, data)
       when is_integer(max) and state.size + byte_size(data) > max do
    kill_and_reap(state.port, :output_too_large)
  end

  defp take_data(state, data),
    do: supervise(%{state | acc: [data | state.acc], size: state.size + byte_size(data)})

  # After `Process.unlink/1` returns no exit signal from the port arrives any more, so a call with
  # `:input` leaves no `{:EXIT, port, _}` message behind for a caller that does not trap exits.
  defp unlink_and_flush(port) do
    Process.unlink(port)

    receive do
      {:EXIT, ^port, _reason} -> :ok
    after
      0 -> :ok
    end
  end

  defp check_due?(nil, _now), do: false
  defp check_due?({_fun, _interval_ms, next_at}, now), do: now >= next_at

  # The next check is scheduled from when this one returned, so a check slower than its own
  # interval cannot run back to back and keep the loop from reading the port.
  defp run_check(%{check: {fun, interval_ms, _next_at}} = state) do
    case call_check(state, fun) do
      :ok ->
        next_at = System.monotonic_time(:millisecond) + interval_ms
        supervise(%{state | check: {fun, interval_ms, next_at}})

      {:halt, reason} ->
        kill_and_reap(state.port, {:halted, reason})
    end
  end

  defp call_check(state, fun) do
    result = if is_function(fun, 1), do: fun.(state.os_pid), else: fun.()

    case result do
      :ok -> :ok
      {:halt, _reason} = halt -> halt
    end
  catch
    kind, reason ->
      kill_and_close(state.port)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp wait_ms(deadline, nil, now), do: deadline - now
  defp wait_ms(deadline, {_fun, _interval_ms, next_at}, now), do: min(deadline, next_at) - now

  defp output(acc), do: IO.iodata_to_binary(Enum.reverse(acc))

  defp kill_and_reap(port, reason) do
    kill_and_close(port)
    {:error, reason}
  end

  # Waits up to `@reap_wait_ms` for the killed process to exit. The deadline is absolute, so a
  # killed process still flushing output cannot extend the wait.
  defp reap(port, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining > 0 do
      receive do
        {^port, {:exit_status, _status}} -> :ok
        {^port, {:data, _data}} -> reap(port, deadline)
      after
        remaining -> :ok
      end
    end
  end

  # `Port.close/1` raises `ArgumentError` if the port already closed on its own (the reaped
  # process exited and the port was already consumed by `reap/2`'s `:exit_status` clause).
  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  # Non-blocking: drains every message already queued for `port` without waiting for more.
  defp drain_immediate(port) do
    receive do
      {^port, _message} -> drain_immediate(port)
    after
      0 -> :ok
    end
  end

  # The OS pid behind a `Port` is not otherwise reachable, and `Port.close/1` alone does not
  # guarantee the process actually stops (#510, #590).
  defp kill(port) do
    with {:os_pid, pid} <- Port.info(port, :os_pid), do: kill_os_process(pid)
    :ok
  catch
    _kind, _reason -> :ok
  end
end
