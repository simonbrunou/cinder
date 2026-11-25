defmodule Cinder.Acquisition.Indexer.Cardigann.DotnetDate do
  @moduledoc ~S"""
  Reads a date with a .NET custom format, as Prowlarr's `dateparse` filter does for every v11
  layout (#1670, part of #1610): `DateTimeUtil.ParseDateTimeGoLang` trims the text and sends a
  layout holding `y`, `h` or `d` to `DateTime.TryParseExact` under the invariant culture with
  `DateTimeStyles.None`. The 83 v11 layouts all hold one (#1612).

  The tokens are those the v11 layouts use: `yyyy`, `yy`, `MMMM`, `MMM`, `MM`, `M`, `dddd`,
  `ddd`, `dd`, `d`, `HH`, `hh`, `h`, `mm`, `ss`, `tt` and `zzz`. Any other run of a .NET format
  letter (`dfFghHKmMstyz`), a quote, a backslash or a `%` is
  `{:error, {:not_supported, {:date_layout, token}}}`, so a load check can refuse the layout
  before any text reaches it. Every other character, `/` and `:` included, matches only itself.

  The rules come from `dotnet fsi` runs (.NET 8.0.427, TZ=UTC), listed in the tests:

  - a two-letter numeric token reads exactly two ASCII digits, a one-letter one one or two, and
    `yyyy` four. `yy` reads 00 to 49 as 2000 to 2049 and 50 to 99 as 1950 to 1999;
  - month names, day names and `AM`/`PM` match in any letter case, in English; a day name
    that is not the date's weekday fails;
  - `hh` and `h` read 0 to 12, and 12 is midnight unless `tt` reads `PM`. With `HH`, a `tt` of
    `AM` needs an hour below 12 and `PM` one of 12 or more. A layout with both `HH` and `hh`
    needs the same digits in each, and the 12-hour rules then apply;
  - `zzz` reads a sign, one or two hour digits, an optional `:` and two minute digits, at most
    14:00, and the time shifts to UTC. `+01` and `Z` fail;
  - a layout with no year, month or day takes `now`'s date; one with some of them takes `now`'s
    year and month 1 and day 1 for the rest;
  - a layout with no `zzz` reads the time as UTC, where .NET returns an unspecified kind that
    Prowlarr reads in its host's zone. This is the issue's choice;
  - an impossible date, such as 2026-02-30, fails, and so does a field read twice with two
    values. A time that `zzz` shifts out of the years 1 to 9999 fails too. .NET also fails past
    9999, and before year 1 it returns a wrong time instead (`0001-01-01 00:00 +01:00` gives
    0001-01-01 23:00 UTC).

  The `dateparse` filter writes a parsed time as `canonical/1`, which `from_unknown/2` reads
  back. Every function is pure: `now` is a UTC `DateTime` the caller passes.
  """

  @tokens ~w(yyyy yy MMMM MMM MM M dddd ddd dd d HH hh h mm ss tt zzz)
  @format_letters ~c"dfFghHKmMstyz"
  @escapes ~c"'\"\\%"

  @months ~w(January February March April May June July August September October November
             December)
  @days ~w(Monday Tuesday Wednesday Thursday Friday Saturday Sunday)

  @type layout_error :: {:not_supported, {:date_layout, String.t()}}

  @doc "`:ok` when every token of `layout` is one `parse/3` reads."
  @spec check_layout(String.t()) :: :ok | {:error, layout_error()}
  def check_layout(layout) do
    with {:ok, _tokens} <- tokenize(layout, []), do: :ok
  end

  @doc "Reads the trimmed `text` with `layout`, as a UTC time."
  @spec parse(String.t(), String.t(), DateTime.t()) ::
          {:ok, DateTime.t()} | {:error, :invalid_date | layout_error()}
  def parse(text, layout, %DateTime{} = now) do
    with {:ok, tokens} <- tokenize(layout, []),
         true <- is_binary(text) and String.valid?(text),
         {:ok, fields} <- read(tokens, String.trim(text), %{}),
         {:ok, time} <- assemble(fields, now) do
      {:ok, time}
    else
      {:error, {:not_supported, _}} = error -> error
      _failed -> {:error, :invalid_date}
    end
  end

  @doc "A UTC time as the one text `dateparse` writes: ISO 8601, to the second."
  @spec canonical(DateTime.t()) :: String.t()
  def canonical(%DateTime{} = time),
    do:
      time
      |> DateTime.shift_zone!("Etc/UTC")
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()

  @doc """
  Reads a date field's value: the canonical text, all ASCII digits as Unix seconds, and any text
  holding `now` in any letter case as `now`. Anything else is `:error`, which leaves the
  release's publication time unset. Prowlarr's other `FromUnknown` fallbacks go to #1677.
  """
  @spec from_unknown(String.t(), DateTime.t()) :: {:ok, DateTime.t()} | :error
  def from_unknown(text, %DateTime{} = now) when is_binary(text) do
    trimmed = if String.valid?(text), do: String.trim(text), else: ""

    with :error <- from_canonical(trimmed),
         :error <- from_unix(trimmed) do
      if String.contains?(String.downcase(trimmed), "now"), do: {:ok, now}, else: :error
    end
  end

  def from_unknown(_text, _now), do: :error

  defp from_canonical(text) do
    with {:ok, time, 0} <- DateTime.from_iso8601(text),
         true <- canonical(time) == text do
      {:ok, time}
    else
      _other -> :error
    end
  end

  # .NET's `long.TryParse` reads any number of leading zeros and then at most 19 digits, and
  # `DateTime.from_unix/1` refuses a time past the year 9999, far below that. The size guard
  # only spares converting a long run of digits.
  defp from_unix(text) when byte_size(text) >= 1 do
    with true <- text |> :binary.bin_to_list() |> Enum.all?(&(&1 in ?0..?9)),
         significant = String.trim_leading(text, "0"),
         true <- byte_size(significant) <= 19,
         {:ok, time} <- DateTime.from_unix(String.to_integer("0" <> significant)) do
      {:ok, time}
    else
      _other -> :error
    end
  end

  defp from_unix(_text), do: :error

  # Layout tokens: `{:token, "yyyy"}` or `{:literal, codepoint}`.
  defp tokenize("", acc), do: {:ok, Enum.reverse(acc)}

  defp tokenize(<<c, _::binary>> = layout, acc) when c in @format_letters do
    {run, rest} = take_run(layout, c, "")

    if run in @tokens,
      do: tokenize(rest, [{:token, run} | acc]),
      else: {:error, {:not_supported, {:date_layout, run}}}
  end

  defp tokenize(<<c, _::binary>>, _acc) when c in @escapes,
    do: {:error, {:not_supported, {:date_layout, <<c>>}}}

  defp tokenize(<<c::utf8, rest::binary>>, acc),
    do: tokenize(rest, [{:literal, <<c::utf8>>} | acc])

  defp tokenize(_invalid, _acc), do: {:error, {:not_supported, {:date_layout, "invalid"}}}

  defp take_run(<<c, rest::binary>>, c, acc), do: take_run(rest, c, acc <> <<c>>)
  defp take_run(rest, _c, acc), do: {acc, rest}

  # Reads each token in turn; the text must end where the layout does.
  defp read([], "", fields), do: {:ok, fields}
  defp read([], _left, _fields), do: :error

  defp read([{:literal, char} | tokens], text, fields) do
    case text do
      <<^char::binary, rest::binary>> -> read(tokens, rest, fields)
      _other -> :error
    end
  end

  defp read([{:token, token} | tokens], text, fields) do
    with {:ok, field, value, rest} <- read_token(token, text),
         {:ok, fields} <- put(fields, field, value) do
      read(tokens, rest, clock(fields, token))
    end
  end

  # `HH`, `hh` and `h` read one hour field, as .NET's do; `hh` or `h` sets the 12-hour clock.
  defp clock(fields, token) when token in ~w(hh h), do: Map.put(fields, :clock12, true)
  defp clock(fields, _token), do: fields

  defp put(fields, field, value) do
    case Map.fetch(fields, field) do
      :error -> {:ok, Map.put(fields, field, value)}
      {:ok, ^value} -> {:ok, fields}
      {:ok, _other} -> :error
    end
  end

  defp read_token("yyyy", text), do: digits(text, 4, 4, :year)
  defp read_token("MM", text), do: digits(text, 2, 2, :month)
  defp read_token("M", text), do: digits(text, 1, 2, :month)
  defp read_token("dd", text), do: digits(text, 2, 2, :day)
  defp read_token("d", text), do: digits(text, 1, 2, :day)
  defp read_token("HH", text), do: digits(text, 2, 2, :hour)
  defp read_token("hh", text), do: digits(text, 2, 2, :hour)
  defp read_token("h", text), do: digits(text, 1, 2, :hour)
  defp read_token("mm", text), do: digits(text, 2, 2, :minute)
  defp read_token("ss", text), do: digits(text, 2, 2, :second)
  defp read_token("MMMM", text), do: name(text, @months, :month)
  defp read_token("MMM", text), do: name(text, Enum.map(@months, &String.slice(&1, 0, 3)), :month)
  defp read_token("dddd", text), do: name(text, @days, :weekday)
  defp read_token("ddd", text), do: name(text, Enum.map(@days, &String.slice(&1, 0, 3)), :weekday)
  defp read_token("tt", text), do: name(text, ~w(AM PM), :meridiem)
  defp read_token("zzz", text), do: offset(text)

  defp read_token("yy", text) do
    with {:ok, :year, yy, rest} <- digits(text, 2, 2, :year),
         do: {:ok, :year, if(yy <= 49, do: 2000 + yy, else: 1900 + yy), rest}
  end

  # Reads `min` to `max` ASCII digits, as many as there are.
  defp digits(text, min, max, field) do
    {taken, rest} = take_digits(text, max, "")

    if byte_size(taken) >= min,
      do: {:ok, field, String.to_integer(taken), rest},
      else: :error
  end

  defp take_digits(<<d, rest::binary>>, max, acc) when d in ?0..?9 and byte_size(acc) < max,
    do: take_digits(rest, max, acc <> <<d>>)

  defp take_digits(rest, _max, acc), do: {acc, rest}

  # The 1-based position of the first name `text` starts with, in any ASCII letter case.
  defp name(text, names, field) do
    names
    |> Enum.with_index(1)
    |> Enum.find_value(:error, fn {name, index} ->
      with {:ok, rest} <- starts_with_name(text, name), do: {:ok, field, index, rest}
    end)
  end

  defp starts_with_name(text, name) do
    size = byte_size(name)

    with <<head::binary-size(^size), rest::binary>> <- text,
         true <- String.downcase(head, :ascii) == String.downcase(name, :ascii) do
      {:ok, rest}
    else
      _other -> nil
    end
  end

  defp offset(<<sign, rest::binary>>) when sign in [?+, ?-] do
    with {:ok, :h, hours, rest} <- digits(rest, 1, 2, :h),
         rest = String.replace_prefix(rest, ":", ""),
         {:ok, :m, minutes, rest} <- digits(rest, 2, 2, :m),
         true <- minutes <= 59 and hours * 60 + minutes <= 14 * 60 do
      minutes = hours * 60 + minutes
      {:ok, :offset, if(sign == ?+, do: minutes, else: -minutes), rest}
    else
      _bad -> :error
    end
  end

  defp offset(_text), do: :error

  defp assemble(fields, now) do
    with {:ok, {year, month, day}} <- date_parts(fields, now),
         {:ok, hour} <- hour(fields),
         {:ok, date} <- Date.new(year, month, day),
         true <- year >= 1,
         :ok <- weekday(fields, date),
         {:ok, time} <- Time.new(hour, Map.get(fields, :minute, 0), Map.get(fields, :second, 0)),
         {:ok, naive} <- NaiveDateTime.new(date, time) do
      utc = DateTime.from_naive!(naive, "Etc/UTC")
      in_range(DateTime.add(utc, -Map.get(fields, :offset, 0) * 60, :second))
    else
      _invalid -> :error
    end
  end

  defp date_parts(fields, now) do
    case Map.take(fields, [:year, :month, :day]) do
      parts when map_size(parts) == 0 ->
        {:ok, {now.year, now.month, now.day}}

      parts ->
        {:ok,
         {Map.get(parts, :year, now.year), Map.get(parts, :month, 1), Map.get(parts, :day, 1)}}
    end
  end

  defp in_range(%DateTime{year: year} = time) when year in 1..9999, do: {:ok, time}
  defp in_range(_out_of_range), do: :error

  defp hour(%{clock12: true} = fields),
    do: hour12(Map.get(fields, :hour), Map.get(fields, :meridiem, 1))

  defp hour(fields), do: hour24(Map.get(fields, :hour, 0), Map.get(fields, :meridiem))

  defp hour12(hour, _meridiem) when hour > 12, do: :error
  defp hour12(12, 1), do: {:ok, 0}
  defp hour12(hour, 1), do: {:ok, hour}
  defp hour12(12, 2), do: {:ok, 12}
  defp hour12(hour, 2), do: {:ok, hour + 12}

  defp hour24(hour, nil), do: {:ok, hour}
  defp hour24(hour, 1) when hour < 12, do: {:ok, hour}
  defp hour24(hour, 2) when hour >= 12, do: {:ok, hour}
  defp hour24(_hour, _inconsistent), do: :error

  defp weekday(%{weekday: weekday}, date),
    do: if(Date.day_of_week(date) == weekday, do: :ok, else: :error)

  defp weekday(_fields, _date), do: :ok
end
