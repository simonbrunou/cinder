defmodule Cinder.Acquisition.Indexer.Cardigann.DotnetDateTest do
  # Each row ran in `dotnet fsi` (.NET 8.0.427, TZ=UTC, `DateTime.TryParseExact` with the
  # invariant culture and `DateTimeStyles.None`) on 2026-11-25, on the text as Prowlarr's
  # `ParseDateTimeGoLang` hands it over: trimmed first, so a row with spaces around the date ran
  # without them. A layout with no offset reads as UTC here, where .NET returns
  # kind=Unspecified (the issue's choice).
  use ExUnit.Case, async: true

  alias Cinder.Acquisition.Indexer
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

  # The accept rows from_unknown/2 read before #1802, kept apart so a run at that base passes.
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

    # The other texts this test once refused, such as `yesterday` and `2 hours ago`, read now
    # (#1802): DotnetDateFromUnknownTest holds their .NET rows.
    test "is :error where .NET throws" do
      for text <- [
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

  describe "from_time_ago/2 reads what Prowlarr's FromTimeAgo reads" do
    # Each row ran in `dotnet fsi` (.NET 8.0.427) on 2026-11-26, through Prowlarr b0b5774's
    # `DateTimeUtil.FromTimeAgo` with its `ParseUtil.CoerceFloat`, from 2026-11-26 12:00 UTC.
    # The number is the span .NET subtracts, in 100-nanosecond ticks.
    @ago_now ~U[2026-11-26 12:00:00Z]

    for {text, ticks} <- [
          {"2 hours ago", 72_000_000_000},
          {"1 day, 3 hours ago", 972_000_000_000},
          {"1h30m", 54_000_000_000},
          {"5 mins ago", 3_000_000_000},
          {"Just NOW", 0},
          {"known", 0},
          {"now 5 days", 0},
          {"3 weeks", 18_144_000_000_000},
          {"2 months", 51_840_000_000_000},
          {"1 year", 315_360_000_000_000},
          {"1.5 days", 1_296_000_000_000},
          {"1,5 days", 12_960_000_000_000},
          {"foo ago", 0},
          {"", 0},
          {".", 0},
          {"2 days ago.", 1_728_000_000_000},
          {"1.2.3 hours", 442_800_006_866},
          {"1.2.3.4 h", 4_442_400_054_931},
          {"1..5 hours", 54_000_000_000},
          {"1.5.h", 540_000_000_000},
          {"5. days", 4_320_000_000_000},
          {".5 days", 432_000_000_000},
          {"10 s", 100_000_000},
          {"3 hrs", 108_000_000_000},
          {"4 wk", 24_192_000_000_000},
          {"2 mo", 51_840_000_000_000},
          {"1 y", 315_360_000_000_000},
          {"2 d", 1_728_000_000_000},
          {"7 m", 4_200_000_000},
          {"1 h", 36_000_000_000},
          {"1 w", 6_048_000_000_000},
          {"2 Hours", 72_000_000_000},
          {"5 DAYS", 4_320_000_000_000},
          {"1 day 2", 864_000_000_000},
          {"2 3 hours", 108_000_000_000},
          {"123456789 seconds", 1_234_567_920_000_000},
          {"16777217 seconds", 167_772_160_000_000},
          {"0.1 seconds", 1_000_000},
          {"1.000000059604644775390625 seconds", 10_000_000},
          {"1.000000059604644775390625001 seconds", 10_000_001},
          {"0.00000000000000000000000000000000000000000001 s", 0},
          {"1 second and 2 minutes", 1_210_000_000},
          {"an hour ago", 0},
          {"5 minutes ago and", 3_000_000_000},
          {"1  \t  day", 864_000_000_000},
          {"1\u00A0day", 864_000_000_000},
          {"2days3hours", 1_836_000_000_000},
          {"1 day-ago", 864_000_000_000},
          {"12.5 s 3 m", 1_925_000_000},
          {"1.5 weeks", 9_072_000_000_000},
          {"0.3 months", 7_776_000_000_000},
          {"2.7 years", 851_472_000_000_000},
          {"2026 years", 638_919_360_000_000_000},
          {"2025.9 years", 638_887_824_000_000_000},
          {"2 hago", 72_000_000_000},
          {"2 hand", 72_000_000_000},
          {"10 sago", 100_000_000},
          {"1 weekday", 864_000_000_000},
          {"1 hrmin", 600_000_000},
          {"1 minsec", 10_000_000},
          {"1 yearmonth", 25_920_000_000_000},
          {"2\u180Edays", 1_728_000_000_000},
          {"1 day\u180E", 864_000_000_000}
        ] do
      test "reads #{inspect(text)}" do
        assert {:ok, time} = DotnetDate.from_time_ago(unquote(text), @ago_now)
        # The time to the microsecond, rounded toward the past as `canonical/1` then truncates.
        microseconds = div(unquote(ticks) + 9, 10)
        assert DateTime.diff(@ago_now, time, :microsecond) == microseconds
      end
    end

    test "writes a fraction of a second as the second before" do
      assert {:ok, time} =
               DotnetDate.from_time_ago("1.000000059604644775390625001 seconds", @ago_now)

      assert DotnetDate.canonical(time) == "2026-11-26T11:59:58Z"
    end

    test "reads a long number as .NET does, and a number at the body cap without raising" do
      # `dotnet fsi` (.NET 8.0.427) on 2026-11-26: `Single.Parse` reads 16777217 followed by 300
      # zeros as 16777216, the tie to even, and with a 1 after 250 zeros as 16777218; 400 zeros
      # then 1 read as 1, and `0.` then 400 zeros then 1 as 0. The rows at the body cap
      # did not run in .NET; each once raised, on a regex match limit or an integer too large
      # to build. A number with no unit after it adds nothing.
      cap = Indexer.max_response_bytes()
      zeros = String.duplicate("0", cap)

      for {label, text, seconds} <- [
            {"tie, 1 after 250 zeros", "16777217." <> String.duplicate("0", 250) <> "1 s",
             16_777_218},
            {"tie, 300 zeros", "16777217." <> String.duplicate("0", 300) <> " s", 16_777_216},
            {"leading zeros", zeros <> "1 d", 86_400},
            {"fraction of zeros", "0." <> zeros <> "1 d", 0},
            {"digits, no unit", String.duplicate("1", cap), 0},
            {"dots, no unit", String.duplicate(".", cap), 0}
          ] do
        assert {:ok, time} = DotnetDate.from_time_ago(text, @ago_now)
        assert {label, DateTime.diff(@ago_now, time)} == {label, seconds}
      end
    end

    test "fails on a whole part past the largest float, however long" do
      cap = Indexer.max_response_bytes()

      for {label, text} <- [
            {"40 digits", "1" <> String.duplicate("0", 39) <> " s"},
            {"at the cap", String.duplicate("1", cap) <> " s"}
          ] do
        assert {label, DotnetDate.from_time_ago(text, @ago_now)} == {label, :error}
      end
    end

    test "fails where .NET throws: an unknown unit, a number it cannot read, an overflow" do
      for text <- [
            "2 fortnights",
            "1 sandwich",
            "1 thousand years",
            "1 déy",
            "٣ days",
            "1 ١day",
            "1e3 seconds",
            "1\u180Ed",
            ". days",
            "99999999 years",
            "3000 years",
            "340282356779733661637539395458142568448 seconds",
            "340282346638528859811704183484516925440 seconds",
            <<0xFF, " 2 days">>
          ] do
        cell = {text, DotnetDate.from_time_ago(text, @ago_now)}
        assert cell == {text, :error}
      end
    end
  end
end
