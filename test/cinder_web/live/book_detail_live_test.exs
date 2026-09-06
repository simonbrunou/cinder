defmodule CinderWeb.BookDetailLiveTest do
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox

  alias Cinder.AccountsFixtures
  alias Cinder.Acquisition.IndexerMock
  alias Cinder.Books
  alias Cinder.Books.{BookGrab, BookTarget, PrimaryMetadataMock}
  alias Cinder.Catalog
  alias Cinder.Repo

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

    test "a monitored audiobook target with no grab offers a search button", %{conn: conn} do
      {target, _work} = audiobook_target()

      {:ok, lv, _html} = live(conn, ~p"/books/#{target.work_id}")

      assert has_element?(
               lv,
               "button[phx-value-target_id='#{target.id}']",
               "Search for a release"
             )
    end

    test "the same work's e-book and audiobook targets can each independently be searched",
         %{conn: conn} do
      {ebook, work} = ebook_target()

      {:ok, audio_profile} =
        Catalog.create_profile(%{
          name: "Audio #{unique_id()}",
          kind: :audiobook,
          handling: :standard
        })

      {:ok, audiobook} = Books.monitor_target(work, :audiobook, audio_profile)

      stub_indexer([])
      stub_audiobook_indexer([])

      {:ok, lv, _html} = live(conn, ~p"/books/#{work.id}")

      # The panel toggle is one `@searching?` value shared by the page (opening a second panel
      # closes the first) — each kind's OWN panel still opens and renders correctly, which is
      # the property under test: an audiobook target is no longer read-only, independent of the
      # e-book target on the same work.
      lv |> element("button[phx-value-target_id='#{ebook.id}']") |> render_click()
      render_async(lv)
      assert has_element?(lv, "#ms-book-#{ebook.id}")

      lv |> element("button[phx-value-target_id='#{audiobook.id}']") |> render_click()
      render_async(lv)
      assert has_element?(lv, "#ms-book-#{audiobook.id}")
      refute has_element?(lv, "#ms-book-#{ebook.id}")
    end

    test "an available target offers 'Find a better match', not the search button", %{conn: conn} do
      {target, _work} = ebook_target()

      {:ok, _file} =
        Books.Files.record_import(target, %{
          path: "/tmp/book-#{target.id}.epub",
          size: 12_345,
          format: :epub
        })

      {:ok, lv, _html} = live(conn, ~p"/books/#{target.work_id}")

      assert has_element?(lv, "#book-target-state-ebook", "Available")

      refute has_element?(
               lv,
               "button[phx-value-target_id='#{target.id}']",
               "Search for a release"
             )

      assert has_element?(
               lv,
               "button[phx-value-target_id='#{target.id}']",
               "Find a better match"
             )
    end

    test "a linked but unmonitored target shows an explicit badge, not a blank one", %{
      conn: conn
    } do
      {:ok, work} =
        Books.upsert_work(%{title: "Paused #{unique_id()}", identifier: identifier()})

      {:ok, target} = Books.ensure_target(work, :ebook)
      assert target.status == :unmonitored

      {:ok, lv, _html} = live(conn, ~p"/books/#{work.id}")

      assert has_element?(lv, "#book-target-state-ebook", "Unmonitored")
    end

    test "a held target shows its hold reason, a Retry button, and no search panel", %{
      conn: conn
    } do
      {target, _work} = ebook_target()
      {:ok, held} = Books.hold_target(target, "identity conflict")

      {:ok, lv, _html} = live(conn, ~p"/books/#{held.work_id}")

      assert has_element?(lv, "#book-target-state-ebook", "Needs attention")
      assert has_element?(lv, "#book-target-hold-reason-ebook", "identity conflict")

      refute has_element?(
               lv,
               "button[phx-value-target_id='#{target.id}']",
               "Search for a release"
             )

      assert has_element?(lv, "button[phx-value-target_id='#{target.id}']", "Retry")
    end

    test "a held audiobook target shows its hold reason, a Retry button, and no search panel", %{
      conn: conn
    } do
      {target, _work} = audiobook_target()
      {:ok, held} = Books.hold_target(target, "identity conflict")

      {:ok, lv, _html} = live(conn, ~p"/books/#{held.work_id}")

      assert has_element?(lv, "#book-target-state-audiobook", "Needs attention")
      assert has_element?(lv, "#book-target-hold-reason-audiobook", "identity conflict")

      refute has_element?(
               lv,
               "button[phx-value-target_id='#{target.id}']",
               "Search for a release"
             )

      assert has_element?(lv, "button[phx-value-target_id='#{target.id}']", "Retry")

      lv |> element("button[phx-value-target_id='#{target.id}']", "Retry") |> render_click()

      assert Books.get_target(target.id).status == :monitored
    end

    test "a held audiobook target with a blocklisted release shows Clear blocklist, and clicking
          it removes the button immediately",
         %{conn: conn} do
      {target, _work} = audiobook_target()
      {:ok, held} = Books.hold_target(target, :download_failed, "Bad Release", true)

      {:ok, lv, _html} = live(conn, ~p"/books/#{held.work_id}")

      assert has_element?(lv, "button[phx-value-target_id='#{target.id}']", "Clear blocklist")

      render_click(lv, "clear_blocklist", %{"target_id" => Integer.to_string(target.id)})

      refute has_element?(lv, "button[phx-value-target_id='#{target.id}']", "Clear blocklist")
      assert Books.blocked_release_titles(target.id) == []
    end

    test "a held target with a blocklisted release shows Clear blocklist, and clicking it
          removes the button immediately",
         %{conn: conn} do
      {target, _work} = ebook_target()
      {:ok, held} = Books.hold_target(target, :download_failed, "Bad Release", true)

      {:ok, lv, _html} = live(conn, ~p"/books/#{held.work_id}")

      assert has_element?(lv, "button[phx-value-target_id='#{target.id}']", "Clear blocklist")

      render_click(lv, "clear_blocklist", %{"target_id" => Integer.to_string(target.id)})

      # The bug this defends against: the button's visibility used to be gated on a live
      # `Books.blocked_release_titles/1` read inside a `:for` keyed off `@work`, an assign the
      # handler never touched — LiveView's change tracking then reused the prior render and the
      # button stayed on screen even though the underlying blocklist was already empty.
      refute has_element?(lv, "button[phx-value-target_id='#{target.id}']", "Clear blocklist")
      assert Books.blocked_release_titles(target.id) == []
    end

    test "a retry_target payload naming another work's (audiobook) target is refused", %{
      conn: conn
    } do
      {target, _work} = ebook_target()
      {other_target, _other_work} = audiobook_target()
      {:ok, other_held} = Books.hold_target(other_target, "unrelated conflict")

      {:ok, lv, _html} = live(conn, ~p"/books/#{target.work_id}")

      render_click(lv, "retry_target", %{"target_id" => Integer.to_string(other_held.id)})

      assert Books.get_target(other_held.id).status == :held
    end

    test "a clear_blocklist payload naming another work's (audiobook) target is refused", %{
      conn: conn
    } do
      {target, _work} = ebook_target()
      {other_target, _other_work} = audiobook_target()
      {:ok, other_held} = Books.hold_target(other_target, :download_failed, "Bad Release", true)

      {:ok, lv, _html} = live(conn, ~p"/books/#{target.work_id}")

      render_click(lv, "clear_blocklist", %{"target_id" => Integer.to_string(other_held.id)})

      refute Books.blocked_release_titles(other_held.id) == []
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

    test "a target's preferred_language gates a wrong-language release, through the real search",
         %{conn: conn} do
      {target, _work} = ebook_target(title: "The Dispossessed")
      {:ok, target} = Books.set_target_language(target, "fr")

      stub_indexer([
        indexer_result("Ursula K. Le Guin - The Dispossessed (French) (EPUB)"),
        indexer_result("Ursula K. Le Guin - The Dispossessed (EPUB)")
      ])

      {:ok, lv, _html} = live(conn, ~p"/books/#{target.work_id}")

      lv |> element("button[phx-value-target_id='#{target.id}']") |> render_click()
      render_async(lv)

      panel = "#ms-book-#{target.id}"
      assert has_element?(lv, panel, "Ursula K. Le Guin - The Dispossessed (French) (EPUB)")
      assert has_element?(lv, panel, "language doesn't match")
    end

    test "no preferred_language accepts a release in any language, through the real search",
         %{conn: conn} do
      {target, _work} = ebook_target(title: "The Dispossessed")
      refute target.preferred_language

      stub_indexer([
        indexer_result("Ursula K. Le Guin - The Dispossessed (French) (EPUB)"),
        indexer_result("Ursula K. Le Guin - The Dispossessed (EPUB)")
      ])

      {:ok, lv, _html} = live(conn, ~p"/books/#{target.work_id}")

      lv |> element("button[phx-value-target_id='#{target.id}']") |> render_click()
      render_async(lv)

      panel = "#ms-book-#{target.id}"
      assert has_element?(lv, panel, "Ursula K. Le Guin - The Dispossessed (French) (EPUB)")
      assert has_element?(lv, panel, "Ursula K. Le Guin - The Dispossessed (EPUB)")
      refute has_element?(lv, panel, "language doesn't match")
    end

    # #495: changing the language while the panel stays open must restart the search under the
    # new preference, and a search that was already in flight under the OLD preference must
    # never land afterward — even when it completes later than the fresh, post-change search.
    # `search_book` is called once per `Books.candidates/2` invocation (the structured query in
    # `Acquisition.Books.plan/1`), so blocking the FIRST call and racing a language change against
    # it exercises the real `start_async`/`cancel_async` ref machinery, not just `update/2`.
    test "changing the language mid-search restarts it, and a late pre-change result never lands",
         %{conn: conn} do
      {target, _work} = ebook_target(title: "The Dispossessed")
      test_pid = self()

      Mox.expect(IndexerMock, :search_book, fn _author, _title, _opts ->
        send(test_pid, {:old_search_started, self()})

        receive do
          :release -> :ok
        end

        {:ok, [indexer_result("Ursula K. Le Guin - The Dispossessed (Stale English) (EPUB)")]}
      end)

      Mox.expect(IndexerMock, :search_book, fn _author, _title, _opts ->
        {:ok, [indexer_result("Ursula K. Le Guin - The Dispossessed (French) (EPUB)")]}
      end)

      stub(IndexerMock, :search_book_query, fn _query, _opts -> {:ok, []} end)

      {:ok, lv, _html} = live(conn, ~p"/books/#{target.work_id}")

      lv |> element("button[phx-value-target_id='#{target.id}']") |> render_click()
      assert_receive {:old_search_started, old_task}

      {:ok, _target} = Books.set_target_language(target, "fr")

      panel = "#ms-book-#{target.id}"

      # Bounded wait for the fast, post-change search to land — not a race against the stale one,
      # which stays deliberately blocked until explicitly released below.
      assert Enum.reduce_while(1..50, false, fn _, _ ->
               if has_element?(lv, panel, "French") do
                 {:halt, true}
               else
                 Process.sleep(10)
                 {:cont, false}
               end
             end),
             "the post-change search never landed"

      refute has_element?(lv, panel, "Stale English")

      send(old_task, :release)
      Process.sleep(200)

      refute has_element?(lv, panel, "Stale English")
      assert has_element?(lv, panel, "French")
    end
  end

  describe "audiobook manual search and grab" do
    test "search shows accepted and rejected releases, and Grab succeeds", %{conn: conn} do
      {target, _work} = audiobook_target(title: "The Dispossessed")

      stub_audiobook_indexer([
        indexer_result("Ursula K. Le Guin - The Dispossessed (M4B)", %{size: 40_000_000}),
        indexer_result("Ursula K. Le Guin - The Dispossessed (EPUB)", %{size: 40_000_000})
      ])

      expect(Cinder.Download.ClientMock, :find_by_operation_key, fn _key -> :not_found end)
      expect(Cinder.Download.ClientMock, :add, fn _release, _opts -> {:ok, "remote-1"} end)

      {:ok, lv, _html} = live(conn, ~p"/books/#{target.work_id}")

      lv |> element("button[phx-value-target_id='#{target.id}']") |> render_click()
      render_async(lv)

      panel = "#ms-book-#{target.id}"
      assert has_element?(lv, panel, "The Dispossessed (M4B)")
      assert has_element?(lv, panel, "format not accepted")

      lv |> element("#{panel} button[phx-value-index='0']", "Grab") |> render_click()

      assert render(lv) =~ "Grabbing the selected release"
      refute has_element?(lv, panel)
      assert has_element?(lv, "#book-target-audiobook", "Downloading")
      assert %BookGrab{} = Books.Grabs.for_target(target.id)
    end

    test "a permanent submission failure holds the target and the flash shows the real reason",
         %{conn: conn} do
      {target, _work} = audiobook_target(title: "The Dispossessed")

      stub_audiobook_indexer([
        indexer_result("Ursula K. Le Guin - The Dispossessed (M4B)", %{size: 40_000_000})
      ])

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
      assert has_element?(lv, "#book-target-state-audiobook", "Needs attention")
      refute Books.Grabs.for_target(target.id)
    end
  end

  describe "language preference" do
    test "picking a language from the select persists it and re-renders without reload", %{
      conn: conn
    } do
      {target, _work} = ebook_target()

      {:ok, lv, _html} = live(conn, ~p"/books/#{target.work_id}")

      lv
      |> form("#book-target-language-ebook", %{"language" => "fr"})
      |> render_change()

      assert Books.get_target(target.id).preferred_language == "fr"
      assert has_element?(lv, ~s(#book-target-language-ebook option[value="fr"][selected]))
    end

    test "an unrecognized language code is refused, not persisted verbatim", %{conn: conn} do
      {target, _work} = ebook_target()

      {:ok, lv, _html} = live(conn, ~p"/books/#{target.work_id}")

      render_change(lv, "set_language", %{
        "target_id" => to_string(target.id),
        "language" => "totally-not-a-real-language"
      })

      assert Books.get_target(target.id).preferred_language == nil
    end

    test "a non-string language payload is ignored, not a crash", %{conn: conn} do
      {target, _work} = ebook_target()

      {:ok, lv, _html} = live(conn, ~p"/books/#{target.work_id}")

      render_change(lv, "set_language", %{
        "target_id" => to_string(target.id),
        "language" => ["fr"]
      })

      assert Books.get_target(target.id).preferred_language == nil
    end

    test "a target_id from another work is refused", %{conn: conn} do
      {target, _work} = ebook_target()
      {other_target, _other_work} = ebook_target()

      {:ok, lv, _html} = live(conn, ~p"/books/#{target.work_id}")

      render_change(lv, "set_language", %{
        "target_id" => to_string(other_target.id),
        "language" => "fr"
      })

      assert Books.get_target(other_target.id).preferred_language == nil
    end
  end

  describe "author monitoring policy" do
    test "the control is hidden until the work has an approved ebook target", %{conn: conn} do
      {:ok, work} =
        Books.upsert_work(%{title: "No target yet #{unique_id()}", identifier: identifier()})

      {:ok, lv, _html} = live(conn, ~p"/books/#{work.id}")

      refute has_element?(lv, "#book-author-policies")
    end

    test "the select reflects the stored policy, and reverting to Selected works applies
          immediately with no preview",
         %{conn: conn} do
      {target, work} = ebook_target()
      %{author: author} = hd(work.credits)
      profile = Catalog.get_profile(target.profile_id)

      {:ok, _policy} = Books.set_author_policy(author, :future, profile)

      {:ok, lv, _html} = live(conn, ~p"/books/#{work.id}")

      assert has_element?(
               lv,
               ~s(#author-policy-form-#{author.id} option[value="future"][selected])
             )

      # No `bibliography`/`get_work` stub is registered — a preview here would raise
      # `Mox.UnexpectedCallError` rather than silently succeeding.
      lv
      |> form("#author-policy-form-#{author.id}", %{"policy" => "specific"})
      |> render_change()

      assert Books.author_policy(author.id) == :specific
      refute has_element?(lv, "#author-policy-#{author.id}", "Confirm")
    end

    test "choosing All works previews the eligible count, and Confirm arms exactly that
          candidate",
         %{conn: conn} do
      {_target, work} = ebook_target()
      %{author: author} = hd(work.credits)

      stub(PrimaryMetadataMock, :provider, fn -> :openlibrary end)

      expect(PrimaryMetadataMock, :bibliography, fn _foreign_id ->
        {:ok, [candidate("OLNEWBOOKW")]}
      end)

      expect(PrimaryMetadataMock, :get_work, fn "OLNEWBOOKW" ->
        {:ok, provider_work("OLNEWBOOKW")}
      end)

      {:ok, lv, _html} = live(conn, ~p"/books/#{work.id}")

      lv
      |> form("#author-policy-form-#{author.id}", %{"policy" => "all"})
      |> render_change()

      render_async(lv)

      assert has_element?(
               lv,
               "#author-policy-#{author.id}",
               "1 new eBook would be monitored"
             )

      before_count = Repo.aggregate(BookTarget, :count)

      lv
      |> element("#author-policy-#{author.id} button", "Confirm")
      |> render_click()

      assert Repo.aggregate(BookTarget, :count) == before_count + 1
      assert Books.author_policy(author.id) == :all
      assert render(lv) =~ "1 eBook is now monitored"
      refute has_element?(lv, "#author-policy-#{author.id}", "Confirm")

      # Confirming already recorded the policy — the "Preview again" escape hatch
      # (`remaining_note/1`'s own promise) is now available without toggling back to Selected.
      assert has_element?(lv, "#author-policy-#{author.id}", "Preview again")

      expect(PrimaryMetadataMock, :bibliography, fn _foreign_id ->
        {:ok, [candidate("OLNEXTW")]}
      end)

      expect(PrimaryMetadataMock, :get_work, fn "OLNEXTW" -> {:ok, provider_work("OLNEXTW")} end)

      lv
      |> element("#author-policy-#{author.id} button", "Preview again")
      |> render_click()

      render_async(lv)
      assert has_element?(lv, "#author-policy-#{author.id}", "1 new eBook would be monitored")
    end

    test "a candidate independently monitored before Confirm is reported as short of the
          preview",
         %{conn: conn} do
      {_target, work} = ebook_target()
      %{author: author} = hd(work.credits)

      stub(PrimaryMetadataMock, :provider, fn -> :openlibrary end)

      expect(PrimaryMetadataMock, :bibliography, fn _foreign_id ->
        {:ok, [candidate("OLRACEW")]}
      end)

      expect(PrimaryMetadataMock, :get_work, fn "OLRACEW" -> {:ok, provider_work("OLRACEW")} end)

      {:ok, lv, _html} = live(conn, ~p"/books/#{work.id}")

      lv
      |> form("#author-policy-form-#{author.id}", %{"policy" => "all"})
      |> render_change()

      render_async(lv)

      # The race, before Confirm is ever clicked: something else monitors the same candidate
      # under a different profile.
      {:ok, race_profile} =
        Catalog.create_profile(%{name: "Raced eBooks", kind: :ebook, handling: :standard})

      {:ok, raced_work} =
        Books.import_resolution(%{provider: :openlibrary, work: provider_work("OLRACEW")})

      {:ok, raced_target} = Books.monitor_target(raced_work, :ebook, race_profile)

      lv
      |> element("#author-policy-#{author.id} button", "Confirm")
      |> render_click()

      assert render(lv) =~ "0 of 1 previewed works are now monitored"
      assert Repo.get!(BookTarget, raced_target.id).profile_id == race_profile.id
    end

    test "an ambiguous candidate is never offered as eligible", %{conn: conn} do
      {_target, work} = ebook_target()
      %{author: author} = hd(work.credits)

      stub(PrimaryMetadataMock, :provider, fn -> :openlibrary end)

      expect(PrimaryMetadataMock, :bibliography, fn _foreign_id ->
        {:ok, [candidate("OLBADW")]}
      end)

      expect(PrimaryMetadataMock, :get_work, fn "OLBADW" -> {:error, :timeout} end)

      {:ok, lv, _html} = live(conn, ~p"/books/#{work.id}")

      lv
      |> form("#author-policy-form-#{author.id}", %{"policy" => "all"})
      |> render_change()

      render_async(lv)

      assert has_element?(lv, "#author-policy-#{author.id}", "Nothing new to monitor")
      assert has_element?(lv, "#author-policy-#{author.id}", "could not be identified")

      # Confirming at 0 eligible still records the policy but creates nothing — the ambiguous
      # candidate is never monitored, by construction, since it never entered `eligible`.
      before_count = Repo.aggregate(BookTarget, :count)

      lv
      |> element("#author-policy-#{author.id} button", "Confirm")
      |> render_click()

      assert Repo.aggregate(BookTarget, :count) == before_count
      assert Books.author_policy(author.id) == :all
    end

    test "a cross-work author_id or a forged policy value is ignored", %{conn: conn} do
      {_target, work} = ebook_target()
      {_other_target, other_work} = ebook_target()
      %{author: other_author} = hd(other_work.credits)

      {:ok, lv, _html} = live(conn, ~p"/books/#{work.id}")

      render_change(lv, "set_author_policy", %{
        "author_id" => to_string(other_author.id),
        "policy" => "all"
      })

      assert Books.author_policy(other_author.id) == :specific

      %{author: author} = hd(work.credits)

      render_change(lv, "set_author_policy", %{
        "author_id" => to_string(author.id),
        "policy" => "not-a-real-policy"
      })

      assert Books.author_policy(author.id) == :specific
    end

    test "confirming with no held preview is ignored, not a crash", %{conn: conn} do
      {_target, work} = ebook_target()
      %{author: author} = hd(work.credits)
      before_count = Repo.aggregate(BookTarget, :count)

      {:ok, lv, _html} = live(conn, ~p"/books/#{work.id}")

      render_click(lv, "confirm_author_policy", %{"author_id" => to_string(author.id)})

      assert Repo.aggregate(BookTarget, :count) == before_count
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

  defp stub_audiobook_indexer(releases) do
    stub(IndexerMock, :search_audiobook, fn _author, _title, _opts -> {:ok, releases} end)
    stub(IndexerMock, :search_audiobook_query, fn _query, _opts -> {:ok, []} end)
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

  defp audiobook_target(opts \\ []) do
    id = unique_id()

    {:ok, profile} =
      Catalog.create_profile(%{name: "Audiobooks #{id}", kind: :audiobook, handling: :standard})

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

    {:ok, %BookTarget{} = target} = Books.monitor_target(work, :audiobook, profile)

    {target, Books.get_work(work.id)}
  end

  defp identifier(id \\ unique_id()),
    do: %{provider: "openlibrary", kind: "work", foreign_id: id}

  defp candidate(foreign_id) do
    %{
      provider: :openlibrary,
      foreign_id: foreign_id,
      title: "New Book #{foreign_id}",
      contributors: [%{foreign_id: "a", name: "Author", role: "author"}],
      contributors_incomplete: false,
      first_published_year: nil,
      edition_count: 1
    }
  end

  defp provider_work(foreign_id) do
    %{
      provider: :openlibrary,
      foreign_id: foreign_id,
      title: "New Book #{foreign_id}",
      first_published_on: ~D[2000-01-01],
      overview: nil,
      contributors: [%{foreign_id: "a", name: "Author", role: "author"}],
      contributors_incomplete: false,
      editions: [
        %{
          foreign_id: foreign_id <> "-ED",
          media_kind: :ebook,
          title: "New Book #{foreign_id}",
          language: "eng",
          format: nil,
          publisher: nil,
          release_date: nil,
          abridged: nil,
          isbn13: nil,
          asin: nil
        }
      ],
      series: []
    }
  end

  defp unique_id, do: Integer.to_string(System.unique_integer([:positive]))
end
