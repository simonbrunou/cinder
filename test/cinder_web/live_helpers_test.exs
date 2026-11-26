defmodule CinderWeb.LiveHelpersTest do
  use ExUnit.Case, async: true

  import CinderWeb.LiveHelpers

  alias Cinder.Download
  alias Cinder.Download.{BookPoller, ContentPolicy, Watch}

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
    # `stored/1` is `Cinder.Books.hold_target/5`'s encoding; `BookPollerRetriedImportErrorsTest`
    # holds a target on every retried import error through the real one.
    defp known_hold_codes do
      (Watch.failure_codes() ++
         [:stalled, :blocked_content] ++
         BookPoller.permanent_import_errors() ++
         BookPoller.retried_import_errors() ++
         Download.permanent_submission_errors())
      |> Enum.map(&stored/1)
    end

    defp stored(reason) when is_atom(reason), do: Atom.to_string(reason)
    defp stored(reason), do: inspect(reason)

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

    # #1656: the two indexer failures `Cinder.Download.GrabFailure` drops a grab on, and the two
    # codes #1658 holds a book target under, which join no producer list here.
    test "the indexer failure codes read as their sentences, in English and French" do
      sentences = [
        {"indexer_changed",
         "The indexer this release came from was changed or deleted after the search. Search again.",
         "L'indexeur d'où vient cette version a été modifié ou supprimé après la recherche. Relancez une recherche."},
        {"indexer_auth_failed",
         "The indexer rejected Cinder's credentials for this download. Update them in Settings, then search again.",
         "L'indexeur a refusé les identifiants de Cinder pour ce téléchargement. Mettez-les à jour dans les Paramètres, puis relancez une recherche."},
        {"grab_retries_exhausted",
         "The indexer kept failing to send this download. Search again.",
         "Après plusieurs tentatives, l'indexeur n'a pas réussi à envoyer ce téléchargement. Relancez une recherche."},
        {"bad_download_file", "The indexer sent a file that is neither an NZB nor a torrent.",
         "L'indexeur a envoyé un fichier qui n'est ni un NZB ni un torrent."}
      ]

      for {code, english, _french} <- sentences, do: assert(book_hold_reason(code) == english)

      Gettext.put_locale(CinderWeb.Gettext, "fr")
      for {code, _english, french} <- sentences, do: assert(book_hold_reason(code) == french)
    after
      Gettext.put_locale(CinderWeb.Gettext, "en")
    end

    test "a stored code and detail reads as the code's sentence followed by the detail" do
      assert book_hold_reason("download_error: Paused on duplicate") ==
               "The download client reported that the download failed. Details: Paused on duplicate"

      assert book_hold_reason("blocked_content: download contains setup.exe") ==
               "The download holds a blocked file (setup.exe) and no book."
    end

    # #913: the content check's detail is Cinder's own English, so the file goes into the
    # sentence. The detail comes from the real writer, so a change to its wording fails here.
    test "a blocked-content detail reads as one sentence that names the file, in French too" do
      {:blocked, detail} = ContentPolicy.check(["Book/setup.exe"], :book)
      stored = "blocked_content: #{detail}"

      english = book_hold_reason(stored)
      assert english == "The download holds a blocked file (setup.exe) and no book."

      Gettext.put_locale(CinderWeb.Gettext, "fr")
      french = book_hold_reason(stored)

      assert french =~ ~r/^\p{Lu}.*\(setup\.exe\).*\.$/u
      assert french != english

      for text <- [english, french], banned <- ["Details", "Détails", "download contains"] do
        refute text =~ banned, "#{inspect(text)} holds #{inspect(banned)}"
      end
    after
      Gettext.put_locale(CinderWeb.Gettext, "en")
    end

    test "a blocked-content detail with no file name reads as the bare sentence" do
      bare = "The download holds a blocked file, such as a program, and no book."

      for stored <- [
            "blocked_content",
            "blocked_content: ",
            "blocked_content: download contains ",
            "blocked_content: download contains   "
          ] do
        assert book_hold_reason(stored) == bare, inspect(stored)
      end
    end

    test "a blocked-content detail in another shape keeps the sentence and its detail" do
      assert book_hold_reason("blocked_content: something else") ==
               "The download holds a blocked file, such as a program, and no book. " <>
                 "Details: something else"

      assert book_hold_reason("blocked_content: download containssetup.exe") ==
               "The download holds a blocked file, such as a program, and no book. " <>
                 "Details: download containssetup.exe"
    end

    test "a blank detail reads as the code's sentence alone" do
      assert book_hold_reason("download_error: ") ==
               "The download client reported that the download failed."
    end

    # Rows from before #733 read `download_failed` or a bare client message; a reason that was
    # neither an atom nor a `{code, detail}` pair was stored inspected. Only the listed codes and
    # refusals are worded: an unlisted `import_stage_*` code, posix code or destination type, or
    # another inspected tuple, keeps its stored text.
    test "unknown or legacy text is shown as stored, and nil does not raise" do
      for stored <- [
            "download_failed",
            "Paused on duplicate",
            "Error: disk full",
            "ebadf",
            "import_stage_not_committed",
            "{:unexpected_destination_type, :fifo}",
            "{:unexpected_destination_type, :directory, :extra}",
            "{:rooted_error, \"ESPIPE\"}"
          ],
          do: assert(book_hold_reason(stored) == stored)

      assert book_hold_reason(nil) == ""
    end
  end

  test "pipeline_hint/1 names the indexers and the download client for a :search_failed movie, in en and fr" do
    assert pipeline_hint(%{status: :search_failed}) ==
             "Cinder couldn't search the indexers or hand a release to the download client. " <>
               "Open it to retry."

    Gettext.put_locale(CinderWeb.Gettext, "fr")

    assert pipeline_hint(%{status: :search_failed}) ==
             "Cinder n’a pas pu interroger les indexeurs ni transmettre une version au client " <>
               "de téléchargement. Ouvrez sa page pour réessayer."
  after
    Gettext.put_locale(CinderWeb.Gettext, "en")
  end
end
