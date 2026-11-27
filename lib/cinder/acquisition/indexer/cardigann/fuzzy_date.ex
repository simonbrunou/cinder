defmodule Cinder.Acquisition.Indexer.Cardigann.FuzzyDate do
  @moduledoc ~S"""
  The pattern branches of Prowlarr's `DateTimeUtil.FromUnknown` (b0b5774, #1802, part of #1610),
  which `Cinder.Acquisition.Indexer.Cardigann.DotnetDate.from_unknown/2` runs after its own
  first branches: the `ago` test, the `today`, `yesterday` and `tomorrow` words, a day name with
  `at`, the two missing-year rewrites and `DateTimeRoutines.TryParseDateOrTime` with `USDate`,
  in that order.

  `from_unknown/2` answers `{:ok, time}` or `:error`, and `ago?/1` answers `true`, `false` or
  `:error`. Inside, each branch answers `{:ok, time}` when it reads the text, `:none` when the
  text goes on to the next branch, and `:error` where .NET throws, which ends `FromUnknown`.
  Every clock reading .NET makes is the `now` argument, a UTC `DateTime`, and every result reads
  as UTC (the issue's choice).

  The patterns are .NET's, rewritten for PCRE so they match what .NET matches. `dotnet fsi` rows
  in the tests pin each rewrite:

  - .NET's `\d` is `\p{Nd}`, its `\s` the 25 code points of PCRE's `\s` but U+180E, its `\w`
    `[\p{L}\p{Mn}\p{Nd}\p{Pc}]`, and its `\b` before a letter a lookbehind for a character
    outside `\w`, U+200C and U+200D. PCRE's own classes under `:ucp` differ: its `\w` takes
    every number and every mark;
  - .NET's case-insensitive letters are written as classes: `i` also matches `İ` (U+0130),
    which .NET's table pairs with it, and `s` does not match `ſ` (U+017F), which PCRE's caseless
    mode would;
  - a lookbehind .NET runs without a length bound is written as the forms it can match: the
    time after a date starts at the first digit after a prefix of blanks with `,`, `at`, `T` or
    `-`, and a time with no date follows the start, a blank or a `T`.

  A digit outside ASCII matches `\d` and makes .NET's `int.Parse` throw, so a group that holds
  one is `:error`. Every match runs as `:re.run/3` with an explicit match limit and
  `:report_errors`, and a limit hit is `:error`, never a raise.

  `ParseTimeSpan`, the time after `today` or a day name, is `DateTime.Parse(rest).TimeOfDay` in
  .NET. Here it reads only the forms the corpus' definitions produce (the issue's choice): `H:mm`,
  `H:mm:ss`, and `H` or `H:mm` followed by `AM` or `PM` in any case, each with an optional
  `+HH:mm` or `-HH:mm` offset of at most 14:00, which shifts the time of day as .NET's
  conversion to its zone does. Blank text reads as midnight. Any other text is `:error`, even
  where .NET reads it, such as `14:5`, `14 : 22`, `14:22:10 PM`, `+0800` or `Z`.
  """

  @limit 10_000_000
  @last_second ~U[9999-12-31 23:59:59Z]

  # .NET's `\s`, `\d` and the members of its `\w`.
  @s "[\\x{9}-\\x{D}\\x{85}\\p{Z}]"
  @s_members "\\x{9}-\\x{D}\\x{85}\\p{Z}"
  @d "\\p{Nd}"
  @w "\\p{L}\\p{Mn}\\p{Nd}\\p{Pc}"
  # `[^\d\w]`, `[^\d\w:]` and `\b` before a word character.
  @not_word "[^#{@w}]"
  @not_word_colon "[^#{@w}:]"
  @boundary "(?<![#{@w}\\x{200C}\\x{200D}])"

  # A word in .NET's case-insensitive mode: each ASCII letter in both cases, `i` also as `İ`.
  ci = fn word ->
    for <<c <- word>>, into: "" do
      cond do
        c in [?i, ?I] -> "[iI\\x{130}]"
        c in ?a..?z or c in ?A..?Z -> "[" <> String.downcase(<<c>>) <> String.upcase(<<c>>) <> "]"
        true -> <<c>>
      end
    end
  end

  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)
  # The month switch of `TryParseDate`, which reads only these spellings: `Jul` has no `JUL`.
  @month_numbers @months
                 |> Enum.with_index(1)
                 |> Enum.flat_map(fn
                   {"Jul", n} -> [{"Jul", n}]
                   {name, n} -> [{name, n}, {String.upcase(name), n}]
                 end)
                 |> Map.new()
  @days ~w(monday tuesday wednesday thursday friday saturday sunday)

  @ago @boundary <> ci.("ago")
  @relative_days (for {word, shift} <- [{"today", 0}, {"yesterday", -1}, {"tomorrow", 1}] do
                    {@boundary <>
                       ci.(word) <>
                       "(?:[#{@s_members},]+(?:#{ci.("at")})?#{@s}*|[#{@s_members},]*|$)", shift}
                  end)
  @weekday @boundary <>
             "(" <> Enum.map_join(@days, "|", ci) <> ")#{@s}+#{ci.("at")}#{@s}+"
  @missing_year "^(#{@d}{1,2}-#{@d}{1,2})(?:#{@s}|$)"
  @missing_year_time "^(#{@d}{1,2}#{@s}+[#{@w}]{3})#{@s}+(#{@d}{1,2}:#{@d}{1,2}.*)$"

  # `TryParseDate`'s patterns, each `RegexOptions.IgnoreCase`.
  @month "(" <> Enum.map_join(@months, "|", ci) <> ")[uarychilestmbroUARYCHILESTMBRO\\x{130}]*"
  @ordinal "(?:" <> Enum.map_join(~w(st th rd nd), "|", &("-?" <> ci.(&1))) <> ")?"
  @numeric_dates [
    # dd/mm/yy: day, separator, month, year. `USDate` reads the first number as the month.
    {"(?<=^|[^#{@d}])(#{@d}{1,2})#{@s}*([\\\\/.])+#{@s}*(#{@d}{1,2})#{@s}*\\2+#{@s}*" <>
       "(#{@d}{2}|#{@d}{4})(?=$|[^#{@d}])", {1, 3, 4}},
    # [yy]yy-mm-dd: year, separator, month, day.
    {"(?<=^|[^#{@d}])(#{@d}{2}|#{@d}{4})#{@s}*(-)#{@s}*(#{@d}{1,2})#{@s}*\\2+#{@s}*" <>
       "(#{@d}{1,2})(?=$|[^#{@d}])", {3, 4, 1}}
  ]
  # The month-name patterns, tried in order until one matches: the group of the month, the day
  # and the year.
  @named_dates [
    {"(?:^|#{@not_word})#{@month}#{@s}+(#{@d}{1,2})#{@ordinal}#{@s}*,?#{@s}*(#{@d}{4})" <>
       "(?=$|#{@not_word})", {1, 2, 3}},
    {"(?:^|#{@not_word_colon})(#{@d}{1,2})(?:" <>
       Enum.map_join(~w(st th rd nd), "|", &("-?" <> ci.(&1) <> "#{@s}+")) <>
       "|-|#{@s}+)#{@month}(?:#{@s}*,?#{@s}*|-)'?(#{@d}{2}|#{@d}{4})(?=$|#{@not_word})",
     {2, 1, 3}},
    {"(?:^|#{@not_word})(#{@d}{4})#{@s}+#{@month}#{@s}+(#{@d}{1,2})#{@ordinal}" <>
       "(?=$|#{@not_word})", {2, 3, 1}},
    {"(?:^|#{@not_word})#{@month}#{@s}+(#{@d}{1,2})#{@s}+#{@d}{2}:#{@d}{2}:#{@d}{2}#{@s}+" <>
       "(?:#{ci.("MDT")}|#{ci.("UTC")})#{@s}+(#{@d}{4})(?=$|#{@not_word})", {1, 2, 3}},
    {"(?:^|#{@not_word})#{@month}#{@s}+(#{@d}{1,2})#{@ordinal}(?:#{@s}*,?#{@s}*(#{@d}{4}))?" <>
       "(?=$|#{@not_word})", {1, 2, 3}}
  ]

  # `TryParseTime`'s patterns, case-sensitive. A pattern with an offset captures the hour,
  # minute, second, sign, offset hours and offset minutes; the others the hour, minute, second,
  # AM or PM and zone name.
  @hms "(#{@d}{2})#{@s}*:#{@s}*(#{@d}{2})#{@s}*:#{@s}*(#{@d}{2})#{@s}+([+\\-])(#{@d}{2}):?"
  @hm "(#{@d}{1,2})#{@s}*:#{@s}*(#{@d}{2})#{@s}*(?::#{@s}*(#{@d}{2}))?" <>
        "(?:#{@s}*(AM|am|PM|pm))?(?:#{@s}*(UTC|GMT|CST|EST))?"
  # `(?<=^\s*,?\s+|^\s*at\s*|^\s*[T\-]\s*)` on the text after the date.
  @after_date "\\A(?:#{@s}*,?#{@s}+|#{@s}*at#{@s}*|#{@s}*[T\\-]#{@s}*)"
  # `(?<=^|\s+|\s*T\s*)`.
  @free_start "(?<=^|[#{@s_members}T])"
  @times_after [
    {:offset, @after_date <> @hms <> "(#{@d}{2})(?=$|#{@not_word})"},
    {:zone, @after_date <> @hm <> "(?=$|#{@not_word})"}
  ]
  @time_around "(?<=^|[^#{@d}])" <> @hm <> "(?=$|[#{@s_members},])"
  @times_alone [
    {:offset, @free_start <> @hms <> "(#{@d}{2})?(?=$|#{@not_word})"},
    {:zone, @free_start <> @hm <> "(?=$|#{@not_word})"}
  ]
  @zones %{"UTC" => 0, "GMT" => 0, "CST" => -360, "EST" => -300}

  # The decided `ParseTimeSpan` forms: hour, minute, second, AM or PM, sign, offset hours and
  # offset minutes, between .NET blanks.
  @time_span "\\A#{@s}*([0-9]{1,2})(?::([0-9]{2})(?::([0-9]{2}))?)?#{@s}*([AaPp][Mm])?#{@s}*" <>
               "(?:([+-])([0-9]{2}):([0-9]{2}))?#{@s}*\\z"
  @blank "\\A#{@s}*\\z"

  @doc """
  `FromUnknown`'s `ago` test: `true` when a word starting with `ago`, in any case, starts at a
  word boundary, which sends the text to `DotnetDate.from_time_ago/2`.
  """
  @spec ago?(String.t()) :: boolean() | :error
  def ago?(text) do
    case run(@ago, text) do
      {:ok, _groups} -> true
      :none -> false
      :error -> :error
    end
  end

  @doc "`FromUnknown`'s branches after the `ago` test, on the trimmed text."
  @spec from_unknown(String.t(), DateTime.t()) :: {:ok, DateTime.t()} | :error
  def from_unknown(text, %DateTime{} = now) do
    with :none <- relative_day(@relative_days, text, now),
         :none <- weekday(text, now),
         {:ok, text} <- missing_year(text, now),
         {:ok, time} <- date_or_time(text, now) do
      {:ok, time}
    else
      {:ok, time} -> {:ok, time}
      _failed -> :error
    end
  end

  # `today`, `yesterday` and `tomorrow`: now's date plus the time left once every copy of the
  # matched text is removed, a day added or taken.
  defp relative_day([], _text, _now), do: :none

  defp relative_day([{pattern, shift} | rest], text, now) do
    case run(pattern, text) do
      {:ok, [{start, length} | _]} ->
        with {:ok, seconds} <- time_span(without(text, start, length)) do
          {:ok, at(Date.add(DateTime.to_date(now), shift), seconds)}
        end

      :none ->
        relative_day(rest, text, now)

      :error ->
        :error
    end
  end

  # `<day name> at <time>`: today at that time, walked back to that day, today included.
  defp weekday(text, now) do
    case run(@weekday, text) do
      {:ok, [{start, length}, name]} ->
        with {:ok, seconds} <- time_span(without(text, start, length)) do
          today = DateTime.to_date(now)
          back = Integer.mod(Date.day_of_week(today) - day_number(text, name), 7)
          {:ok, at(Date.add(today, -back), seconds)}
        end

      :none ->
        :none

      :error ->
        :error
    end
  end

  # The matched name in .NET's lower case, where `İ` is `i`.
  defp day_number(text, group) do
    name = text |> part(group) |> String.replace("İ", "i") |> String.downcase(:ascii)
    Enum.find_index(@days, &(&1 == name)) + 1
  end

  # .NET's `str.Replace(match, "")`: every copy of the matched text, not only the match.
  defp without(text, start, length),
    do: String.replace(text, binary_part(text, start, length), "")

  defp at(date, seconds), do: DateTime.add(DateTime.new!(date, ~T[00:00:00]), seconds)

  # `11-25` takes now's year in front of every copy of it, and `25 Nov 14:22` takes it between
  # the date and the time.
  defp missing_year(text, now) do
    with {:ok, text} <- missing_year_date(text, now) do
      case run(@missing_year_time, text) do
        {:ok, [_whole, date, time]} ->
          {:ok, "#{part(text, date)} #{now.year} #{part(text, time)}"}

        :none ->
          {:ok, text}

        :error ->
          :error
      end
    end
  end

  defp missing_year_date(text, now) do
    case run(@missing_year, text) do
      {:ok, [_whole, date]} ->
        date = part(text, date)
        {:ok, String.replace(text, date, "#{now.year}-#{date}")}

      :none ->
        {:ok, text}

      :error ->
        :error
    end
  end

  # `TryParseDateOrTime`: a date and the time around it, a date alone at midnight, or a time
  # alone on now's date.
  defp date_or_time(text, now) do
    case date(text, now) do
      {:ok, date, span} -> dated(text, date, span)
      :none -> undated(text, now)
      :error -> :error
    end
  end

  defp dated(text, date, span) do
    case time(text, span) do
      {:ok, {hour, minute, second}, offset} ->
        time = DateTime.new!(date, Time.new!(hour, minute, second))
        if offset_fits?(time, offset), do: {:ok, time}, else: :error

      :none ->
        {:ok, DateTime.new!(date, ~T[00:00:00])}

      :error ->
        :error
    end
  end

  defp undated(text, now) do
    case time(text, nil) do
      {:ok, {hour, minute, second}, _offset} ->
        {:ok, DateTime.new!(DateTime.to_date(now), Time.new!(hour, minute, second))}

      _none_or_error ->
        :error
    end
  end

  # `ParsedDateTime` adds an offset under 12 hours to a found date to build its `UtcDateTime`,
  # and that throws past the year 9999. `FromFuzzyTime` then drops the offset.
  defp offset_fits?(_time, nil), do: true
  defp offset_fits?(_time, offset) when abs(offset) >= 720, do: true
  defp offset_fits?(time, offset), do: DateTime.diff(@last_second, time) >= offset * 60

  # `TryParseDate`: the first pattern that matches decides; a date it cannot build is no date.
  defp date(text, now) do
    case first_match(@numeric_dates, text) do
      {:ok, groups, {month, day, year}} -> numeric_date(text, groups, {month, day, year})
      :none -> named_date(text, now)
      :error -> :error
    end
  end

  defp numeric_date(text, groups, {month, day, year}) do
    with {:ok, year} <- int(text, Enum.at(groups, year)),
         {:ok, month} <- int(text, Enum.at(groups, month)),
         {:ok, day} <- int(text, Enum.at(groups, day)) do
      build_date(year, month, day, hd(groups))
    end
  end

  defp named_date(text, now) do
    case first_match(@named_dates, text) do
      {:ok, groups, {month, day, year}} ->
        month = Map.get(@month_numbers, part(text, Enum.at(groups, month)), -1)

        with {:ok, year} <- year(text, Enum.at(groups, year), now),
             {:ok, day} <- int(text, Enum.at(groups, day)) do
          build_date(year, month, day, hd(groups))
        end

      other ->
        other
    end
  end

  defp year(_text, {-1, 0}, now), do: {:ok, now.year}
  defp year(text, group, _now), do: int(text, group)

  # `ConvertToDate`: a year of 100 to 999 fails, one under 100 reads 31 to 99 as 1931 to 1999
  # and 0 to 30 as 2000 to 2030.
  defp build_date(year, month, day, span) do
    year =
      cond do
        year >= 100 -> year
        year > 30 -> year + 1900
        true -> year + 2000
      end

    with true <- year >= 1000,
         {:ok, date} <- Date.new(year, month, day) do
      {:ok, date, span}
    else
      _invalid -> :none
    end
  end

  defp first_match([], _text), do: :none

  defp first_match([{pattern, order} | rest], text) do
    case run(pattern, text) do
      {:ok, groups} -> {:ok, groups, order}
      :none -> first_match(rest, text)
      :error -> :error
    end
  end

  # `TryParseTime`: with a date, after it, then before it, then inside it; without one,
  # anywhere. The first pattern that matches decides.
  defp time(text, nil), do: time_in(@times_alone, text)

  defp time(text, {start, length}) do
    after_date = binary_part(text, start + length, byte_size(text) - start - length)

    with :none <- time_in(@times_after, after_date),
         :none <- time_in([{:zone, @time_around}], binary_part(text, 0, start)) do
      time_in([{:zone, @time_around}], binary_part(text, start, length))
    end
  end

  defp time_in([], _text), do: :none

  defp time_in([{kind, pattern} | rest], text) do
    case run(pattern, text) do
      {:ok, [_whole | groups]} -> time_value(kind, text, groups)
      :none -> time_in(rest, text)
      :error -> :error
    end
  end

  # Each number is read and checked in .NET's order, so a bad hour stops before the minute is
  # read. A time out of range is no time.
  defp time_value(kind, text, [hour, minute, second | rest]) do
    with {:ok, hour} when hour <= 23 <- int(text, hour),
         {:ok, minute} when minute <= 59 <- int(text, minute),
         {:ok, second} when second <= 59 <- int_or_zero(text, second),
         hour = meridiem(kind, text, rest, hour),
         {:ok, offset} <- offset(kind, text, rest) do
      {:ok, {hour, minute, second}, offset}
    else
      {:ok, _out_of_range} -> :none
      :error -> :error
    end
  end

  # A group that took no part, such as a time's missing seconds, reads as 0.
  defp int_or_zero(_text, {-1, 0}), do: {:ok, 0}
  defp int_or_zero(text, group), do: int(text, group)

  defp meridiem(:zone, text, [ampm | _], hour) do
    case {String.upcase(part(text, ampm)), hour} do
      {"PM", hour} when hour < 12 -> hour + 12
      {"AM", 12} -> 0
      _other -> hour
    end
  end

  defp meridiem(:offset, _text, _groups, hour), do: hour

  defp offset(:offset, text, [sign, hours | minutes]) do
    with {:ok, hours} <- int(text, hours),
         {:ok, minutes} <- int_or_zero(text, List.first(minutes, {-1, 0})) do
      total = hours * 60 + minutes
      {:ok, if(part(text, sign) == "-", do: -total, else: total)}
    end
  end

  defp offset(:zone, text, [_ampm | zone]) do
    case zone do
      [{start, length}] when start >= 0 -> {:ok, Map.fetch!(@zones, part(text, {start, length}))}
      _no_zone -> {:ok, nil}
    end
  end

  # .NET's `int.Parse` on a matched `\d` run: a digit outside ASCII throws.
  defp int(text, group) do
    digits = part(text, group)

    if digits != "" and digits |> :binary.bin_to_list() |> Enum.all?(&(&1 in ?0..?9)),
      do: {:ok, String.to_integer(digits)},
      else: :error
  end

  defp part(_text, {-1, 0}), do: ""
  defp part(text, {start, length}), do: binary_part(text, start, length)

  # The decided `ParseTimeSpan` bound, as seconds into the day.
  defp time_span(rest) do
    with :none <- blank(rest),
         {:ok, [_whole | groups]} <- run(@time_span, rest),
         {:ok, seconds} <- span_seconds(Enum.map(groups, &part(rest, &1))) do
      {:ok, seconds}
    else
      {:ok, 0} -> {:ok, 0}
      _other -> :error
    end
  end

  defp blank(rest) do
    case run(@blank, rest) do
      {:ok, _groups} -> {:ok, 0}
      other -> other
    end
  end

  defp span_seconds([hour, minute, second, ampm | offset]) do
    with true <- form?(minute, second, ampm),
         {:ok, hour} <- span_hour(String.to_integer(hour), String.upcase(ampm)),
         minute = number(minute),
         second = number(second),
         true <- minute <= 59 and second <= 59,
         {:ok, offset} <- span_offset(offset) do
      {:ok, Integer.mod(hour * 3600 + minute * 60 + second - offset * 60, 86_400)}
    else
      _invalid -> :error
    end
  end

  # `H` needs AM or PM, and `H:mm:ss` takes none.
  defp form?("", _second, ampm), do: ampm != ""
  defp form?(_minute, "", _ampm), do: true
  defp form?(_minute, _second, ampm), do: ampm == ""

  defp span_hour(hour, ""), do: if(hour <= 23, do: {:ok, hour}, else: :error)
  defp span_hour(hour, "AM"), do: if(hour <= 12, do: {:ok, rem(hour, 12)}, else: :error)
  defp span_hour(hour, "PM") when hour < 12, do: {:ok, hour + 12}
  defp span_hour(hour, "PM"), do: if(hour <= 23, do: {:ok, hour}, else: :error)

  defp span_offset(["", "", ""]), do: {:ok, 0}
  defp span_offset([]), do: {:ok, 0}

  defp span_offset([sign, hours, minutes]) do
    total = String.to_integer(hours) * 60 + String.to_integer(minutes)

    if String.to_integer(minutes) <= 59 and total <= 14 * 60,
      do: {:ok, if(sign == "-", do: -total, else: total)},
      else: :error
  end

  defp number(""), do: 0
  defp number(digits), do: String.to_integer(digits)

  # The whole match and every group, `{-1, 0}` for one that took no part. `:re` leaves out the
  # groups after the last one that took part, so an empty group, which always takes part, ends
  # the pattern and is dropped from the answer.
  #
  # `:no_start_optimize` turns off PCRE2's search for a code unit the match needs. For a letter
  # class such as `[tT]` that search looks for both cases from each start, so on 4 MiB of
  # `T1:11 `, which holds no `t`, the day-name pattern took 19.9 s, and 0.5 s without it.
  defp run(pattern, text) do
    {:ok, regex} = :re.compile(pattern <> "()", [:unicode, :ucp, :no_start_optimize])
    options = [:report_errors, {:match_limit, @limit}, {:capture, :all, :index}]

    case :re.run(text, regex, options) do
      {:match, groups} -> {:ok, Enum.drop(groups, -1)}
      :nomatch -> :none
      {:error, _limit} -> :error
    end
  end
end
