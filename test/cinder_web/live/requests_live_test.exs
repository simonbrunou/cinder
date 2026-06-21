defmodule CinderWeb.RequestsLiveTest do
  use CinderWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Cinder.AccountsFixtures

  setup :register_and_log_in_admin

  test "lists pending and approves", %{conn: conn} do
    user = user_fixture()

    {:ok, req} =
      Cinder.Requests.create_request(user, %{
        target_type: "movie",
        target_id: 603,
        title: "The Matrix"
      })

    {:ok, lv, html} = live(conn, ~p"/requests")
    assert html =~ "The Matrix"
    lv |> element("button", "Approve") |> render_click()
    assert [%Cinder.Catalog.Movie{status: :requested}] = Cinder.Catalog.list_by_status(:requested)
    assert {:ok, %{status: :approved}} = {:ok, Cinder.Repo.reload(req)}
  end

  test "a non-admin cannot reach /requests", %{conn: conn} do
    user = user_fixture()
    conn = log_in_user(conn, user)
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/requests")
  end
end
