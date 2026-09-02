defmodule CinderWeb.LibraryLiveTest do
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox

  alias Cinder.Books
  alias Cinder.Books.Grabs
  alias Cinder.Catalog
  alias Cinder.Repo

  import Cinder.CatalogFixtures

  setup :register_and_log_in_admin
  setup :set_mox_global

  setup do
    # cancel_movie may remove an active download via the client; default to a no-op.
    stub(Cinder.Download.ClientMock, :remove, fn _id, _opts -> :ok end)
    stub(Cinder.Download.SabnzbdClientMock, :remove, fn _id, _opts -> :ok end)
    # Mounting `/` (the redirect-target assertions) fetches the landing rails; default them empty.
    stub(Cinder.Catalog.TMDBMock, :trending, fn _ -> {:ok, []} end)
    stub(Cinder.Catalog.TMDBMock, :popular_movies, fn _ -> {:ok, []} end)
    stub(Cinder.Catalog.TMDBMock, :top_rated_movies, fn _ -> {:ok, []} end)
    stub(Cinder.Catalog.TMDBMock, :now_playing_movies, fn _ -> {:ok, []} end)
    :ok
  end

  defp series!(attrs) do
    Repo.insert!(
      struct(
        %Cinder.Catalog.Series{
          tmdb_id: System.unique_integer([:positive]),
          title: "Severance",
          monitor_strategy: :future
        },
        attrs
      )
    )
  end

  defp book_target!(attrs) do
    id = System.unique_integer([:positive])
    media_kind = Map.get(attrs, :media_kind, :ebook)

    {:ok, profile} =
      Catalog.create_profile(%{name: "Books #{id}", kind: media_kind, handling: :standard})

    work_attrs =
      Map.merge(
        %{
          title: "Book #{id}",
          identifier: %{provider: "openlibrary", kind: "work", foreign_id: "#{id}"}
        },
        Map.take(attrs, [:title, :first_published_on])
      )

    {:ok, work} = Books.upsert_work(work_attrs)

    {:ok, author} =
      Books.upsert_author(%{
        name: "Author #{id}",
        identifier: %{provider: "openlibrary", kind: "author", foreign_id: "a#{id}"}
      })

    {:ok, _credit} = Books.put_credit(work, %{author_id: author.id, role: "author", position: 0})

    {:ok, target} = Books.monitor_target(work, media_kind, profile)
    target
  end

  defp available_book!(attrs) do
    target = book_target!(attrs)
    size = Map.get(attrs, :size, 2_000_000)

    {:ok, _file} =
      Books.Files.record_import(target, %{
        path: "/tmp/book-#{target.id}.epub",
        size: size,
        format: :epub
      })

    Books.get_target(target.id)
  end

  test "lists movies with cancel/delete quick actions but no inline edit", %{conn: conn} do
    movie = movie_fixture(%{title: "Dune", year: 2021})
    {:ok, lv, html} = live(conn, ~p"/library")
    assert html =~ "Dune"
    assert html =~ "Movies"
    # Edit moved to /movies/:id; the library card links there instead.
    refute has_element?(lv, "#movie-#{movie.id} button", "Edit")
    assert has_element?(lv, ~s|#movie-#{movie.id} a[href="/movies/#{movie.id}"]|)
    assert has_element?(lv, "#movie-#{movie.id} button", "Cancel")
  end

  # The clause has already matched by the time the body runs, so the module catch-all cannot
  # help: `find_movie/2` used to `to_string/1` the CLIENT value, which raises
  # Protocol.UndefinedError on a forged map and takes /library down with the tab.
  test "a forged id on a movie confirm event is ignored rather than crashing the view", %{
    conn: conn
  } do
    movie = movie_fixture(%{title: "Dune", year: 2021})
    {:ok, lv, _html} = live(conn, ~p"/library")

    for event <- ~w(confirm_cancel_movie confirm_delete_movie),
        forged <- [%{"forged" => true}, 7] do
      assert render_click(lv, event, %{"id" => forged})
    end

    assert Process.alive?(lv.pid)
    assert render(lv) =~ "Dune"
    assert Repo.get(Cinder.Catalog.Movie, movie.id)
  end

  test "a movie held mid-verification shows Needs verification, not bare Import failed", %{
    conn: conn
  } do
    movie = movie_fixture(%{title: "Anime Movie", status: :import_failed})

    {:ok, movie} =
      Catalog.transition(movie, %{
        status: :import_failed,
        verification_hold_origin: :download
      })

    {:ok, lv, _html} = live(conn, ~p"/library")
    assert has_element?(lv, "#movie-#{movie.id} span.badge-warning", "Needs verification")
    refute has_element?(lv, "#movie-#{movie.id}", "Import failed")
  end

  test "renders movie download progress", %{conn: conn} do
    movie = movie_fixture(%{status: :downloading})

    {:ok, _} =
      Catalog.update_movie_download_metrics(movie, %{
        download_progress: 0.42,
        download_speed: 1_500_000,
        download_eta: 90
      })

    {:ok, lv, _html} = live(conn, ~p"/library")
    assert lv |> element("#movie-#{movie.id}") |> render() =~ "42%"
  end

  test "cancels an active movie through the confirm step", %{conn: conn} do
    movie = movie_fixture(%{title: "Tenet"})
    {:ok, lv, _html} = live(conn, ~p"/library")

    lv |> element("#movie-#{movie.id} button", "Cancel") |> render_click()
    lv |> element("#confirm-cancel-movie-#{movie.id} button", "Cancel movie") |> render_click()

    assert Catalog.get_movie_by_id(movie.id).status == :cancelled
  end

  test "deletes an inactive movie through the confirm step", %{conn: conn} do
    movie = movie_fixture(%{title: "Old"})
    {:ok, _} = Catalog.transition(movie, %{status: :cancelled})
    {:ok, lv, _html} = live(conn, ~p"/library")

    lv |> element("#movie-#{movie.id} button", "Delete") |> render_click()
    lv |> element("#confirm-delete-movie-#{movie.id} button", "Delete") |> render_click()

    refute has_element?(lv, "#movie-#{movie.id}")
    assert Catalog.get_movie_by_id(movie.id) == nil
  end

  test "the Series tab navigates to the TV list and hides movies", %{conn: conn} do
    movie = movie_fixture(%{title: "Dune"})
    s = series!(%{title: "Severance"})
    series!(%{title: "Andor"})

    {:ok, lv, html} = live(conn, ~p"/library")
    assert html =~ ~s|id="movie-#{movie.id}"|
    refute html =~ ~s|id="series-row-#{s.id}"|
    # The hidden tab's count must come from its own canonical list, not from @visible —
    # unequal counts are what makes this fail if the template ever reads @visible.
    assert html =~ "Movies (1)"
    assert html =~ "Series (2)"

    # Click the real link rather than mounting ?type=tv directly, so the tab itself is covered.
    {:ok, _tv_lv, tv_html} =
      lv |> element("#library-tab-tv") |> render_click() |> follow_redirect(conn)

    assert tv_html =~ ~s|id="series-row-#{s.id}"|
    refute tv_html =~ ~s|id="movie-#{movie.id}"|
  end

  test "the filter narrows the grid and clearing it restores the full list", %{conn: conn} do
    keep = movie_fixture(%{title: "Dune"})
    drop = movie_fixture(%{title: "Arrival"})

    {:ok, lv, _html} = live(conn, ~p"/library")

    html = lv |> form("#library-filter-form", %{"filter" => "dUnE"}) |> render_change()
    assert html =~ ~s|id="movie-#{keep.id}"|
    refute html =~ ~s|id="movie-#{drop.id}"|
    # The tab count describes the library, not the filtered view — it must not track @visible.
    assert html =~ "Movies (2)"

    # @movies must stay canonical — filtering into the assign would lose this row for good.
    html = lv |> form("#library-filter-form", %{"filter" => ""}) |> render_change()
    assert html =~ ~s|id="movie-#{keep.id}"|
    assert html =~ ~s|id="movie-#{drop.id}"|
  end

  test "a broadcast for a filtered-out movie does not resurrect it into the grid", %{conn: conn} do
    keep = movie_fixture(%{title: "Dune"})
    hidden = movie_fixture(%{title: "Arrival"})

    {:ok, lv, _html} = live(conn, ~p"/library")
    lv |> form("#library-filter-form", %{"filter" => "dune"}) |> render_change()

    # upsert_by_id/2 prepends when absent: against a filtered assign this row would pop back in.
    {:ok, _} = Catalog.transition(hidden, %{status: :cancelled})

    html = render(lv)
    assert html =~ ~s|id="movie-#{keep.id}"|
    refute html =~ ~s|id="movie-#{hidden.id}"|
  end

  test "an unmatched filter shows the no-matches empty state", %{conn: conn} do
    movie_fixture(%{title: "Dune"})
    {:ok, lv, _html} = live(conn, ~p"/library")

    html =
      lv |> form("#library-filter-form", %{"filter" => "nothing-matches-this"}) |> render_change()

    assert html =~ "No matches"
    refute html =~ "No movies yet"
  end

  test "lists series with a drill-down link, a status badge, and deletes one", %{conn: conn} do
    s = series!(%{title: "Severance"})
    {:ok, lv, html} = live(conn, ~p"/library?type=tv")
    assert html =~ "Severance"
    assert has_element?(lv, ~s|#series-row-#{s.id} a[href="/series/#{s.id}"]|)
    # Parity with movie cards: a series card carries a monitored/unmonitored badge.
    assert has_element?(lv, "#series-row-#{s.id} .badge")

    lv |> element("#series-row-#{s.id} button", "Delete") |> render_click()
    lv |> element("#confirm-delete-series-#{s.id} button", "Delete") |> render_click()

    refute has_element?(lv, "#series-row-#{s.id}")
    assert Catalog.list_series() == []
  end

  describe "books tab" do
    test "lists book targets with a drill-down link and a status badge", %{
      conn: conn
    } do
      target = book_target!(%{title: "Dune"})

      {:ok, lv, html} = live(conn, ~p"/library?type=books")
      assert html =~ "Dune"

      assert has_element?(
               lv,
               ~s|#book-target-row-#{target.id} a[href="/books/#{target.work_id}"]|
             )

      assert has_element?(lv, "#book-target-row-#{target.id} .badge")

      # No cancel/delete affordance anywhere on this tab, per #405 — those stay heavier
      # decisions than this row offers. Pause/Resume (B5c) are covered separately below.
      refute has_element?(lv, "#book-target-row-#{target.id} button", "Cancel")
      refute has_element?(lv, "#book-target-row-#{target.id} button", "Delete")
    end

    test "the Books tab navigates to the Books list and hides movies", %{conn: conn} do
      movie = movie_fixture(%{title: "Dune"})
      target = book_target!(%{title: "Foundation"})

      {:ok, lv, html} = live(conn, ~p"/library")
      assert html =~ ~s|id="movie-#{movie.id}"|
      refute html =~ ~s|id="book-target-row-#{target.id}"|
      # The tab count must come from the canonical @books list, not @visible — matches the
      # movies/series count assertions above, and would fail if it read the filtered view.
      assert html =~ "Books (1)"

      {:ok, _books_lv, books_html} =
        lv |> element("#library-tab-books") |> render_click() |> follow_redirect(conn)

      assert books_html =~ ~s|id="book-target-row-#{target.id}"|
      refute books_html =~ ~s|id="movie-#{movie.id}"|
    end

    test "an unknown ?type= falls back to Movies instead of crashing", %{conn: conn} do
      movie = movie_fixture(%{title: "Dune"})

      {:ok, lv, html} = live(conn, ~p"/library?type=' OR 1=1--")
      assert html =~ ~s|id="movie-#{movie.id}"|
      assert has_element?(lv, ~s|#library-tab-movies[aria-current="page"]|)
    end

    test "a {:book_target_updated} broadcast refreshes the books tab live", %{conn: conn} do
      target = book_target!(%{title: "Dune"})

      {:ok, lv, _html} = live(conn, ~p"/library?type=books")
      assert has_element?(lv, "#book-target-row-#{target.id}", "Approved")

      {:ok, _held} = Cinder.Books.hold_target(target, "identity conflict")

      assert has_element?(lv, "#book-target-row-#{target.id}", "Needs attention")
    end

    test "the Wanted quick link shows only monitored targets, Held only held, default unfiltered",
         %{conn: conn} do
      wanted = book_target!(%{title: "Dune"})

      {:ok, held} =
        book_target!(%{title: "Foundation"}) |> Books.hold_target("identity conflict")

      available = available_book!(%{title: "Neuromancer"})

      {:ok, lv, _html} = live(conn, ~p"/library?type=books&status=wanted")
      assert has_element?(lv, "#book-target-row-#{wanted.id}")
      refute has_element?(lv, "#book-target-row-#{held.id}")
      refute has_element?(lv, "#book-target-row-#{available.id}")

      {:ok, lv, _html} = live(conn, ~p"/library?type=books&status=held")
      refute has_element?(lv, "#book-target-row-#{wanted.id}")
      assert has_element?(lv, "#book-target-row-#{held.id}")
      refute has_element?(lv, "#book-target-row-#{available.id}")

      {:ok, lv, _html} = live(conn, ~p"/library?type=books")
      assert has_element?(lv, "#book-target-row-#{wanted.id}")
      assert has_element?(lv, "#book-target-row-#{held.id}")
      assert has_element?(lv, "#book-target-row-#{available.id}")
    end

    test "pausing a monitored target with no grab hides it from the wanted filter; resuming " <>
           "returns it there",
         %{conn: conn} do
      target = book_target!(%{title: "Dune"})

      {:ok, lv, _html} = live(conn, ~p"/library?type=books&status=wanted")
      assert has_element?(lv, "#book-target-row-#{target.id}")

      lv |> element("#book-target-row-#{target.id} button", "Pause") |> render_click()

      refute has_element?(lv, "#book-target-row-#{target.id}")
      assert Books.get_target(target.id).status == :unmonitored

      {:ok, lv, _html} = live(conn, ~p"/library?type=books")
      lv |> element("#book-target-row-#{target.id} button", "Resume") |> render_click()

      assert Books.get_target(target.id).status == :monitored

      {:ok, lv, _html} = live(conn, ~p"/library?type=books&status=wanted")
      assert has_element?(lv, "#book-target-row-#{target.id}")
    end

    test "pausing/resuming an :audiobook target round-trips identically to an :ebook one — the
          same status-keyed control, proven for the OTHER kind, not merely read from source",
         %{conn: conn} do
      target = book_target!(%{title: "Dune Audio", media_kind: :audiobook})

      {:ok, lv, _html} = live(conn, ~p"/library?type=books&status=wanted")
      assert has_element?(lv, "#book-target-row-#{target.id}")

      lv |> element("#book-target-row-#{target.id} button", "Pause") |> render_click()

      refute has_element?(lv, "#book-target-row-#{target.id}")
      assert Books.get_target(target.id).status == :unmonitored

      {:ok, lv, _html} = live(conn, ~p"/library?type=books")
      lv |> element("#book-target-row-#{target.id} button", "Resume") |> render_click()

      assert Books.get_target(target.id).status == :monitored

      {:ok, lv, _html} = live(conn, ~p"/library?type=books&status=wanted")
      assert has_element?(lv, "#book-target-row-#{target.id}")
    end

    test "Pause is hidden while a grab is in flight, and pausing anyway is refused with a " <>
           "specific flash",
         %{conn: conn} do
      target = book_target!(%{title: "Dune"})
      {:ok, _grab} = Grabs.create(target.id, "remote-1", :torrent, "Dune Release")

      {:ok, lv, _html} = live(conn, ~p"/library?type=books")
      refute has_element?(lv, "#book-target-row-#{target.id} button", "Pause")

      # A stale/racing request bypassing the hidden button — the context choke-point must still
      # refuse it, with the specific flash rather than the generic one.
      html = render_click(lv, "pause_target", %{"id" => to_string(target.id)})
      assert html =~ "This target has a download in progress"
      assert Books.get_target(target.id).status == :monitored
    end

    test "a forged id on a book pause/resume event is ignored rather than crashing the view", %{
      conn: conn
    } do
      target = book_target!(%{title: "Dune"})
      {:ok, lv, _html} = live(conn, ~p"/library?type=books")

      for event <- ~w(pause_target resume_target),
          forged <- [%{"forged" => true}, 7, "-1", "not-an-id"] do
        assert render_click(lv, event, %{"id" => forged})
      end

      assert Process.alive?(lv.pid)
      assert render(lv) =~ "Dune"
      assert Books.get_target(target.id).status == :monitored
    end

    test "changing the sort while status-filtered keeps the filter across a reconnect", %{
      conn: conn
    } do
      wanted = book_target!(%{title: "Dune"})

      {:ok, held} =
        book_target!(%{title: "Foundation"}) |> Books.hold_target("identity conflict")

      {:ok, lv, _html} = live(conn, ~p"/library?type=books&status=wanted")
      assert has_element?(lv, "#book-target-row-#{wanted.id}")

      sort_by(lv, "title")
      assert_patch(lv, ~p"/library?type=books&sort=title&status=wanted")

      # A reconnect is a fresh mount/3 against the browser's CURRENT url — asserting only the
      # live socket's in-memory assign would miss a URL regression that drops the filter.
      {:ok, reconnected_lv, _html} =
        live(conn, ~p"/library?type=books&sort=title&status=wanted")

      assert has_element?(reconnected_lv, "#book-target-row-#{wanted.id}")
      refute has_element?(reconnected_lv, "#book-target-row-#{held.id}")
    end

    test "the Wanted/Held quick links only render on the Books tab", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/library")
      refute has_element?(lv, "#library-books-wanted")
      refute has_element?(lv, "#library-books-held")

      {:ok, lv, _html} = live(conn, ~p"/library?type=tv")
      refute has_element?(lv, "#library-books-wanted")
      refute has_element?(lv, "#library-books-held")

      {:ok, lv, _html} = live(conn, ~p"/library?type=books")
      assert has_element?(lv, "#library-books-wanted")
      assert has_element?(lv, "#library-books-held")
    end
  end

  test "non-admins are redirected away from /library", %{conn: _conn} do
    conn = build_conn() |> log_in_user(Cinder.AccountsFixtures.user_fixture())
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/library")
  end

  test "/movies redirects to /library", %{conn: conn} do
    assert redirected_to(get(conn, ~p"/movies")) == "/library"
  end

  defp available_movie!(file_path, attrs \\ %{}) do
    movie = movie_fixture(Map.merge(%{title: "M", year: 2010}, attrs))

    {:ok, movie} =
      movie
      |> Ecto.Changeset.change(status: :available, file_path: file_path)
      |> Cinder.Repo.update()

    movie
  end

  test "deleting a movie with the delete-files box ticked unlinks the file", %{conn: conn} do
    movie = available_movie!("/tmp/cinder-test-library/M (2010)/M (2010).mkv")

    expect(
      Cinder.Library.FilesystemMock,
      :rm,
      fn "/tmp/cinder-test-library/M (2010)/M (2010).mkv" -> :ok end
    )

    stub(Cinder.Library.FilesystemMock, :rmdir, fn _ -> {:error, :enotempty} end)

    {:ok, lv, _html} = live(conn, ~p"/library")

    lv
    |> element("button[phx-click=ask_delete_movie][phx-value-id='#{movie.id}']")
    |> render_click()

    lv |> element("input[phx-click=toggle_delete_files]") |> render_click()

    lv
    |> element("button[phx-click=confirm_delete_movie][phx-value-id='#{movie.id}']")
    |> render_click()

    refute Cinder.Repo.get(Cinder.Catalog.Movie, movie.id)
  end

  test "deleting a movie without ticking the box leaves the file (no FS call)", %{conn: conn} do
    movie = available_movie!("/tmp/x.mkv")
    {:ok, lv, _html} = live(conn, ~p"/library")

    lv
    |> element("button[phx-click=ask_delete_movie][phx-value-id='#{movie.id}']")
    |> render_click()

    lv
    |> element("button[phx-click=confirm_delete_movie][phx-value-id='#{movie.id}']")
    |> render_click()

    refute Cinder.Repo.get(Cinder.Catalog.Movie, movie.id)
  end

  test "Discover no longer renders the Added series block", %{conn: conn} do
    series!(%{title: "Severance"})
    {:ok, _lv, html} = live(conn, ~p"/")
    refute html =~ "Added series"
  end

  test "FR session shows the localized title; EN session shows canonical", %{conn: conn} do
    _movie =
      movie_fixture(%{
        title: "Inception",
        localizations: %{"fr" => %{"title" => "Origine"}}
      })

    {:ok, _lv, fr_html} =
      conn
      |> Plug.Test.init_test_session(%{"locale" => "fr"})
      |> live(~p"/library")

    assert fr_html =~ "Origine"
    refute fr_html =~ "Inception"

    {:ok, _lv, en_html} = live(conn, ~p"/library")
    assert en_html =~ "Inception"
    refute en_html =~ "Origine"
  end

  describe "sorting" do
    # Rendered order, which has no `has_element?` equivalent. Floki is not a dependency here;
    # LazyHTML is (test-only), and it is what LiveViewTest itself parses with.
    defp card_ids(html, selector) do
      html |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> LazyHTML.attribute("id")
    end

    defp sort_by(lv, value),
      do: lv |> form("#library-sort-form", %{"sort" => value}) |> render_change()

    test "Title (A–Z) reorders the movie grid against the default newest-first", %{conn: conn} do
      # Inserted so the default `desc: id` order (zulu, alpha) disagrees with alphabetical.
      alpha = movie_fixture(%{title: "Alpha"})
      zulu = movie_fixture(%{title: "Zulu"})

      {:ok, lv, html} = live(conn, ~p"/library")
      assert card_ids(html, "#movies-list > div") == ["movie-#{zulu.id}", "movie-#{alpha.id}"]

      sort_by(lv, "title")
      assert_patch(lv, ~p"/library?sort=title")

      assert card_ids(render(lv), "#movies-list > div") ==
               ["movie-#{alpha.id}", "movie-#{zulu.id}"]
    end

    test "a leading accent sorts under its base letter, not after Z", %{conn: conn} do
      # The accent has to be the character that DECIDES the comparison, or the test can't see
      # folding at all: "Amélie" vs "Zulu" is settled at `a` < `z` and sorts identically folded
      # or not. Only a leading accent discriminates — plain `String.downcase/1` leaves "é" at
      # U+00E9, which is greater than every ASCII letter, so "Écran" lands after "Zulu"; NFD
      # decomposes it to "e" + U+0301, so it sorts under E where a reader expects it.
      ecran = movie_fixture(%{title: "Écran"})
      zulu = movie_fixture(%{title: "Zulu"})

      {:ok, lv, _html} = live(conn, ~p"/library?sort=title")

      assert card_ids(render(lv), "#movies-list > div") ==
               ["movie-#{ecran.id}", "movie-#{zulu.id}"]
    end

    test "Size puts the largest first, the never-imported last, and prints the bytes", %{
      conn: conn
    } do
      small = available_movie!("/tmp/small.mkv", %{title: "Small", imported_size: 2_000_000})
      never = movie_fixture(%{title: "Never"})
      big = available_movie!("/tmp/big.mkv", %{title: "Big", imported_size: 9_000_000})

      {:ok, lv, _html} = live(conn, ~p"/library")
      sort_by(lv, "size")
      assert_patch(lv, ~p"/library?sort=size")

      html = render(lv)

      assert card_ids(html, "#movies-list > div") ==
               ["movie-#{big.id}", "movie-#{small.id}", "movie-#{never.id}"]

      # Sorting by a number the grid never shows would be a half-feature.
      assert has_element?(lv, "#movie-#{big.id} p", "8.6 MB")
      refute has_element?(lv, "#movie-#{never.id} p")
    end

    test "a retried movie sorts and renders as sizeless once its file is gone", %{conn: conn} do
      # Positive control, created FIRST so it holds the lower id: same size, same selector, file
      # still on disk. Without it the refute below would also pass if the card vanished or the
      # selector were wrong — and without the id ordering, the sort assertion would pass on the
      # `-id` tiebreak alone, since dropping the guard leaves both movies on an equal size.
      kept = available_movie!("/tmp/kept.mkv", %{title: "Kept", imported_size: 9_000_000})

      # retry_movie/1 clears file_path but leaves imported_size behind. Parked directly via a raw
      # changeset (like available_movie!/2 above) — :available -> :import_failed isn't a real
      # pipeline edge (a live movie only reaches :import_failed via the verification-hold path,
      # which carries its own origin-tagged guard), so this doesn't go through Catalog.transition.
      movie = available_movie!("/tmp/gone.mkv", %{title: "Gone", imported_size: 9_000_000})

      {:ok, failed} =
        movie |> Ecto.Changeset.change(status: :import_failed) |> Cinder.Repo.update()

      {:ok, movie} = Catalog.retry_movie(failed)
      assert movie.file_path == nil and movie.imported_size == 9_000_000

      {:ok, lv, _html} = live(conn, ~p"/library?sort=size")

      assert has_element?(lv, "#movie-#{kept.id} p", "8.6 MB")
      assert has_element?(lv, "#movie-#{movie.id}")
      refute has_element?(lv, "#movie-#{movie.id} p", "8.6 MB")

      # ...and it sorts as sizeless too, not just renders as one.
      assert card_ids(render(lv), "#movies-list > div") ==
               ["movie-#{kept.id}", "movie-#{movie.id}"]
    end

    test "sorting on the Series tab keeps ?type=tv and totals each series' files", %{conn: conn} do
      # Created biggest-first so the default `desc: id` order is the REVERSE of the expected
      # size order — otherwise the assertion below passes without any sorting happening.
      big = series!(%{title: "Big Show"})
      small = series!(%{title: "Small Show"})
      seed_episode_file(small, "/tv/small.mkv", 2_000_000)
      seed_episode_file(big, "/tv/big.mkv", 9_000_000)

      {:ok, lv, _html} = live(conn, ~p"/library?type=tv")
      sort_by(lv, "size")

      # The patch must carry the tab: a reconnect remounts against this URL, and a bare
      # ?sort=size would silently drop the operator back onto the Movies tab.
      assert_patch(lv, ~p"/library?type=tv&sort=size")

      assert card_ids(render(lv), "#series-list > div") ==
               ["series-row-#{big.id}", "series-row-#{small.id}"]

      assert has_element?(lv, "#series-row-#{big.id} p", "8.6 MB")
    end

    test "a series import refreshes the size readout live", %{conn: conn} do
      series = series!(%{title: "Severance"})
      episode = episode_fixture(season_fixture(series))

      {:ok, lv, _html} = live(conn, ~p"/library?type=tv")
      refute has_element?(lv, "#series-row-#{series.id} p")

      # Driven through the real writer, not a hand-sent message: transition_episode/2 is the
      # episode pipeline choke-point and broadcasts {:series_updated, _} itself, so this covers
      # the subscription in mount/3 as well as the handler. A `send(lv.pid, ...)` here would stay
      # green even with Catalog.subscribe_series/0 deleted.
      {:ok, _} =
        Catalog.transition_episode(episode, %{
          file_path: "/tv/new.mkv",
          imported_size: 9_000_000
        })

      assert has_element?(lv, "#series-row-#{series.id} p", "8.6 MB")
    end

    test "Title (A–Z) reorders the Books tab against the default newest-first", %{conn: conn} do
      alpha = book_target!(%{title: "Alpha"})
      zulu = book_target!(%{title: "Zulu"})

      {:ok, lv, html} = live(conn, ~p"/library?type=books")

      assert card_ids(html, "#books-list > article") ==
               ["book-target-row-#{zulu.id}", "book-target-row-#{alpha.id}"]

      sort_by(lv, "title")
      assert_patch(lv, ~p"/library?type=books&sort=title")

      assert card_ids(render(lv), "#books-list > article") ==
               ["book-target-row-#{alpha.id}", "book-target-row-#{zulu.id}"]
    end

    test "Size on the Books tab totals each target's book_files, largest first", %{conn: conn} do
      small = available_book!(%{title: "Small", size: 2_000_000})
      never = book_target!(%{title: "Never"})
      big = available_book!(%{title: "Big", size: 9_000_000})

      {:ok, lv, _html} = live(conn, ~p"/library?type=books")
      sort_by(lv, "size")
      assert_patch(lv, ~p"/library?type=books&sort=size")

      html = render(lv)

      assert card_ids(html, "#books-list > article") ==
               [
                 "book-target-row-#{big.id}",
                 "book-target-row-#{small.id}",
                 "book-target-row-#{never.id}"
               ]

      # Sorting by a number the grid never shows would be a half-feature.
      assert has_element?(lv, "#book-target-row-#{big.id} span", "8.6 MB")
      refute has_element?(lv, "#book-target-row-#{never.id} span", "MB")
    end

    test "Year (newest first) on the Books tab sorts off the work's first_published_on", %{
      conn: conn
    } do
      old = book_target!(%{title: "Old", first_published_on: ~D[1965-01-01]})
      new = book_target!(%{title: "New", first_published_on: ~D[2020-01-01]})
      undated = book_target!(%{title: "Undated"})

      {:ok, lv, _html} = live(conn, ~p"/library?type=books")
      sort_by(lv, "year")
      assert_patch(lv, ~p"/library?type=books&sort=year")

      assert card_ids(render(lv), "#books-list > article") ==
               [
                 "book-target-row-#{new.id}",
                 "book-target-row-#{old.id}",
                 "book-target-row-#{undated.id}"
               ]
    end

    test "an unknown ?sort= falls back to the default instead of crashing", %{conn: conn} do
      newest = movie_fixture(%{title: "Alpha"})

      {:ok, lv, html} = live(conn, ~p"/library?sort=' OR 1=1--")
      assert card_ids(html, "#movies-list > div") == ["movie-#{newest.id}"]

      # Raw event rather than the form: `form/3` refuses a value the <select> doesn't offer, so
      # only a direct payload exercises the handler's own allowlist — which is what a hand-rolled
      # request would send. The value must never reach String.to_atom/1.
      render_change(lv, "sort", %{"sort" => "not-a-sort"})
      assert_patch(lv, ~p"/library?sort=added")
    end

    defp seed_episode_file(series, path, size) do
      season = season_fixture(series)
      episode_fixture(season, %{file_path: path, imported_size: size})
    end
  end
end
