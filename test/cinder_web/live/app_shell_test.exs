defmodule CinderWeb.AppShellTest do
  use CinderWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "as an admin" do
    setup :register_and_log_in_admin

    test "renders the role-grouped sidebar with all admin links", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/calendar")

      for label <- ~w(Discover Dashboard Requests Library Activity Calendar Settings Users) do
        assert html =~ label
      end

      refute html =~ ">Status<"
    end

    test "marks the current route active", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/calendar")
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

    test "non-admins see only the Everyone group", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/")

      assert html =~ "Discover"
      assert html =~ "My requests"
      refute html =~ "Dashboard"
      refute html =~ "Library"
      refute html =~ "Activity"
      refute html =~ "Settings"
    end
  end
end
