defmodule Cinder.Acquisition.Indexer.Cardigann.DotnetDateTest do
  # Each row ran in `dotnet fsi` (.NET 8.0.427, TZ=UTC, `DateTime.TryParseExact` with the
  # invariant culture and `DateTimeStyles.None`) on 2026-11-25, on the text as Prowlarr's
  # `ParseDateTimeGoLang` hands it over: trimmed first, so a row with spaces around the date ran
  # without them. A layout with no offset reads as UTC here, where .NET returns
  # kind=Unspecified (the issue's choice).
  use ExUnit.Case, async: true

  alias Cinder.Acquisition.Indexer.Cardigann.DotnetDate

  @now ~U[2026-11-25 19:45:30Z]

  defp parse(text, layout), do: DotnetDate.parse(text, layout, @now)

  describe "parse/3 reads what .NET reads" do
    for {text, layout, expected} <- [
          {"2026-11-25 14:02 +01:00", "yyyy-MM-dd HH:mm zzz", ~U[2026-11-25 13:02:00Z]},
          {"25/11/2026", "dd/MM/yyyy", ~U[2026-11-25 00:00:00Z]},
          {"  25/11/2026 ", "dd/MM/yyyy", ~U[2026-11-25 00:00:00Z]},
          {"11/25 14:02", "MM/dd HH:mm", ~U[2026-11-25 14:02:00Z]},
          {"14:02 +00:00", "HH:mm zzz", ~U[2026-11-25 14:02:00Z]},
          {"00:30 +01:00", "HH:mm zzz", ~U[2026-11-24 23:30:00Z]},
          {"5 Nov 99", "d MMM yy", ~U[1999-11-05 00:00:00Z]},
          {"25 Nov 99", "d MMM yy", ~U[1999-11-25 00:00:00Z]},
          {"5 Nov 26", "d MMM yy", ~U[2026-11-05 00:00:00Z]},
          {"5 Nov 49", "d MMM yy", ~U[2049-11-05 00:00:00Z]},
          {"5 Nov 50", "d MMM yy", ~U[1950-11-05 00:00:00Z]},
          {"5 Nov 00", "d MMM yy", ~U[2000-11-05 00:00:00Z]},
          {"nov 25 2026, 14:02", "MMM dd yyyy, HH:mm", ~U[2026-11-25 14:02:00Z]},
          {"NOV 25 2026, 14:02", "MMM dd yyyy, HH:mm", ~U[2026-11-25 14:02:00Z]},
          {"5 NOVEMBER 2026", "d MMMM yyyy", ~U[2026-11-05 00:00:00Z]},
          {"Wed 25 Nov 2026", "ddd dd MMM yyyy", ~U[2026-11-25 00:00:00Z]},
          {"wednesday 25 Nov 2026", "dddd dd MMM yyyy", ~U[2026-11-25 00:00:00Z]},
          {"Wed 25 Nov", "ddd dd MMM", ~U[2026-11-25 00:00:00Z]},
          {"Wed 14:02", "ddd HH:mm", ~U[2026-11-25 14:02:00Z]},
          {"2026-11-25T14:02:03", "yyyy-MM-ddTHH:mm:ss", ~U[2026-11-25 14:02:03Z]},
          {"2026-11-25  14:02", "yyyy-MM-dd  HH:mm", ~U[2026-11-25 14:02:00Z]},
          {"25 nov. 2026", "dd MMM. yyyy", ~U[2026-11-25 00:00:00Z]},
          {"2028-02-29", "yyyy-MM-dd", ~U[2028-02-29 00:00:00Z]},
          {"0001-01-01", "yyyy-MM-dd", ~U[0001-01-01 00:00:00Z]},
          # 12-hour clock: 12 without tt is 0, AM and PM in any case.
          {"12:00", "hh:mm", ~U[2026-11-25 00:00:00Z]},
          {"03 03 AM", "HH hh tt", ~U[2026-11-25 03:00:00Z]},
          {"03 03", "HH hh", ~U[2026-11-25 03:00:00Z]},
          {"00:30", "hh:mm", ~U[2026-11-25 00:30:00Z]},
          {"12:30 AM", "hh:mm tt", ~U[2026-11-25 00:30:00Z]},
          {"12:30 PM", "hh:mm tt", ~U[2026-11-25 12:30:00Z]},
          {"01:30 PM", "hh:mm tt", ~U[2026-11-25 13:30:00Z]},
          {"1:30 pm", "h:mm tt", ~U[2026-11-25 13:30:00Z]},
          {"2026-11-25 2:05 Pm", "yyyy-MM-dd h:mm tt", ~U[2026-11-25 14:05:00Z]},
          {"13:00 PM", "HH:mm tt", ~U[2026-11-25 13:00:00Z]},
          # A missing year takes now's; a missing month or day is 1 once any date part is there.
          {"2026", "yyyy", ~U[2026-01-01 00:00:00Z]},
          {"11/2026", "MM/yyyy", ~U[2026-11-01 00:00:00Z]},
          {"25 14:02", "dd HH:mm", ~U[2026-01-25 14:02:00Z]},
          {"Nov 14:02", "MMM HH:mm", ~U[2026-11-01 14:02:00Z]},
          # zzz: one or two hour digits, an optional colon, two minute digits, at most 14:00.
          {"2026-11-25 14:02 +14:00", "yyyy-MM-dd HH:mm zzz", ~U[2026-11-25 00:02:00Z]},
          {"2026-11-25 14:02 -14:00", "yyyy-MM-dd HH:mm zzz", ~U[2026-11-26 04:02:00Z]},
          {"2026-11-25 14:02 +01:30", "yyyy-MM-dd HH:mm zzz", ~U[2026-11-25 12:32:00Z]},
          {"2026-11-25 14:02 -00:00", "yyyy-MM-dd HH:mm zzz", ~U[2026-11-25 14:02:00Z]},
          {"2026-11-25 14:02 +1:00", "yyyy-MM-dd HH:mm zzz", ~U[2026-11-25 13:02:00Z]},
          {"2026-11-25 14:02 -1:30", "yyyy-MM-dd HH:mm zzz", ~U[2026-11-25 15:32:00Z]},
          {"2026-11-25 14:02 +0100", "yyyy-MM-dd HH:mm zzz", ~U[2026-11-25 13:02:00Z]},
          {"2026-11-25 14:02 +1400", "yyyy-MM-dd HH:mm zzz", ~U[2026-11-25 00:02:00Z]}
        ] do
      test "#{inspect(text)} with #{inspect(layout)}" do
        assert parse(unquote(text), unquote(layout)) == {:ok, unquote(Macro.escape(expected))}
      end
    end
  end

  describe "parse/3 refuses what .NET refuses" do
    for {text, layout} <- [
          {"5/11/2026", "dd/MM/yyyy"},
          {"25/11/26", "dd/MM/yyyy"},
          {"25-11-2026", "dd/MM/yyyy"},
          {"026-11-25", "yyyy-MM-dd"},
          {"20260-11-25", "yyyy-MM-dd"},
          {"2026-1-25", "yyyy-MM-dd"},
          {"005/11/2026", "d/MM/yyyy"},
          {"5/011/2026", "d/M/yyyy"},
          {"5 Nov 2026", "d MMM yy"},
          {"2026-11-25 14:02 +01", "yyyy-MM-dd HH:mm zzz"},
          {"2026-11-25 14:02", "yyyy-MM-dd HH:mm zzz"},
          {"2026-11-25 14:02 +1", "yyyy-MM-dd HH:mm zzz"},
          {"2026-11-25 14:02 +100", "yyyy-MM-dd HH:mm zzz"},
          {"2026-11-25 14:02 +01:0", "yyyy-MM-dd HH:mm zzz"},
          {"2026-11-25 14:02 +14:30", "yyyy-MM-dd HH:mm zzz"},
          {"2026-11-25 14:02 +15:00", "yyyy-MM-dd HH:mm zzz"},
          {"2026-11-25 14:02 +01:60", "yyyy-MM-dd HH:mm zzz"},
          {"2026-11-25 14:02 +01:00:00", "yyyy-MM-dd HH:mm zzz"},
          {"2026-11-25 14:02 +001:00", "yyyy-MM-dd HH:mm zzz"},
          {"2026-11-25 14:02 Z", "yyyy-MM-dd HH:mm zzz"},
          {"Mon, 25 Nov 2026 14:02:03 +00:00", "ddd, dd MMM yyyy HH:mm:ss zzz"},
          {"Tue 25 Nov", "ddd dd MMM"},
          {"Tue 14:02", "ddd HH:mm"},
          {"Wednesday 25 Nov 2026", "ddd dd MMM yyyy"},
          {"Wed 25 Nov 2026", "dddd dd MMM yyyy"},
          {"5 Sept 2026", "d MMM yyyy"},
          {"5 September 2026", "d MMM yyyy"},
          {"5 Nov 2026", "d MMMM yyyy"},
          {"5 mai 2026", "d MMM yyyy"},
          {"2026-02-30", "yyyy-MM-dd"},
          {"2026-02-29", "yyyy-MM-dd"},
          {"0000-01-01", "yyyy-MM-dd"},
          {"00/11/2026", "dd/MM/yyyy"},
          {"0/11/2026", "d/MM/yyyy"},
          {"25/00/2026", "dd/MM/yyyy"},
          {"25/13/2026", "dd/MM/yyyy"},
          {"2026-11-25 24:00", "yyyy-MM-dd HH:mm"},
          {"2026-11-25 14:60", "yyyy-MM-dd HH:mm"},
          {"2026-11-25 14:02:60", "yyyy-MM-dd HH:mm:ss"},
          {"2026-11-25 14:5", "yyyy-MM-dd HH:mm"},
          {"13:00", "hh:mm"},
          {"13:00 AM", "HH:mm tt"},
          {"01:00 PM", "HH:mm tt"},
          # HH and hh read one hour field: the digits must agree.
          {"16 03 PM", "HH hh tt"},
          {"15 03 PM", "HH hh tt"},
          {"15 03", "HH hh"},
          {"12 00", "HH hh"},
          {"00 12", "HH hh"},
          {"2026-11-25 14:02 A", "yyyy-MM-dd HH:mm tt"},
          {"2026-11-25 2:02 a.m.", "yyyy-MM-dd h:mm tt"},
          {"2026-11-25t14:02:03", "yyyy-MM-ddTHH:mm:ss"},
          {"2026-11-25 14:02", "yyyy-MM-dd HH:mm "},
          {"2026-11-25 14:02", "yyyy-MM-dd  HH:mm"},
          {"2026-11-25\t14:02", "yyyy-MM-dd HH:mm"},
          {"2026-11-25", "yyyy/MM/dd"},
          {"２０２６-11-25", "yyyy-MM-dd"},
          {"", "yyyy-MM-dd"},
          {<<0xFF>>, "yyyy"}
        ] do
      test "#{inspect(text)} with #{inspect(layout)}" do
        assert parse(unquote(text), unquote(layout)) == {:error, :invalid_date}
      end
    end

    test "a time zzz shifts out of the years 1 to 9999 fails" do
      # .NET fails past 9999 too. Before year 1 it returns a wrong time instead:
      # `0001-01-01 00:00 +01:00` gives 0001-01-01 23:00 UTC.
      assert parse("9999-12-31 23:00 -01:00", "yyyy-MM-dd HH:mm zzz") == {:error, :invalid_date}
      assert parse("0001-01-01 00:00 +01:00", "yyyy-MM-dd HH:mm zzz") == {:error, :invalid_date}

      assert parse("0001-01-01 01:00 +01:00", "yyyy-MM-dd HH:mm zzz") ==
               {:ok, ~U[0001-01-01 00:00:00Z]}
    end

    test "a field read twice with two values fails, and with one value passes" do
      assert parse("2026 2026", "yyyy yyyy") == {:ok, ~U[2026-01-01 00:00:00Z]}
      assert parse("2026 2027", "yyyy yyyy") == {:error, :invalid_date}
    end
  end

  describe "a layout token outside the supported set" do
    test "is a not-supported tag naming the token" do
      for {layout, token} <- [
            {"yyyy-MM-dd HH:mm:ss.fff", "fff"},
            {"yyyy-MM-dd h:mm t", "t"},
            {"yyyy-MM-dd HH:mm z", "z"},
            {"yyy", "yyy"},
            {"yyyy-MM-dd HH'h'mm", "'"},
            {"yyyy\\-MM", "\\"},
            {"%d", "%"},
            {"yyyy K", "K"},
            {"yyyy-MM-dd H:mm", "H"}
          ] do
        assert DotnetDate.check_layout(layout) ==
                 {:error, {:not_supported, {:date_layout, token}}}

        assert parse("2026", layout) == {:error, {:not_supported, {:date_layout, token}}}
      end
    end

    test "a supported layout checks :ok" do
      assert DotnetDate.check_layout("dddd, dd MMMM yyyy hh:mm:ss tt zzz") == :ok
      assert DotnetDate.check_layout("d/M/yy h:mm") == :ok
    end
  end

  describe "canonical/1 and from_unknown/2" do
    test "canonical text is ISO 8601 in UTC" do
      assert DotnetDate.canonical(~U[2026-11-25 13:02:00Z]) == "2026-11-25T13:02:00Z"
    end

    test "reads the canonical text back" do
      assert DotnetDate.from_unknown("2026-11-25T13:02:00Z", @now) ==
               {:ok, ~U[2026-11-25 13:02:00Z]}

      assert DotnetDate.from_unknown(" 2026-11-25T13:02:00Z ", @now) ==
               {:ok, ~U[2026-11-25 13:02:00Z]}
    end

    test "reads all digits as Unix seconds" do
      assert DotnetDate.from_unknown("1764075720", @now) == {:ok, ~U[2025-11-25 13:02:00Z]}
      assert DotnetDate.from_unknown("0", @now) == {:ok, ~U[1970-01-01 00:00:00Z]}
      # .NET's long.TryParse reads leading zeros past 19 digits: 20 zeros give 0.
      zeros = String.duplicate("0", 20)
      assert DotnetDate.from_unknown(zeros, @now) == {:ok, ~U[1970-01-01 00:00:00Z]}

      assert DotnetDate.from_unknown(zeros <> "1764075720", @now) ==
               {:ok, ~U[2025-11-25 13:02:00Z]}
    end

    test "reads any text holding now as now" do
      assert DotnetDate.from_unknown("Now", @now) == {:ok, @now}
      assert DotnetDate.from_unknown("just NOW", @now) == {:ok, @now}
    end

    test "anything else is :error" do
      for text <- [
            "2026-11-25T13:02:00+01:00",
            "2026-11-25 13:02:00Z",
            "2026-11-25T13:02:00.5Z",
            "2 hours ago",
            "yesterday",
            "",
            "12a",
            "99999999999999999999",
            String.duplicate("9", 19),
            <<0xFF>>
          ] do
        cell = {text, DotnetDate.from_unknown(text, @now)}
        assert cell == {text, :error}
      end
    end
  end
end
