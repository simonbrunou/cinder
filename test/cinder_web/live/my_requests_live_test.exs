defmodule CinderWeb.MyRequestsLiveTest do
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Cinder.Requests

  test "shows the current user's requests with status, not other users'", %{conn: conn} do
    user = Cinder.AccountsFixtures.user_fixture()
    other = Cinder.AccountsFixtures.user_fixture()

    {:ok, _} =
      Requests.create_request(user, %{
        target_type: "movie",
        target_id: 1,
        title: "Mine",
        year: 2001,
        poster_path: "/a.jpg"
      })

    {:ok, _} =
      Requests.create_request(other, %{
        target_type: "movie",
        target_id: 2,
        title: "Theirs",
        year: 2002,
        poster_path: "/b.jpg"
      })

    conn = log_in_user(conn, user)
    {:ok, lv, _html} = live(conn, ~p"/my-requests")

    assert has_element?(lv, "#my-requests", "Mine")
    refute has_element?(lv, "#my-requests", "Theirs")
    assert render(lv) =~ "pending"
  end

  test "a season request shows the show title and season number", %{conn: conn} do
    user = Cinder.AccountsFixtures.user_fixture()

    {:ok, _} =
      Requests.create_request(user, %{
        target_type: "season",
        target_id: 1399,
        season_number: 3,
        title: "GoT",
        year: 2011
      })

    conn = log_in_user(conn, user)
    {:ok, _lv, html} = live(conn, ~p"/my-requests")
    assert html =~ "GoT"
    assert html =~ "Season 3"
  end

  test "season request row does not show movie pipeline badge even when a movie shares the same tmdb_id",
       %{conn: conn} do
    user = Cinder.AccountsFixtures.user_fixture()

    # season request with target_id 777
    {:ok, _} =
      Requests.create_request(user, %{
        target_type: "season",
        target_id: 777,
        season_number: 2,
        title: "Collision Show",
        year: 2020
      })

    # movie whose tmdb_id numerically matches the series tmdb_id
    {:ok, movie} =
      Cinder.Catalog.add_to_watchlist(%{
        tmdb_id: 777,
        title: "Collision Movie",
        year: 2019,
        poster_path: "/col.jpg"
      })

    {:ok, _} = Cinder.Catalog.transition(movie, %{status: :downloading})

    conn = log_in_user(conn, user)
    {:ok, _lv, html} = live(conn, ~p"/my-requests")

    # season row renders correctly
    assert html =~ "Collision Show"
    assert html =~ "Season 2"
    assert html =~ "pending"

    # movie pipeline badge must NOT appear on the season row
    refute html =~ "downloading"
  end

  test "live-updates when the user's request is approved", %{conn: conn} do
    user = Cinder.AccountsFixtures.user_fixture()
    admin = Cinder.AccountsFixtures.admin_fixture()

    {:ok, req} =
      Requests.create_request(user, %{
        target_type: "movie",
        target_id: 3,
        title: "Live",
        year: 2003,
        poster_path: "/c.jpg"
      })

    conn = log_in_user(conn, user)
    {:ok, lv, _html} = live(conn, ~p"/my-requests")

    {:ok, _} = Requests.approve_request(req, admin)
    assert render(lv) =~ "approved"
  end

  test "survives a {:movie_deleted, id} broadcast (reloads, no crash)", %{conn: conn} do
    user = Cinder.AccountsFixtures.user_fixture()
    conn = log_in_user(conn, user)
    {:ok, movie} = Cinder.Catalog.add_to_watchlist(%{tmdb_id: 9600, title: "Vanish"})

    {:ok, lv, _html} = live(conn, ~p"/my-requests")
    Cinder.Catalog.broadcast_movie_deleted(movie.id)
    # still alive after reload
    assert render(lv)
  end
end
