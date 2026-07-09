defmodule CinderWeb.UsersLiveTest do
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  test "admin sets a user's quota", %{conn: conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()
    user = Cinder.AccountsFixtures.user_fixture()
    conn = log_in_user(conn, admin)

    {:ok, lv, _html} = live(conn, ~p"/users")
    lv |> form("#quota-#{user.id}", %{"quota" => "2"}) |> render_submit()

    assert Cinder.Repo.get!(Cinder.Accounts.User, user.id).request_quota == 2
  end

  test "clearing the quota field sets unlimited (nil)", %{conn: conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()
    user = Cinder.AccountsFixtures.user_fixture()
    {:ok, _} = Cinder.Accounts.update_user_quota(admin, user, 5)
    conn = log_in_user(conn, admin)

    {:ok, lv, _html} = live(conn, ~p"/users")
    lv |> form("#quota-#{user.id}", %{"quota" => ""}) |> render_submit()

    assert Cinder.Repo.get!(Cinder.Accounts.User, user.id).request_quota == nil
  end

  test "admin creates a new user", %{conn: conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()
    conn = log_in_user(conn, admin)
    email = Cinder.AccountsFixtures.unique_user_email()

    {:ok, lv, _html} = live(conn, ~p"/users")

    lv |> element("button", "New user") |> render_click()

    lv
    |> form("#create-user-form", %{
      "user" => %{
        "email" => email,
        "password" => Cinder.AccountsFixtures.valid_user_password(),
        "password_confirmation" => Cinder.AccountsFixtures.valid_user_password(),
        "role" => "user"
      }
    })
    |> render_submit()

    assert Cinder.Repo.get_by(Cinder.Accounts.User, email: email)
    assert render(lv) =~ email
  end

  test "create form shows validation errors", %{conn: conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()
    conn = log_in_user(conn, admin)

    {:ok, lv, _html} = live(conn, ~p"/users")
    lv |> element("button", "New user") |> render_click()

    html =
      lv
      |> form("#create-user-form", %{
        "user" => %{
          "email" => "bad",
          "password" => "short",
          "password_confirmation" => "short",
          "role" => "user"
        }
      })
      |> render_submit()

    assert html =~ "must have the @ sign"
  end

  test "admin creates a user with admin role via form", %{conn: conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()
    conn = log_in_user(conn, admin)
    email = Cinder.AccountsFixtures.unique_user_email()

    {:ok, lv, _html} = live(conn, ~p"/users")

    lv |> element("button", "New user") |> render_click()

    lv
    |> form("#create-user-form", %{
      "user" => %{
        "email" => email,
        "password" => Cinder.AccountsFixtures.valid_user_password(),
        "password_confirmation" => Cinder.AccountsFixtures.valid_user_password(),
        "role" => "admin"
      }
    })
    |> render_submit()

    created = Cinder.Repo.get_by(Cinder.Accounts.User, email: email)
    assert created != nil
    assert created.role == :admin
  end

  test "admin edits a user's email", %{conn: conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()
    user = Cinder.AccountsFixtures.user_fixture()
    conn = log_in_user(conn, admin)
    new_email = Cinder.AccountsFixtures.unique_user_email()

    {:ok, lv, _html} = live(conn, ~p"/users")
    lv |> element("#edit-email-btn-#{user.id}") |> render_click()

    lv
    |> form("#edit-email-form-#{user.id}", %{"user" => %{"email" => new_email}})
    |> render_submit()

    assert Cinder.Repo.get!(Cinder.Accounts.User, user.id).email == new_email
  end

  test "admin toggles a user's role", %{conn: conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()
    user = Cinder.AccountsFixtures.user_fixture()
    conn = log_in_user(conn, admin)

    {:ok, lv, _html} = live(conn, ~p"/users")
    lv |> element("#role-btn-#{user.id}") |> render_click()

    assert Cinder.Repo.get!(Cinder.Accounts.User, user.id).role == :admin
  end

  test "demoting the last admin flashes an error and does not change the role", %{conn: conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()
    conn = log_in_user(conn, admin)

    {:ok, lv, _html} = live(conn, ~p"/users")
    html = lv |> element("#role-btn-#{admin.id}") |> render_click()

    assert html =~ "last admin"
    assert Cinder.Repo.get!(Cinder.Accounts.User, admin.id).role == :admin
  end

  test "admin resets a user's password", %{conn: conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()
    user = Cinder.AccountsFixtures.user_fixture()
    conn = log_in_user(conn, admin)

    {:ok, lv, _html} = live(conn, ~p"/users")
    lv |> element("#reset-pw-btn-#{user.id}") |> render_click()

    lv
    |> form("#reset-pw-form-#{user.id}", %{
      "user" => %{
        "password" => "a fresh password!",
        "password_confirmation" => "a fresh password!"
      }
    })
    |> render_submit()

    assert Cinder.Accounts.get_user_by_email_and_password(user.email, "a fresh password!")
  end

  test "admin deletes a user via the confirm panel", %{conn: conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()
    user = Cinder.AccountsFixtures.user_fixture()
    conn = log_in_user(conn, admin)

    {:ok, lv, _html} = live(conn, ~p"/users")
    lv |> element("#delete-btn-#{user.id}") |> render_click()
    lv |> element("#confirm-delete-#{user.id} button[phx-click=\"delete\"]") |> render_click()

    refute Cinder.Repo.get_by(Cinder.Accounts.User, email: user.email)
    refute render(lv) =~ user.email
  end

  test "deleting your own account flashes an error", %{conn: conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()
    _second = Cinder.AccountsFixtures.admin_fixture()
    conn = log_in_user(conn, admin)

    {:ok, lv, _html} = live(conn, ~p"/users")
    lv |> element("#delete-btn-#{admin.id}") |> render_click()

    html =
      lv |> element("#confirm-delete-#{admin.id} button[phx-click=\"delete\"]") |> render_click()

    assert html =~ "your own account"
    assert Cinder.Repo.get!(Cinder.Accounts.User, admin.id)
  end

  test "deleting the last admin flashes an error", %{conn: conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()
    other = Cinder.AccountsFixtures.admin_fixture()
    {:ok, _} = Cinder.Accounts.update_user_role(admin, other, :user)
    conn = log_in_user(conn, admin)

    {:ok, lv, _html} = live(conn, ~p"/users")
    lv |> element("#delete-btn-#{admin.id}") |> render_click()

    html =
      lv |> element("#confirm-delete-#{admin.id} button[phx-click=\"delete\"]") |> render_click()

    assert html =~ "last admin"
    assert Cinder.Repo.get!(Cinder.Accounts.User, admin.id)
  end

  test "a forged non-numeric phx-value id does not crash the LiveView and mutates nothing",
       %{conn: conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()
    user = Cinder.AccountsFixtures.user_fixture()
    conn = log_in_user(conn, admin)

    {:ok, lv, _html} = live(conn, ~p"/users")

    forged = "abc"
    role_before = Cinder.Repo.get!(Cinder.Accounts.User, user.id).role
    email_before = Cinder.Repo.get!(Cinder.Accounts.User, user.id).email
    quota_before = Cinder.Repo.get!(Cinder.Accounts.User, user.id).request_quota

    # Every destructive / mutating handler, plus the start_* handlers that read the
    # raw id into an assign. A forged "abc" must never raise (String.to_integer would).
    render_hook(lv, "toggle_role", %{"id" => forged})
    render_hook(lv, "delete", %{"id" => forged})
    render_hook(lv, "start_edit_email", %{"id" => forged})
    render_hook(lv, "start_reset_pw", %{"id" => forged})
    render_hook(lv, "start_delete", %{"id" => forged})
    render_hook(lv, "set_quota", %{"_id" => forged, "quota" => "7"})

    render_hook(lv, "save_email", %{"_id" => forged, "user" => %{"email" => "forged@example.com"}})

    render_hook(lv, "reset_pw", %{
      "_id" => forged,
      "user" => %{
        "password" => "a fresh password!",
        "password_confirmation" => "a fresh password!"
      }
    })

    # Process still alive after every forged event.
    assert Process.alive?(lv.pid)

    # No mutation happened to the real user.
    reloaded = Cinder.Repo.get!(Cinder.Accounts.User, user.id)
    assert reloaded.role == role_before
    assert reloaded.email == email_before
    assert reloaded.request_quota == quota_before
  end

  test "acting on a since-deleted user id no-ops without raising", %{conn: conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()
    user = Cinder.AccountsFixtures.user_fixture()
    conn = log_in_user(conn, admin)

    {:ok, lv, _html} = live(conn, ~p"/users")

    # The user is deleted out from under this LiveView (e.g. a stale second tab).
    stale_id = to_string(user.id)
    {:ok, _} = Cinder.Accounts.delete_user(admin, user)
    refute Cinder.Repo.get_by(Cinder.Accounts.User, email: user.email)

    render_hook(lv, "toggle_role", %{"id" => stale_id})
    render_hook(lv, "delete", %{"id" => stale_id})
    render_hook(lv, "start_edit_email", %{"id" => stale_id})
    render_hook(lv, "start_reset_pw", %{"id" => stale_id})
    render_hook(lv, "start_delete", %{"id" => stale_id})
    render_hook(lv, "set_quota", %{"_id" => stale_id, "quota" => "7"})

    render_hook(lv, "save_email", %{
      "_id" => stale_id,
      "user" => %{"email" => "stale@example.com"}
    })

    render_hook(lv, "reset_pw", %{
      "_id" => stale_id,
      "user" => %{
        "password" => "a fresh password!",
        "password_confirmation" => "a fresh password!"
      }
    })

    assert Process.alive?(lv.pid)
  end

  test "a non-admin cannot reach /users", %{conn: conn} do
    user = Cinder.AccountsFixtures.user_fixture()
    conn = log_in_user(conn, user)
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/users")
  end

  test "a logged-out visitor is redirected to log in", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/users")
  end
end
