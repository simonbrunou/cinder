defmodule Cinder.Subtitles.Sync.Timing do
  @moduledoc false

  @srt ~r/(?<h>\d{2}):(?<m>\d{2}):(?<s>\d{2}),(?<f>\d{3})/
  @vtt ~r/(?:(?<h>\d{2}):)?(?<m>\d{2}):(?<s>\d{2})\.(?<f>\d{3})/
  @ass ~r/(?<h>\d+):(?<m>\d{2}):(?<s>\d{2})\.(?<f>\d{2})/
  @sub ~r/(?<h>\d{2}):(?<m>\d{2}):(?<s>\d{2})\.(?<f>\d{2})/

  @spec retime(binary(), String.t(), integer(), number()) :: {:ok, binary()} | {:error, atom()}
  def retime(source, extension, offset_ms, rate)
      when is_binary(source) and is_integer(offset_ms) and is_number(rate) and rate > 0 do
    extension = String.downcase(extension)

    if extension in [".srt", ".vtt", ".ass", ".ssa", ".sub"] do
      if valid_structure?(source, extension),
        do: retime_valid(source, extension, offset_ms, rate),
        else: {:error, :invalid_subtitle}
    else
      {:error, :unsupported_format}
    end
  end

  def retime(_source, _extension, _offset_ms, _rate), do: {:error, :invalid_adjustment}

  defp retime_valid(source, extension, offset_ms, rate) do
    case extension do
      ".srt" ->
        {:ok, retime_arrow_cues(source, @srt, 3, offset_ms, rate, :srt)}

      ".vtt" ->
        {:ok, retime_arrow_cues(source, @vtt, 3, offset_ms, rate, :vtt)}

      extension when extension in [".ass", ".ssa"] ->
        {:ok, retime_ass(source, offset_ms, rate)}

      ".sub" ->
        {:ok, retime_sub(source, offset_ms, rate)}
    end
  end

  @spec from_anchors([{integer(), integer()}]) ::
          {:ok, {integer(), float()}} | {:error, :invalid_anchors}
  def from_anchors([{sidecar, video}]) when is_integer(sidecar) and is_integer(video),
    do: {:ok, {video - sidecar, 1.0}}

  def from_anchors([{sidecar_a, video_a}, {sidecar_b, video_b}])
      when is_integer(sidecar_a) and is_integer(video_a) and is_integer(sidecar_b) and
             is_integer(video_b) and sidecar_a != sidecar_b do
    rate = (video_b - video_a) / (sidecar_b - sidecar_a)

    if rate > 0,
      do: {:ok, {round(video_a - sidecar_a * rate), rate}},
      else: {:error, :invalid_anchors}
  end

  def from_anchors(_anchors), do: {:error, :invalid_anchors}

  defp valid_structure?(source, ".srt"), do: arrow_cue?(source, @srt)
  defp valid_structure?(source, ".vtt"), do: arrow_cue?(source, @vtt)

  defp valid_structure?(source, extension) when extension in [".ass", ".ssa"] do
    Enum.any?(lines(source), fn line ->
      String.starts_with?(line, "Dialogue:") and two_timestamps?(line, @ass)
    end)
  end

  defp valid_structure?(source, ".sub") do
    timestamped? =
      Enum.any?(lines(source), fn line ->
        String.starts_with?(line, "[") and two_timestamps?(line, @sub)
      end)

    microdvd? =
      Enum.any?(lines(source), fn line ->
        case Regex.run(~r/^\{(\d+)\}\{(\d+)\}(.*)$/, line, capture: :all_but_first) do
          ["1", "1", text] -> not Regex.match?(~r/^\d+(?:\.\d+)?$/, text)
          [_start, _finish, _text] -> true
          _ -> false
        end
      end)

    timestamped? or microdvd?
  end

  defp arrow_cue?(source, regex) do
    Enum.any?(lines(source), fn line ->
      String.contains?(line, "-->") and two_timestamps?(line, regex)
    end)
  end

  defp two_timestamps?(line, regex), do: length(Regex.scan(regex, line)) >= 2
  defp lines(source), do: String.split(source, ~r/\r\n|\n|\r/)

  defp retime_arrow_cues(source, regex, precision, offset_ms, rate, style) do
    map_lines(source, fn line ->
      if String.contains?(line, "-->"),
        do: retime_pair(line, regex, precision, offset_ms, rate, style),
        else: line
    end)
  end

  defp retime_ass(source, offset_ms, rate) do
    map_lines(source, fn
      "Dialogue:" <> _rest = row -> retime_pair(row, @ass, 2, offset_ms, rate, :ass)
      row -> row
    end)
  end

  defp retime_sub(source, offset_ms, rate) do
    case Regex.run(~r/^\{1\}\{1\}(?<fps>\d+(?:\.\d+)?)$/m, source, capture: :all_names) do
      [fps] -> retime_microdvd(source, String.to_float(normalize_float(fps)), offset_ms, rate)
      nil -> retime_timestamped_sub(source, offset_ms, rate)
    end
  end

  defp retime_timestamped_sub(source, offset_ms, rate) do
    map_lines(source, fn line ->
      if String.starts_with?(line, "["),
        do: retime_pair(line, @sub, 2, offset_ms, rate, :sub),
        else: line
    end)
  end

  defp retime_microdvd(source, fps, offset_ms, rate) do
    Regex.replace(~r/^\{(?<start>\d+)\}\{(?<finish>\d+)\}(?<text>.*)$/m, source, fn
      whole, "1", "1", text ->
        if Regex.match?(~r/^\d+(?:\.\d+)?$/, text),
          do: whole,
          else: microdvd_line(1, 1, text, fps, offset_ms, rate)

      _whole, start, finish, text ->
        microdvd_line(
          String.to_integer(start),
          String.to_integer(finish),
          text,
          fps,
          offset_ms,
          rate
        )
    end)
  end

  defp microdvd_line(start, finish, text, fps, offset_ms, rate) do
    start = adjust_frame(start, fps, offset_ms, rate)
    finish = max(adjust_frame(finish, fps, offset_ms, rate), start + 1)
    "{#{start}}{#{finish}}#{text}"
  end

  defp adjust_frame(frame, fps, offset_ms, rate) do
    frame
    |> Kernel./(fps)
    |> Kernel.*(1_000)
    |> adjust(offset_ms, rate)
    |> Kernel.*(fps)
    |> Kernel./(1_000)
    |> round()
    |> max(0)
  end

  # Subtitle dialogue may legitimately contain timestamp-shaped text. Restrict rewriting to the
  # first start/end pair on a structural cue row, and replace from right to left so byte offsets stay
  # valid. Clamping a negative shift still leaves a positive-duration cue.
  defp retime_pair(line, regex, precision, offset_ms, rate, style) do
    matches =
      regex
      |> Regex.scan(line, return: :index)
      |> Enum.take(2)
      |> Enum.map(fn [{start, length} | _captures] ->
        whole = binary_part(line, start, length)
        {start, length, Regex.named_captures(regex, whole)}
      end)

    case matches do
      [{_, _, start_captures}, {_, _, finish_captures}] ->
        start_ms = start_captures |> to_milliseconds(precision) |> adjust(offset_ms, rate)
        finish_ms = finish_captures |> to_milliseconds(precision) |> adjust(offset_ms, rate)
        tick_ms = if precision == 2, do: 10, else: 1
        finish_ms = max(finish_ms, start_ms + tick_ms)

        replacements = [
          render(start_ms, precision, style, start_captures["h"]),
          render(finish_ms, precision, style, finish_captures["h"])
        ]

        matches
        |> Enum.zip(replacements)
        |> Enum.reverse()
        |> Enum.reduce(line, fn {{start, length, _captures}, replacement}, acc ->
          prefix = binary_part(acc, 0, start)
          suffix_start = start + length
          suffix = binary_part(acc, suffix_start, byte_size(acc) - suffix_start)
          prefix <> replacement <> suffix
        end)

      _ ->
        line
    end
  end

  defp map_lines(source, fun) do
    source
    |> String.split(~r/(\r\n|\n|\r)/, include_captures: true, trim: false)
    |> Enum.map_join(fn
      newline when newline in ["\r\n", "\n", "\r"] -> newline
      line -> fun.(line)
    end)
  end

  defp to_milliseconds(captures, precision) do
    hours = integer(captures["h"])
    minutes = integer(captures["m"])
    seconds = integer(captures["s"])
    fraction = integer(captures["f"]) * if(precision == 2, do: 10, else: 1)
    ((hours * 60 + minutes) * 60 + seconds) * 1_000 + fraction
  end

  defp adjust(milliseconds, offset_ms, rate),
    do: milliseconds |> Kernel.*(rate) |> Kernel.+(offset_ms) |> round() |> max(0)

  defp render(milliseconds, precision, style, original_hours) do
    hours = div(milliseconds, 3_600_000)
    minutes = div(rem(milliseconds, 3_600_000), 60_000)
    seconds = div(rem(milliseconds, 60_000), 1_000)
    fraction = div(rem(milliseconds, 1_000), if(precision == 2, do: 10, else: 1))
    separator = if style == :srt, do: ",", else: "."
    hours? = style in [:srt, :ass, :sub] or original_hours not in [nil, ""]

    if hours? do
      hour_width = if style == :ass, do: 1, else: 2

      "#{pad(hours, hour_width)}:#{pad(minutes, 2)}:#{pad(seconds, 2)}#{separator}#{pad(fraction, precision)}"
    else
      "#{pad(minutes, 2)}:#{pad(seconds, 2)}#{separator}#{pad(fraction, precision)}"
    end
  end

  defp integer(value) when value in [nil, ""], do: 0
  defp integer(value), do: String.to_integer(value)
  defp pad(value, width), do: value |> Integer.to_string() |> String.pad_leading(width, "0")

  defp normalize_float(value),
    do: if(String.contains?(value, "."), do: value, else: value <> ".0")
end
