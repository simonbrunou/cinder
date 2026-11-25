# `format_household_time/2` reads the household zone from the `:cinder` env, which
# `Cinder.ConfigCase.put_env/2` sets process-globally, so this module is not async.
defmodule CinderWeb.LiveHelpersHouseholdTimeTest do
  use ExUnit.Case, async: false

  import CinderWeb.LiveHelpers, only: [format_household_time: 2, household_time_parts: 2]

  alias Cinder.ConfigCase

  # Asia/Tokyo is UTC+9 all year (no DST), so each expected string below is a fixed literal.
  setup do
    ConfigCase.put_env(:household_timezone, "Asia/Tokyo")
    Gettext.put_locale(CinderWeb.Gettext, "en")
    :ok
  end

  test "a time on the household's today shows hours and minutes alone" do
    now = ~U[2026-06-03 01:00:00Z]

    assert format_household_time(~U[2026-06-03 05:35:00Z], now) == "14:35"
  end

  test "a time on another household day shows the date, then the time" do
    now = ~U[2026-06-03 01:00:00Z]

    assert format_household_time(~U[2026-06-05 05:35:00Z], now) == "Jun 5, 14:35"
    assert format_household_time(~U[2026-06-01 05:35:00Z], now) == "Jun 1, 14:35"
  end

  test "a zone ahead of UTC moves a 23:30 UTC time onto the next day's date" do
    # 23:30 UTC on Jun 3 is 08:30 on Jun 4 in Tokyo; `now` is 10:00 on Jun 3 in Tokyo.
    now = ~U[2026-06-03 01:00:00Z]

    assert format_household_time(~U[2026-06-03 23:30:00Z], now) == "Jun 4, 08:30"
  end

  test "today is the household's day, not UTC's: both instants shift before the dates compare" do
    # Both are Jun 4 in Tokyo, while `now` is still Jun 3 in UTC.
    now = ~U[2026-06-03 23:00:00Z]

    assert format_household_time(~U[2026-06-04 05:35:00Z], now) == "14:35"
  end

  test "an instant held in another zone formats in the household zone" do
    {:ok, paris} = DateTime.shift_zone(~U[2026-06-03 05:35:00Z], "Europe/Paris")

    assert format_household_time(paris, ~U[2026-06-03 01:00:00Z]) == "14:35"
  end

  test "an unusable household zone falls back to UTC" do
    ConfigCase.put_env(:household_timezone, "Not/A_Zone")

    assert format_household_time(~U[2026-06-03 05:35:00Z], ~U[2026-06-03 01:00:00Z]) == "05:35"
  end

  test "household_time_parts/2 gives no date on the household's today, else the date apart" do
    now = ~U[2026-06-03 01:00:00Z]

    assert household_time_parts(~U[2026-06-03 05:35:00Z], now) == {nil, "14:35"}
    assert household_time_parts(~U[2026-06-03 23:30:00Z], now) == {"Jun 4", "08:30"}
  end

  test "the French catalog words the date and time" do
    Gettext.put_locale(CinderWeb.Gettext, "fr")

    assert format_household_time(~U[2026-06-05 05:35:00Z], ~U[2026-06-03 01:00:00Z]) ==
             "5 juin à 14:35"
  after
    Gettext.put_locale(CinderWeb.Gettext, "en")
  end
end
