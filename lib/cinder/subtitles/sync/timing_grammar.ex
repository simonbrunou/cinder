defmodule Cinder.Subtitles.Sync.TimingGrammar do
  @moduledoc false

  @srt ~r/(?<h>\d{2}):(?<m>\d{2}):(?<s>\d{2}),(?<f>\d{3})/
  @vtt ~r/(?:(?<h>\d{2}):)?(?<m>\d{2}):(?<s>\d{2})\.(?<f>\d{3})/
  @ass ~r/(?<h>\d+):(?<m>\d{2}):(?<s>\d{2})\.(?<f>\d{2})/
  @sub ~r/(?<h>\d{2}):(?<m>\d{2}):(?<s>\d{2})\.(?<f>\d{2})/
  @max_timestamp_ms 604_800_000
  @max_fps 1_000.0
  @max_microdvd_frame 604_800_000
  @sub_headers [
    "INFORMATION",
    "TITLE",
    "AUTHOR",
    "SOURCE",
    "FILEPATH",
    "DELAY",
    "COMMENT",
    "END INFORMATION",
    "SUBTITLE",
    "COLF",
    "SIZE",
    "FONT",
    "CD TRACK"
  ]

  @spec valid?(binary(), String.t()) :: boolean()
  def valid?(source, extension) when is_binary(source) do
    case extension do
      ".srt" -> valid_srt?(source)
      ".vtt" -> valid_vtt?(source)
      extension when extension in [".ass", ".ssa"] -> valid_ass?(source)
      ".sub" -> valid_microdvd?(source) or valid_timestamped_sub?(source)
      _ -> false
    end
  rescue
    _ -> false
  end

  defp valid_srt?(source) do
    case blocks(source) do
      [] -> false
      cue_blocks -> Enum.all?(cue_blocks, &valid_srt_block?/1)
    end
  end

  defp valid_srt_block?([first | _rest] = block) do
    if String.contains?(first, "-->") or Regex.match?(~r/^\d+$/, String.trim(first)),
      do: valid_cue_block?(block, @srt, 3),
      else: false
  end

  defp valid_srt_block?(_block), do: false

  defp valid_vtt?(source) do
    case blocks(source) do
      [[header | metadata] | body] ->
        valid_vtt_header?(header, metadata) and body != [] and
          Enum.any?(body, &vtt_cue_block?/1) and Enum.all?(body, &valid_vtt_block?/1)

      _ ->
        false
    end
  end

  defp valid_vtt_header?(header, metadata) do
    header = String.trim_leading(header, "\uFEFF")

    Regex.match?(~r/^WEBVTT(?:[\t ].*)?$/, header) and
      Enum.all?(metadata, &Regex.match?(~r/^[A-Za-z][A-Za-z0-9_-]*:\s*.*$/, &1))
  end

  defp valid_vtt_block?(["NOTE" | _lines]), do: true
  defp valid_vtt_block?(["NOTE " <> _comment | _lines]), do: true
  defp valid_vtt_block?(["STYLE" | rules]), do: Enum.any?(rules, &(String.trim(&1) != ""))

  defp valid_vtt_block?(["REGION" | settings]),
    do: Enum.all?(settings, &String.contains?(&1, ":"))

  defp valid_vtt_block?(block), do: vtt_cue_block?(block)

  defp vtt_cue_block?(block), do: valid_cue_block?(block, @vtt, 3)

  defp valid_cue_block?([first | rest], regex, precision) do
    case cue_timing_and_text(first, rest) do
      {timing, text} ->
        text != [] and Enum.any?(text, &(String.trim(&1) != "")) and
          Enum.all?(text, &(not String.contains?(&1, "-->"))) and
          valid_arrow_row?(timing, regex, precision)

      :error ->
        false
    end
  end

  defp valid_cue_block?(_block, _regex, _precision), do: false

  defp cue_timing_and_text(first, rest) do
    cond do
      String.contains?(first, "-->") -> {first, rest}
      Regex.match?(~r/^\d+$/, String.trim(first)) and rest != [] -> {hd(rest), tl(rest)}
      first != "" and rest != [] and String.contains?(hd(rest), "-->") -> {hd(rest), tl(rest)}
      true -> :error
    end
  end

  defp valid_ass?(source) do
    source_lines = lines(source)
    events_index = Enum.find_index(source_lines, &(String.trim(&1) == "[Events]"))

    if is_integer(events_index) do
      event_lines =
        source_lines
        |> Enum.drop(events_index + 1)
        |> Enum.take_while(&(not section_line?(&1)))

      Enum.all?(source_lines, &valid_ass_line?/1) and
        Enum.any?(event_lines, &valid_ass_format?/1) and
        Enum.any?(event_lines, &valid_ass_dialogue?/1)
    else
      false
    end
  end

  defp valid_ass_line?(line) do
    line = String.trim(line)

    cond do
      line == "" -> true
      String.starts_with?(line, ";") -> true
      section_line?(line) -> true
      String.starts_with?(line, "Dialogue:") -> valid_ass_dialogue?(line)
      String.starts_with?(line, "Comment:") -> valid_ass_event?(line)
      true -> Regex.match?(~r/^[^:\r\n]+:\s*.*$/, line)
    end
  end

  defp section_line?(line), do: Regex.match?(~r/^\[[^\]\r\n]+\]$/, String.trim(line))

  defp valid_ass_format?(line) do
    case String.split(line, ":", parts: 2) do
      ["Format", fields] ->
        fields =
          fields |> String.split(",") |> Enum.map(&(&1 |> String.trim() |> String.downcase()))

        length(fields) == 10 and Enum.at(fields, 1) == "start" and Enum.at(fields, 2) == "end" and
          List.last(fields) == "text"

      _ ->
        false
    end
  end

  defp valid_ass_dialogue?("Dialogue:" <> _rest = line), do: valid_ass_event?(line)
  defp valid_ass_dialogue?(_line), do: false

  defp valid_ass_event?(line) do
    case line |> String.split(":", parts: 2) |> List.last() |> String.split(",", parts: 10) do
      [_layer, start, finish, _style, _name, _margin_l, _margin_r, _margin_v, _effect, _text] ->
        valid_timestamp_pair?(String.trim(start), String.trim(finish), @ass, 2)

      _ ->
        false
    end
  end

  defp valid_timestamped_sub?(source) do
    {valid?, seen_cue?, _cue_open?} =
      Enum.reduce(lines(source), {true, false, false}, fn line, state ->
        validate_sub_line(String.trim_trailing(line), state)
      end)

    valid? and seen_cue?
  end

  defp validate_sub_line(_line, {false, seen?, open?}), do: {false, seen?, open?}
  defp validate_sub_line("", {true, seen?, open?}), do: {true, seen?, open?}

  defp validate_sub_line(line, {true, seen?, _open?}) do
    cond do
      valid_timestamped_sub_cue?(line) -> {true, true, true}
      valid_sub_header?(line) and not seen? -> {true, false, false}
      String.starts_with?(line, "[") -> {false, seen?, false}
      seen? -> {true, true, true}
      true -> {false, false, false}
    end
  end

  defp valid_timestamped_sub_cue?(line) do
    case Regex.run(~r/^\[([^\]]+)\]\[([^\]]+)\](.*)$/, line, capture: :all_but_first) do
      [start, finish, _text] -> valid_timestamp_pair?(start, finish, @sub, 2)
      _ -> false
    end
  end

  defp valid_sub_header?(line) do
    case Regex.run(~r/^\[([A-Z][A-Z ]+)\](.*)$/, line, capture: :all_but_first) do
      [name, _value] -> name in @sub_headers
      _ -> false
    end
  end

  defp valid_microdvd?(source) do
    rows = source |> lines() |> Enum.reject(&(String.trim(&1) == ""))
    headers = Enum.filter(rows, &Regex.match?(~r/^\{1\}\{1\}\d+(?:\.\d+)?$/, &1))

    case {microdvd_fps(headers), headers} do
      {{:ok, fps}, [_header]} ->
        Enum.any?(rows, &microdvd_cue?(&1, fps)) and
          Enum.all?(rows, &valid_microdvd_row?(&1, fps))

      _ ->
        false
    end
  end

  defp microdvd_fps(["{1}{1}" <> value]) do
    case Float.parse(value) do
      {fps, ""} when fps > 0 and fps <= @max_fps -> {:ok, fps}
      _ -> :error
    end
  end

  defp microdvd_fps(_headers), do: :error

  defp valid_microdvd_row?("{1}{1}" <> _value = line, fps) do
    Regex.match?(~r/^\{1\}\{1\}\d+(?:\.\d+)?$/, line) or microdvd_cue?(line, fps)
  end

  defp valid_microdvd_row?(line, fps), do: microdvd_cue?(line, fps)

  defp microdvd_cue?(line, fps) do
    case Regex.run(~r/^\{(\d+)\}\{(\d+)\}(.*)$/, line, capture: :all_but_first) do
      [start, finish, _text] -> valid_frame_pair?(start, finish, fps)
      _ -> false
    end
  end

  defp valid_frame_pair?(start, finish, fps) do
    with {start, ""} <- Integer.parse(start),
         {finish, ""} <- Integer.parse(finish),
         true <- start < finish,
         true <- finish <= @max_microdvd_frame,
         do: finish / fps * 1_000 <= @max_timestamp_ms,
         else: (_ -> false)
  end

  defp valid_arrow_row?(line, regex, precision) do
    case String.split(line, "-->") do
      [start, finish] ->
        with {:ok, start} <- exact_timestamp(String.trim(start), regex),
             {:ok, finish} <- leading_timestamp(String.trim(finish), regex),
             do: timestamp_ordered?(start, finish, precision),
             else: (_ -> false)

      _ ->
        false
    end
  end

  defp valid_timestamp_pair?(start, finish, regex, precision) do
    with {:ok, start} <- exact_timestamp(start, regex),
         {:ok, finish} <- exact_timestamp(finish, regex),
         do: timestamp_ordered?(start, finish, precision),
         else: (_ -> false)
  end

  defp exact_timestamp(value, regex) do
    case Regex.run(regex, value) do
      [^value | _captures] -> {:ok, Regex.named_captures(regex, value)}
      _ -> :error
    end
  end

  defp leading_timestamp(value, regex) do
    case Regex.run(regex, value, return: :index) do
      [{0, length} | _captures] ->
        timestamp = binary_part(value, 0, length)
        trailing = binary_part(value, length, byte_size(value) - length)

        if trailing == "" or String.starts_with?(trailing, [" ", "\t"]),
          do: {:ok, Regex.named_captures(regex, timestamp)},
          else: :error

      _ ->
        :error
    end
  end

  defp timestamp_ordered?(start, finish, precision) do
    valid_timestamp?(start, precision) and valid_timestamp?(finish, precision) and
      milliseconds(start, precision) < milliseconds(finish, precision)
  end

  defp valid_timestamp?(captures, precision) do
    minutes = String.to_integer(captures["m"])
    seconds = String.to_integer(captures["s"])
    value = milliseconds(captures, precision)
    minutes < 60 and seconds < 60 and value >= 0 and value <= @max_timestamp_ms
  end

  defp milliseconds(captures, precision) do
    hours = captures["h"] |> empty_zero() |> String.to_integer()
    minutes = String.to_integer(captures["m"])
    seconds = String.to_integer(captures["s"])
    fraction = String.to_integer(captures["f"]) * if(precision == 2, do: 10, else: 1)
    ((hours * 60 + minutes) * 60 + seconds) * 1_000 + fraction
  end

  defp empty_zero(nil), do: "0"
  defp empty_zero(""), do: "0"
  defp empty_zero(value), do: value

  defp blocks(source) do
    source
    |> normalize_newlines()
    |> String.split(~r/\n[\t ]*\n+/, trim: true)
    |> Enum.map(&String.split(&1, "\n", trim: false))
  end

  defp lines(source), do: source |> normalize_newlines() |> String.split("\n", trim: false)

  defp normalize_newlines(source),
    do:
      source
      |> String.trim_leading("\uFEFF")
      |> String.replace("\r\n", "\n")
      |> String.replace("\r", "\n")
end
