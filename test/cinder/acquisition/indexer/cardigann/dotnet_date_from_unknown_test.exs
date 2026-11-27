defmodule Cinder.Acquisition.Indexer.Cardigann.DotnetDateFromUnknownTest do
  # Each row ran on 2026-11-27 through Prowlarr b0b5774's own `DateTimeUtil.FromUnknown` and
  # `DateTimeRoutines.TryParseDateOrTime`, built from their source into a library that `dotnet fsi`
  # loads (.NET 8.0.427, TZ=UTC, LANG unset). The one edit to that source turns `DateTime.Now`
  # and `DateTime.UtcNow` into a fixed clock: 2026-11-26 19:45:30 UTC, a Thursday, unless a test
  # names another. `IsAllDigits`, `ContainsIgnoreCase` and `ParseUtil.CoerceFloat` are copied from
  # b0b5774 beside them. A result .NET gives as Local or Unspecified reads as UTC here (the issue's
  # choice).
  use ExUnit.Case, async: true

  alias Cinder.Acquisition.Indexer.Cardigann.DotnetDate
  alias Cinder.Acquisition.Indexer.Cardigann.Template

  @now ~U[2026-11-26 19:45:30Z]

  defp microseconds({:ok, time}), do: {:ok, DateTime.to_unix(time, :microsecond)}
  defp microseconds(other), do: other

  describe "from_unknown/2 reads what .NET reads" do
    for {text, expected} <- [
          {"Wed, 25 Nov 2026 13:02:00 +1", ~U[2026-11-25 12:02:00Z]},
          {"Wed, 25 Nov 2026 13:02:00 +01", ~U[2026-11-25 12:02:00Z]},
          {"Wed, 25 Nov 2026 13:02:00 +0", ~U[2026-11-25 13:02:00Z]},
          {"Wed, 25 Nov 2026 13:02:00 -1", ~U[2026-11-25 14:02:00Z]},
          {"Wed, 25 Nov 2026 13:02:00 +14", ~U[2026-11-24 23:02:00Z]},
          {"Wed, 25 Nov 2026 13:02:00 -14", ~U[2026-11-26 03:02:00Z]},
          {"Wed, 25 Nov 2026 13:02:00 +15", ~U[2026-11-25 13:02:00Z]},
          {"Wed, 25 Nov 2026 13:02:00 +99", ~U[2026-11-25 13:02:00Z]},
          {"Wed, 25 Nov 2026 13:02:00 +100", ~U[2026-11-25 13:02:00Z]},
          {"Wed, 25 Nov 2026 13:02:00 +01:00", ~U[2026-11-25 13:02:00Z]},
          {"Wed, 25 Nov 2026 13:02:00 +0100", ~U[2026-11-25 13:02:00Z]},
          {"Wed, 25 Nov 2026 13:02:00 GMT", ~U[2026-11-25 13:02:00Z]},
          {"Wed, 25 Nov 2026 13:02:00 Z", ~U[2026-11-25 13:02:00Z]},
          {"Thu, 25 Nov 2026 13:02:00 +1", ~U[2026-11-25 13:02:00Z]},
          {"wed, 25 nov 2026 13:02:00 +1", ~U[2026-11-25 12:02:00Z]},
          {"WEDNESDAY, 25 Nov 2026 13:02:00 +1", ~U[2026-11-25 13:02:00Z]},
          {"Wed, 5 Nov 2026 13:02:00 +1", ~U[2026-11-05 13:02:00Z]},
          {"Wed, 25 Nov 2026 13:02:00  +1", ~U[2026-11-25 13:02:00Z]},
          {"Wed,  25 Nov 2026 13:02:00 +1", ~U[2026-11-25 13:02:00Z]},
          {"Wed, 25 Nov 2026 23:30:00 -1", ~U[2026-11-26 00:30:00Z]},
          {"Fri, 31 Dec 9999 23:30:00 -1", ~U[9999-12-31 23:30:00Z]},
          {"Wed, 25 Nov 2026 13:02 +1", ~U[2026-11-25 13:02:00Z]},
          {"Wed, 25 Nov 26 13:02:00 +1", ~U[2026-11-25 13:02:00Z]},
          {"1764075720", ~U[2025-11-25 13:02:00Z]},
          {"0", ~U[1970-01-01 00:00:00Z]},
          {"00000000000000000000", ~U[1970-01-01 00:00:00Z]},
          {"000000000000000000001764075720", ~U[2025-11-25 13:02:00Z]},
          {"253402300799", ~U[9999-12-31 23:59:59Z]},
          {"Now", ~U[2026-11-26 19:45:30Z]},
          {"just NOW", ~U[2026-11-26 19:45:30Z]},
          {"Unknown", ~U[2026-11-26 19:45:30Z]},
          {"NOW 5 days ago", ~U[2026-11-26 19:45:30Z]},
          {"2 hours ago", ~U[2026-11-26 17:45:30Z]},
          {"1 day, 3 hours ago", ~U[2026-11-25 16:45:30Z]},
          {"2 hours AGO", ~U[2026-11-26 17:45:30Z]},
          {"ago", ~U[2026-11-26 19:45:30Z]},
          {"Today", ~U[2026-11-26 00:00:00Z]},
          {"today", ~U[2026-11-26 00:00:00Z]},
          {"TODAY", ~U[2026-11-26 00:00:00Z]},
          {"Today,", ~U[2026-11-26 00:00:00Z]},
          {"Today at", ~U[2026-11-26 00:00:00Z]},
          {"Today 14:22", ~U[2026-11-26 14:22:00Z]},
          {"Today, 14:22", ~U[2026-11-26 14:22:00Z]},
          {"Today at 14:22", ~U[2026-11-26 14:22:00Z]},
          {"Today, at 14:22", ~U[2026-11-26 14:22:00Z]},
          {"Today,14:22", ~U[2026-11-26 14:22:00Z]},
          {"Today14:22", ~U[2026-11-26 14:22:00Z]},
          {"Today at 9:05", ~U[2026-11-26 09:05:00Z]},
          {"Today 09:05", ~U[2026-11-26 09:05:00Z]},
          {"Today 0:00", ~U[2026-11-26 00:00:00Z]},
          {"Today 23:59", ~U[2026-11-26 23:59:00Z]},
          {"Today 14:22:10", ~U[2026-11-26 14:22:10Z]},
          {"Today 2 PM", ~U[2026-11-26 14:00:00Z]},
          {"Today 2PM", ~U[2026-11-26 14:00:00Z]},
          {"Today 2 pm", ~U[2026-11-26 14:00:00Z]},
          {"Today 10:01 pm", ~U[2026-11-26 22:01:00Z]},
          {"Today 10:01PM", ~U[2026-11-26 22:01:00Z]},
          {"Today 12:25am", ~U[2026-11-26 00:25:00Z]},
          {"Today 12 AM", ~U[2026-11-26 00:00:00Z]},
          {"Today 12 PM", ~U[2026-11-26 12:00:00Z]},
          {"Today 0 AM", ~U[2026-11-26 00:00:00Z]},
          {"Today 0 PM", ~U[2026-11-26 12:00:00Z]},
          {"Today 13 PM", ~U[2026-11-26 13:00:00Z]},
          {"Today 13:00 PM", ~U[2026-11-26 13:00:00Z]},
          {"Today 12:30 AM", ~U[2026-11-26 00:30:00Z]},
          {"Today 11:59 PM", ~U[2026-11-26 23:59:00Z]},
          {"Today 1:30 AM", ~U[2026-11-26 01:30:00Z]},
          {"14:22 Today", ~U[2026-11-26 14:22:00Z]},
          {"Today 14:22 +08:00", ~U[2026-11-26 06:22:00Z]},
          {"Today 02:00 +08:00", ~U[2026-11-26 18:00:00Z]},
          {"Today 23:30 -01:00", ~U[2026-11-26 00:30:00Z]},
          {"Today 14:22 -05:00", ~U[2026-11-26 19:22:00Z]},
          {"Today 14:22 +14:00", ~U[2026-11-26 00:22:00Z]},
          {"Today 14:22 -14:00", ~U[2026-11-26 04:22:00Z]},
          {"Today 14:22+08:00", ~U[2026-11-26 06:22:00Z]},
          {"Today 14:22  +08:00", ~U[2026-11-26 06:22:00Z]},
          {"Today 14:22\t+08:00", ~U[2026-11-26 06:22:00Z]},
          {"Today 2 PM +08:00", ~U[2026-11-26 06:00:00Z]},
          {"Today 10:01 PM +08:00", ~U[2026-11-26 14:01:00Z]},
          {"Today 14:22:10 +08:00", ~U[2026-11-26 06:22:10Z]},
          {"Today\t14:22", ~U[2026-11-26 14:22:00Z]},
          {"14:22", ~U[2026-11-26 14:22:00Z]},
          {"Yesterday 14:22", ~U[2026-11-25 14:22:00Z]},
          {"Yesterday at 10:01 PM", ~U[2026-11-25 22:01:00Z]},
          {"yesterday", ~U[2026-11-25 00:00:00Z]},
          {"Yesterday 14:22 +08:00", ~U[2026-11-25 06:22:00Z]},
          {"Yesterday 6:00 AM", ~U[2026-11-25 06:00:00Z]},
          {"Yesterday 02:00 +08:00", ~U[2026-11-25 18:00:00Z]},
          {"Yesterday, 22:47", ~U[2026-11-25 22:47:00Z]},
          {"Tomorrow 14:22", ~U[2026-11-27 14:22:00Z]},
          {"tomorrow", ~U[2026-11-27 00:00:00Z]},
          {"Monday at 14:22", ~U[2026-11-23 14:22:00Z]},
          {"Tuesday at 14:22", ~U[2026-11-24 14:22:00Z]},
          {"Wednesday at 14:22", ~U[2026-11-25 14:22:00Z]},
          {"Thursday at 14:22", ~U[2026-11-26 14:22:00Z]},
          {"Friday at 14:22", ~U[2026-11-20 14:22:00Z]},
          {"Saturday at 14:22", ~U[2026-11-21 14:22:00Z]},
          {"Sunday at 14:22", ~U[2026-11-22 14:22:00Z]},
          {"saturday AT 14:22", ~U[2026-11-21 14:22:00Z]},
          {"Saturday at 10:01 PM", ~U[2026-11-21 22:01:00Z]},
          {"Saturday 14:22", ~U[2026-11-26 14:22:00Z]},
          {"Saturday at  14:22", ~U[2026-11-21 14:22:00Z]},
          {"Saturday at 14:22 +08:00", ~U[2026-11-21 06:22:00Z]},
          {"Saturday at 02:00 +08:00", ~U[2026-11-21 18:00:00Z]},
          {"11-25", ~U[2026-11-25 00:00:00Z]},
          {"11-25 14:22", ~U[2026-11-25 14:22:00Z]},
          {"1-5", ~U[2026-01-05 00:00:00Z]},
          {"11-25 11-25", ~U[2026-11-25 00:00:00Z]},
          {"25 Nov 14:22", ~U[2026-11-25 14:22:00Z]},
          {"1 Jan 10:30", ~U[2026-01-01 10:30:00Z]},
          {"25 nov 14:22", ~U[2026-11-26 14:22:00Z]},
          {"25 Nov 14:22:10 +0100", ~U[2026-11-25 14:22:10Z]},
          {"Nov 25 14:22", ~U[2026-11-25 14:22:00Z]},
          {"Nov 25 2026", ~U[2026-11-25 00:00:00Z]},
          {"NOV 25 2026", ~U[2026-11-25 00:00:00Z]},
          {"Jul 4 2026", ~U[2026-07-04 00:00:00Z]},
          {"July 4 2026", ~U[2026-07-04 00:00:00Z]},
          {"November 25, 2026", ~U[2026-11-25 00:00:00Z]},
          {"Nov 25th, 2026", ~U[2026-11-25 00:00:00Z]},
          {"25th Nov 2026", ~U[2026-11-25 00:00:00Z]},
          {"25-Nov-2026", ~U[2026-11-25 00:00:00Z]},
          {"25 Nov '26", ~U[2026-11-25 00:00:00Z]},
          {"25 Nov 99", ~U[1999-11-25 00:00:00Z]},
          {"25 Nov 30", ~U[2030-11-25 00:00:00Z]},
          {"25 Nov 31", ~U[1931-11-25 00:00:00Z]},
          {"2026 Nov 25", ~U[2026-11-25 00:00:00Z]},
          {"Nov 25 14:22:10 UTC 2026", ~U[2026-11-25 14:22:10Z]},
          {"Nov 25 14:22:10 MDT 2026", ~U[2026-11-25 14:22:10Z]},
          {"11/25/2026", ~U[2026-11-25 00:00:00Z]},
          {"11/25/26", ~U[2026-11-25 00:00:00Z]},
          {"11.25.2026", ~U[2026-11-25 00:00:00Z]},
          {"11//25//2026", ~U[2026-11-25 00:00:00Z]},
          {"11 / 25 / 2026", ~U[2026-11-25 00:00:00Z]},
          {"25.11.2026 14:22", ~U[2026-11-26 14:22:00Z]},
          {"2026-11-25", ~U[2026-11-25 00:00:00Z]},
          {"2026-11-25 14:22", ~U[2026-11-25 14:22:00Z]},
          {"2026-11-25T14:22:10", ~U[2026-11-25 14:22:10Z]},
          {"2026-11-25T13:02:00+01:00", ~U[2026-11-25 13:02:00Z]},
          {"2026-11-25 14:22:10 +0100", ~U[2026-11-25 14:22:10Z]},
          {"2026-11-25 13:02:00Z", ~U[2026-11-25 13:02:00Z]},
          {"2026-11-25T13:02:00.5Z", ~U[2026-11-25 13:02:00Z]},
          {"26-11-25", ~U[2026-11-25 00:00:00Z]},
          {"0050-01-01", ~U[1950-01-01 00:00:00Z]},
          {"12:25am", ~U[2026-11-26 00:25:00Z]},
          {"12:25 AM", ~U[2026-11-26 00:25:00Z]},
          {"12:25 Am", ~U[2026-11-26 12:25:00Z]},
          {"2:05 pm", ~U[2026-11-26 14:05:00Z]},
          {"9:05", ~U[2026-11-26 09:05:00Z]},
          {"14:22 UTC", ~U[2026-11-26 14:22:00Z]},
          {"14:22 CST", ~U[2026-11-26 14:22:00Z]},
          {"T14:22", ~U[2026-11-26 14:22:00Z]},
          {"14:22:10 +0100", ~U[2026-11-26 14:22:10Z]},
          {"14:22:10 +01", ~U[2026-11-26 14:22:10Z]},
          {"14:22:10 -0530", ~U[2026-11-26 14:22:10Z]},
          {"11/25/2026 14:22", ~U[2026-11-25 14:22:00Z]},
          {"11/25/2026, 14:22", ~U[2026-11-25 14:22:00Z]},
          {"11/25/2026 at 14:22", ~U[2026-11-25 14:22:00Z]},
          {"11/25/2026T14:22", ~U[2026-11-25 14:22:00Z]},
          {"11/25/2026 - 14:22", ~U[2026-11-25 14:22:00Z]},
          {"11/25/2026 2:05 PM", ~U[2026-11-25 14:05:00Z]},
          {"11/25/2026 14:22:10 +0100", ~U[2026-11-25 14:22:10Z]},
          {"11/25/2026 25:00", ~U[2026-11-25 00:00:00Z]},
          {"14:22 11/25/2026", ~U[2026-11-25 14:22:00Z]},
          {"14:22, 11/25/2026", ~U[2026-11-25 14:22:00Z]},
          {"11/25/2026 x 14:22", ~U[2026-11-25 00:00:00Z]},
          {"11/25/2026 ,14:22", ~U[2026-11-25 00:00:00Z]},
          {"11/25/2026at14:22", ~U[2026-11-25 14:22:00Z]},
          {"11/25/2026 AT 14:22", ~U[2026-11-25 00:00:00Z]},
          {"12/31/9999 23:00:00 +1300", ~U[9999-12-31 23:00:00Z]},
          {"12/31/9999 23:00:00 -0100", ~U[9999-12-31 23:00:00Z]},
          {"12/31/9999 23:00 EST", ~U[9999-12-31 23:00:00Z]},
          {"1/1/1000 00:00:00 -0100", ~U[1000-01-01 00:00:00Z]},
          {"xToday 14:22", ~U[2026-11-26 14:22:00Z]},
          {"xSaturday at 14:22", ~U[2026-11-26 14:22:00Z]},
          {"_Saturday at 14:22", ~U[2026-11-26 14:22:00Z]},
          {"\u{E9}Saturday at 14:22", ~U[2026-11-26 14:22:00Z]},
          {"\u{200D}Saturday at 14:22", ~U[2026-11-26 14:22:00Z]},
          {"\u{301}Saturday at 14:22", ~U[2026-11-26 14:22:00Z]},
          {"\u{B2}2 days ago", ~U[2026-11-24 19:45:30Z]},
          {"x 2 days ago", ~U[2026-11-24 19:45:30Z]},
          {"Today at 00:48", ~U[2026-11-26 00:48:00Z]},
          {"Yesterday at 23:57", ~U[2026-11-25 23:57:00Z]},
          {"\u{A0}Today 14:22\u{A0}", ~U[2026-11-26 14:22:00Z]},
          {"Today\r\n14:22", ~U[2026-11-26 14:22:00Z]},
          {"\u{3000}Today 14:22", ~U[2026-11-26 14:22:00Z]},
          {"Today 14:22\u{85}", ~U[2026-11-26 14:22:00Z]},
          {"Today 23 PM", ~U[2026-11-26 23:00:00Z]},
          {"Today 2 Pm", ~U[2026-11-26 14:00:00Z]},
          {"Today 2 pM", ~U[2026-11-26 14:00:00Z]},
          {"Today 0:30 PM", ~U[2026-11-26 12:30:00Z]},
          {"Today 00:30", ~U[2026-11-26 00:30:00Z]},
          {"Today 7:05:09", ~U[2026-11-26 07:05:09Z]},
          {"Today 23:59:59", ~U[2026-11-26 23:59:59Z]},
          {"Today 14:22 +01:30", ~U[2026-11-26 12:52:00Z]},
          {"Wed, 25 Nov 2026 13:02:00 -15", ~U[2026-11-25 13:02:00Z]},
          {"Wed, 25 Nov 2026 13:02:00 1", ~U[2026-11-25 13:02:00Z]},
          {"Wed, 25 Nov 2026 13:02:00 +", ~U[2026-11-25 13:02:00Z]},
          {"Sun, 29 Feb 2032 13:02:00 +1", ~U[2032-02-29 12:02:00Z]},
          {"Wed, 25 Nov 2026 24:00:00 +1", ~U[2026-11-25 00:00:00Z]},
          {"Wed, 25 NOVEMBER 2026 13:02:00 +1", ~U[2026-11-25 13:02:00Z]},
          {"Wed, 25 Nov 2026 13:02:00 +1 ", ~U[2026-11-25 12:02:00Z]},
          {"Wed, 25 Nov 2026 13:02:00\t+1", ~U[2026-11-25 13:02:00Z]},
          {"Wed, 25 Nov 2026 1:02:00 +1", ~U[2026-11-25 01:02:00Z]},
          {"Fri, 31 Dec 9999 23:30:00 -0", ~U[9999-12-31 23:30:00Z]},
          {"Fri, 31 Dec 9999 23:30:00 +0", ~U[9999-12-31 23:30:00Z]},
          {"\u{17F}aturday at 14:22", ~U[2026-11-26 14:22:00Z]},
          {"fr\u{130}day at 14:22", ~U[2026-11-20 14:22:00Z]},
          {"fr\u{131}day at 14:22", ~U[2026-11-26 14:22:00Z]},
          {"11/25/2026 25:\u{662}\u{662}", ~U[2026-11-25 00:00:00Z]},
          {"Today 14:22\n", ~U[2026-11-26 14:22:00Z]},
          {"Nov 25 2026\n14:22", ~U[2026-11-25 14:22:00Z]},
          {"1 Jan 10:30\nx", ~U[2010-01-01 00:00:00Z]},
          {"11-25\n14:22", ~U[2026-11-25 14:22:00Z]},
          {"\u{903}Nov 25 2026", ~U[2026-11-25 00:00:00Z]},
          {"\u{20DD}Nov 25 2026", ~U[2026-11-25 00:00:00Z]},
          {"\u{200D}Nov 25 2026", ~U[2026-11-25 00:00:00Z]},
          {"\u{B2}Nov 25 2026", ~U[2026-11-25 00:00:00Z]},
          {"\u{2160}Nov 25 2026", ~U[2026-11-25 00:00:00Z]},
          {"\u{200C}Saturday at 14:22", ~U[2026-11-26 14:22:00Z]},
          {"YESTERDAY 14:22", ~U[2026-11-25 14:22:00Z]},
          {"Nov 25 2026 m\u{130}ddle", ~U[2026-11-25 00:00:00Z]},
          {"25 Nov\u{130} 2026", ~U[2026-11-25 00:00:00Z]},
          {"Sep 25 2026", ~U[2026-09-25 00:00:00Z]},
          {"Sept 25 2026", ~U[2026-09-25 00:00:00Z]},
          {"September 25 2026", ~U[2026-09-25 00:00:00Z]},
          {"Nov 25TH 2026", ~U[2026-11-25 00:00:00Z]},
          {"Nov 25 2026 14:22:10 utc", ~U[2026-11-25 14:22:10Z]},
          {"Nov 25 14:22:10 utc 2026", ~U[2026-11-25 14:22:10Z]},
          {"Nov 25 14:22:10 UTC 2026 15:00", ~U[2026-11-25 15:00:00Z]},
          {"2026-11-25 14:22 utc", ~U[2026-11-25 14:22:00Z]},
          {"2026-11-25 14:22 PM", ~U[2026-11-25 14:22:00Z]},
          {"2026-11-25 2:22pm", ~U[2026-11-25 14:22:00Z]},
          {"2026-11-25 14:22 Pm", ~U[2026-11-25 14:22:00Z]},
          {"Nov 25 0099", ~U[1999-11-25 00:00:00Z]},
          {"Today Today 14:22", ~U[2026-11-26 14:22:00Z]},
          {"10:00 Nov 25 2026 14:22", ~U[2026-11-25 14:22:00Z]},
          {"10:00 11/25/2026, 14:22", ~U[2026-11-25 14:22:00Z]},
          {"Yesterday 08:00", ~U[2026-11-25 08:00:00Z]},
          {"Today 10:01 PM", ~U[2026-11-26 22:01:00Z]},
          {"Tomorrow 14:22:10 +08:00", ~U[2026-11-27 06:22:10Z]},
          {"25 Nov 2026 14:22", ~U[2026-11-25 14:22:00Z]},
          {"Today 14:22 +09:00", ~U[2026-11-26 05:22:00Z]},
          {"Yesterday", ~U[2026-11-25 00:00:00Z]},
          {"Mon, 01 Jan 0001 00:30:00 +1", ~U[0001-01-01 23:30:00Z]},
          {"Mon, 01 Jan 0001 00:30:00 +2", ~U[0001-01-01 22:30:00Z]},
          {"Mon, 01 Jan 0001 00:30:00 +14", ~U[0001-01-01 10:30:00Z]},
          {"Mon, 01 Jan 0001 13:00:00 +14", ~U[0001-01-01 23:00:00Z]},
          {"Mon, 01 Jan 0001 23:59:59 +14", ~U[0001-01-01 09:59:59Z]},
          {"Mon, 01 Jan 0001 00:00:00 +1", ~U[0001-01-01 23:00:00Z]},
          {"Tue, 02 Jan 0001 00:30:00 +1", ~U[0001-01-01 23:30:00Z]},
          {"Mon, 01 Jan 0001 00:30:00 -1", ~U[0001-01-01 01:30:00Z]}
        ] do
      test "#{inspect(text)}" do
        assert microseconds(DotnetDate.from_unknown(unquote(text), @now)) ==
                 {:ok, DateTime.to_unix(unquote(Macro.escape(expected)), :microsecond)}
      end
    end

    test "Cinder's own canonical text, which no .NET branch reads, before the year 1000 too" do
      # `timeago` writes `1100 years ago` as `0927-08-20T19:45:30Z`, and the month-name and
      # numeric patterns read no year before 1000.
      assert DotnetDate.from_unknown("0500-01-01T00:00:00Z", @now) ==
               {:ok, ~U[0500-01-01 00:00:00Z]}
    end
  end

  describe "from_unknown/2 is :error where .NET throws" do
    for text <- [
          "9223372036854775807",
          "9223372036854775808",
          "253402300800",
          "9999999999999999999",
          "99999999999999999999",
          "chicago 2 days",
          "x_ago 2 days",
          "2 fortnights ago",
          "3 hours ago 14:22",
          "Today 24:00",
          "Today 23:60",
          "Today 14:22:60",
          "Today 14:22 AM",
          "Today 10:01 p.m.",
          "Today 9",
          "Today 009:05",
          "Today 14h22",
          "Today \u{661}\u{664}:\u{662}\u{662}",
          "Uploaded today at 14:22",
          "Today at 14:22 Today",
          "Todays 14:22",
          "Today 14:22 +14:01",
          "Today 14:22 +15:00",
          "Today 14:22 UTC",
          "Yesterday 25:00",
          "Saturday at",
          "Saturday at x",
          "Last Saturday at 14:22",
          "11-25-2026",
          "\u{661}\u{661}-\u{662}\u{665}",
          "nov 25 2026",
          "JUL 4 2026",
          "25/11/2026",
          "11/25.2026",
          "2026-02-30",
          "2026-13-01",
          "0999-01-01",
          "25:00",
          "14:60",
          "14:22:60",
          "x14:22",
          "\u{662}\u{660}\u{662}\u{666}-\u{661}\u{661}-\u{662}\u{665}",
          "\u{661}\u{664}:\u{662}\u{662}",
          "Nov \u{662}\u{665} 2026",
          "11/25/2026 \u{661}\u{664}:\u{662}\u{662}",
          "garbage",
          "12a",
          "",
          "12/31/9999 23:00:00 +0100",
          "\u{B2}Saturday at 14:22",
          "Uploaded Today at 00:48 by",
          "   ",
          "\u{FEFF}Today 14:22",
          "\u{180E}Today 14:22",
          "Today 13 AM",
          "Today 24 PM",
          "Today 12:60 PM",
          "Today 14:22 -14:01",
          "Today 14:22 +00:60",
          "Augu\u{17F}t 4 2026",
          "11/25/2026 14:22:10 +\u{660}\u{661}\u{660}\u{660}",
          "11/25/2026 14:\u{662}\u{662}",
          "25:\u{662}\u{662}",
          "Yesterday 14:22 +08:00 Yesterday 14:22 +08:00",
          "\u{661}\u{661}/\u{662}\u{665}/\u{662}\u{660}\u{662}\u{666}",
          "\u{903}Saturday at 14:22",
          "\u{20DD}Saturday at 14:22",
          "\u{301}Nov 25 2026",
          "\u{2160}Saturday at 14:22",
          "\u{130}",
          "25 Nov\u{ED} 2026",
          "Sepx 25 2026",
          "Nov 25 0100",
          "11/25/0100"
        ] do
      test "#{inspect(text)}" do
        assert DotnetDate.from_unknown(unquote(text), @now) == :error
      end
    end

    test "text that is not UTF-8" do
      for text <- [<<0xFF>>, "Today 14:22" <> <<0xFF>>, <<0xFF>> <> "1764075720"] do
        assert {text, DotnetDate.from_unknown(text, @now)} == {text, :error}
      end
    end
  end

  describe "from_unknown/2 is :error where the issue's bound stops and .NET reads a time" do
    # After Today, Yesterday or Tomorrow, the issue reads only H:mm, H:mm:ss, H or H:mm with AM or
    # PM, each with at most one +HH:mm or -HH:mm offset. Each test name holds .NET's reading.
    for {text, dotnet} <- [
          {"Today 14:5", "2026-11-26T14:05:00 Unspecified"},
          {"Today 9:5", "2026-11-26T09:05:00 Unspecified"},
          {"Today 14 : 22", "2026-11-26T14:22:00 Unspecified"},
          {"Today 14:22:10 PM", "2026-11-26T14:22:10 Unspecified"},
          {"Today 14:22 +0800", "2026-11-26T06:22:00 Unspecified"},
          {"Today 14:22 +8:00", "2026-11-26T06:22:00 Unspecified"},
          {"Today 14:22 +08", "2026-11-26T06:22:00 Unspecified"},
          {"Today 14:22 Z", "2026-11-26T14:22:00 Unspecified"}
        ] do
      test "#{inspect(text)}, where .NET reads #{dotnet}" do
        assert DotnetDate.from_unknown(unquote(text), @now) == :error
      end
    end
  end

  describe "from_unknown/2 on long text" do
    test "a pattern that hits its match limit is :error, where .NET reads the date" do
      # The first month-name pattern backtracks over the blanks between `,?` and the year it
      # never finds, and hits the limit past about 3,000 of them. Without the limit the last
      # month-name pattern would read Jan 1, or a match read as no match would go on to the
      # time alone, 14:22 today. .NET reads 2026-01-01T00:00:00 Unspecified.
      text = "Jan 1" <> String.duplicate(" ", 4000) <> "x 14:22"

      assert DotnetDate.from_unknown(text, @now) == :error
    end

    test "a pattern's start repeated costs at most 3 times the reductions of text with none" do
      # `:re.run/3` counts its matching work as reductions, which the host's load leaves alone.
      # With PCRE2's start optimizations, 1 MiB of `T1:11 ` cost the day-name pattern 716M
      # reductions, against 0.7M without them.
      size = 262_144

      cost = fn unit ->
        text = String.duplicate(unit, div(size, byte_size(unit)))

        Task.async(fn ->
          {:reductions, before} = Process.info(self(), :reductions)
          result = DotnetDate.from_unknown(text, @now)
          {:reductions, later} = Process.info(self(), :reductions)
          {result, later - before}
        end)
        |> Task.await(:infinity)
      end

      {:error, none} = cost.("q")

      for unit <- [
            "T1:11 ",
            "TY ",
            "AO ",
            "MONDAY A ",
            "1 : 1 : ",
            "Jan 1 ",
            "1/1/",
            "Wed, ",
            "1 hour ago "
          ] do
        {result, reductions} = cost.(unit)
        assert result == :error or match?({:ok, %DateTime{}}, result)
        assert {unit, reductions <= 3 * none} == {unit, true}
      end
    end

    test "each pattern's start, repeated to the template output cap, reads without a raise" do
      size = Template.output_cap()

      for unit <- [
            "ago ",
            "today ",
            "yesterday ",
            "tomorrow ",
            "Monday at ",
            "11-25 ",
            "1 Jan ",
            "1/1/",
            "11-1-",
            "Jan 1 ",
            "1st Jan ",
            "2026 Jan ",
            "Jan 1 11:11:11 UTC ",
            "T1:11 ",
            "11:11:11 +11 ",
            "Today 1 ",
            "Wed, ",
            "1.1.",
            "1-1-",
            "1 hour ago "
          ] do
        text = String.duplicate(unit, div(size, byte_size(unit)))
        result = DotnetDate.from_unknown(text, @now)
        assert {unit, result == :error or match?({:ok, %DateTime{}}, result)} == {unit, true}
      end
    end
  end

  describe "from_unknown/2 reads each clock reading from now" do
    # The same rows on two more clocks: 2026-01-01 05:00:00, a Thursday, and 2026-12-31 23:59:59.
    for {now, rows} <- [
          {~U[2026-01-01 05:00:00Z],
           [
             {"Yesterday 14:22", ~U[2025-12-31 14:22:00Z]},
             {"Tomorrow 14:22", ~U[2026-01-02 14:22:00Z]},
             {"11-25", ~U[2026-11-25 00:00:00Z]},
             {"25 Nov 14:22", ~U[2026-11-25 14:22:00Z]},
             {"Nov 25", ~U[2026-11-25 00:00:00Z]},
             {"14:22", ~U[2026-01-01 14:22:00Z]},
             {"Thursday at 14:22", ~U[2026-01-01 14:22:00Z]},
             {"Wednesday at 14:22", ~U[2025-12-31 14:22:00Z]},
             {"Today", ~U[2026-01-01 00:00:00Z]}
           ]},
          {~U[2026-12-31 23:59:59Z],
           [
             {"Yesterday 14:22", ~U[2026-12-30 14:22:00Z]},
             {"Tomorrow 14:22", ~U[2027-01-01 14:22:00Z]},
             {"11-25", ~U[2026-11-25 00:00:00Z]},
             {"25 Nov 14:22", ~U[2026-11-25 14:22:00Z]},
             {"Nov 25", ~U[2026-11-25 00:00:00Z]},
             {"14:22", ~U[2026-12-31 14:22:00Z]},
             {"Thursday at 14:22", ~U[2026-12-31 14:22:00Z]},
             {"Wednesday at 14:22", ~U[2026-12-30 14:22:00Z]},
             {"Today", ~U[2026-12-31 00:00:00Z]}
           ]}
        ] do
      test "at #{now}" do
        for {text, expected} <- unquote(Macro.escape(rows)) do
          assert {text, DotnetDate.from_unknown(text, unquote(Macro.escape(now)))} ==
                   {text, {:ok, expected}}
        end
      end
    end
  end
end
