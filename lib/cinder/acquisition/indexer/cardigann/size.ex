defmodule Cinder.Acquisition.Indexer.Cardigann.Size do
  @moduledoc """
  Reads a Cardigann `size` field into bytes as Prowlarr's `ParseUtil.GetBytes` reads it (#1671,
  read at Prowlarr `b0b5774`):

  - the unit is every letter of the text, joined, with each lowercase `i` taken out and then
    lowercased: `GiB` reads `gb`, `KIB` reads `kib`. It names kilobytes when it holds `kb`, else
    megabytes when it holds `mb`, else gigabytes when it holds `gb`, else terabytes when it holds
    `tb`, each a power of 1,024; any other unit, none included, is bytes. So `700 MB` and
    `700 MiB` are both 734,003,200 bytes, `1.2 GB` 1,288,490,188, and `700 Mo` (French) 700;
  - the number is every ASCII digit, `.` and `,` of the text, in order, with each `,` read as `.`;
    when that leaves more than one `.`, only the last is the decimal point. `1,4 GiB` is 1.4 GiB
    and `1.234.567` is 1234.567;
  - the value is the number times the unit, as a 64-bit float, cut to an integer toward zero.

  `bytes/1` answers nil where Prowlarr throws (no digit, as in `n/a`, or a lone `.`), never 0,
  which a size band would read as a known size; and nil for a value past a signed 64-bit integer,
  a whole part of more than 20 digits after its leading zeros included, before any arithmetic.
  """

  @kib 1024.0
  @max_int64 9_223_372_036_854_775_807
  # More whole digits than this is past a signed 64-bit integer in any unit.
  @max_whole_digits 20

  @doc "The bytes `text` names, or nil; see the moduledoc."
  @spec bytes(String.t()) :: non_neg_integer() | nil
  def bytes(text) when is_binary(text) do
    case number(text) do
      {:ok, number} ->
        value = number * multiplier(unit(text))
        if value <= @max_int64, do: trunc(value)

      :error ->
        nil
    end
  end

  def bytes(_text), do: nil

  defp unit(text) do
    ~r/\p{L}/u
    |> Regex.scan(text)
    |> Enum.join()
    |> String.replace("i", "")
    |> String.downcase()
  end

  defp multiplier(unit) do
    cond do
      String.contains?(unit, "kb") -> @kib
      String.contains?(unit, "mb") -> @kib * @kib
      String.contains?(unit, "gb") -> @kib * @kib * @kib
      String.contains?(unit, "tb") -> @kib * @kib * @kib * @kib
      true -> 1.0
    end
  end

  defp number(text) do
    kept = for <<c <- text>>, c in ?0..?9 or c in [?., ?,], into: "", do: <<c>>

    case kept |> String.replace(",", ".") |> String.split(".") do
      [""] -> :error
      [whole] -> float(whole, "")
      parts -> float(Enum.join(Enum.drop(parts, -1)), List.last(parts))
    end
  end

  defp float("", ""), do: :error

  defp float(whole, fraction) do
    whole = String.trim_leading(whole, "0")

    if byte_size(whole) > @max_whole_digits do
      :error
    else
      {value, ""} = Float.parse("0" <> whole <> "." <> fraction <> "0")
      {:ok, value}
    end
  end
end
