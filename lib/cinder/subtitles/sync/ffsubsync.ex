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

  # Minimum alignment score to trust, enforced by the engine (`--min-score`) and re-checked here.
  @min_score 10

  # Every run goes through `priv/ffsubsync_runner.py`: it is what carries the formats the
  # extension-less descriptor paths cannot, and what reports the metrics under a per-run token.
  @impl true
  def sync(reference, input, output),
    do: sync(reference, input, output, Path.extname(reference), Path.extname(input))

  def sync(reference, input, output, reference_extension, input_extension) do
    token = metrics_token()

    args =
      [
        runner(),
        "--cinder-input-format",
        format(input_extension),
        "--cinder-reference-format",
        format(reference_extension),
        "--cinder-output-format",
        format(input_extension),
        "--cinder-metrics-token",
        token,
        reference
        | arguments(input, output)
      ]

    run(runner_python(), args, output, token)
  end

  defp run(executable, args, output, token) do
    command = ["--kill-after=5s", Integer.to_string(timeout_seconds()), executable | args]

    case System.cmd(timeout_bin(), command, stderr_to_stdout: true) do
      {log, 0} -> result(log, output, token)
      {_log, 124} -> {:review, %{reason: :timeout}}
      {log, code} -> {:error, {:ffsubsync_exit, code, String.trim(log)}}
    end
  rescue
    error -> {:error, error}
  end

  defp arguments(input, output) do
    [
      "-i",
      input,
      "-o",
      output,
      "--skip-sync-on-low-quality",
      "--min-score",
      Integer.to_string(@min_score),
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

  # The engine's metrics come from the runner as one line prefixed with this run's random token,
  # never scraped out of the human-readable log: that stream also carries subtitle bytes verbatim
  # (the `srt` parser logs an unparseable block, and a traceback can embed one), so a downloaded
  # sidecar could otherwise forge its own alignment result — including a segment the engine never
  # applied — and be recorded as aligned without having been corrected. Nothing in a subtitle file
  # can carry a token generated after it was written.
  defp result(log, output, token) do
    case reported(log, token) do
      {:ok, reported} -> verdict(reported, output)
      :error -> {:review, %{reason: :unparseable_output}}
    end
  end

  defp reported(log, token) do
    with [payload] <-
           Regex.run(~r/^#{Regex.escape(token)} (.+)$/m, log, capture: :all_but_first),
         {:ok, %{} = reported} <- Jason.decode(payload),
         {:ok, metrics} <- metrics(reported) do
      {:ok, %{metrics: metrics, trustworthy?: trustworthy?(reported)}}
    else
      _ -> :error
    end
  end

  defp verdict(%{trustworthy?: false, metrics: metrics}, _output),
    do: {:review, Map.put(metrics, :reason, :low_confidence)}

  defp verdict(%{metrics: metrics}, output) do
    cond do
      metrics.score < @min_score -> {:review, Map.put(metrics, :reason, :low_confidence)}
      not regular_file?(output) -> {:review, Map.put(metrics, :reason, :missing_output)}
      true -> {:ok, metrics}
    end
  end

  defp metrics(
         %{
           "score" => score,
           "offset_seconds" => offset_seconds,
           "framerate_scale_factor" => rate
         } = reported
       )
       when is_number(score) and is_number(offset_seconds) and is_number(rate) and rate > 0 do
    metrics = %{score: score * 1.0, offset_ms: round(offset_seconds * 1_000), rate: rate * 1.0}

    {:ok, Map.merge(metrics, segment_metrics(reported["segment_offsets_seconds"]))}
  end

  defp metrics(_reported), do: :error

  # A piecewise run applied one shift per segment of the timeline, and `offset_ms` is their
  # median — on its own it reports a 40s tail correction as a fraction of that. The caller needs
  # the largest shift actually applied to judge the correction significant.
  defp segment_metrics([_ | _] = offsets) do
    if Enum.all?(offsets, &is_number/1),
      do: %{segments: length(offsets), max_offset_ms: max_offset_ms(offsets)},
      else: %{}
  end

  defp segment_metrics(_offsets), do: %{}

  defp max_offset_ms(offsets),
    do: offsets |> Enum.map(&(&1 |> Kernel.*(1_000) |> round() |> abs())) |> Enum.max()

  # An alignment the engine itself refused (low quality) or could not finish reports metrics for
  # the record, but they never justify a rewrite.
  defp trustworthy?(%{"low_quality_reasons" => [_ | _]}), do: false
  defp trustworthy?(%{"sync_was_successful" => true}), do: true
  defp trustworthy?(_reported), do: false

  defp metrics_token,
    do: "cinder-metrics-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

  defp regular_file?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size > 0 -> true
      _ -> false
    end
  end

  defp format(extension),
    do: extension |> String.downcase() |> String.trim_leading(".")

  defp runner,
    do: Path.join(:code.priv_dir(:cinder), "ffsubsync_runner.py")

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
