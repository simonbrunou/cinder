defmodule CinderWeb.PendingApprovalLiveTest do
  use CinderWeb.ConnCase, async: false

  import Cinder.AccountsFixtures
  import Phoenix.LiveViewTest

  test "inactive users are gated from protected sessions and can reach the pending page", %{
    conn: conn
  } do
    inactive = user_fixture() |> Ecto.Changeset.change(active: false) |> Cinder.Repo.update!()
    conn = log_in_user(conn, inactive)

    assert {:error, {:redirect, %{to: "/pending"}}} = live(conn, ~p"/")
    assert {:error, {:redirect, %{to: "/pending"}}} = live(conn, ~p"/users")

    assert {:ok, live_view, _html} = live(conn, ~p"/pending")
    assert has_element?(live_view, "#pending-approval")
    assert has_element?(live_view, "#pending-logout[href='/users/log-out']", "Log out")
  end
end
