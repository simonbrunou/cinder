defmodule CinderWeb.HealthControllerTest do
  use CinderWeb.ConnCase, async: true

  test "GET /healthz is content-free and does not create a session", %{conn: conn} do
    conn = get(conn, ~p"/healthz")

    assert response(conn, 200) == "ok"
    assert get_resp_header(conn, "set-cookie") == []
  end
end
