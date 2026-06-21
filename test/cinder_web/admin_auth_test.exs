defmodule CinderWeb.AdminAuthTest do
  # async: false — toggles process-global env, so it must run in the sync phase
  # with no concurrent endpoint test reading it (the LiveView tests are async: false
  # too, and sync modules don't overlap).
  use CinderWeb.ConnCase, async: false

  defp configure_auth(user, pass) do
    System.put_env("CINDER_BASIC_AUTH_USER", user)
    System.put_env("CINDER_BASIC_AUTH_PASSWORD", pass)

    on_exit(fn ->
      System.delete_env("CINDER_BASIC_AUTH_USER")
      System.delete_env("CINDER_BASIC_AUTH_PASSWORD")
    end)
  end

  test "with no credentials configured, /status is reachable (auth is opt-in)", %{conn: conn} do
    assert get(conn, ~p"/status") |> html_response(200) =~ "Status"
  end

  test "with credentials configured, an unauthenticated request is challenged 401", %{conn: conn} do
    configure_auth("admin", "secret")

    conn = get(conn, ~p"/status")
    assert conn.status == 401
    assert get_resp_header(conn, "www-authenticate") != []
  end

  test "with credentials configured, the correct Basic auth is accepted", %{conn: conn} do
    configure_auth("admin", "secret")

    conn =
      conn
      |> put_req_header("authorization", Plug.BasicAuth.encode_basic_auth("admin", "secret"))
      |> get(~p"/status")

    assert html_response(conn, 200) =~ "Status"
  end

  test "with only one credential env var set, the app fails loud (not silently open)", %{
    conn: conn
  } do
    # A half-configured operator (typo'd or missing one var) must NOT silently fall
    # through to no-auth — fail closed so the misconfig surfaces instead of leaking.
    System.put_env("CINDER_BASIC_AUTH_USER", "admin")
    on_exit(fn -> System.delete_env("CINDER_BASIC_AUTH_USER") end)

    assert_raise RuntimeError, ~r/both/, fn -> get(conn, ~p"/status") end
  end

  test "blank (empty-string) credentials are treated as unset, not empty-cred auth", %{conn: conn} do
    # is_binary("") is true, so naive guards would ENABLE BasicAuth with empty
    # credentials (any client passes). Blank must mean 'off', not 'open'.
    System.put_env("CINDER_BASIC_AUTH_USER", "")
    System.put_env("CINDER_BASIC_AUTH_PASSWORD", "")

    on_exit(fn ->
      System.delete_env("CINDER_BASIC_AUTH_USER")
      System.delete_env("CINDER_BASIC_AUTH_PASSWORD")
    end)

    assert get(conn, ~p"/status") |> html_response(200) =~ "Status"
  end
end
