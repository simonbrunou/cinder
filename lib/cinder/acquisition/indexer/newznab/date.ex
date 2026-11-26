defmodule Cinder.Acquisition.Indexer.Newznab.Date do
  @moduledoc """
  Reads an RSS `pubDate`, an RFC 822 date as RFC 2822 writes it, into a UTC `DateTime` (#1653):
  an optional day name and comma, the day of the month in one or two digits, an English month
  abbreviation in any case, a four-digit year, `HH:MM` with optional `:SS`, then a numeric offset
  (`+0100`, `-0500`) or `GMT`, `UTC`, `UT` or `Z`. Any other text, another zone name (`EST`), and
  a date or time that does not exist, read as nil. The day name is not checked against the date.
  `parse/1` never raises.
  """

  @months ~w(jan feb mar apr may jun jul aug sep oct nov dec)

  @pattern ~r/\A(?:[A-Za-z]{3},\s*)?(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4})\s+(\d{2}):(\d{2})(?::(\d{2}))?\s+([+-]\d{4}|GMT|UTC|UT|Z)\z/

  @doc "Parses `text`; see the moduledoc."
  @spec parse(term()) :: DateTime.t() | nil
  def parse(text) when is_binary(text) do
    with [_match, day, month, year, hour, minute, second, zone] <-
           Regex.run(@pattern, String.trim(text)),
         month when is_integer(month) <- month(month),
         {:ok, date} <- Date.new(int(year), month, int(day)),
         {:ok, time} <- Time.new(int(hour), int(minute), seconds(second)),
         {:ok, datetime} <- DateTime.new(date, time) do
      DateTime.add(datetime, -offset_seconds(zone), :second)
    else
      _invalid -> nil
    end
  end

  def parse(_text), do: nil

  defp month(name) do
    case Enum.find_index(@months, &(&1 == String.downcase(name))) do
      nil -> nil
      index -> index + 1
    end
  end

  defp int(digits), do: String.to_integer(digits)

  defp seconds(""), do: 0
  defp seconds(digits), do: int(digits)

  defp offset_seconds(<<sign, hours::binary-size(2), minutes::binary-size(2)>>)
       when sign in [?+, ?-] do
    seconds = int(hours) * 3600 + int(minutes) * 60
    if sign == ?+, do: seconds, else: -seconds
  end

  defp offset_seconds(_zone), do: 0
end
