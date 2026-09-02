defmodule Cinder.Library.AudioProbe.Ffprobe do
  @moduledoc """
  `Cinder.Library.AudioProbe` via the `ffprobe` CLI (FFmpeg).

  Reuses `Cinder.Library.MediaInfo.Ffprobe`'s two established techniques rather than inventing a
  third ad hoc timeout/projection discipline:

  - **Time bound**: `Task.async/yield/shutdown(:brutal_kill)`, exactly `MediaInfo.Ffprobe.health/0`'s
    own pattern, generalized from the `-version` no-file call to a real per-file probe
    (`@probe_timeout` 10s — generous for even a large M4B's moov-atom-only read: `ffprobe` never
    decodes audio for `-show_entries`, only parses container metadata).
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

  @impl true
  def probe(path) do
    task = Task.async(fn -> run_probe(path) end)

    case Task.yield(task, @probe_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:ffprobe_exit, reason}}
      nil -> {:error, :timeout}
    end
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

  defp run_probe(path) do
    case System.cmd(bin(), args(path), stderr_to_stdout: true) do
      {out, 0} -> parse(out)
      {out, code} -> {:error, {:ffprobe_exit, code, String.trim(out)}}
    end
  rescue
    e -> {:error, e}
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
