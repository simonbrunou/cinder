defmodule Cinder.Subtitles.Sync.Timing do
  @moduledoc false

  alias Cinder.Subtitles.Sync.TimingGrammar

  @srt ~r/(?<h>\d{2}):(?<m>\d{2}):(?<s>\d{2}),(?<f>\d{3})/
  @vtt ~r/(?:(?<h>\d{2}):)?(?<m>\d{2}):(?<s>\d{2})\.(?<f>\d{3})/
  @srt_row ~r/^\s*\d{2}:\d{2}:\d{2},\d{3}\s*-->\s*\d{2}:\d{2}:\d{2},\d{3}(?:\s+.*)?$/
  @vtt_row ~r/^\s*(?:\d{2}:)?\d{2}:\d{2}\.\d{3}\s*-->\s*(?:\d{2}:)?\d{2}:\d{2}\.\d{3}(?:\s+.*)?$/
  @ass ~r/(?<h>\d+):(?<m>\d{2}):(?<s>\d{2})\.(?<f>\d{2})/
  @sub ~r/(?<h>\d{2}):(?<m>\d{2}):(?<s>\d{2})\.(?<f>\d{2})/
  @max_abs_offset_ms 86_400_000
  @max_timestamp_ms 604_800_000
  @min_rate 0.1
  @max_rate 10.0
  @max_fps 1_000.0
  @max_microdvd_frame 604_800_000

  @spec retime(binary(), String.t(), integer(), number()) :: {:ok, binary()} | {:error, atom()}
  def retime(source, extension, offset_ms, rate)
      when is_binary(source) and is_integer(offset_ms) and is_number(rate) do
    extension = String.downcase(extension)

    if valid_adjustment?(offset_ms, rate) do
      retime_supported(source, extension, offset_ms, rate)
    else
      {:error, :invalid_adjustment}
    end
  end

  def retime(_source, _extension, _offset_ms, _rate), do: {:error, :invalid_adjustment}

  @spec validate(binary(), String.t()) :: :ok | {:error, atom()}
  def validate(source, extension) when is_binary(source) and is_binary(extension) do
    extension = String.downcase(extension)

    cond do
      extension not in [".srt", ".vtt", ".ass", ".ssa", ".sub"] ->
        {:error, :unsupported_format}

      valid_structure?(source, extension) ->
        :ok

      true ->
        {:error, :invalid_subtitle}
    end
  rescue
    _ -> {:error, :invalid_subtitle}
  end

  def validate(_source, _extension), do: {:error, :invalid_subtitle}

  @spec valid_adjustment?(integer(), number()) :: boolean()
  def valid_adjustment?(offset_ms, rate) when is_integer(offset_ms) and is_number(rate) do
    abs(offset_ms) <= @max_abs_offset_ms and rate >= @min_rate and rate <= @max_rate
  end

  def valid_adjustment?(_offset_ms, _rate), do: false

  @spec valid_timestamp_ms?(integer()) :: boolean()
  def valid_timestamp_ms?(value),
    do: is_integer(value) and value >= 0 and value <= @max_timestamp_ms

  defp retime_supported(<<0xEF, 0xBB, 0xBF, source::binary>>, extension, offset_ms, rate) do
    case retime_supported(source, extension, offset_ms, rate) do
      {:ok, output} -> {:ok, <<0xEF, 0xBB, 0xBF, output::binary>>}
      {:error, _reason} = error -> error
    end
  end

  defp retime_supported(source, extension, offset_ms, rate) do
    if extension in [".srt", ".vtt", ".ass", ".ssa", ".sub"] do
      if valid_structure?(source, extension),
        do: safely_retime_valid(source, extension, offset_ms, rate),
        else: {:error, :invalid_subtitle}
    else
      {:error, :unsupported_format}
    end
  end

  defp safely_retime_valid(source, extension, offset_ms, rate) do
    retime_valid(source, extension, offset_ms, rate)
  rescue
    ArithmeticError -> {:error, :invalid_subtitle}
    ArgumentError -> {:error, :invalid_subtitle}
  end

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
  def from_anchors([{sidecar, video}]) when is_integer(sidecar) and is_integer(video) do
    offset = video - sidecar

    if valid_timestamp_ms?(sidecar) and valid_timestamp_ms?(video) and
         valid_adjustment?(offset, 1.0),
       do: {:ok, {offset, 1.0}},
       else: {:error, :invalid_anchors}
  end

  def from_anchors([{sidecar_a, video_a}, {sidecar_b, video_b}])
      when is_integer(sidecar_a) and is_integer(video_a) and is_integer(sidecar_b) and
             is_integer(video_b) and sidecar_a != sidecar_b do
    if Enum.all?([sidecar_a, video_a, sidecar_b, video_b], &valid_timestamp_ms?/1) do
      rate = (video_b - video_a) / (sidecar_b - sidecar_a)
      offset = round(video_a - sidecar_a * rate)

      if valid_adjustment?(offset, rate),
        do: {:ok, {offset, rate}},
        else: {:error, :invalid_anchors}
    else
      {:error, :invalid_anchors}
    end
  end

  def from_anchors(_anchors), do: {:error, :invalid_anchors}

  @doc """
  In-time and out-time (ms) of every cue of an `.srt` or `.vtt` file, in file order. The cue rows
  are the ones `retime/4` rewrites, so `put_cue_times/3` takes the same list back.
  """
  @spec cue_times(binary(), String.t()) ::
          {:ok, [{non_neg_integer(), non_neg_integer()}]} | {:error, atom()}
  def cue_times(source, extension) when is_binary(source) and is_binary(extension) do
    with {:ok, style, body} <- arrow_body(source, extension) do
      {:ok,
       body |> String.split(~r/(\r\n|\n|\r)/, trim: false) |> Enum.flat_map(&row_times(&1, style))}
    end
  end

  @doc """
  Text of every cue of an `.srt` or `.vtt` file (the lines after its timing row, up to a blank
  line or the next cue), in the order `cue_times/2` lists the cues.
  """
  @spec cue_texts(binary(), String.t()) :: {:ok, [String.t()]} | {:error, atom()}
  def cue_texts(source, extension) when is_binary(source) and is_binary(extension) do
    with {:ok, style, body} <- arrow_body(source, extension) do
      {texts, current} =
        body
        |> String.split(~r/\r\n|\n|\r/)
        |> Enum.reduce({[], nil}, &collect_text(&1, &2, style))

      {:ok, texts |> push_text(current) |> Enum.reverse()}
    end
  end

  defp collect_text(line, {texts, current}, style) do
    cond do
      row_times(line, style) != [] -> {push_text(texts, current), []}
      is_nil(current) -> {texts, nil}
      String.trim(line) == "" -> {push_text(texts, current), nil}
      true -> {texts, [line | current]}
    end
  end

  defp push_text(texts, nil), do: texts
  defp push_text(texts, lines), do: [lines |> Enum.reverse() |> Enum.join("\n") | texts]

  @doc """
  Rewrites every cue row of an `.srt` or `.vtt` file with the given `{in_ms, out_ms}` list, one
  entry per cue in file order (as `cue_times/2` returns them). Everything else is kept byte for
  byte, including a BOM and line endings.
  """
  @spec put_cue_times(binary(), String.t(), [{non_neg_integer(), non_neg_integer()}]) ::
          {:ok, binary()} | {:error, atom()}
  def put_cue_times(source, extension, times)
      when is_binary(source) and is_binary(extension) and is_list(times) do
    with {:ok, style, body} <- arrow_body(source, extension),
         true <- Enum.all?(times, &valid_cue_time?/1) || {:error, :invalid_adjustment},
         {parts, []} <-
           body
           |> String.split(~r/(\r\n|\n|\r)/, include_captures: true, trim: false)
           |> Enum.map_reduce(times, &put_row_times(&1, &2, style)),
         true <- length(times) == length(Enum.flat_map(parts, &row_times(&1, style))) do
      bom = binary_part(source, 0, byte_size(source) - byte_size(body))
      {:ok, bom <> IO.iodata_to_binary(parts)}
    else
      {:error, _reason} = error -> error
      _mismatch -> {:error, :cue_count_mismatch}
    end
  rescue
    ArgumentError -> {:error, :invalid_adjustment}
  end

  defp row_times(line, style) do
    {regex, precision} = arrow_regex(style)
    if cue_row?(line, style), do: List.wrap(pair_times(line, regex, precision)), else: []
  end

  defp put_row_times(line, [{start_ms, finish_ms} | rest] = times, style) do
    {regex, precision} = arrow_regex(style)

    if row_times(line, style) == [],
      do: {line, times},
      else:
        {rewrite_pair(line, regex, precision, style, fn _, _ -> {start_ms, finish_ms} end), rest}
  end

  defp put_row_times(line, [], _style), do: {line, []}

  # The structure check runs on the text after a BOM, the same as `retime/4` does.
  defp arrow_body(source, extension) do
    body =
      case source do
        <<0xEF, 0xBB, 0xBF, rest::binary>> -> rest
        _ -> source
      end

    extension = String.downcase(extension)

    style =
      case extension do
        ".srt" -> :srt
        ".vtt" -> :vtt
        _ -> nil
      end

    cond do
      is_nil(style) -> {:error, :unsupported_format}
      valid_structure?(body, extension) -> {:ok, style, body}
      true -> {:error, :invalid_subtitle}
    end
  end

  defp arrow_regex(:srt), do: {@srt, 3}
  defp arrow_regex(:vtt), do: {@vtt, 3}

  defp valid_cue_time?({start_ms, finish_ms}),
    do: valid_timestamp_ms?(start_ms) and valid_timestamp_ms?(finish_ms) and finish_ms > start_ms

  defp valid_cue_time?(_time), do: false

  defp valid_structure?(source, extension), do: TimingGrammar.valid?(source, extension)

  defp retime_arrow_cues(source, regex, precision, offset_ms, rate, style) do
    map_lines(source, fn line ->
      if cue_row?(line, style),
        do: retime_pair(line, regex, precision, offset_ms, rate, style),
        else: line
    end)
  end

  defp cue_row?(line, :srt), do: Regex.match?(@srt_row, line)
  defp cue_row?(line, :vtt), do: Regex.match?(@vtt_row, line)

  defp retime_ass(source, offset_ms, rate) do
    map_lines(source, fn
      "Dialogue:" <> _rest = row -> retime_pair(row, @ass, 2, offset_ms, rate, :ass)
      row -> row
    end)
  end

  defp retime_sub(source, offset_ms, rate) do
    case microdvd_fps(source) do
      {:ok, fps} -> retime_microdvd(source, fps, offset_ms, rate)
      :error -> retime_timestamped_sub(source, offset_ms, rate)
    end
  end

  defp microdvd_fps(source) do
    case Regex.run(~r/^\{1\}\{1\}(?<fps>\d+(?:\.\d+)?)\r?$/m, source, capture: :all_names) do
      [value] ->
        case Float.parse(normalize_float(value)) do
          {fps, ""} when fps > 0 and fps <= @max_fps -> {:ok, fps}
          _ -> :error
        end

      nil ->
        :error
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
    Regex.replace(~r/^\{(?<start>\d+)\}\{(?<finish>\d+)\}(?<text>.*?)(?<cr>\r?)$/m, source, fn
      whole, "1", "1", text, _cr ->
        if Regex.match?(~r/^\d+(?:\.\d+)?$/, text),
          do: whole,
          else: microdvd_line(1, 1, text, fps, offset_ms, rate)

      _whole, start, finish, text, cr ->
        microdvd_line(
          String.to_integer(start),
          String.to_integer(finish),
          text <> cr,
          fps,
          offset_ms,
          rate
        )
    end)
  end

  defp microdvd_line(start, finish, text, fps, offset_ms, rate) do
    start = adjust_frame(start, fps, offset_ms, rate)
    finish = max(adjust_frame(finish, fps, offset_ms, rate), start + 1)

    if finish > @max_microdvd_frame or finish / fps * 1_000 > @max_timestamp_ms,
      do: raise(ArgumentError, "retimed MicroDVD frame is out of bounds")

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
    rewrite_pair(line, regex, precision, style, fn start_ms, finish_ms ->
      start_ms = adjust(start_ms, offset_ms, rate)
      finish_ms = adjust(finish_ms, offset_ms, rate)
      tick_ms = if precision == 2, do: 10, else: 1
      {start_ms, max(finish_ms, start_ms + tick_ms)}
    end)
  end

  defp pair_matches(line, regex) do
    regex
    |> Regex.scan(line, return: :index)
    |> Enum.take(2)
    |> Enum.map(fn [{start, length} | _captures] ->
      whole = binary_part(line, start, length)
      {start, length, Regex.named_captures(regex, whole)}
    end)
  end

  defp pair_times(line, regex, precision) do
    case pair_matches(line, regex) do
      [{_, _, start_captures}, {_, _, finish_captures}] ->
        {to_milliseconds(start_captures, precision), to_milliseconds(finish_captures, precision)}

      _ ->
        nil
    end
  end

  defp rewrite_pair(line, regex, precision, style, fun) do
    matches = pair_matches(line, regex)

    case matches do
      [{_, _, start_captures}, {_, _, finish_captures}] ->
        {start_ms, finish_ms} =
          fun.(
            to_milliseconds(start_captures, precision),
            to_milliseconds(finish_captures, precision)
          )

        ensure_renderable!(start_ms, style)
        ensure_renderable!(finish_ms, style)

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

  defp adjust(milliseconds, offset_ms, rate) do
    adjusted = milliseconds |> Kernel.*(rate) |> Kernel.+(offset_ms) |> round() |> max(0)

    if valid_timestamp_ms?(adjusted),
      do: adjusted,
      else: raise(ArgumentError, "retimed timestamp is out of bounds")
  end

  defp ensure_renderable!(milliseconds, _style) when milliseconds > @max_timestamp_ms,
    do: raise(ArgumentError, "retimed timestamp is out of bounds")

  defp ensure_renderable!(milliseconds, style)
       when style in [:srt, :vtt, :sub] and milliseconds >= 360_000_000,
       do: raise(ArgumentError, "retimed timestamp exceeds two-digit hours")

  defp ensure_renderable!(_milliseconds, _style), do: :ok

  defp render(milliseconds, precision, style, original_hours) do
    hours = div(milliseconds, 3_600_000)
    minutes = div(rem(milliseconds, 3_600_000), 60_000)
    seconds = div(rem(milliseconds, 60_000), 1_000)
    fraction = div(rem(milliseconds, 1_000), if(precision == 2, do: 10, else: 1))
    separator = if style == :srt, do: ",", else: "."
    hours? = style in [:srt, :ass, :sub] or original_hours not in [nil, ""] or hours > 0

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
