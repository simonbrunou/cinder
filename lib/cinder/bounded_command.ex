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
  calls, and `Subtitles.Sync.EngineWorkspace`'s seal call. A port the caller keeps open across
  calls (`Filesystem.Disk`'s rooted port, `EngineWorkspace`'s holder) closes through
  `kill_and_close/1` instead. Outside this module: `Cinder.Disk.CommandProbe` is a GenServer that
  owns its port across messages, and `Subtitles.Sync.Ffsubsync` runs under coreutils
  `timeout --kill-after`.

  The caller owns the port, so every port message is consumed or drained before `run/4` returns,
  timeout or not. A stray `{port, {:data, _}}`/`{port, {:exit_status, _}}` surviving past the
  return would crash a caller with no catch-all `handle_info/2` (the poller GenServers).
  """

  # Bounded wait for a killed process to actually exit before giving up on it and closing the
  # port out from under it regardless.
  @reap_wait_ms 200

  @doc """
  Resolves `bin` on `PATH` (`Port.open/2` does no lookup for `:spawn_executable`, unlike
  `System.cmd/3`), runs it as a supervised `Port`, and kills its process group if it is still
  running at `timeout_ms`.

  Returns `{:ok, output, status}` on a normal exit — the same `{output, status}` shape
  `System.cmd/3` itself returns, so a caller's existing zero/non-zero-exit handling is unchanged
  — or `{:error, {:timeout, output}}` with whatever output had already accumulated when the
  bound fired (usually none: a hang is a blocking syscall before the subprocess ever writes
  anything). A missing binary returns `{:error, %ErlangError{original: :enoent}}`, reproducing
  `System.cmd/3`'s own raised shape as a plain return value instead.

  Options:

    * `stderr_to_stdout: true` mirrors `System.cmd/3`'s option of the same name.
    * `env: [{"KEY", "value"}]` adds string variables to the child's environment.
    * `check: {interval_ms, fun}` calls the zero-arity `fun` in the caller's process every
      `interval_ms` (a positive integer) while the command runs, first at `interval_ms` after
      start. `fun` returns `:ok` to continue or `{:halt, reason}` to kill the command, which makes
      `run/4` return `{:error, {:halted, reason}}`. No check starts at or after the deadline, but
      a running check is not interrupted: keep `fun` cheap and non-blocking, since a slow check
      delays the timeout by its own duration. If `fun` raises (or returns anything else), the
      command is killed before the exception propagates. `BookArchive.Rar` uses this to measure
      the extraction directory against its expanded-size ceiling while `unrar x` runs.

  A malformed `:check` or `:env` raises `ArgumentError` (or `FunctionClauseError`) before the
  command is spawned.
  """
  @spec run(String.t(), [String.t()], non_neg_integer(), keyword()) ::
          {:ok, binary(), non_neg_integer()}
          | {:error, {:timeout, binary()}}
          | {:error, {:halted, term()}}
          | {:error, Exception.t()}
          | {:error, {:port_open_failed, term()}}
  def run(bin, args, timeout_ms, opts \\ []) do
    case System.find_executable(bin) do
      nil -> {:error, %ErlangError{original: :enoent}}
      exe -> open_and_supervise(exe, args, timeout_ms, opts)
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

  defp open_and_supervise(exe, args, timeout_ms, opts) do
    # Both raise on a malformed option, before anything is spawned: a raise once the process runs
    # would leave it alive and its port messages headed for the caller.
    check = check_option(opts)
    port_options = port_options(args, opts)

    case open_port(exe, port_options) do
      {:ok, port} ->
        started_at = System.monotonic_time(:millisecond)
        supervise(port, started_at + timeout_ms, schedule(check, started_at), [])

      {:error, _reason} = error ->
        error
    end
  end

  # Only `Port.open/2` itself is guarded here: anything raised later, once the process is
  # running, must not be reported as a failed open with the process left alive.
  defp open_port(exe, port_options) do
    {:ok, Port.open({:spawn_executable, exe}, port_options)}
  catch
    :error, reason -> {:error, {:port_open_failed, reason}}
  end

  # A zero interval would make every pass of `supervise/4` run the check and never read the port.
  defp check_option(opts) do
    case Keyword.get(opts, :check) do
      nil ->
        nil

      {interval_ms, fun} = check
      when is_integer(interval_ms) and interval_ms > 0 and is_function(fun, 0) ->
        check

      other ->
        raise ArgumentError,
              "expected :check to be {interval_ms, fun} with a positive integer interval " <>
                "and a zero-arity fun, got: #{inspect(other)}"
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
  defp supervise(port, deadline, check, acc) do
    now = System.monotonic_time(:millisecond)

    cond do
      now >= deadline ->
        kill_and_reap(port, {:timeout, output(acc)})

      check_due?(check, now) ->
        run_check(port, deadline, check, acc)

      true ->
        receive do
          {^port, {:data, data}} ->
            supervise(port, deadline, check, [data | acc])

          {^port, {:exit_status, status}} ->
            # No further messages for this port should exist, since every `:data` message was
            # already consumed above in send order before `:exit_status` — drained defensively
            # regardless, so a trapless caller can never see a stray message past this return.
            drain_immediate(port)
            {:ok, output(acc), status}
        after
          wait_ms(deadline, check, now) -> supervise(port, deadline, check, acc)
        end
    end
  end

  defp check_due?(nil, _now), do: false
  defp check_due?({_fun, _interval_ms, next_at}, now), do: now >= next_at

  # The next check is scheduled from when this one returned, so a check slower than its own
  # interval cannot run back to back and keep the loop from reading the port.
  defp run_check(port, deadline, {fun, interval_ms, _next_at}, acc) do
    case call_check(port, fun) do
      :ok ->
        next_at = System.monotonic_time(:millisecond) + interval_ms
        supervise(port, deadline, {fun, interval_ms, next_at}, acc)

      {:halt, reason} ->
        kill_and_reap(port, {:halted, reason})
    end
  end

  defp call_check(port, fun) do
    case fun.() do
      :ok -> :ok
      {:halt, _reason} = halt -> halt
    end
  catch
    kind, reason ->
      kill_and_close(port)
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
  #
  # OTP's port spawner (`erl_child_setup`) calls `setsid` in the child, so the command leads its
  # own process group, whose id is its pid. `kill -KILL -<pid>` reaches every process in that
  # group, so a child the command forked stops writing too (#876). The group is named by the
  # pid, never looked up: if the command leads no group, that kill fails and the pid kill after
  # it still lands, so the kill is never weaker than a pid-only one. dash, the `/bin/sh` of the
  # Debian image and of CI, refuses `kill -KILL -- -<pid>`; `kill -KILL -<pid>` works in dash,
  # bash and busybox `sh` alike. A pid of 1 would make it `-1`, every process this user may
  # signal, so the guard refuses it; no port child has that pid. Like the pid kill before it, the
  # group kill could reach an unrelated process only if the command exited and its pid was reused
  # in the moment before this runs.
  defp kill(port) do
    with {:os_pid, pid} when is_integer(pid) and pid > 1 <- Port.info(port, :os_pid) do
      System.cmd(
        "/bin/sh",
        ["-c", ~S|kill -KILL -"$1"; kill -KILL "$1"|, "kill", Integer.to_string(pid)],
        stderr_to_stdout: true
      )
    end

    :ok
  catch
    _kind, _reason -> :ok
  end
end
