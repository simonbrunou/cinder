defmodule CinderWeb.AuthorizationTest do
  use CinderWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Cinder.AccountsFixtures

  for path <- ["/activity", "/settings", "/requests", "/users"] do
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

  test "/my-requests requires authentication", %{conn: conn} do
    assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/my-requests")
    assert to =~ "/users/log-in"
  end

  test "a non-admin reaches /my-requests", %{conn: conn} do
    conn = log_in_user(conn, user_fixture())
    assert {:ok, _lv, _html} = live(conn, ~p"/my-requests")
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
      conn = get(conn, unquote(path))
      location = conn |> Plug.Conn.get_resp_header("location") |> List.first()

      assert conn.status == 200 or (location && String.starts_with?(location, "/dev")),
             "admin should reach #{unquote(path)} (got #{conn.status} -> #{inspect(location)})"
    end
  end
end
