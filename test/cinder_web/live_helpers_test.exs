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

  describe "relative_time/2" do
    @now ~U[2026-06-03 12:00:00Z]

    test "buckets a past instant into just now / minutes / hours / days" do
      assert relative_time(DateTime.add(@now, -10, :second), @now) == "just now"
      assert relative_time(DateTime.add(@now, -60, :second), @now) == "1 minute ago"
      assert relative_time(DateTime.add(@now, -5 * 60, :second), @now) == "5 minutes ago"
      assert relative_time(DateTime.add(@now, -1 * 3600, :second), @now) == "1 hour ago"
      assert relative_time(DateTime.add(@now, -3 * 86_400, :second), @now) == "3 days ago"
    end

    test "accepts a NaiveDateTime (Ecto timestamps) and clamps a future instant to just now" do
      naive = NaiveDateTime.add(DateTime.to_naive(@now), -2 * 86_400, :second)
      assert relative_time(naive, @now) == "2 days ago"
      assert relative_time(DateTime.add(@now, 90, :second), @now) == "just now"
    end
  end

  describe "book_badge_state/2" do
    # The target outranks the request: nothing reaches :available until B4 imports a file, so
    # without this table the precedence rule ships with no coverage at all.
    test "an existing target outranks the request that created it" do
      assert book_badge_state(:approved, :available) == :available
      assert book_badge_state(:pending, :available) == :available
      assert book_badge_state(nil, :available) == :available
      assert book_badge_state(:approved, :monitored) == :approved
      assert book_badge_state(nil, :monitored) == :approved
      # A second requester whose own row is still pending against a work someone else already
      # had approved is waiting on nothing — "Pending" would send them to chase an admin.
      assert book_badge_state(:pending, :monitored) == :approved
    end

    test "a held target outranks the request that created it" do
      # B4b's pipeline parks a target `:held` with a `hold_reason` on a dead download, a refused
      # payload, or a rejected submission. Falling through left every one of those reading
      # "Approved" forever — told Cinder is fetching a book while nothing is.
      assert book_badge_state(:approved, :held) == :held
      assert book_badge_state(:pending, :held) == :held
      assert book_badge_state(nil, :held) == :held
    end

    test "falls back to the request when the target says nothing yet" do
      assert book_badge_state(:pending, nil) == :pending
      assert book_badge_state(:pending, :unmonitored) == :pending
      assert book_badge_state(:approved, nil) == :approved
      assert book_badge_state(:denied, nil) == :denied
      assert book_badge_state(nil, nil) == :none
    end

    # A linked target with no request behind it and still `:unmonitored` must render its own
    # explicit state — falling to `:none` (no badge at all) is indistinguishable from "there is
    # nothing here", which is wrong once a target exists.
    test "a linked, unmonitored target with no request renders explicitly, not blank" do
      assert book_badge_state(nil, :unmonitored) == :unmonitored
    end
  end
end
