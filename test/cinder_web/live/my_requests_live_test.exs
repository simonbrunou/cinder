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
end
