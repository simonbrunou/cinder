defmodule Cinder.Library.AudioProbe.Ffprobe do
  @moduledoc """
  `Cinder.Library.AudioProbe` via the `ffprobe` CLI (FFmpeg).

  Reuses `Cinder.Library.MediaInfo.Ffprobe`'s established techniques rather than inventing ad hoc
  timeout/projection disciplines:

  - **Time bound**: `probe/1` uses the same supervised `Port` + `SIGKILL`-by-`os_pid` idiom
    `MediaInfo.Ffprobe.run_bounded/4` and `BookArchive.Rar.run_extraction/6` use (`@probe_timeout`
    10s — generous for even a large M4B's moov-atom-only read: `ffprobe` never decodes audio for
    `-show_entries`, only parses container metadata). `Task.shutdown(:brutal_kill)` only kills
    the *Elixir* task, not a child that never reads stdin — exactly `ffprobe`'s situation — so a
    hung/slow probe used to keep running and holding the source file open past the reported
    timeout (#510). `health/0`'s own `-version` no-file call stays on the lighter
    `Task.async/yield/shutdown(:brutal_kill)` idiom deliberately; it is out of this issue's scope.
  - **Output bound**: a narrow `-show_entries format=format_name,duration:format_tags=album,title,
    track,disc:chapter=id -of json` projection — the same "ask only for the fields you need"
    discipline `MediaInfo.Ffprobe.args/1`'s CSV projection already uses, rather than a full
    `-show_streams -show_format` dump. `chapter_count` is `length(chapters)` from that SAME
    bounded call, never a second subprocess.

  A timeout, a missing binary, a non-zero exit, or unparseable JSON all return `{:error, _}` —
  every caller degrades, per `Cinder.Library.AudioProbe`'s own moduledoc; none of these are raised.

  The binary is `ffprobe` on `PATH` by default, sharing `config :cinder, :ffprobe_bin` with
  `MediaInfo.Ffprobe` — one operator-editable setting for the one binary both probes shell out to.
  """
  @behaviour Cinder.Library.AudioProbe

  @probe_timeout 10_000
  @health_timeout 3_000

  # Bounded wait for a killed process to actually exit before giving up on it — mirrors
  # `Cinder.Library.MediaInfo.Ffprobe`'s own `@reap_wait_ms` / `BookArchive.Rar`'s `@reap_wait_ms`.
  @reap_wait_ms 200

  # Supervised `Port` + `SIGKILL`-by-`os_pid` (#510) — `Task.shutdown(:brutal_kill)` only kills
  # the *Elixir* task, not a child that never reads stdin (ffprobe's situation), so a hung/slow
  # probe kept running and holding the source file open past the reported timeout. Mirrors
  # `Cinder.Library.MediaInfo.Ffprobe.run_bounded/4`'s exact technique.
  @impl true
  def probe(path) do
    case run_bounded(bin(), args(path), probe_timeout_ms()) do
      {:ok, out, 0} -> parse(out)
      {:ok, out, code} -> {:error, {:ffprobe_exit, code, String.trim(out)}}
      {:error, _reason} = error -> error
    end
  rescue
    e -> {:error, e}
  end

  # `health/0` mirrors `MediaInfo.Ffprobe.health/0` exactly (`-version`, same timeout) — see its
  # own comments for why the missing-binary rescue must run INSIDE the task.
  @impl true
  def health do
    task =
      Task.async(fn ->
        try do
          System.cmd(bin(), ["-version"], stderr_to_stdout: true)
        rescue
          e -> {:error, e}
        end
      end)

    case Task.yield(task, @health_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:error, _} = error} -> error
      {:ok, {_out, 0}} -> :ok
      {:ok, {out, code}} -> {:error, {:ffprobe_exit, code, String.trim(out)}}
      {:exit, reason} -> {:error, {:ffprobe_exit, reason}}
      nil -> {:error, :timeout}
    end
  end

  defp probe_timeout_ms,
    do: Application.get_env(:cinder, :audiobook_probe_timeout_ms, @probe_timeout)

  defp run_bounded(bin, args, timeout_ms) do
    case System.find_executable(bin) do
      nil -> {:error, %ErlangError{original: :enoent}}
      exe -> open_and_supervise(exe, args, timeout_ms)
    end
  end

  defp open_and_supervise(exe, args, timeout_ms) do
    port =
      Port.open({:spawn_executable, exe}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        args: args
      ])

    deadline = System.monotonic_time(:millisecond) + timeout_ms
    supervise(port, deadline, [])
  catch
    :error, reason -> {:error, {:port_open_failed, reason}}
  end

  # Bounded by an ABSOLUTE deadline recomputed on every receive (not a fixed poll tick reset by
  # each matched message) — see `MediaInfo.Ffprobe.supervise/3`'s own comment for why a fixed
  # `after` would let a chatty process starve the timeout forever.
  defp supervise(port, deadline, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      kill_and_reap(port)
    else
      receive do
        {^port, {:data, data}} ->
          supervise(port, deadline, [data | acc])

        {^port, {:exit_status, status}} ->
          drain_immediate(port)
          {:ok, IO.iodata_to_binary(Enum.reverse(acc)), status}
      after
        remaining -> kill_and_reap(port)
      end
    end
  end

  # Kills the OS process, waits briefly for it to actually exit, then closes the port and drains
  # anything left in its mailbox regardless — a stray `{port, {:data, _}}` past this return could
  # reach a caller with no catch-all `handle_info/2`.
  defp kill_and_reap(port) do
    kill(port)
    reap(port, System.monotonic_time(:millisecond) + @reap_wait_ms)
    close_port(port)
    drain_immediate(port)
    {:error, :timeout}
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

  # `Port.close/1` raises `ArgumentError` if the port already closed on its own.
  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp drain_immediate(port) do
    receive do
      {^port, _message} -> drain_immediate(port)
    after
      0 -> :ok
    end
  end

  # Mirrors `MediaInfo.Ffprobe.kill/1` / `BookArchive.Rar.kill/1` exactly: the OS pid behind a
  # `Port` is not otherwise reachable, and `Port.close/1` alone does not guarantee the process
  # actually stops.
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

  defp args(path),
    do: ~w(-v error
        -show_entries format=format_name,duration:format_tags=album,title,track,disc:chapter=id
        -of json) ++ [path]

  defp parse(out) do
    case Jason.decode(out) do
      {:ok, decoded} -> {:ok, extract(decoded)}
      {:error, _reason} -> {:error, :invalid_probe_output}
    end
  end

  defp extract(decoded) do
    format = Map.get(decoded, "format") || %{}
    tags = Map.get(format, "tags") || %{}
    chapters = Map.get(decoded, "chapters") || []

    %{
      container: container(Map.get(format, "format_name")),
      duration_seconds: duration(Map.get(format, "duration")),
      chapter_count: length(chapters),
      track_tag: leading_integer(Map.get(tags, "track")),
      disc_tag: leading_integer(Map.get(tags, "disc")),
      album_tag: nonblank(Map.get(tags, "album")),
      title_tag: nonblank(Map.get(tags, "title"))
    }
  end

  # ffprobe reports every MP4-family container (M4B included — it has no format name distinct
  # from M4A/MP4) under the same `format_name` string, so this can only ever confirm "one of the
  # two accepted containers", never distinguish M4B from a same-family container ffprobe itself
  # cannot tell apart. `Cinder.Library.AudiobookSources`' own extension + magic-byte check is the
  # actual format gate; this field rides along on the probe result for completeness only.
  defp container(name) when is_binary(name) do
    cond do
      String.contains?(name, "mp3") -> :mp3
      String.contains?(name, "mov") or String.contains?(name, "mp4") -> :m4b
      true -> :unknown
    end
  end

  defp container(_name), do: :unknown

  defp duration(value) when is_binary(value) do
    case Float.parse(value) do
      {seconds, _rest} when seconds >= 0 -> trunc(seconds)
      _ -> nil
    end
  end

  defp duration(_value), do: nil

  defp leading_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _rest} when int > 0 -> int
      _ -> nil
    end
  end

  defp leading_integer(_value), do: nil

  defp nonblank(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp nonblank(_value), do: nil

  defp bin, do: Application.get_env(:cinder, :ffprobe_bin, "ffprobe")
end
