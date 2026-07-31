defmodule CinderWeb.UsersLiveTest do
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  test "admin approves a pending account", %{conn: conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()

    pending =
      Cinder.AccountsFixtures.user_fixture()
      |> Ecto.Changeset.change(active: false)
      |> Cinder.Repo.update!()

    conn = log_in_user(conn, admin)

    {:ok, live_view, _html} = live(conn, ~p"/users")
    assert has_element?(live_view, "#pending-user-#{pending.id}")
    refute has_element?(live_view, "#role-btn-#{pending.id}")

    live_view |> element("#approve-user-#{pending.id}") |> render_click()

    assert Cinder.Repo.get!(Cinder.Accounts.User, pending.id).active
    refute has_element?(live_view, "#pending-user-#{pending.id}")
    assert has_element?(live_view, "#role-btn-#{pending.id}")
  end

  test "admin denies a pending account", %{conn: conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()

    pending =
      Cinder.AccountsFixtures.user_fixture()
      |> Ecto.Changeset.change(active: false)
      |> Cinder.Repo.update!()

    conn = log_in_user(conn, admin)

    {:ok, live_view, _html} = live(conn, ~p"/users")
    live_view |> element("#deny-user-#{pending.id}") |> render_click()

    refute Cinder.Repo.get(Cinder.Accounts.User, pending.id)
    refute has_element?(live_view, "#pending-user-#{pending.id}")
  end

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

    assert %{active: true} = Cinder.Repo.get_by(Cinder.Accounts.User, email: email)
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
    topics = session_topics(user)
    conn = log_in_user(conn, admin)

    {:ok, lv, _html} = live(conn, ~p"/users")
    lv |> element("#role-btn-#{user.id}") |> render_click()

    assert Cinder.Repo.get!(Cinder.Accounts.User, user.id).role == :admin
    assert_disconnects(topics)
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
    topics = session_topics(user)
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
    assert_disconnects(topics)
  end

  test "admin deletes a user via the confirm panel", %{conn: conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()
    user = Cinder.AccountsFixtures.user_fixture()
    topics = session_topics(user)
    conn = log_in_user(conn, admin)

    {:ok, lv, _html} = live(conn, ~p"/users")
    lv |> element("#delete-btn-#{user.id}") |> render_click()
    lv |> element("#confirm-delete-#{user.id} button[phx-click=\"delete\"]") |> render_click()

    refute Cinder.Repo.get_by(Cinder.Accounts.User, email: user.email)
    refute render(lv) =~ user.email
    assert_disconnects(topics)
  end

  test "a mounted admin loses every privileged writer after demotion", %{conn: conn} do
    stale_admin = Cinder.AccountsFixtures.admin_fixture()
    demoter = Cinder.AccountsFixtures.admin_fixture()
    target = Cinder.AccountsFixtures.user_fixture() |> Cinder.AccountsFixtures.set_password()
    created_email = Cinder.AccountsFixtures.unique_user_email()
    changed_email = Cinder.AccountsFixtures.unique_user_email()
    conn = log_in_user(conn, stale_admin)

    {:ok, lv, _html} = live(conn, ~p"/users")
    demote(demoter, stale_admin)

    results = [
      render_hook(lv, "create", %{
        "user" => %{
          "email" => created_email,
          "password" => Cinder.AccountsFixtures.valid_user_password(),
          "password_confirmation" => Cinder.AccountsFixtures.valid_user_password(),
          "role" => "admin"
        }
      }),
      render_hook(lv, "set_quota", %{"_id" => to_string(target.id), "quota" => "7"}),
      render_hook(lv, "save_email", %{
        "_id" => to_string(target.id),
        "user" => %{"email" => changed_email}
      }),
      render_hook(lv, "toggle_role", %{"id" => to_string(target.id)}),
      render_hook(lv, "approve", %{"id" => to_string(target.id)}),
      render_hook(lv, "deny", %{"id" => to_string(target.id)}),
      render_hook(lv, "reset_pw", %{
        "_id" => to_string(target.id),
        "user" => %{
          "password" => "a stale reset password!",
          "password_confirmation" => "a stale reset password!"
        }
      }),
      render_hook(lv, "delete", %{"id" => to_string(target.id)})
    ]

    assert Enum.all?(results, &(&1 =~ "access to that page"))
    refute Cinder.Repo.get_by(Cinder.Accounts.User, email: created_email)

    reloaded = Cinder.Repo.get!(Cinder.Accounts.User, target.id)
    assert reloaded.role == :user
    assert reloaded.request_quota == nil
    assert reloaded.email == target.email
    assert Cinder.Accounts.get_user_by_email_and_password(target.email, valid_password())
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
    {:ok, _, _} = Cinder.Accounts.update_user_role(admin, other, :user)
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
    render_hook(lv, "approve", %{"id" => forged})
    render_hook(lv, "deny", %{"id" => forged})
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
    {:ok, _, _} = Cinder.Accounts.delete_user(admin, user)
    refute Cinder.Repo.get_by(Cinder.Accounts.User, email: user.email)

    render_hook(lv, "toggle_role", %{"id" => stale_id})
    render_hook(lv, "approve", %{"id" => stale_id})
    render_hook(lv, "deny", %{"id" => stale_id})
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

  describe "media-server user import" do
    # The LiveView runs in its own process, so the media-server mock must be global.
    setup do
      Mox.set_mox_global()
      :ok
    end

    test "admin imports the selected users from the configured media server", %{conn: conn} do
      admin = Cinder.AccountsFixtures.admin_fixture()
      stub_media_server_users()
      conn = log_in_user(conn, admin)

      {:ok, lv, _html} = live(conn, ~p"/users")
      lv |> element("#load-import-btn") |> render_click()

      html = render(lv)
      assert html =~ "kim@example.com"
      assert html =~ "sam@example.com"
      # An account the media server reports without an email can't be imported.
      assert html =~ "no email on the media server"

      lv |> form("#import-users-form", %{"import" => ["5001"]}) |> render_submit()

      assert %Cinder.Accounts.User{} = kim = user_by_email("kim@example.com")
      assert kim.role == :user
      assert kim.plex_id == 5001
      # Only the ticked account was created.
      refute user_by_email("sam@example.com")
      assert render(lv) =~ "Imported 1 account."
    end

    test "an imported user can't log in until they come through the media server", %{conn: conn} do
      admin = Cinder.AccountsFixtures.admin_fixture()
      stub_media_server_users()
      conn = log_in_user(conn, admin)

      {:ok, lv, _html} = live(conn, ~p"/users")
      lv |> element("#load-import-btn") |> render_click()
      lv |> form("#import-users-form", %{"import" => ["5001"]}) |> render_submit()

      # No password exists, so no password logs them in...
      refute Cinder.Accounts.get_user_by_email_and_password(
               "kim@example.com",
               Cinder.AccountsFixtures.valid_user_password()
             )

      # ...but the imported plex_id resolves the media-server sign-in to THIS account
      # rather than creating a second one.
      assert {:ok, signed_in} =
               Cinder.Accounts.login_or_register_plex_user(%{
                 id: 5001,
                 email: "kim@example.com",
                 username: "kim"
               })

      assert signed_in.id == user_by_email("kim@example.com").id
    end

    test "re-running the import creates nothing new", %{conn: conn} do
      admin = Cinder.AccountsFixtures.admin_fixture()
      stub_media_server_users()
      conn = log_in_user(conn, admin)

      {:ok, lv, _html} = live(conn, ~p"/users")
      lv |> element("#load-import-btn") |> render_click()
      lv |> form("#import-users-form", %{"import" => ["5001", "5002"]}) |> render_submit()

      count = Cinder.Repo.aggregate(Cinder.Accounts.User, :count)

      lv |> element("#load-import-btn") |> render_click()
      lv |> form("#import-users-form", %{"import" => ["5001", "5002"]}) |> render_submit()

      assert Cinder.Repo.aggregate(Cinder.Accounts.User, :count) == count
      assert render(lv) =~ "already exist"
    end

    test "every import is audited", %{conn: conn} do
      admin = Cinder.AccountsFixtures.admin_fixture()
      stub_media_server_users()
      conn = log_in_user(conn, admin)

      {:ok, lv, _html} = live(conn, ~p"/users")
      lv |> element("#load-import-btn") |> render_click()
      lv |> form("#import-users-form", %{"import" => ["5001"]}) |> render_submit()

      imported = user_by_email("kim@example.com")

      audit =
        Cinder.Repo.get_by!(Cinder.Audit.AdminAudit,
          entity_type: "User",
          entity_id: imported.id
        )

      assert audit.action == "import_media_server_user"
      assert audit.actor_id == admin.id
    end

    test "an admin demoted mid-session can't import", %{conn: conn} do
      admin = Cinder.AccountsFixtures.admin_fixture()
      other_admin = Cinder.AccountsFixtures.admin_fixture()
      stub_media_server_users()
      conn = log_in_user(conn, admin)

      {:ok, lv, _html} = live(conn, ~p"/users")
      lv |> element("#load-import-btn") |> render_click()

      demote(other_admin, admin)

      lv |> form("#import-users-form", %{"import" => ["5001"]}) |> render_submit()

      refute user_by_email("kim@example.com")
      assert render(lv) =~ "You don&#39;t have access to that page."
    end

    test "submitting with nothing ticked says so instead of claiming they exist", %{conn: conn} do
      admin = Cinder.AccountsFixtures.admin_fixture()
      stub_media_server_users()
      conn = log_in_user(conn, admin)

      {:ok, lv, _html} = live(conn, ~p"/users")
      lv |> element("#load-import-btn") |> render_click()

      assert lv |> form("#import-users-form") |> render_submit() =~ "Select at least one account"
      refute user_by_email("kim@example.com")
    end

    # The payload is a client-supplied query string: `import[a]=1` decodes to a MAP, not a list.
    test "a forged, map-shaped selection imports nothing and keeps the view alive", %{conn: conn} do
      admin = Cinder.AccountsFixtures.admin_fixture()
      stub_media_server_users()
      conn = log_in_user(conn, admin)

      {:ok, lv, _html} = live(conn, ~p"/users")
      lv |> element("#load-import-btn") |> render_click()

      render_hook(lv, "import", %{"import" => %{"a" => "5001"}})
      render_hook(lv, "import", %{"import" => [%{"a" => "5001"}, 5001]})
      render_hook(lv, "import", %{})

      refute user_by_email("kim@example.com")
      assert Process.alive?(lv.pid)
    end

    test "a media server that can't be read surfaces an error, not a crash", %{conn: conn} do
      admin = Cinder.AccountsFixtures.admin_fixture()

      Mox.stub(Cinder.Library.MediaServerMock, :list_users, fn -> {:error, :timeout} end)

      conn = log_in_user(conn, admin)
      {:ok, lv, _html} = live(conn, ~p"/users")

      assert lv |> element("#load-import-btn") |> render_click() =~
               "Couldn&#39;t read the media server"

      refute has_element?(lv, "#import-users-form")
    end

    defp stub_media_server_users do
      Mox.stub(Cinder.Library.MediaServerMock, :list_users, fn ->
        {:ok,
         [
           %{id: 5001, email: "kim@example.com", username: "kim"},
           %{id: 5002, email: "sam@example.com", username: "sam"},
           %{id: 5003, email: nil, username: "managed-kid"}
         ]}
      end)
    end

    defp user_by_email(email), do: Cinder.Repo.get_by(Cinder.Accounts.User, email: email)
  end

  test "a non-admin cannot reach /users", %{conn: conn} do
    user = Cinder.AccountsFixtures.user_fixture()
    conn = log_in_user(conn, user)
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/users")
  end

  test "a logged-out visitor is redirected to log in", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/users")
  end

  defp demote(actor, target) do
    case Cinder.Accounts.update_user_role(actor, target, :user) do
      {:ok, user} -> user
      {:ok, user, _tokens} -> user
    end
  end

  defp session_topics(user) do
    for _ <- 1..2 do
      token = Cinder.Accounts.generate_user_session_token(user)
      topic = "users_sessions:#{Base.url_encode64(token)}"
      CinderWeb.Endpoint.subscribe(topic)
      topic
    end
  end

  defp assert_disconnects(topics) do
    Enum.each(topics, fn topic ->
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect", topic: ^topic}
    end)
  end

  defp valid_password, do: Cinder.AccountsFixtures.valid_user_password()
end
