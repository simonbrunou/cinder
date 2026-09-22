defmodule Cinder.BoundedCommand do
  @moduledoc """
  Bounded external-command execution via a supervised `Port` + `SIGKILL`-by-`os_pid` (issue
  #590) — the same idiom `Cinder.Library.MediaInfo.Ffprobe.open_and_supervise/4`,
  `Cinder.Library.AudioProbe.Ffprobe`, and `Cinder.Library.BookArchive.Rar` each already
  implement privately for their own subprocess (#447/#510). `System.cmd/3` has no `:timeout`
  option at all, so any caller shelling out through it runs unbounded; `Task.shutdown(
  :brutal_kill)` only kills the *Elixir* side of a port, not a child OS process that never reads
  stdin.

  Used by `Cinder.Library.Filesystem.Disk`'s rooted-helper, directory-sync, and `mv --exchange`
  fallback calls. Extracting a shared module here is deliberately scoped to this new caller only
  — migrating the three existing private copies above to it is out of scope for this change (see
  issue #590's PR body for the follow-up).
  """

  # Bounded wait for a killed process to actually exit before giving up on it and closing the
  # port out from under it regardless — mirrors `MediaInfo.Ffprobe`/`AudioProbe.Ffprobe`/
  # `BookArchive.Rar`'s own `@reap_wait_ms`.
  @reap_wait_ms 200

  @doc """
  Resolves `bin` on `PATH` (`Port.open/2` does no lookup for `:spawn_executable`, unlike
  `System.cmd/3`), runs it as a supervised `Port`, and kills it by OS pid if it is still running
  at `timeout_ms`.

  Returns `{:ok, output, status}` on a normal exit — the same `{output, status}` shape
  `System.cmd/3` itself returns, so a caller's existing zero/non-zero-exit handling is unchanged
  — or `{:error, {:timeout, output}}` with whatever output had already accumulated when the
  bound fired (usually none: a hang is a blocking syscall before the subprocess ever writes
  anything). A missing binary returns `{:error, %ErlangError{original: :enoent}}`, reproducing
  `System.cmd/3`'s own raised shape as a plain return value instead.

  `opts` accepts `stderr_to_stdout: true`, mirroring `System.cmd/3`'s own option of the same
  name.
  """
  @spec run(String.t(), [String.t()], non_neg_integer(), keyword()) ::
          {:ok, binary(), non_neg_integer()}
          | {:error, {:timeout, binary()}}
          | {:error, Exception.t()}
          | {:error, {:port_open_failed, term()}}
  def run(bin, args, timeout_ms, opts \\ []) do
    case System.find_executable(bin) do
      nil -> {:error, %ErlangError{original: :enoent}}
      exe -> open_and_supervise(exe, args, timeout_ms, opts)
    end
  end

  @doc """
  Kills the OS process behind an already-open `port` by pid, waits briefly for it to actually
  exit, closes the port, and drains anything left in its mailbox — for a port whose lifecycle is
  otherwise managed by the caller (e.g. `Cinder.Library.Filesystem.Disk.close_rooted_port/1`),
  unlike one opened and fully supervised by `run/4`. Always returns `:ok`: closing an already-
  managed port is best-effort cleanup, not a new failure mode for the caller to handle.
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
    port = Port.open({:spawn_executable, exe}, port_options(args, opts))
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    supervise(port, deadline, [])
  catch
    :error, reason -> {:error, {:port_open_failed, reason}}
  end

  defp port_options(args, opts) do
    base = [:binary, :exit_status, :use_stdio, args: args]
    if Keyword.get(opts, :stderr_to_stdout, false), do: [:stderr_to_stdout | base], else: base
  end

  # Accumulates stdout exactly like `System.cmd/3` returns it (iodata built up, then flattened),
  # bounded by an ABSOLUTE deadline recomputed on every receive rather than a fixed poll tick.
  # A fixed `after` timer restarts on every matched message, so a subprocess emitting `:data`
  # faster than the tick interval would starve the `after` clause forever and this call would
  # never time out at all (#506/#590) — recomputing `remaining` from a fixed deadline before
  # every `receive` closes that gap.
  defp supervise(port, deadline, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      kill_and_reap(port, acc)
    else
      receive do
        {^port, {:data, data}} ->
          supervise(port, deadline, [data | acc])

        {^port, {:exit_status, status}} ->
          # No further messages for this port should exist, since every `:data` message was
          # already consumed above in send order before `:exit_status` — drained defensively
          # regardless, so a trapless caller can never see a stray message past this return.
          drain_immediate(port)
          {:ok, IO.iodata_to_binary(Enum.reverse(acc)), status}
      after
        remaining -> kill_and_reap(port, acc)
      end
    end
  end

  # Kills the OS process, waits up to `@reap_wait_ms` for it to actually exit, then closes the
  # port and drains anything left in the mailbox regardless of whether the reap succeeded — a
  # stray `{port, {:data, _}}`/`{port, {:exit_status, _}}` surviving past this return could crash
  # a trapless caller (the poller GenServers reached through `Cinder.Library.Filesystem.Disk`
  # have no catch-all `handle_info/2`).
  defp kill_and_reap(port, acc) do
    kill(port)
    reap(port, System.monotonic_time(:millisecond) + @reap_wait_ms)
    close_port(port)
    drain_immediate(port)
    {:error, {:timeout, IO.iodata_to_binary(Enum.reverse(acc))}}
  end

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
  # guarantee the process actually stops — exactly the defect class #510 fixed for three other
  # modules and #590 fixes here.
  defp kill(port) do
    with {:os_pid, pid} <- Port.info(port, :os_pid) do
      System.cmd(
        "/bin/sh",
        ["-c", ~S|kill -KILL "$1"|, "kill", Integer.to_string(pid)],
        stderr_to_stdout: true
      )
    end

    :ok
  catch
    _kind, _reason -> :ok
  end
end
