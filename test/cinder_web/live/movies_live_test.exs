defmodule CinderWeb.MoviesLiveTest do
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox
  import Cinder.AccountsFixtures

  alias Cinder.{Catalog, Repo}
  alias Cinder.Catalog.Movie

  setup :register_and_log_in_admin
  setup :set_mox_global

  defp movie!(attrs \\ %{}) do
    {:ok, movie} =
      Catalog.add_to_watchlist(
        Map.merge(%{tmdb_id: System.unique_integer([:positive]), title: "Inception"}, attrs)
      )

    movie
  end

  test "lists movies with their status", %{conn: conn} do
    movie!(%{title: "Arrival", year: 2016})
    {:ok, _lv, html} = live(conn, ~p"/movies")
    assert html =~ "Arrival"
    assert html =~ "Requested"
  end

  test "editing a movie's metadata persists", %{conn: conn} do
    movie = movie!(%{title: "Old"})
    {:ok, lv, _html} = live(conn, ~p"/movies")

    lv |> element(~s|button[phx-click="edit"][phx-value-id="#{movie.id}"]|) |> render_click()

    lv
    |> form("#movie-form-#{movie.id}", %{"movie" => %{"title" => "New", "year" => "2020"}})
    |> render_submit()

    assert Repo.get!(Movie, movie.id).title == "New"
  end

  test "cancelling an active movie removes the client download and sets :cancelled", %{conn: conn} do
    {:ok, movie} =
      Catalog.transition(movie!(), %{
        status: :downloading,
        download_id: "H",
        download_protocol: :torrent
      })

    expect(Cinder.Download.ClientMock, :remove, fn "H", _opts -> :ok end)

    {:ok, lv, _html} = live(conn, ~p"/movies")

    lv
    |> element(~s|button[phx-click="ask_cancel"][phx-value-id="#{movie.id}"]|)
    |> render_click()

    lv
    |> element(~s|button[phx-click="confirm_cancel"][phx-value-id="#{movie.id}"]|)
    |> render_click()

    assert Repo.get!(Movie, movie.id).status == :cancelled
  end

  test "deleting an idle movie drops it from the list", %{conn: conn} do
    movie = movie!() |> then(&elem(Catalog.transition(&1, %{status: :available}), 1))

    {:ok, lv, _html} = live(conn, ~p"/movies")

    lv
    |> element(~s|button[phx-click="ask_delete"][phx-value-id="#{movie.id}"]|)
    |> render_click()

    lv
    |> element(~s|button[phx-click="confirm_delete"][phx-value-id="#{movie.id}"]|)
    |> render_click()

    assert Repo.get(Movie, movie.id) == nil
    refute render(lv) =~ "movie-#{movie.id}"
  end

  test "a cancelled movie's badge renders (no crash)", %{conn: conn} do
    {:ok, _} = Catalog.transition(movie!(%{title: "Doomed"}), %{status: :cancelled})
    {:ok, _lv, html} = live(conn, ~p"/movies")
    assert html =~ "Doomed"
    assert html =~ "Cancelled"
  end

  test "a non-admin is redirected away from /movies", %{conn: _conn} do
    user = user_fixture()
    conn = log_in_user(build_conn(), user)
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/movies")
  end
end
