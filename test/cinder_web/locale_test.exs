defmodule CinderWeb.LocaleTest do
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Cinder.AccountsFixtures

  alias Cinder.Accounts
  alias Cinder.Accounts.Scope
  alias CinderWeb.Locale

  describe "Locale plug" do
    test "session locale takes precedence over Accept-Language" do
      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{"locale" => "fr"})
        |> Plug.Conn.put_req_header("accept-language", "en-US,en;q=0.9")
        |> Locale.call([])

      assert conn.assigns.locale == "fr"
      assert Gettext.get_locale(CinderWeb.Gettext) == "fr"
    end

    test "authenticated user locale takes precedence over session and Accept-Language" do
      user = user_fixture()
      {:ok, user} = Accounts.update_user_locale(user, %{locale: "fr"})

      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{"locale" => "en"})
        |> Plug.Conn.assign(:current_scope, Scope.for_user(user))
        |> Plug.Conn.put_req_header("accept-language", "en-US,en;q=0.9")
        |> Locale.call([])

      assert conn.assigns.locale == "fr"
      assert get_session(conn, :locale) == "fr"
    end

    test "negotiates Accept-Language when no session locale is stored" do
      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_req_header("accept-language", "fr-CA,fr;q=0.9,en;q=0.8")
        |> Locale.call([])

      assert conn.assigns.locale == "fr"
      # negotiated locale is persisted so it sticks on later requests
      assert get_session(conn, :locale) == "fr"
    end

    test "defaults to en for an unsupported Accept-Language" do
      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_req_header("accept-language", "de-DE,de;q=0.9")
        |> Locale.call([])

      assert conn.assigns.locale == "en"
    end

    test "ignores an unsupported stored session locale" do
      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{"locale" => "zz"})
        |> Locale.call([])

      assert conn.assigns.locale == "en"
    end
  end

  describe "GET /locale/:locale" do
    test "persists a supported locale and redirects to the referer path", %{conn: conn} do
      conn =
        conn
        |> Plug.Conn.put_req_header("referer", "http://localhost/users/log-in?foo=1")
        |> get(~p"/locale/fr")

      assert redirected_to(conn) == "/users/log-in?foo=1"
      assert get_session(conn, :locale) == "fr"
    end

    test "persists a supported locale to an authenticated user's account", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> log_in_user(user)
        |> get(~p"/locale/fr")

      assert get_session(conn, :locale) == "fr"
      assert Cinder.Repo.reload!(user).locale == "fr"
    end

    test "falls back to root for a protocol-relative referer (no open redirect / no 500)", %{
      conn: conn
    } do
      conn =
        conn
        |> Plug.Conn.put_req_header("referer", "http://localhost//evil.com/phish")
        |> get(~p"/locale/fr")

      assert redirected_to(conn) == "/"
    end

    test "ignores an unsupported locale but still redirects to root", %{conn: conn} do
      conn = get(conn, ~p"/locale/zz")

      assert redirected_to(conn) == "/"
      # the unsupported value is not stored; the plug's default stands
      assert get_session(conn, :locale) == "en"
    end
  end

  describe "rendering" do
    test "uses the saved user locale for a LiveView even when the session differs", %{conn: conn} do
      user = user_fixture()
      {:ok, user} = Accounts.update_user_locale(user, %{locale: "fr"})

      {:ok, live_view, _html} =
        conn
        |> log_in_user(user)
        |> Plug.Conn.put_session(:locale, "en")
        |> live(~p"/users/settings")

      assert has_element?(live_view, ~s|a[href="/locale/fr"][aria-current="true"]|)
    end

    test "renders the login page in French when the session locale is fr", %{conn: conn} do
      {:ok, _lv, html} =
        conn
        |> Plug.Test.init_test_session(%{"locale" => "fr"})
        |> live(~p"/users/log-in")

      assert html =~ "Se connecter"
      refute html =~ "Log in and stay logged in"
    end

    test "renders the login page in English by default", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/log-in")

      assert html =~ "Log in and stay logged in"
    end
  end
end
