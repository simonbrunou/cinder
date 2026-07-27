defmodule CinderWeb.HealthControllerTest do
  # async: false — the database-volume floor tests drive the global `:disk_stats_stub`.
  use CinderWeb.ConnCase, async: false

  setup do
    original = Application.get_env(:cinder, :disk_stats_stub)

    on_exit(fn ->
      if is_nil(original),
        do: Application.delete_env(:cinder, :disk_stats_stub),
        else: Application.put_env(:cinder, :disk_stats_stub, original)
    end)

    :ok
  end

  test "GET /healthz is content-free and does not create a session", %{conn: conn} do
    conn = get(conn, ~p"/healthz")

    assert response(conn, 200) == "ok"
    assert get_resp_header(conn, "set-cookie") == []
  end

  test "GET /healthz is 200 when the database volume has room", %{conn: conn} do
    Application.put_env(
      :cinder,
      :disk_stats_stub,
      {:ok, %{free_bytes: 5_000_000_000, total_bytes: 10_000_000_000}}
    )

    assert response(get(conn, ~p"/healthz"), 200) == "ok"
  end

  test "GET /healthz is 503 when the database volume is below the floor", %{conn: conn} do
    Application.put_env(
      :cinder,
      :disk_stats_stub,
      {:ok, %{free_bytes: 50_000_000, total_bytes: 10_000_000_000}}
    )

    conn = get(conn, ~p"/healthz")

    assert response(conn, 503) =~ "database volume low"
  end

  test "GET /healthz fails open (200) when the database volume can't be read", %{conn: conn} do
    Application.put_env(:cinder, :disk_stats_stub, {:error, :df_failed})

    assert response(get(conn, ~p"/healthz"), 200) == "ok"
  end
end
