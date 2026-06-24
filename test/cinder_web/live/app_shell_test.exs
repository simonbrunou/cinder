defmodule CinderWeb.AppShellTest do
  use CinderWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "as an admin" do
    setup :register_and_log_in_admin

    test "renders the role-grouped sidebar with all admin links", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/")

      for label <- [
            "Discover",
            "My requests",
            "Requests",
            "Status",
            "Calendar",
            "Users",
            "Settings"
          ] do
        assert html =~ label
      end
    end

    test "marks the current route active", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/status")
      assert html =~ ~s(aria-current="page")
    end

    test "ships no Phoenix-generator chrome and a Cinder title", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/")
      refute html =~ "phoenixframework.org"
      refute html =~ "Get Started"
      refute html =~ "Phoenix Framework"
    end

    test "exposes a skip-to-content link and a main landmark", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/")
      assert html =~ ~s(href="#main")
      assert html =~ ~s(id="main")
    end
  end

  describe "as a non-admin user" do
    setup :register_and_log_in_user

    test "shows only the everyone links, never the admin group", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/")
      assert html =~ "Discover"
      assert html =~ "My requests"
      refute html =~ "Requests"
      refute html =~ "Status"
      refute html =~ "Users"
      refute html =~ "Settings"
    end
  end
end
