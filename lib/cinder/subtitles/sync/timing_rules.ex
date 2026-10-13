defmodule Cinder.Subtitles.Sync.TimingRules do
  @moduledoc """
  The timing rules of the Netflix Timed Text Style Guide that a computer can apply:
  `specs/069-subtitle-timing-rules`.

  With the video's shot changes (cuts), when they are known:
  - **In-time just after a cut**: a line starting within half a second after a cut starts on it.
  - **In-time just before a cut**, for a line that runs across it: a line starting at least
    three quarters of half a second before the cut starts half a second before it; one starting
    closer starts on the cut.
  - **Out-time just before a cut**: a line ending within half a second before a cut, with no
    line starting before that cut, ends 2 frames before it.
  - **Out-time just after a cut**: a line ending less than half a second into the next shot ends
    2 frames before the cut when it keeps 20 frames and a reading speed of 17 characters per
    second, and half a second after the cut otherwise.

  Always:
  - **Gaps** between consecutive lines are either 2 frames or at least half a second. A shorter
    gap is closed to 2 frames by extending the earlier line ("chaining"). A gap under 2 frames, or
    an overlap, is opened to 2 frames by pulling the earlier out-time in.
  - **Minimum duration**: a line lasts at least 20 frames, growing into the gap after it as far as
    2 frames before the next line.

  A rule that would leave a line, or the line before it, shorter than 20 frames is not applied.
  Without cuts, in-times never move. "Half a second" is a whole number of frames (12 at 24 fps,
  15 at 30 fps), and the minimum gap is 2 frames at every frame rate.

  Only `.srt` and `.vtt` are rewritten. Styled formats (`.ass`, `.ssa`) overlap events on purpose
  (signs, karaoke, two speakers at once), and `.sub` is frame-based already.
  """

  alias Cinder.Subtitles.Sync.Timing

  @default_frame_rate 24_000 / 1001
  @formats ~w(.srt .vtt)
  @max_characters_per_second 17

  @doc """
  Applies the rules to a subtitle file. `:frame_rate` is the video's frames per second (24000/1001
  when unknown); `:shot_changes` its cuts in ms, ascending (nil when unknown). A file the rules
  leave alone is returned byte for byte.
  """
  @spec rewrite(binary(), String.t(), keyword()) :: {:ok, binary()} | {:error, atom()}
  def rewrite(source, extension, opts \\ []) when is_binary(source) and is_binary(extension) do
    with true <- String.downcase(extension) in @formats,
         {:ok, cues} <- Timing.cue_times(source, extension),
         {:ok, texts} <- texts(source, extension, opts),
         retimed when retimed != cues <-
           times(cues, frame_rate(opts), shot_changes: opts[:shot_changes], texts: texts) do
      Timing.put_cue_times(source, extension, retimed)
    else
      {:error, _reason} = error -> error
      _unchanged -> {:ok, source}
    end
  end

  defp texts(source, extension, opts) do
    if opts[:shot_changes], do: Timing.cue_texts(source, extension), else: {:ok, nil}
  end

  @doc """
  The rules over `{in_ms, out_ms}` cues, returned in the order given. Lines are related to each
  other in in-time order, whatever order the file lists them in. Options: `:shot_changes` (cuts in
  ms, ascending) and `:texts` (each cue's text, for its reading speed).
  """
  @spec times([{non_neg_integer(), non_neg_integer()}], number(), keyword()) ::
          [{non_neg_integer(), non_neg_integer()}]
  def times(cues, frame_rate, opts \\ [])
      when is_list(cues) and is_number(frame_rate) and frame_rate > 0 do
    rules = rules(frame_rate, opts[:shot_changes])
    texts = opts[:texts] || List.duplicate("", length(cues))

    cues
    |> Enum.zip(texts)
    |> Enum.with_index()
    |> Enum.sort_by(fn {{{start_ms, _finish_ms}, _text}, index} -> {start_ms, index} end)
    |> Enum.map(fn {{{start_ms, finish_ms}, text}, index} ->
      %{index: index, start: start_ms, finish: finish_ms, text: text}
    end)
    |> in_times(rules)
    |> out_times(rules)
    |> Enum.sort_by(& &1.index)
    |> Enum.map(&{&1.start, &1.finish})
  end

  defp rules(frame_rate, cuts) do
    frame = 1000 / frame_rate
    half_frames = round(frame_rate / 2)

    %{
      two_frames: round(2 * frame),
      half_second: round(half_frames * frame),
      bring_forward: round(Float.ceil(half_frames * 0.75) * frame),
      min_duration: round(20 * frame),
      cuts: List.to_tuple(cuts || [])
    }
  end

  # In-times move only to cuts, and only where the line before can still end 2 frames earlier
  # with 20 frames left, or the line itself keeps 20 frames before the next one.
  defp in_times(lines, %{cuts: {}}), do: lines

  defp in_times(lines, rules) do
    nexts = Enum.map(Enum.drop(lines, 1), & &1.start) ++ [nil]

    lines
    |> Enum.zip(nexts)
    |> Enum.map_reduce(nil, fn {line, next_start}, previous ->
      line = %{line | start: in_time(line, previous, next_start, rules)}
      {line, line}
    end)
    |> elem(0)
  end

  defp in_time(%{start: start, finish: finish}, previous, next_start, rules) do
    before = last_cut_at_or_before(rules.cuts, start)
    after_ = first_cut_after(rules.cuts, start)

    cond do
      before && start - before < rules.half_second && earlier_ok?(before, previous, rules) ->
        before

      after_ && after_ - start < rules.half_second && after_ < finish ->
        across_cut(start, after_, previous, next_start, rules)

      true ->
        start
    end
  end

  defp across_cut(start, cut, previous, next_start, rules) do
    forward = cut - rules.half_second

    cond do
      cut - start >= rules.bring_forward and earlier_ok?(forward, previous, rules) -> forward
      cut - start < rules.bring_forward and room_after?(cut, next_start, rules) -> cut
      true -> start
    end
  end

  defp earlier_ok?(time, nil, _rules), do: time >= 0

  defp earlier_ok?(time, previous, rules),
    do: time - rules.two_frames - previous.start >= rules.min_duration

  defp room_after?(_time, nil, _rules), do: true

  defp room_after?(time, next_start, rules),
    do: next_start - rules.two_frames - time >= rules.min_duration

  defp out_times(lines, rules) do
    nexts = Enum.map(Enum.drop(lines, 1), & &1.start) ++ [nil]

    lines
    |> Enum.zip(nexts)
    |> Enum.map(fn {line, next_start} ->
      finish = cut_out_time(line, next_start, rules)
      %{line | finish: line.start |> out_time(finish, next_start, rules) |> max(line.start + 1)}
    end)
  end

  defp cut_out_time(%{start: start, finish: finish} = line, next_start, rules) do
    crossed = last_cut_at_or_before(rules.cuts, finish)
    upcoming = first_cut_after(rules.cuts, finish)

    cond do
      crossed && crossed > start && finish - crossed < rules.half_second ->
        crossed_out_time(line, crossed, next_start, rules)

      upcoming && upcoming - finish <= rules.half_second && free_until?(next_start, upcoming) ->
        upcoming - rules.two_frames

      true ->
        finish
    end
  end

  # The fallback only ever extends: capping at the next line could otherwise land before this
  # line's own out-time (simultaneous or overlapping cues, a sound cue beside dialogue) and shrink
  # it to nothing. An overlap left here is the gap pass's to settle, under its 20-frame guard.
  defp crossed_out_time(%{start: start, finish: finish, text: text}, cut, next_start, rules) do
    pulled = cut - rules.two_frames

    if pulled - start >= rules.min_duration and readable?(text, pulled - start),
      do: pulled,
      else: max(finish, cap(cut + rules.half_second, next_start, rules))
  end

  defp free_until?(nil, _cut), do: true
  defp free_until?(next_start, cut), do: next_start >= cut

  defp cap(time, nil, _rules), do: time
  defp cap(time, next_start, rules), do: min(time, next_start - rules.two_frames)

  defp readable?(text, duration_ms) do
    characters =
      text
      |> String.replace(~r/<[^>]+>|\{[^}]*\}/, "")
      |> String.replace(~r/\s*\n\s*/, " ")
      |> String.trim()
      |> String.length()

    characters * 1000 <= @max_characters_per_second * duration_ms
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

  # Binary searches over the ascending cut tuple.
  defp last_cut_at_or_before(cuts, time),
    do: search(cuts, time, 0, tuple_size(cuts) - 1, nil, :le)

  defp first_cut_after(cuts, time), do: search(cuts, time, 0, tuple_size(cuts) - 1, nil, :gt)

  defp search(_cuts, _time, low, high, found, _mode) when low > high, do: found

  defp search(cuts, time, low, high, found, mode) do
    middle = div(low + high, 2)
    cut = elem(cuts, middle)

    case mode do
      :le when cut <= time -> search(cuts, time, middle + 1, high, cut, mode)
      :le -> search(cuts, time, low, middle - 1, found, mode)
      :gt when cut > time -> search(cuts, time, low, middle - 1, cut, mode)
      :gt -> search(cuts, time, middle + 1, high, found, mode)
    end
  end

  defp frame_rate(opts) do
    case Keyword.get(opts, :frame_rate) do
      fps when is_number(fps) and fps >= 1 and fps <= 300 -> fps
      _ -> @default_frame_rate
    end
  end
end
