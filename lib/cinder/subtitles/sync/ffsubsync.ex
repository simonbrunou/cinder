defmodule Cinder.Subtitles.Sync.Ffsubsync do
  @moduledoc false
  @behaviour Cinder.Subtitles.Sync.Engine

  @default_timeout_seconds 900

  # Piecewise ("alass-style") alignment: the cost, in seconds of speech overlap, of letting the
  # applied shift change at one point in the timeline. A single global shift cannot follow a
  # sidecar whose divergence is structural rather than constant — ad breaks cut out of the video,
  # a theatrical/extended cut mismatch, a recap trimmed off the front, discs concatenated into
  # one file — and those leave the tail of the file tens of seconds out even though the opening
  # scene looks perfect. 5s is the engine's own default: high enough that a correctly timed
  # sidecar still aligns as a single segment, low enough to admit a genuine structural break.
  @split_penalty "5"

  # Reject a framerate correction only outside the range real releases produce. The widest
  # legitimate ratio is 30/23.976 (1.2513) and its reciprocal (0.7992) — NTSC-timed subtitles on
  # a film-rate release; the 23.976/24/25 family all sits inside 5%. A tighter cap threw away
  # the correct alignment for the NTSC case and left the sidecar minutes out by the end. The
  # overfitting this used to guard against (a structural cut "fixed" by stretching time, #348)
  # is now handled by @split_penalty, and the engine still scores every candidate scale against
  # the piecewise fit, so an inferred-but-wrong ratio loses to "no stretch plus one split".
  @max_framerate_deviation "0.26"

  # One log line per segment of the applied offset function: "  30 cue(s) offset -40.500s".
  @segment_offset ~r/\d+\s+cue\(s\)\s+offset\s+(-?\d+(?:\.\d+)?)s/i

  @impl true
  def sync(reference, input, output) do
    run(
      ffsubsync_bin(),
      arguments(reference, input, output),
      output
    )
  end

  def sync(reference, input, output, reference_extension, input_extension) do
    args =
      [
        runner(),
        "--cinder-input-format",
        format(input_extension),
        "--cinder-reference-format",
        format(reference_extension),
        "--cinder-output-format",
        format(input_extension),
        reference
        | arguments(input, output)
      ]

    run(runner_python(), args, output)
  end

  defp run(executable, args, output) do
    command = ["--kill-after=5s", Integer.to_string(timeout_seconds()), executable | args]

    case System.cmd(timeout_bin(), command, stderr_to_stdout: true, env: log_env()) do
      {log, 0} -> result(log, output)
      {_log, 124} -> {:review, %{reason: :timeout}}
      {log, code} -> {:error, {:ffsubsync_exit, code, String.trim(log)}}
    end
  rescue
    error -> {:error, error}
  end

  defp arguments(reference, input, output), do: [reference | arguments(input, output)]

  defp arguments(input, output) do
    [
      "-i",
      input,
      "-o",
      output,
      "--skip-sync-on-low-quality",
      "--min-score",
      "10",
      "--quality-max-offset-seconds",
      "90",
      "--max-offset-seconds",
      "90",
      "--split-penalty",
      @split_penalty,
      "--max-framerate-deviation",
      @max_framerate_deviation,
      "--output-encoding",
      "same"
    ]
  end

  defp result(log, output) do
    with {:ok, score} <- metric(log, ~r/score:\s*(-?\d+(?:\.\d+)?)/i),
         {:ok, offset_seconds} <-
           metric(log, ~r/offset seconds:\s*(-?\d+(?:\.\d+)?)/i),
         {:ok, rate} <-
           metric(log, ~r/framerate scale factor:\s*(\d+(?:\.\d+)?)/i),
         true <- rate > 0 do
      metrics =
        %{
          score: score,
          offset_ms: round(offset_seconds * 1_000),
          rate: applied_rate(log, rate)
        }
        |> Map.merge(segment_metrics(log))

      cond do
        score < 10 or String.contains?(String.downcase(log), "low-quality") ->
          {:review, Map.put(metrics, :reason, :low_confidence)}

        not regular_file?(output) ->
          {:review, Map.put(metrics, :reason, :missing_output)}

        true ->
          {:ok, metrics}
      end
    else
      _ -> {:review, %{reason: :unparseable_output}}
    end
  end

  defp metric(log, regex) do
    case Regex.run(regex, log, capture: :all_but_first) do
      [value] -> {:ok, to_float(value)}
      _ -> :error
    end
  end

  # A piecewise run logs one line per segment of the offset function it applied. The header
  # metrics above describe the single-offset search that ran first, so they can read as a
  # sub-100ms no-op while the tail of the file actually moved by tens of seconds; the caller
  # needs the largest shift that was really applied to judge the correction significant.
  defp segment_metrics(log) do
    case Regex.scan(@segment_offset, log, capture: :all_but_first) do
      [] -> %{}
      offsets -> %{segments: length(offsets), max_offset_ms: max_offset_ms(offsets)}
    end
  end

  defp max_offset_ms(offsets) do
    offsets
    |> Enum.map(fn [seconds] -> seconds |> to_float() |> Kernel.*(1_000) |> round() |> abs() end)
    |> Enum.max()
  end

  # The piecewise search re-scores every candidate framerate scale and may prefer one the
  # single-offset search did not, which it logs separately. That is the scale actually applied.
  defp applied_rate(log, rate) do
    case metric(log, ~r/split search preferred framerate scale\s*(\d+(?:\.\d+)?)/i) do
      {:ok, preferred} when preferred > 0 -> preferred
      _ -> rate
    end
  end

  # The engine logs through `rich`, which wraps to 80 columns when stdout is not a terminal —
  # mid-line breaks in the very lines these metrics are read from.
  defp log_env, do: [{"COLUMNS", "200"}]

  defp regular_file?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size > 0 -> true
      _ -> false
    end
  end

  defp to_float(value) do
    normalized = if String.contains?(value, "."), do: value, else: value <> ".0"
    String.to_float(normalized)
  end

  defp format(extension),
    do: extension |> String.downcase() |> String.trim_leading(".")

  defp runner,
    do: Path.join(:code.priv_dir(:cinder), "ffsubsync_runner.py")

  defp ffsubsync_bin, do: Application.get_env(:cinder, :ffsubsync_bin, "ffsubsync")

  defp runner_python do
    Application.get_env(:cinder, :ffsubsync_python) || default_runner_python()
  end

  defp default_runner_python do
    if File.regular?("/opt/ffsubsync/bin/python3"),
      do: "/opt/ffsubsync/bin/python3",
      else: System.find_executable("python3") || "python3"
  end

  defp timeout_bin, do: Application.get_env(:cinder, :timeout_bin, "timeout")

  defp timeout_seconds do
    Application.get_env(:cinder, __MODULE__, [])
    |> Keyword.get(:timeout_seconds, @default_timeout_seconds)
  end
end
