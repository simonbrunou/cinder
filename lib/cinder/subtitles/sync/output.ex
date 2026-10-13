defmodule Cinder.Subtitles.Sync.Output do
  @moduledoc """
  The bytes an automatic analysis publishes: the engine's alignment, unless it is too small for
  anyone to perceive, with the timing rules (`Cinder.Subtitles.Sync.TimingRules`) applied on top.
  """

  alias Cinder.Subtitles.ShotChanges
  alias Cinder.Subtitles.Sync.TimingRules

  @rewritten ~w(.srt .vtt)

  @doc """
  What to write over `source`. Equal to `source` when neither the alignment nor the timing rules
  change anything, which records the sidecar as aligned without touching it. `opts` are the
  `TimingRules.rewrite/3` options (`:frame_rate`, `:shot_changes`).

  The rules read stricter SRT/VTT than the engine does: a sidecar downloaded before Cinder
  validated downloads can hold an empty cue or a `.` before the milliseconds. When the base is
  such a file (a small alignment keeps the source as is), it is published without the rules
  rather than failing the analysis.
  """
  @spec automatic(binary(), binary(), map(), String.t(), keyword()) ::
          {:ok, binary()} | {:error, atom()}
  def automatic(source, engine_output, metrics, extension, opts) do
    base = if insignificant?(metrics), do: source, else: engine_output

    case TimingRules.rewrite(base, extension, opts) do
      {:ok, _ruled} = ok -> ok
      {:error, :invalid_subtitle} -> {:ok, base}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  The video's shot changes for timing its sidecars, or nil when unknown. Detection (minutes of
  CPU) runs only for `shot_changes: :detect` and only when a sidecar is in a format the rules
  rewrite; otherwise only the cache is read.
  """
  @spec shot_changes(String.t(), String.t(), [map()], keyword()) :: [non_neg_integer()] | nil
  def shot_changes(video_path, moviehash, items, opts) do
    detect =
      Keyword.get(opts, :shot_changes) == :detect and
        Enum.any?(items, &(String.downcase(Path.extname(&1.sidecar_path)) in @rewritten))

    ShotChanges.for_video(video_path, moviehash, detect)
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
