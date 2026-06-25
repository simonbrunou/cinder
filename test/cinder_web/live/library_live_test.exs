defmodule CinderWeb.LibraryLiveTest do
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox

  alias Cinder.Catalog
  alias Cinder.Repo

  setup :register_and_log_in_admin
  setup :set_mox_global

  setup do
    # cancel_movie may remove an active download via the client; default to a no-op.
    stub(Cinder.Download.ClientMock, :remove, fn _id, _opts -> :ok end)
    stub(Cinder.Download.SabnzbdClientMock, :remove, fn _id, _opts -> :ok end)
    :ok
  end

  defp movie!(attrs) do
    {:ok, movie} =
      Catalog.add_to_watchlist(
        Enum.into(attrs, %{tmdb_id: System.unique_integer([:positive]), title: "Untitled"})
      )

    movie
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

  test "lists movies with edit/cancel/delete affordances", %{conn: conn} do
    movie!(%{title: "Dune", year: 2021})
    {:ok, _lv, html} = live(conn, ~p"/library")
    assert html =~ "Dune"
    assert html =~ "Movies"
  end

  test "edits a movie's metadata", %{conn: conn} do
    movie = movie!(%{title: "Dune", year: 2021})
    {:ok, lv, _html} = live(conn, ~p"/library")

    lv |> element("#movie-#{movie.id} button", "Edit") |> render_click()

    lv
    |> form("#movie-form-#{movie.id}", movie: %{title: "Dune: Part Two", year: 2024})
    |> render_submit()

    assert Catalog.get_movie_by_id(movie.id).title == "Dune: Part Two"
  end

  test "cancels an active movie through the confirm step", %{conn: conn} do
    movie = movie!(%{title: "Tenet"})
    {:ok, lv, _html} = live(conn, ~p"/library")

    lv |> element("#movie-#{movie.id} button", "Cancel") |> render_click()
    lv |> element("#confirm-cancel-movie-#{movie.id} button", "Cancel movie") |> render_click()

    assert Catalog.get_movie_by_id(movie.id).status == :cancelled
  end

  test "deletes an inactive movie through the confirm step", %{conn: conn} do
    movie = movie!(%{title: "Old"})
    {:ok, _} = Catalog.transition(movie, %{status: :cancelled})
    {:ok, lv, _html} = live(conn, ~p"/library")

    lv |> element("#movie-#{movie.id} button", "Delete") |> render_click()
    lv |> element("#confirm-delete-movie-#{movie.id} button", "Delete") |> render_click()

    refute has_element?(lv, "#movie-#{movie.id}")
    assert Catalog.get_movie_by_id(movie.id) == nil
  end

  test "lists series with a drill-down link and deletes one", %{conn: conn} do
    s = series!(%{title: "Severance"})
    {:ok, lv, html} = live(conn, ~p"/library")
    assert html =~ "Severance"
    assert has_element?(lv, ~s|#series-row-#{s.id} a[href="/series/#{s.id}"]|)

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
    movie = movie!(%{title: "M", year: 2010})

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
