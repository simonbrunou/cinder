defmodule CinderWeb.LiveHelpersTest do
  use ExUnit.Case, async: true

  import CinderWeb.LiveHelpers

  alias Cinder.Download
  alias Cinder.Download.{BookPoller, Watch}

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

    # PR #557 follow-up: a household is single-shared, so a book a DIFFERENT request already
    # made :available/:held/:monitored is genuinely that, for every current-state surface
    # (Discover, book detail, library) — a denied requester must still be told the truth about
    # whether the book is actually there, not shown a stale "Denied" for something they can
    # already open. `CinderWeb.MyRequestsLive` needs the opposite (a denied ROW keeps reading
    # Denied) precisely because it answers a different question — "what happened to each of my
    # own past requests" — and gets it via its own local short-circuit in `book_badge/2`, not
    # here. Pinning both halves of that split so neither regresses into the other's job.
    test "the target still outranks a denied request in the shared, current-state function" do
      assert book_badge_state(:denied, :available) == :available
      assert book_badge_state(:denied, :held) == :held
      assert book_badge_state(:denied, :monitored) == :approved
    end

    # A linked target with no request behind it and still `:unmonitored` must render its own
    # explicit state — falling to `:none` (no badge at all) is indistinguishable from "there is
    # nothing here", which is wrong once a target exists.
    test "a linked, unmonitored target with no request renders explicitly, not blank" do
      assert book_badge_state(nil, :unmonitored) == :unmonitored
    end
  end

  describe "book_hold_reason/1" do
    # The lists come from their producers, so a code added to one fails here until it has a
    # sentence. The watch's `:stalled` and `{:blocked_content, _}` verdicts have no list to read.
    defp known_hold_codes do
      (Watch.failure_codes() ++
         [:stalled, :blocked_content] ++
         BookPoller.permanent_import_errors() ++
         Download.permanent_submission_errors())
      |> Enum.map(&Atom.to_string/1)
    end

    test "every known reason code reads as a sentence, not as the code" do
      for code <- known_hold_codes() do
        sentence = book_hold_reason(code)
        assert sentence != code, "#{code} has no sentence"
        assert sentence =~ ~r/^\p{Lu}.*\.$/u, "#{code} reads #{inspect(sentence)}"
      end
    end

    test "every known reason code has its own French sentence" do
      english = Map.new(known_hold_codes(), &{&1, book_hold_reason(&1)})
      Gettext.put_locale(CinderWeb.Gettext, "fr")

      for {code, sentence} <- english do
        french = book_hold_reason(code)
        assert french not in [code, sentence], "#{code} has no French sentence"
        assert french =~ ~r/^\p{Lu}.*\.$/u, "#{code} reads #{inspect(french)}"
      end

      assert book_hold_reason("download_error: Paused on duplicate") =~
               ~r/^#{Regex.escape(book_hold_reason("download_error"))} .+ Paused on duplicate$/
    after
      Gettext.put_locale(CinderWeb.Gettext, "en")
    end

    test "a stored code and detail reads as the code's sentence followed by the detail" do
      assert book_hold_reason("download_error: Paused on duplicate") ==
               "The download client reported that the download failed. Details: Paused on duplicate"

      assert book_hold_reason("blocked_content: download contains setup.exe") ==
               "The download holds a blocked file, such as a program, and no book. " <>
                 "Details: download contains setup.exe"
    end

    test "a blank detail reads as the code's sentence alone" do
      assert book_hold_reason("download_error: ") ==
               "The download client reported that the download failed."
    end

    # Rows from before #733 read `download_failed` or a bare client message; a reason that was
    # neither an atom nor a `{code, detail}` pair was stored inspected.
    test "unknown or legacy text is shown as stored, and nil does not raise" do
      for stored <- [
            "download_failed",
            "Paused on duplicate",
            "Error: disk full",
            "{:unexpected_destination_type, :directory}"
          ],
          do: assert(book_hold_reason(stored) == stored)

      assert book_hold_reason(nil) == ""
    end
  end
end
