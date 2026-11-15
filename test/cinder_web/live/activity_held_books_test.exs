defmodule CinderWeb.ActivityHeldBooksTest do
  # #773: a held book target needs attention, so /activity lists it with the Retry and Clear
  # blocklist actions its classification offers, and the Activity nav badge counts it.
  use CinderWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Cinder.BooksFixtures

  alias Cinder.Books
  alias Cinder.Books.BookTarget
  alias Cinder.Repo

  setup :register_and_log_in_admin

  # Moves a target's status in the database without a broadcast, so the open view keeps the
  # snapshot it rendered: the next click acts on a target that has moved on. Only a held target
  # carries a hold reason (`book_targets_hold_reason_valid`).
  defp move_silently(%BookTarget{id: id}, status) do
    {1, _} =
      Repo.update_all(from(t in BookTarget, where: t.id == ^id),
        set: [status: status, hold_reason: nil]
      )

    Repo.get!(BookTarget, id)
  end

  describe "the held books section" do
    test "lists a held e-book and a held audiobook with their kind, actions and a link to the work",
         %{conn: conn} do
      # Earlier works shift the ids, so a link built from the target id would point elsewhere.
      for _ <- 1..3, do: book_work_fixture()
      work = book_work_fixture(title: "The Left Hand of Darkness")
      ebook = book_target_in(:held, :ebook, work)
      audiobook = book_target_in(:held, :audiobook, work)
      refute ebook.id == work.id or audiobook.id == work.id

      {:ok, view, _html} = live(conn, ~p"/activity")

      for {target, kind} <- [{ebook, "eBook"}, {audiobook, "Audiobook"}] do
        row = "#held-book-#{target.id}"

        assert has_element?(
                 view,
                 "#{row} a[href='/books/#{work.id}']",
                 "The Left Hand of Darkness"
               )

        assert has_element?(view, "#held-book-#{target.id}-state", kind)
        assert has_element?(view, "#held-book-#{target.id}-state", "Needs attention")
        assert has_element?(view, "#retry-book-#{target.id}", "Retry")
        assert has_element?(view, "#clear-book-blocklist-#{target.id}", "Clear blocklist")
      end

      assert has_element?(
               view,
               "#retry-book-#{audiobook.id}[aria-label='Retry: The Left Hand of Darkness (audiobook)']"
             )

      assert has_element?(
               view,
               "#clear-book-blocklist-#{ebook.id}[aria-label='Clear blocklist: The Left Hand of Darkness (eBook)']"
             )
    end

    test "shows the hold reason in the words /books/:id uses, not the stored code", %{conn: conn} do
      target = monitored_book_target(:audiobook)
      {:ok, held} = Books.hold_target(target, {:download_error, "Paused on duplicate"})

      {:ok, view, _html} = live(conn, ~p"/activity")
      {:ok, detail, _html} = live(conn, ~p"/books/#{held.work_id}")

      words =
        "The download client reported that the download failed. Details: Paused on duplicate"

      assert has_element?(detail, "#book-target-hold-reason-audiobook", words)
      assert has_element?(view, "#held-book-#{held.id}-reason", words)
      refute has_element?(view, "#held-book-#{held.id}-reason", "download_error")
    end

    test "offers no Clear blocklist for a held target with no blocked release", %{conn: conn} do
      {:ok, held} = Books.hold_target(monitored_book_target(), "identity conflict")

      {:ok, view, _html} = live(conn, ~p"/activity")

      assert has_element?(view, "#retry-book-#{held.id}")
      refute has_element?(view, "#clear-book-blocklist-#{held.id}")
    end

    test "lists no monitored, downloading, available or paused target", %{conn: conn} do
      targets =
        for state <- [:wanted, :grabbing, :available, :replacing, :paused],
            kind <- [:ebook, :audiobook],
            do: book_target_in(state, kind)

      {:ok, view, _html} = live(conn, ~p"/activity")

      refute has_element?(view, "#activity-held-books")
      for t <- targets, do: refute(has_element?(view, "#held-book-#{t.id}"))
    end
  end

  describe "Retry" do
    test "returns the target to monitored through Books.retry_target/1 and drops its row", %{
      conn: conn
    } do
      held = book_target_in(:held, :ebook)
      {:ok, view, _html} = live(conn, ~p"/activity")

      view |> element("#retry-book-#{held.id}") |> render_click()

      assert Repo.get!(BookTarget, held.id).status == :monitored
      refute has_element?(view, "#held-book-#{held.id}")
      # Retry keeps the failed release blocked, as on /books/:id.
      assert Books.blocked_release_titles(held.id) == ["Dead Release"]
    end

    test "refuses a target that is no longer held and leaves it unchanged", %{conn: conn} do
      held = book_target_in(:held, :audiobook)
      {:ok, view, _html} = live(conn, ~p"/activity")
      moved = move_silently(held, :available)

      view |> element("#retry-book-#{held.id}") |> render_click()

      assert has_element?(view, "#flash-error", "Couldn't retry this target. Try again.")
      assert Repo.get!(BookTarget, held.id) == moved
      refute has_element?(view, "#held-book-#{held.id}")
    end
  end

  describe "Clear blocklist" do
    test "clears the blocked releases through Books.clear_blocklist/1 and keeps the target held",
         %{conn: conn} do
      held = book_target_in(:held, :audiobook)
      {:ok, view, _html} = live(conn, ~p"/activity")

      view |> element("#clear-book-blocklist-#{held.id}") |> render_click()

      assert Books.blocked_release_titles(held.id) == []
      assert Repo.get!(BookTarget, held.id).status == :held
      refute has_element?(view, "#clear-book-blocklist-#{held.id}")
      assert has_element?(view, "#retry-book-#{held.id}")
    end

    test "refuses a target that is no longer held and keeps its blocklist", %{conn: conn} do
      held = book_target_in(:held, :ebook)
      {:ok, view, _html} = live(conn, ~p"/activity")
      moved = move_silently(held, :monitored)

      view |> element("#clear-book-blocklist-#{held.id}") |> render_click()

      assert has_element?(
               view,
               "#flash-error",
               "This target is no longer held, so its blocklist stays."
             )

      assert Books.blocked_release_titles(held.id) == ["Dead Release"]
      assert Repo.get!(BookTarget, held.id) == moved
      refute has_element?(view, "#held-book-#{held.id}")
    end
  end

  describe "live updates" do
    test "a target joins the list when it is held and leaves it once it is not", %{conn: conn} do
      target = monitored_book_target(:ebook)
      {:ok, view, _html} = live(conn, ~p"/activity")
      refute has_element?(view, "#held-book-#{target.id}")

      {:ok, held} = Books.hold_target(target, :download_failed, "Dead Release")
      assert has_element?(view, "#held-book-#{target.id}")
      # The hold's broadcast follows its blocked release, so the re-read finds it.
      assert has_element?(view, "#clear-book-blocklist-#{target.id}")

      {:ok, _retried} = Books.retry_target(held)
      refute has_element?(view, "#held-book-#{target.id}")
    end

    test "the Activity nav badge counts a held target and drops it once retried", %{conn: conn} do
      target = monitored_book_target(:audiobook)
      {:ok, view, _html} = live(conn, ~p"/calendar")
      refute has_element?(view, ~s(a[href="/activity"] .badge))

      {:ok, held} = Books.hold_target(target, "identity conflict")
      assert has_element?(view, ~s(a[href="/activity"] .badge[aria-label="1 need attention"]))

      {:ok, _retried} = Books.retry_target(held)
      refute has_element?(view, ~s(a[href="/activity"] .badge))
    end
  end
end
