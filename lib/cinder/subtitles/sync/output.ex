defmodule Cinder.Subtitles.Sync.Output do
  @moduledoc """
  The bytes an automatic analysis publishes: the engine's alignment, unless it is too small for
  anyone to perceive, with the timing rules (`Cinder.Subtitles.Sync.TimingRules`) applied on top.
  """

  alias Cinder.Subtitles.Sync.TimingRules

  @doc """
  What to write over `source`. Equal to `source` when neither the alignment nor the timing rules
  change anything, which records the sidecar as aligned without touching it.

  The rules read stricter SRT/VTT than the engine does: a sidecar downloaded before Cinder
  validated downloads can hold an empty cue or a `.` before the milliseconds. When the base is
  such a file (a small alignment keeps the source as is), it is published without the rules
  rather than failing the analysis.
  """
  @spec automatic(binary(), binary(), map(), String.t(), number() | nil) ::
          {:ok, binary()} | {:error, atom()}
  def automatic(source, engine_output, metrics, extension, frame_rate) do
    base = if insignificant?(metrics), do: source, else: engine_output

    case TimingRules.rewrite(base, extension, frame_rate: frame_rate) do
      {:ok, _ruled} = ok -> ok
      {:error, :invalid_subtitle} -> {:ok, base}
      {:error, _reason} = error -> error
    end
  end

  @doc "The video's frame rate, or nil when there is no media inspector or it cannot tell."
  @spec frame_rate(module() | nil, String.t()) :: float() | nil
  def frame_rate(nil, _video_path), do: nil

  def frame_rate(media_info, video_path) do
    case media_info.frame_rate(video_path) do
      {:ok, fps} when is_number(fps) -> fps
      _unknown -> nil
    end
  end

  # Skips a shift nobody can perceive, so the timing rules apply to the downloaded timing as is.
  # A piecewise alignment reports the largest shift it actually applied: its `offset_ms` is only
  # the global search that preceded the splits and can read as ~0 while the tail of the file moves
  # by tens of seconds, so trusting it here would discard exactly the corrections that matter most.
  defp insignificant?(metrics) do
    offset_ms = Map.get(metrics, :max_offset_ms) || Map.get(metrics, :offset_ms, 0)

    abs(offset_ms) <= 100 and abs(Map.get(metrics, :rate, 1.0) - 1.0) <= 0.0005
  end
end
