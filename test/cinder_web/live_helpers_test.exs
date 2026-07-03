defmodule CinderWeb.LiveHelpersTest do
  use ExUnit.Case, async: true

  import CinderWeb.LiveHelpers

  # The date format strings AND month names are gettext-translated, so a bad .po
  # msgstr would be executed as strftime syntax at render time — this pins every
  # locale's values as valid (an invalid directive would raise here, not in a view).
  test "format_date/1 and format_date_year/1 render in every locale" do
    date = ~D[2026-06-03]

    for locale <- Gettext.known_locales(CinderWeb.Gettext) do
      Gettext.put_locale(CinderWeb.Gettext, locale)
      assert format_date(date) =~ "3"
      assert format_date_year(date) =~ "2026"
    end
  after
    Gettext.put_locale(CinderWeb.Gettext, "en")
  end

  test "format_date/1 localizes month names (fr)" do
    Gettext.put_locale(CinderWeb.Gettext, "fr")
    assert format_date(~D[2026-06-03]) == "3 juin"
    assert format_date_year(~D[2026-06-03]) == "3 juin 2026"
  after
    Gettext.put_locale(CinderWeb.Gettext, "en")
  end

  test "format_date/1 keeps English month-first order (en)" do
    Gettext.put_locale(CinderWeb.Gettext, "en")
    assert format_date(~D[2026-06-03]) == "Jun 3"
    assert format_date_year(~D[2026-06-03]) == "Jun 3, 2026"
  end
end
