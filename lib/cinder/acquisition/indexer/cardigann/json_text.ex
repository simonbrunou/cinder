defmodule Cinder.Acquisition.Indexer.Cardigann.JsonText do
  @moduledoc ~S"""
  The text of a JSON value as Prowlarr's Newtonsoft.Json 13.0.4 gives it (#1678), for a value
  `Jason.decode/2` read with `objects: :ordered_objects`. JSON definitions are written against
  that text: `bitporn.yml` keys `case` on `True` and `False`, and the UNIT3D definitions parse a
  date with the layout `MM/dd/yyyy HH:mm:ss zzz`. Pure.

  Each rule below was read from a run of Newtonsoft.Json 13.0.4 on .NET 8 under the invariant
  culture and `TZ=UTC` (#1678's PR), as Prowlarr runs in its container:

  - `true` and `false` read `True` and `False`, and `null` reads nothing;
  - an integer reads its digits;
  - a fraction reads the shortest digits that read back to the same double, in fixed notation
    when its decimal exponent is above -5 and below 17 (`0.0001`, `1000000000000000`,
    `12345678901234568`) and as `1E-05`, `1.5E-07` or `1E+17` otherwise. A whole number has no
    point: `1.0` reads `1`, `-0.0` reads `-0`;
  - a string that Newtonsoft reads as a date reads `MM/dd/yyyy HH:mm:ss`: an ISO 8601 date and
    time with an upper-case `T`, seconds, at most 7 fraction digits (dropped), and `Z`, `z`, an
    offset `+hh:mm`, `+hhmm` or `+hh` or no zone; or `/Date(<milliseconds>)/`, an offset after
    the milliseconds ignored. A time with a zone is shown in UTC, and `24:00:00` is the next
    day's midnight. Any other string, `2026-02-20 18:17:51` or `2026-13-20T00:00:00Z` included,
    reads as written.

  `string_value/1` is Newtonsoft's `Value<string>()`: it fails on an object, an array and an
  integer outside the signed 64-bit range. `text/1` is `JToken.ToString()`: an object or an
  array reads as indented JSON, two spaces per level, `"key": value`, an empty one as `{}` or
  `[]`, a fraction there with `.0` added when its text has neither a point nor an exponent.
  Inside that JSON a string keeps its written form, a date included, where Newtonsoft writes the
  date again in ISO form; and only `"`, `\` and control characters are escaped.
  """

  @int64_min -9_223_372_036_854_775_808
  @int64_max 9_223_372_036_854_775_807

  @iso ~r/\A(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,7}))?(?:([Zz])|([+-])(\d{2})(?::?(\d{2}))?)?\z/
  @ms_date ~r/\A\/Date\((-?\d{1,19})(?:[+-]\d{4})?\)\/\z/

  @doc "`Value<string>()`: the value's text, nil for `null`, `:error` where Newtonsoft throws."
  @spec string_value(term()) :: String.t() | nil | :error
  def string_value(nil), do: nil
  def string_value(%Jason.OrderedObject{}), do: :error
  def string_value(list) when is_list(list), do: :error

  def string_value(integer) when is_integer(integer) and integer not in @int64_min..@int64_max,
    do: :error

  def string_value(value), do: text(value)

  @doc "`JToken.ToString()`: the value's text, an object or an array as indented JSON."
  @spec text(term()) :: String.t()
  def text(nil), do: ""
  def text(true), do: "True"
  def text(false), do: "False"
  def text(integer) when is_integer(integer), do: Integer.to_string(integer)
  def text(float) when is_float(float), do: float_text(float)
  def text(string) when is_binary(string), do: date_text(string) || string
  def text(value), do: value |> indented(0) |> IO.iodata_to_binary()

  @doc """
  The texts of `value`'s children, as `jsonjoinarray` enumerates a token: each item of an array,
  each property of an object as `"key": value`, and none for any other value.
  """
  @spec items(term()) :: [String.t()]
  def items(list) when is_list(list), do: Enum.map(list, &text/1)

  def items(%Jason.OrderedObject{values: pairs}),
    do:
      Enum.map(pairs, fn {key, value} ->
        IO.iodata_to_binary([quoted(key), ": ", indented(value, 0)])
      end)

  def items(_value), do: []

  @doc """
  `items/1` joined with `separator`, or `:too_large` when that text would pass `max_bytes`. The
  size is counted before any text is built, so a value whose indented text is far larger than
  its JSON, such as a million items 62 arrays deep (#1678), builds nothing.
  """
  @spec join(term(), String.t(), non_neg_integer()) :: {:ok, String.t()} | :too_large
  def join(value, separator, max_bytes) do
    if joined_size(value, byte_size(separator)) > max_bytes,
      do: :too_large,
      else: {:ok, value |> items() |> Enum.join(separator)}
  end

  # The byte size of `items(value)` joined with a separator of `separator_bytes`, item by item
  # as `items/1` builds it.
  defp joined_size(list, separator_bytes) when is_list(list),
    do: sum(list, &item_size/1) + separators(length(list), separator_bytes)

  defp joined_size(%Jason.OrderedObject{values: pairs}, separator_bytes),
    do:
      sum(pairs, fn {key, value} -> quoted_size(key) + 2 + indented_size(value, 0) end) +
        separators(length(pairs), separator_bytes)

  defp joined_size(_value, _separator_bytes), do: 0

  defp item_size(value) when is_list(value) or is_struct(value, Jason.OrderedObject),
    do: indented_size(value, 0)

  defp item_size(value), do: byte_size(text(value))

  defp separators(0, _separator_bytes), do: 0
  defp separators(count, separator_bytes), do: (count - 1) * separator_bytes

  defp sum(enumerable, size), do: Enum.reduce(enumerable, 0, &(size.(&1) + &2))

  # --- numbers ---

  @doc false
  # A double as .NET's shortest round-trip form writes it; public for its test.
  @spec float_text(float()) :: String.t()
  def float_text(float) do
    {sign, digits, point} = shortest(float)

    cond do
      digits == "" -> sign <> "0"
      point - 1 > -5 and point - 1 < 17 -> sign <> fixed(digits, point)
      true -> sign <> scientific(digits, point - 1)
    end
  end

  # The shortest digits of `float`, without leading or trailing zeros, and the position of the
  # decimal point counted from the first digit.
  defp shortest(float) do
    # `Regex.run/2` leaves out the groups after the last one that matched.
    [_whole, sign, int, frac, exp] =
      ~r/\A(-?)(\d+)(?:\.(\d+))?(?:e([+-]?\d+))?\z/
      |> Regex.run(Float.to_string(float))
      |> pad(5)

    exponent = if exp == "", do: 0, else: String.to_integer(exp)
    raw = int <> frac
    leading = byte_size(raw) - byte_size(String.trim_leading(raw, "0"))
    digits = raw |> String.trim_leading("0") |> String.trim_trailing("0")
    {sign, digits, byte_size(int) + exponent - leading}
  end

  defp pad(list, n), do: list ++ List.duplicate("", n - length(list))

  defp fixed(digits, point) when point <= 0, do: "0." <> String.duplicate("0", -point) <> digits

  defp fixed(digits, point) when point >= byte_size(digits),
    do: digits <> String.duplicate("0", point - byte_size(digits))

  defp fixed(digits, point),
    do:
      binary_part(digits, 0, point) <>
        "." <> binary_part(digits, point, byte_size(digits) - point)

  defp scientific(<<first, rest::binary>>, exponent) do
    mantissa = if rest == "", do: <<first>>, else: <<first, ?., rest::binary>>
    sign = if exponent < 0, do: "-", else: "+"
    mantissa <> "E" <> sign <> String.pad_leading(Integer.to_string(abs(exponent)), 2, "0")
  end

  # --- dates ---

  @doc false
  # The date text Newtonsoft gives `string`, or nil for a string it keeps; public for its test.
  @spec date_text(String.t()) :: String.t() | nil
  def date_text(string) do
    cond do
      match = Regex.run(@iso, string) -> iso_date(match)
      match = Regex.run(@ms_date, string) -> ms_date(match)
      true -> nil
    end
  end

  defp iso_date([_whole, y, mo, d, h, mi, s | zone]) do
    [y, mo, d, h, mi, s] = Enum.map([y, mo, d, h, mi, s], &String.to_integer/1)

    with {:ok, date} <- Date.new(y, mo, d),
         {:ok, naive} <- naive(date, h, mi, s, Enum.at(zone, 0, "")),
         {:ok, utc} <- in_utc(naive, zone) do
      format(utc)
    else
      _invalid -> nil
    end
  end

  # `24:00:00` with no fraction is the next day's midnight, as .NET reads it.
  defp naive(date, 24, 0, 0, ""), do: {:ok, NaiveDateTime.new!(Date.add(date, 1), ~T[00:00:00])}
  defp naive(_date, 24, _mi, _s, _fraction), do: :error

  defp naive(date, h, mi, s, _fraction) do
    case Time.new(h, mi, s) do
      {:ok, time} -> {:ok, NaiveDateTime.new!(date, time)}
      error -> error
    end
  end

  defp in_utc(naive, [_fraction, _z, sign, hh | rest]) when sign in ["+", "-"] do
    mm =
      case rest do
        [text] when text != "" -> text
        _none -> "0"
      end

    minutes = String.to_integer(hh) * 60 + String.to_integer(mm)
    offset = if sign == "+", do: minutes, else: -minutes
    {:ok, NaiveDateTime.add(naive, -offset * 60, :second)}
  end

  defp in_utc(naive, _zone), do: {:ok, naive}

  defp ms_date([_whole, ms]) do
    case DateTime.from_unix(String.to_integer(ms), :millisecond) do
      {:ok, time} -> time |> DateTime.to_naive() |> format()
      {:error, _reason} -> nil
    end
  end

  defp format(%NaiveDateTime{} = time) when time.year in 1..9999,
    do: Calendar.strftime(time, "%m/%d/%Y %H:%M:%S")

  defp format(_time), do: nil

  # --- indented JSON ---

  defp indented(%Jason.OrderedObject{values: []}, _level), do: "{}"

  defp indented(%Jason.OrderedObject{values: pairs}, level) do
    inner = pad_spaces(level + 1)

    items =
      Enum.map(pairs, fn {key, value} ->
        [inner, quoted(key), ": ", indented(value, level + 1)]
      end)

    ["{\n", Enum.intersperse(items, ",\n"), "\n", pad_spaces(level), "}"]
  end

  defp indented([], _level), do: "[]"

  defp indented(list, level) when is_list(list) do
    inner = pad_spaces(level + 1)
    items = Enum.map(list, &[inner, indented(&1, level + 1)])
    ["[\n", Enum.intersperse(items, ",\n"), "\n", pad_spaces(level), "]"]
  end

  defp indented(nil, _level), do: "null"
  defp indented(true, _level), do: "true"
  defp indented(false, _level), do: "false"
  defp indented(integer, _level) when is_integer(integer), do: Integer.to_string(integer)
  defp indented(string, _level) when is_binary(string), do: quoted(string)

  defp indented(float, _level) when is_float(float) do
    text = float_text(float)
    if String.contains?(text, [".", "E"]), do: text, else: text <> ".0"
  end

  # The byte size of `indented(value, level)`, clause by clause, without building it.
  defp indented_size(%Jason.OrderedObject{values: []}, _level), do: 2

  defp indented_size(%Jason.OrderedObject{values: pairs}, level) do
    inner = 2 * (level + 1)

    items =
      sum(pairs, fn {key, value} ->
        inner + quoted_size(key) + 2 + indented_size(value, level + 1)
      end)

    2 + items + separators(length(pairs), 2) + 1 + 2 * level + 1
  end

  defp indented_size([], _level), do: 2

  defp indented_size(list, level) when is_list(list) do
    inner = 2 * (level + 1)
    items = sum(list, &(inner + indented_size(&1, level + 1)))
    2 + items + separators(length(list), 2) + 1 + 2 * level + 1
  end

  defp indented_size(scalar, level), do: IO.iodata_length(indented(scalar, level))

  defp quoted_size(string), do: IO.iodata_length(quoted(string))

  defp pad_spaces(level), do: String.duplicate("  ", level)

  defp quoted(string), do: [?", escape(string), ?"]

  defp escape(string) do
    for <<char::utf8 <- String.replace_invalid(string)>>, into: "", do: escaped(char)
  end

  @escapes %{
    ?" => "\\\"",
    ?\\ => "\\\\",
    ?\b => "\\b",
    ?\t => "\\t",
    ?\n => "\\n",
    ?\f => "\\f",
    ?\r => "\\r"
  }

  defp escaped(char) when is_map_key(@escapes, char), do: Map.fetch!(@escapes, char)

  defp escaped(char) when char < 0x20,
    do: "\\u" <> String.pad_leading(Integer.to_string(char, 16), 4, "0")

  defp escaped(char), do: <<char::utf8>>
end
