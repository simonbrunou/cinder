defmodule CinderWeb.AuthorizationTest do
  use CinderWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Cinder.AccountsFixtures

  for path <- ["/status", "/settings", "/requests"] do
    test "anonymous is redirected from #{path}", %{conn: conn} do
      assert {:error, {:redirect, %{to: to}}} = live(conn, unquote(path))
      assert to =~ "/users/log-in"
    end

    test "a non-admin is redirected from #{path}", %{conn: conn} do
      conn = log_in_user(conn, user_fixture())
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, unquote(path))
    end

    test "an admin reaches #{path}", %{conn: conn} do
      conn = log_in_user(conn, admin_fixture())
      assert {:ok, _lv, _html} = live(conn, unquote(path))
    end
  end

  test "/ requires authentication", %{conn: conn} do
    assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/")
    assert to =~ "/users/log-in"
  end

  test "a non-admin reaches /", %{conn: conn} do
    conn = log_in_user(conn, user_fixture())
    assert {:ok, _lv, _html} = live(conn, ~p"/")
  end

  test "an admin reaches /", %{conn: conn} do
    conn = log_in_user(conn, admin_fixture())
    assert {:ok, _lv, _html} = live(conn, ~p"/")
  end

  for path <- ["/dev/dashboard", "/dev/mailbox"] do
    test "anonymous gets 302 on #{path}", %{conn: conn} do
      assert redirected_to(get(conn, unquote(path))) =~ "/users/log-in"
    end

    test "a non-admin gets 302 on #{path}", %{conn: conn} do
      conn = log_in_user(conn, user_fixture())
      assert redirected_to(get(conn, unquote(path))) == "/"
    end

    test "an admin reaches #{path}", %{conn: conn} do
      conn = log_in_user(conn, admin_fixture())
      assert get(conn, unquote(path)).status in [200, 301, 302]
    end
  end
end
