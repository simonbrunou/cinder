defmodule CinderWeb.UserLive.LoginTest do
  use CinderWeb.ConnCase

  import Phoenix.LiveViewTest
  import Cinder.AccountsFixtures
  import Cinder.ConfigCase

  describe "login page" do
    test "renders login page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/log-in")

      assert html =~ "Log in"
      assert html =~ "Sign up"
    end
  end

  describe "user login - password" do
    test "redirects if user logs in with valid credentials", %{conn: conn} do
      user = user_fixture() |> set_password()

      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      form =
        form(lv, "#login_form_password",
          user: %{email: user.email, password: valid_user_password(), remember_me: true}
        )

      conn = submit_form(form, conn)

      assert redirected_to(conn) == ~p"/"
    end

    test "redirects to login page with a flash error if credentials are invalid", %{
      conn: conn
    } do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      form =
        form(lv, "#login_form_password", user: %{email: "test@email.com", password: "123456"})

      render_submit(form, %{user: %{remember_me: true}})

      conn = follow_trigger_action(form, conn)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid email or password"
      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  describe "login navigation" do
    test "redirects to registration page when the Register button is clicked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      {:ok, _login_live, login_html} =
        lv
        |> element("main a", "Sign up")
        |> render_click()
        |> follow_redirect(conn, ~p"/users/register")

      assert login_html =~ "Register"
    end
  end

  describe "Sign in with Plex" do
    test "renders a button pointing at /auth/plex when Plex is configured", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/log-in")

      assert html =~ "Sign in with Plex"
      assert html =~ ~s(href="/auth/plex")
    end
  end

  describe "Sign in with Jellyfin" do
    test "renders a credential form posting to /auth/jellyfin when Jellyfin is configured", %{
      conn: conn
    } do
      {:ok, _lv, html} = live(conn, ~p"/users/log-in")

      assert html =~ "Sign in with Jellyfin"
      assert html =~ ~s(action="/auth/jellyfin")
    end

    test "is hidden when no Jellyfin server is configured", %{conn: conn} do
      put_config(Cinder.Library.MediaServer.Jellyfin, url: nil)

      {:ok, _lv, html} = live(conn, ~p"/users/log-in")

      refute html =~ "Sign in with Jellyfin"
    end

    test "submitting valid credentials signs in against the configured server", %{conn: conn} do
      _admin = admin_fixture()

      Mox.expect(Cinder.Accounts.JellyfinAuthMock, :authenticate, fn "viewer", "s3cret" ->
        {:ok, %{id: "jf-login-1", name: "viewer"}}
      end)

      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      conn =
        lv
        |> form("#login_form_jellyfin", jellyfin: %{username: "viewer", password: "s3cret"})
        |> submit_form(conn)

      assert redirected_to(conn) == ~p"/"

      assert Cinder.Repo.get_by!(Cinder.Accounts.User, jellyfin_user_id: "jf-login-1").role ==
               :user
    end
  end

  describe "Sign in with OpenID" do
    test "is shown only when the three OIDC settings are configured", %{conn: conn} do
      original = Application.get_env(:cinder, Cinder.Accounts.OIDC)

      Application.put_env(:cinder, Cinder.Accounts.OIDC,
        issuer_url: "https://id.example.com",
        client_id: "cinder",
        client_secret: "secret"
      )

      on_exit(fn -> Application.put_env(:cinder, Cinder.Accounts.OIDC, original) end)

      {:ok, lv, _html} = live(conn, ~p"/users/log-in")
      assert has_element?(lv, "#oidc-login[href='/auth/oidc']")
    end

    test "is hidden when OIDC is incomplete", %{conn: conn} do
      original = Application.get_env(:cinder, Cinder.Accounts.OIDC)
      Application.put_env(:cinder, Cinder.Accounts.OIDC, issuer_url: "https://id.example.com")
      on_exit(fn -> Application.put_env(:cinder, Cinder.Accounts.OIDC, original) end)

      {:ok, lv, _html} = live(conn, ~p"/users/log-in")
      refute has_element?(lv, "#oidc-login")
    end
  end

  describe "re-authentication (sudo mode)" do
    setup %{conn: conn} do
      user = user_fixture()
      %{user: user, conn: log_in_user(conn, user)}
    end

    test "shows login page with email filled in", %{conn: conn, user: user} do
      {:ok, _lv, html} = live(conn, ~p"/users/log-in")

      assert html =~ "You need to log in again"
      refute html =~ "Register"

      assert html =~
               ~s(<input type="email" name="user[email]" id="login_form_password_email" value="#{user.email}")
    end
  end

  describe "handle_event" do
    test "forged/unknown event does not crash the page", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")
      # Send an unknown event - should not raise FunctionClauseError
      assert is_binary(render(lv))
    end
  end
end
