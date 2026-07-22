defmodule CinderWeb.LibraryLiveTest do
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox

  alias Cinder.Catalog
  alias Cinder.Repo

  import Cinder.CatalogFixtures

  setup :register_and_log_in_admin
  setup :set_mox_global

  setup do
    # cancel_movie may remove an active download via the client; default to a no-op.
    stub(Cinder.Download.ClientMock, :remove, fn _id, _opts -> :ok end)
    stub(Cinder.Download.SabnzbdClientMock, :remove, fn _id, _opts -> :ok end)
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

    {:ok, lv, html} = live(conn, ~p"/library")
    assert html =~ ~s|id="movie-#{movie.id}"|
    refute html =~ ~s|id="series-row-#{s.id}"|

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

  test "non-admins are redirected away from /library", %{conn: _conn} do
    conn = build_conn() |> log_in_user(Cinder.AccountsFixtures.user_fixture())
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/library")
  end

  test "/movies redirects to /library", %{conn: conn} do
    assert redirected_to(get(conn, ~p"/movies")) == "/library"
  end

  defp available_movie!(file_path) do
    movie = movie_fixture(%{title: "M", year: 2010})

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
end
