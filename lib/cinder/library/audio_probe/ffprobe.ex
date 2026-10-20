defmodule Cinder.Library.AudioProbe.Ffprobe do
  @moduledoc """
  `Cinder.Library.AudioProbe` via the `ffprobe` CLI (FFmpeg).

  Reuses `Cinder.Library.MediaInfo.Ffprobe`'s established techniques rather than inventing ad hoc
  timeout/projection disciplines:

  - **Time bound**: both `probe/1` and `health/0` run through `Cinder.BoundedCommand.run/4`, a
    supervised `Port` killed with `SIGKILL` by its OS pid (`@probe_timeout` 10s for `probe/1`,
    generous for even a large M4B's moov-atom-only read: `ffprobe` never decodes audio for
    `-show_entries`, only parses container metadata; `@health_timeout` 3s for `health/0`'s cheap
    no-file `-version` call, mirroring every other service's `health/0` bound). `Task.shutdown(
    :brutal_kill)` only kills the *Elixir* task, not a child that never reads stdin — exactly
    `ffprobe`'s situation, for a `-version` probe as much as a real file read — so a hung/slow
    call used to keep running (and, for `probe/1`, holding the source file open) past the
    reported timeout (#510).
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

  alias Cinder.BoundedCommand

  @probe_timeout 10_000
  @health_timeout 3_000

  # `Task.shutdown(:brutal_kill)` only kills the *Elixir* task, not a child that never reads
  # stdin (ffprobe's situation), so a hung/slow probe kept running and holding the source file
  # open past the reported timeout (#510). `run_bounded/3` kills the OS process instead.
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

  # `-version` is a cheap no-file call, but that does not make a hung binary harmless (#510): a
  # `Task.shutdown(:brutal_kill)`-killed Elixir task does not kill the OS process behind it
  # either, so it is bounded the same way as `probe/1`. `run_bounded/3` already returns the exact
  # `{:error, %ErlangError{original: :enoent}}` shape a missing binary needs, so no separate
  # rescue is required here.
  @impl true
  def health do
    case run_bounded(bin(), ["-version"], health_timeout_ms()) do
      {:ok, _out, 0} -> :ok
      {:ok, out, code} -> {:error, {:ffprobe_exit, code, String.trim(out)}}
      {:error, _reason} = error -> error
    end
  end

  defp probe_timeout_ms,
    do: Application.get_env(:cinder, :audiobook_probe_timeout_ms, @probe_timeout)

  defp health_timeout_ms,
    do: Application.get_env(:cinder, :audiobook_health_timeout_ms, @health_timeout)

  # Its timeout carries the partial output, but this module's contract is the bare
  # `{:error, :timeout}`, which `/dashboard` shows as "Timed out" for `health/0`.
  defp run_bounded(bin, args, timeout_ms) do
    case BoundedCommand.run(bin, args, timeout_ms, stderr_to_stdout: true) do
      {:error, {:timeout, _output}} -> {:error, :timeout}
      result -> result
    end
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
