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

  # Robustness: malformed/forged events must not crash the LiveView.
  # These tests verify the fix for String.to_integer/1 raising on non-integer
  # client input, and missing catch-all handle_event/3.

  test "approve with non-integer id does not crash the LiveView", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/requests")
    render_hook(lv, "approve", %{"id" => "not-an-int"})
    # LiveView process must still be alive
    assert render(lv) =~ "Pending requests"
  end

  test "start_deny with non-integer id does not crash the LiveView", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/requests")
    render_hook(lv, "start_deny", %{"id" => "not-an-int"})
    assert render(lv) =~ "Pending requests"
  end

  test "deny with non-integer _id does not crash the LiveView", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/requests")
    render_hook(lv, "deny", %{"_id" => "not-an-int", "reason" => "bad input"})
    assert render(lv) =~ "Pending requests"
  end

  test "unknown event name does not crash the LiveView", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/requests")
    render_hook(lv, "bogus", %{})
    assert render(lv) =~ "Pending requests"
  end
end
