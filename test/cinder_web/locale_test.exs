defmodule CinderWeb.LocaleTest do
  use CinderWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

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

    test "ignores an unsupported locale but still redirects to root", %{conn: conn} do
      conn = get(conn, ~p"/locale/zz")

      assert redirected_to(conn) == "/"
      # the unsupported value is not stored; the plug's default stands
      assert get_session(conn, :locale) == "en"
    end
  end

  describe "rendering" do
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
