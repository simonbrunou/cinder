defmodule CinderWeb.BookDetailLiveTest do
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox

  alias Cinder.AccountsFixtures
  alias Cinder.Acquisition.IndexerMock
  alias Cinder.Books
  alias Cinder.Books.{BookGrab, BookTarget}
  alias Cinder.Catalog

  setup :register_and_log_in_admin
  setup :set_mox_global
  setup :verify_on_exit!

  describe "gating" do
    test "a non-admin is redirected with a flash" do
      {target, _work} = ebook_target()
      conn = build_conn() |> log_in_user(AccountsFixtures.user_fixture())

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/books/#{target.work_id}")
    end
  end

  describe "mount param safety" do
    test "a non-integer id redirects to /requests instead of crashing", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/requests"}}} = live(conn, "/books/not-a-number")
    end

    test "a nonexistent work id redirects to /requests", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/requests"}}} = live(conn, ~p"/books/999999999")
    end
  end

  describe "pipeline rendering" do
    test "a work with no approved target shows 'Not yet approved'", %{conn: conn} do
      {:ok, work} =
        Books.upsert_work(%{title: "Untouched #{unique_id()}", identifier: identifier()})

      {:ok, _lv, html} = live(conn, ~p"/books/#{work.id}")

      assert html =~ "Not yet approved."
    end

    test "a monitored ebook target with no grab offers a search button", %{conn: conn} do
      {target, _work} = ebook_target()

      {:ok, lv, _html} = live(conn, ~p"/books/#{target.work_id}")

      assert has_element?(
               lv,
               "button[phx-value-target_id='#{target.id}']",
               "Search for a release"
             )
    end

    test "an audiobook target renders read-only with no search affordance", %{conn: conn} do
      {_ebook, work} = ebook_target()

      {:ok, audio_profile} =
        Catalog.create_profile(%{
          name: "Audio #{unique_id()}",
          kind: :audiobook,
          handling: :standard
        })

      {:ok, audiobook} = Books.monitor_target(work, :audiobook, audio_profile)

      {:ok, lv, _html} = live(conn, ~p"/books/#{work.id}")

      assert has_element?(lv, "#book-target-state-audiobook")
      refute has_element?(lv, "button[phx-value-target_id='#{audiobook.id}']")
    end

    test "an available target shows no search panel", %{conn: conn} do
      {target, _work} = ebook_target()

      {:ok, _file} =
        Books.Files.record_import(target, %{
          path: "/tmp/book-#{target.id}.epub",
          size: 12_345,
          format: :epub
        })

      {:ok, lv, _html} = live(conn, ~p"/books/#{target.work_id}")

      assert has_element?(lv, "#book-target-state-ebook", "Available")
      refute has_element?(lv, "button[phx-value-target_id='#{target.id}']")
    end

    test "a held target shows its hold reason and no search panel", %{conn: conn} do
      {target, _work} = ebook_target()
      {:ok, held} = Books.hold_target(target, "identity conflict")

      {:ok, lv, _html} = live(conn, ~p"/books/#{held.work_id}")

      assert has_element?(lv, "#book-target-state-ebook", "Needs attention")
      assert has_element?(lv, "#book-target-hold-reason-ebook", "identity conflict")
      refute has_element?(lv, "button[phx-value-target_id='#{target.id}']")
    end

    test "a target already downloading offers no second search button", %{conn: conn} do
      {target, _work} = ebook_target()
      {:ok, _grab} = Books.Grabs.create(target.id, "remote-1", :torrent, "Some Release")

      {:ok, lv, _html} = live(conn, ~p"/books/#{target.work_id}")

      refute has_element?(lv, "button[phx-value-target_id='#{target.id}']")
      assert has_element?(lv, "#book-target-ebook", "Downloading")
    end

    test "a malformed target_id on the manual_search event is ignored, not a crash", %{
      conn: conn
    } do
      {target, _work} = ebook_target()

      {:ok, lv, _html} = live(conn, ~p"/books/#{target.work_id}")

      render_click(lv, "manual_search", %{"target_id" => "not-a-number"})

      refute has_element?(lv, "#ms-book-#{target.id}")
    end

    test "a non-string target_id on the manual_search event is ignored, not a crash", %{
      conn: conn
    } do
      {target, _work} = ebook_target()

      {:ok, lv, _html} = live(conn, ~p"/books/#{target.work_id}")

      render_click(lv, "manual_search", %{"target_id" => ["1"]})

      refute has_element?(lv, "#ms-book-#{target.id}")
    end
  end

  describe "manual search and grab" do
    test "search shows accepted and rejected releases, and Grab succeeds", %{conn: conn} do
      {target, _work} = ebook_target(title: "The Dispossessed")

      stub_indexer([
        indexer_result("Ursula K. Le Guin - The Dispossessed (EPUB)"),
        indexer_result("Ursula K. Le Guin - The Dispossessed (PDF)")
      ])

      expect(Cinder.Download.ClientMock, :find_by_operation_key, fn _key -> :not_found end)
      expect(Cinder.Download.ClientMock, :add, fn _release, _opts -> {:ok, "remote-1"} end)

      {:ok, lv, _html} = live(conn, ~p"/books/#{target.work_id}")

      lv |> element("button[phx-value-target_id='#{target.id}']") |> render_click()
      render_async(lv)

      panel = "#ms-book-#{target.id}"
      assert has_element?(lv, panel, "The Dispossessed (EPUB)")
      assert has_element?(lv, panel, "format not accepted")

      lv |> element("#{panel} button[phx-value-index='0']", "Grab") |> render_click()

      assert render(lv) =~ "Grabbing the selected release"
      refute has_element?(lv, panel)
      assert has_element?(lv, "#book-target-ebook", "Downloading")
      assert %BookGrab{} = Books.Grabs.for_target(target.id)
    end

    test "a permanent submission failure holds the target and the flash shows the real reason",
         %{conn: conn} do
      {target, _work} = ebook_target(title: "The Dispossessed")

      stub_indexer([indexer_result("Ursula K. Le Guin - The Dispossessed (EPUB)")])

      expect(Cinder.Download.ClientMock, :find_by_operation_key, fn _key -> :not_found end)
      expect(Cinder.Download.ClientMock, :add, fn _release, _opts -> {:error, :bad_torrent} end)

      {:ok, lv, _html} = live(conn, ~p"/books/#{target.work_id}")

      lv |> element("button[phx-value-target_id='#{target.id}']") |> render_click()
      render_async(lv)

      panel = "#ms-book-#{target.id}"
      lv |> element("#{panel} button[phx-value-index='0']", "Grab") |> render_click()

      html = render(lv)
      held = Books.get_target(target.id)
      assert held.status == :held
      assert html =~ held.hold_reason
      assert has_element?(lv, "#book-target-state-ebook", "Needs attention")
      refute Books.Grabs.for_target(target.id)
    end

    test "a client hiccup (non-permanent error) leaves the target monitored with generic copy",
         %{conn: conn} do
      {target, _work} = ebook_target(title: "The Dispossessed")

      stub_indexer([indexer_result("Ursula K. Le Guin - The Dispossessed (EPUB)")])

      expect(Cinder.Download.ClientMock, :find_by_operation_key, fn _key ->
        {:error, :unreachable}
      end)

      {:ok, lv, _html} = live(conn, ~p"/books/#{target.work_id}")

      lv |> element("button[phx-value-target_id='#{target.id}']") |> render_click()
      render_async(lv)

      panel = "#ms-book-#{target.id}"
      lv |> element("#{panel} button[phx-value-index='0']", "Grab") |> render_click()

      assert render(lv) =~ "submit this release"
      assert has_element?(lv, "#book-target-state-ebook", "Approved")
    end
  end

  describe "live updates" do
    test "a {:book_target_updated} broadcast reflects a hold without a manual reload", %{
      conn: conn
    } do
      {target, _work} = ebook_target()

      {:ok, lv, _html} = live(conn, ~p"/books/#{target.work_id}")
      refute render(lv) =~ "Needs attention"

      {:ok, _held} = Books.hold_target(target, "operator conflict")

      assert render(lv) =~ "Needs attention"
      assert render(lv) =~ "operator conflict"
    end

    test "a {:book_grab_updated} broadcast renders live download progress", %{conn: conn} do
      {target, _work} = ebook_target()
      {:ok, grab} = Books.Grabs.create(target.id, "remote-1", :torrent, "Some Release")

      {:ok, lv, _html} = live(conn, ~p"/books/#{target.work_id}")
      refute render(lv) =~ "50%"

      {:ok, _} =
        Books.Grabs.track(grab, %{download_progress: 0.5, download_speed: 100, download_eta: 60})

      assert render(lv) =~ "50%"
    end

    test "a broadcast for an unrelated work is ignored", %{conn: conn} do
      {target, _work} = ebook_target()
      {other_target, _other_work} = ebook_target()

      {:ok, lv, _html} = live(conn, ~p"/books/#{target.work_id}")

      {:ok, _held} = Books.hold_target(other_target, "unrelated conflict")

      refute render(lv) =~ "unrelated conflict"
    end

    test "a grab's badge does not outlive Grabs.delete/1's own corrective broadcast", %{
      conn: conn
    } do
      {target, _work} = ebook_target()
      {:ok, grab} = Books.Grabs.create(target.id, "remote-1", :torrent, "Some Release")

      {:ok, lv, _html} = live(conn, ~p"/books/#{target.work_id}")
      assert has_element?(lv, "#book-target-ebook", "Downloading")

      # Reproduces #403's race deterministically rather than by scheduling luck:
      # `Books.hold_target/2` alone — exactly what `BookPoller.hold/3` calls first — commits the
      # target's terminal status and broadcasts `{:book_target_updated, held}`, but never touches
      # the grab. This view reloads on that broadcast and re-reads a grab that is still there.
      assert {:ok, held} = Books.hold_target(target, "operator conflict")
      assert held.status == :held
      assert %BookGrab{} = Books.Grabs.for_target(target.id)

      assert render(lv) =~ "Needs attention"
      assert has_element?(lv, "#book-target-ebook", "Downloading")

      # The corrective: deleting the grab (as the poller does next, in production) broadcasts
      # {:book_grab_deleted, target_id} on its own — no further target broadcast is coming, since
      # the target already reached its terminal state above — and that alone clears the stale
      # badge.
      assert :ok = Books.Grabs.delete(grab)
      refute has_element?(lv, "#book-target-ebook", "Downloading")
    end
  end

  defp stub_indexer(releases) do
    stub(IndexerMock, :search_book, fn _author, _title, _opts -> {:ok, releases} end)
    stub(IndexerMock, :search_book_query, fn _query, _opts -> {:ok, []} end)
  end

  defp indexer_result(title, attrs \\ %{}) do
    Map.merge(
      %{
        title: title,
        size: 2_000_000,
        download_url: "http://indexer.test/#{:erlang.phash2(title)}",
        protocol: :torrent,
        query_origins: [:free_text]
      },
      attrs
    )
  end

  defp ebook_target(opts \\ []) do
    id = unique_id()

    {:ok, profile} =
      Catalog.create_profile(%{name: "Ebooks #{id}", kind: :ebook, handling: :standard})

    {:ok, work} =
      Books.upsert_work(%{
        title: Keyword.get(opts, :title, "The Dispossessed #{id}"),
        identifier: identifier(id)
      })

    {:ok, author} =
      Books.upsert_author(%{
        name: "Ursula K. Le Guin",
        identifier: %{provider: "openlibrary", kind: "author", foreign_id: "a#{id}"}
      })

    {:ok, _credit} = Books.put_credit(work, %{author_id: author.id, role: "author", position: 0})

    {:ok, %BookTarget{} = target} = Books.monitor_target(work, :ebook, profile)

    {target, Books.get_work(work.id)}
  end

  defp identifier(id \\ unique_id()),
    do: %{provider: "openlibrary", kind: "work", foreign_id: id}

  defp unique_id, do: Integer.to_string(System.unique_integer([:positive]))
end
