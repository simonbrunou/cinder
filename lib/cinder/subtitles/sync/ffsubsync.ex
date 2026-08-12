defmodule Cinder.Subtitles.Sync.Ffsubsync do
  @moduledoc false
  @behaviour Cinder.Subtitles.Sync.Engine

  @default_timeout_seconds 900

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
        reference
        | arguments(input, output)
      ]

    run(runner_python(), args, output)
  end

  defp run(executable, args, output) do
    command = ["--kill-after=5s", Integer.to_string(timeout_seconds()), executable | args]

    case System.cmd(timeout_bin(), command, stderr_to_stdout: true) do
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
      "35",
      "--max-offset-seconds",
      "35",
      "--max-framerate-deviation",
      "0.05",
      "--gss",
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
      metrics = %{score: score, offset_ms: round(offset_seconds * 1_000), rate: rate}

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
      [value] -> {:ok, String.to_float(normalize_float(value))}
      _ -> :error
    end
  end

  defp regular_file?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size > 0 -> true
      _ -> false
    end
  end

  defp normalize_float(value),
    do: if(String.contains?(value, "."), do: value, else: value <> ".0")

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
