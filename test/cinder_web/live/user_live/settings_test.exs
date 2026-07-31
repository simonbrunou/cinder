defmodule CinderWeb.UserLive.SettingsTest do
  use CinderWeb.ConnCase

  alias Cinder.Accounts
  alias Cinder.Accounts.Scope
  alias CinderWeb.UserLive.Settings
  import Phoenix.LiveViewTest
  import Cinder.AccountsFixtures

  # The mount-time :require_sudo_mode gate and the per-event rechecks below share the same
  # sudo window (finding 7), so a socket that got past mount can't naturally go stale before an
  # event fires within a fast test process. Build the post-mount socket directly (as
  # user_auth_test.exs already does for on_mount) with an already-stale `authenticated_at`, to
  # exercise the event-level recheck in isolation.
  defp stale_socket(user) do
    stale_user = %{user | authenticated_at: DateTime.add(DateTime.utc_now(), -11, :minute)}

    %Phoenix.LiveView.Socket{
      endpoint: CinderWeb.Endpoint,
      assigns: %{current_scope: Scope.for_user(stale_user), flash: %{}, __changed__: %{}}
    }
  end

  defp linked_user_with_token do
    user = user_fixture()
    {:ok, user} = Accounts.link_plex_to_user(user, %{id: 4321, email: nil, username: "plex-me"})
    {:ok, user} = Accounts.store_plex_token(user, "plex-token")
    user
  end

  describe "Settings page" do
    test "renders settings page", %{conn: conn} do
      {:ok, _lv, html} =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/settings")

      assert html =~ "Change email"
      assert html =~ "Save password"
    end

    test "renders the data-export link and the delete-account danger zone", %{conn: conn} do
      {:ok, _lv, html} =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/settings")

      assert html =~ "Download my data"
      assert html =~ ~s(href="/users/export")
      assert html =~ "Danger zone"
      assert html =~ "Delete my account"
      assert html =~ ~s(action="/users/delete-account")
    end

    test "updates the user's language and applies it immediately", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      redirect =
        lv
        |> form("#locale_form", %{"user" => %{"locale" => "fr"}})
        |> render_submit()

      assert Cinder.Repo.reload!(user).locale == "fr"
      {:ok, redirected_conn} = follow_redirect(redirect, conn, ~p"/users/settings")
      assert redirected_conn.assigns.locale == "fr"
    end

    test "toggles the email-notification preference", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      assert has_element?(lv, ~s(input[name="notify_email"][checked]))

      lv
      |> element("form[phx-change=toggle_notify_email]")
      |> render_change(%{"notify_email" => "false"})

      refute has_element?(lv, ~s(input[name="notify_email"][checked]))
      assert Cinder.Repo.reload!(user).notify_email == false
    end

    test "redirects if user is not logged in", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/users/settings")

      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/log-in"
      assert %{"error" => "You must log in to access this page."} = flash
    end

    test "redirects if user is not in sudo mode", %{conn: conn} do
      {:ok, conn} =
        conn
        |> log_in_user(user_fixture(),
          token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -11, :minute)
        )
        |> live(~p"/users/settings")
        |> follow_redirect(conn, ~p"/users/log-in")

      assert conn.resp_body =~ "You must re-authenticate to access this page."
    end
  end

  describe "update email form" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "updates the user email", %{conn: conn, user: user} do
      new_email = unique_user_email()

      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> form("#email_form", %{
          "user" => %{"email" => new_email}
        })
        |> render_submit()

      assert result =~ "A link to confirm your email"
      assert Cinder.Repo.get_by(Cinder.Accounts.User, email: user.email)
    end

    test "renders errors with invalid data (phx-change)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> element("#email_form")
        |> render_change(%{
          "action" => "update_email",
          "user" => %{"email" => "with spaces"}
        })

      assert result =~ "Change email"
      assert result =~ "must have the @ sign and no spaces"
    end

    test "renders errors with invalid data (phx-submit)", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> form("#email_form", %{
          "user" => %{"email" => user.email}
        })
        |> render_submit()

      assert result =~ "Change email"
      assert result =~ "did not change"
    end
  end

  describe "update password form" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "updates the user password", %{conn: conn, user: user} do
      new_password = valid_user_password()

      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      form =
        form(lv, "#password_form", %{
          "user" => %{
            "email" => user.email,
            "password" => new_password,
            "password_confirmation" => new_password
          }
        })

      render_submit(form)

      new_password_conn = follow_trigger_action(form, conn)

      assert redirected_to(new_password_conn) == ~p"/users/settings"

      assert get_session(new_password_conn, :user_token) != get_session(conn, :user_token)

      assert Phoenix.Flash.get(new_password_conn.assigns.flash, :info) =~
               "Password updated successfully"

      assert Accounts.get_user_by_email_and_password(user.email, new_password)
    end

    test "renders errors with invalid data (phx-change)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> element("#password_form")
        |> render_change(%{
          "user" => %{
            "password" => "too short",
            "password_confirmation" => "does not match"
          }
        })

      assert result =~ "Save password"
      assert result =~ "should be at least 12 character(s)"
      assert result =~ "does not match password"
    end

    test "renders errors with invalid data (phx-submit)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> form("#password_form", %{
          "user" => %{
            "password" => "too short",
            "password_confirmation" => "does not match"
          }
        })
        |> render_submit()

      assert result =~ "Save password"
      assert result =~ "should be at least 12 character(s)"
      assert result =~ "does not match password"
    end
  end

  describe "confirm email" do
    setup %{conn: conn} do
      user = user_fixture()
      email = unique_user_email()

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(%{user | email: email}, user.email, url)
        end)

      %{conn: log_in_user(conn, user), token: token, email: email, user: user}
    end

    test "updates the user email once", %{conn: conn, user: user, token: token, email: email} do
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/#{token}")

      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/settings"
      assert %{"info" => message} = flash
      assert message == "Email changed successfully."
      refute Cinder.Repo.get_by(Cinder.Accounts.User, email: user.email)
      assert Cinder.Repo.get_by(Cinder.Accounts.User, email: email)

      # use confirm token again
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/#{token}")
      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/settings"
      assert %{"error" => message} = flash
      assert message == "Email change link is invalid or it has expired."
    end

    test "does not update email with invalid token", %{conn: conn, user: user} do
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/oops")
      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/settings"
      assert %{"error" => message} = flash
      assert message == "Email change link is invalid or it has expired."
      assert Cinder.Repo.get_by(Cinder.Accounts.User, email: user.email)
    end

    test "redirects if user is not logged in", %{token: token} do
      conn = build_conn()
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/#{token}")
      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/log-in"
      assert %{"error" => message} = flash
      assert message == "You must log in to access this page."
    end
  end

  describe "Plex account section" do
    test "an unlinked user sees a Link Plex account link pointing at /auth/plex", %{conn: conn} do
      {:ok, _lv, html} =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/settings")

      assert html =~ "Link Plex account"
      assert html =~ ~s(href="/auth/plex")
    end

    test "a linked user sees the linked state and can unlink", %{conn: conn} do
      user = user_fixture()

      {:ok, user} =
        Cinder.Accounts.link_plex_to_user(user, %{
          id: 1234,
          email: nil,
          username: "plex-me"
        })

      {:ok, lv, html} = conn |> log_in_user(user) |> live(~p"/users/settings")

      assert html =~ "Linked as plex-me"
      refute html =~ "Link Plex account"

      html = lv |> element("button", "Unlink") |> render_click()

      assert html =~ "Link Plex account"
      refute html =~ "Linked as plex-me"
      assert Cinder.Repo.reload!(user).plex_id == nil
    end

    test "unlink_plex requires fresh sudo: an expired session redirects to reauth without unlinking" do
      user = user_fixture()

      {:ok, user} =
        Cinder.Accounts.link_plex_to_user(user, %{id: 1234, email: nil, username: "plex-me"})

      assert {:noreply, socket} = Settings.handle_event("unlink_plex", %{}, stale_socket(user))

      assert {:redirect, %{to: "/users/log-in"}} = socket.redirected
      assert Phoenix.Flash.get(socket.assigns.flash, :error) =~ "re-authenticate"
      assert Cinder.Repo.reload!(user).plex_id == 1234
    end
  end

  describe "Plex watchlist sync opt-in" do
    test "is off by default and can be turned on and off from the account page", %{conn: conn} do
      user = linked_user_with_token()
      {:ok, lv, _html} = conn |> log_in_user(user) |> live(~p"/users/settings")

      refute user.plex_watchlist_sync
      refute has_element?(lv, ~s(input[name="plex_watchlist_sync"][checked]))

      lv
      |> element("form[phx-change=toggle_plex_watchlist]")
      |> render_change(%{"plex_watchlist_sync" => "true"})

      assert has_element?(lv, ~s(input[name="plex_watchlist_sync"][checked]))
      assert Cinder.Repo.reload!(user).plex_watchlist_sync

      lv
      |> element("form[phx-change=toggle_plex_watchlist]")
      |> render_change(%{"plex_watchlist_sync" => "false"})

      refute Cinder.Repo.reload!(user).plex_watchlist_sync
    end

    test "a linked user with no stored token is told to link again", %{conn: conn} do
      user = user_fixture()
      {:ok, user} = Accounts.link_plex_to_user(user, %{id: 4322, email: nil, username: "plex-me"})

      {:ok, lv, html} = conn |> log_in_user(user) |> live(~p"/users/settings")

      refute has_element?(lv, ~s(form[phx-change=toggle_plex_watchlist]))
      assert html =~ "Link your Plex account again"
    end

    test "the toggle is not offered to a user with no Plex link at all", %{conn: conn} do
      {:ok, lv, _html} = conn |> log_in_user(user_fixture()) |> live(~p"/users/settings")

      refute has_element?(lv, ~s(form[phx-change=toggle_plex_watchlist]))
    end
  end

  describe "sudo-mode expiry on sensitive events (finding 7)" do
    test "update_email redirects to reauth instead of crashing when sudo has expired" do
      user = user_fixture()

      assert {:noreply, socket} =
               Settings.handle_event(
                 "update_email",
                 %{"user" => %{"email" => unique_user_email()}},
                 stale_socket(user)
               )

      assert {:redirect, %{to: "/users/log-in"}} = socket.redirected
      assert Phoenix.Flash.get(socket.assigns.flash, :error) =~ "re-authenticate"
    end

    test "update_password redirects to reauth instead of crashing when sudo has expired" do
      user = user_fixture()
      new_password = valid_user_password()

      assert {:noreply, socket} =
               Settings.handle_event(
                 "update_password",
                 %{
                   "user" => %{
                     "password" => new_password,
                     "password_confirmation" => new_password
                   }
                 },
                 stale_socket(user)
               )

      assert {:redirect, %{to: "/users/log-in"}} = socket.redirected
      assert Phoenix.Flash.get(socket.assigns.flash, :error) =~ "re-authenticate"
    end
  end
end
