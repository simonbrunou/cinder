defmodule Cinder.Subtitles.Sync.TimingRules do
  @moduledoc """
  The timing rules of the Netflix Timed Text Style Guide that hold without watching the video,
  applied to a subtitle's out-times: `specs/069-subtitle-timing-rules`.

  - **Gaps** between consecutive lines are either 2 frames or at least half a second. A shorter
    gap is closed to 2 frames by extending the earlier line ("chaining"). A gap under 2 frames, or
    an overlap, is opened to 2 frames by pulling the earlier out-time in.
  - **Minimum duration**: a line lasts at least 20 frames, growing into the gap after it as far as
    2 frames before the next line.

  In-times never move: they are where the alignment put the dialogue. A rule that would leave a
  line shorter than 20 frames is not applied to that line. "Half a second" is a whole number of
  frames (12 at 24 fps, 15 at 30 fps), and the minimum gap is 2 frames at every frame rate.

  Only `.srt` and `.vtt` are rewritten. Styled formats (`.ass`, `.ssa`) overlap events on purpose
  (signs, karaoke, two speakers at once), and `.sub` is frame-based already.
  """

  alias Cinder.Subtitles.Sync.Timing

  @default_frame_rate 24_000 / 1001
  @formats ~w(.srt .vtt)

  @doc """
  Applies the rules to a subtitle file. `:frame_rate` is the video's frames per second; when it is
  unknown the rules assume 24000/1001. A file the rules leave alone is returned byte for byte.
  """
  @spec rewrite(binary(), String.t(), keyword()) :: {:ok, binary()} | {:error, atom()}
  def rewrite(source, extension, opts \\ []) when is_binary(source) and is_binary(extension) do
    with true <- String.downcase(extension) in @formats,
         {:ok, cues} <- Timing.cue_times(source, extension),
         retimed when retimed != cues <- times(cues, frame_rate(opts)) do
      Timing.put_cue_times(source, extension, retimed)
    else
      {:error, _reason} = error -> error
      _unchanged -> {:ok, source}
    end
  end

  @doc """
  The rules over `{in_ms, out_ms}` cues, returned in the order given. Lines are related to each
  other in in-time order, whatever order the file lists them in.
  """
  @spec times([{non_neg_integer(), non_neg_integer()}], number()) ::
          [{non_neg_integer(), non_neg_integer()}]
  def times(cues, frame_rate) when is_list(cues) and is_number(frame_rate) and frame_rate > 0 do
    frame = 1000 / frame_rate

    rules = %{
      two_frames: round(2 * frame),
      half_second: round(round(frame_rate / 2) * frame),
      min_duration: round(20 * frame)
    }

    order =
      cues
      |> Enum.with_index()
      |> Enum.sort_by(fn {{start_ms, _finish_ms}, index} -> {start_ms, index} end)

    nexts = Enum.drop(order, 1) |> Enum.map(fn {{start_ms, _}, _} -> start_ms end)

    order
    |> Enum.zip(nexts ++ [nil])
    |> Enum.map(fn {{{start_ms, finish_ms}, index}, next_start} ->
      {index, {start_ms, out_time(start_ms, finish_ms, next_start, rules)}}
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp out_time(start_ms, finish_ms, nil, rules),
    do: max(finish_ms, start_ms + rules.min_duration)

  defp out_time(start_ms, finish_ms, next_start, rules) do
    limit = next_start - rules.two_frames

    chained =
      cond do
        next_start - finish_ms >= rules.half_second -> finish_ms
        limit >= finish_ms -> limit
        limit - start_ms >= rules.min_duration -> limit
        true -> finish_ms
      end

    if chained - start_ms < rules.min_duration,
      do: max(chained, min(start_ms + rules.min_duration, limit)),
      else: chained
  end

  defp frame_rate(opts) do
    case Keyword.get(opts, :frame_rate) do
      fps when is_number(fps) and fps >= 1 and fps <= 300 -> fps
      _ -> @default_frame_rate
    end
  end
end
