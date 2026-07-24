defmodule CinderWeb.SetupRoutingTest do
  # async: false — toggles the global :enforce_setup flag and writes a setting.
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  import Mox

  setup do
    Application.put_env(:cinder, :enforce_setup, true)
    on_exit(fn -> Application.put_env(:cinder, :enforce_setup, false) end)
    # Mounting `/` fetches trending (async, private-mode Mox reaches it via $callers).
    stub(Cinder.Catalog.TMDBMock, :trending, fn _ -> {:ok, []} end)
    :ok
  end

  test "incomplete setup redirects an admin to /setup", %{conn: conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()
    conn = log_in_user(conn, admin)
    assert {:error, {:redirect, %{to: "/setup"}}} = live(conn, ~p"/")
  end

  test "incomplete setup parks a non-admin at log-in", %{conn: conn} do
    user = Cinder.AccountsFixtures.user_fixture()
    conn = log_in_user(conn, user)
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/")
  end

  test "completed setup lets the app load normally", %{conn: conn} do
    Cinder.Settings.mark_setup_complete()
    on_exit(fn -> Cinder.Settings.delete("setup_complete") end)
    admin = Cinder.AccountsFixtures.admin_fixture()
    conn = log_in_user(conn, admin)
    assert {:ok, _lv, _html} = live(conn, ~p"/")
  end
end
