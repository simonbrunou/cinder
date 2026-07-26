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

  test "redirects to / as soon as an admin activates the waiting account", %{conn: conn} do
    admin = admin_fixture()
    inactive = user_fixture() |> Ecto.Changeset.change(active: false) |> Cinder.Repo.update!()
    conn = log_in_user(conn, inactive)

    {:ok, lv, _html} = live(conn, ~p"/pending")

    {:ok, _} = Cinder.Accounts.activate_user(admin, inactive)

    assert_redirect(lv, "/")
  end

  test "ignores another user's activation broadcast", %{conn: conn} do
    admin = admin_fixture()
    inactive = user_fixture() |> Ecto.Changeset.change(active: false) |> Cinder.Repo.update!()
    other = user_fixture() |> Ecto.Changeset.change(active: false) |> Cinder.Repo.update!()
    conn = log_in_user(conn, inactive)

    {:ok, lv, _html} = live(conn, ~p"/pending")

    {:ok, _} = Cinder.Accounts.activate_user(admin, other)

    # Still on /pending — no crash, no redirect for someone else's activation.
    assert has_element?(lv, "#pending-approval")
  end
end
