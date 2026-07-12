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

    test "renders a localized route title and one labelled primary navigation", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/calendar")

      assert html =~ ">Calendar · Cinder</title>"
      refute html =~ ">Cinder · Cinder</title>"
      assert length(Regex.scan(~r/<nav[^>]+aria-label="Primary"/, html)) == 1
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

  describe "UX-5 a11y hardening" do
    setup :register_and_log_in_admin

    test "the icon-only theme toggle exposes an accessible name per option", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/")

      assert html =~ ~s(aria-label="Use system theme")
      assert html =~ ~s(aria-label="Use light theme")
      assert html =~ ~s(aria-label="Use dark theme")
    end

    test "the mobile nav drawer toggle is labelled", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/")
      assert html =~ ~s(aria-label="Toggle navigation menu")
    end

    test "the mobile drawer stays viewport-bound and centers its brand", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/")

      assert html =~ ~s(class="navbar relative justify-center)
      assert html =~ ~s(class="flex h-dvh w-64 flex-col)
      assert html =~ "overflow-y-auto"
    end
  end

  describe "auth pages (unauthenticated)" do
    test "render their route titles", %{conn: conn} do
      {:ok, _lv, login} = live(conn, ~p"/users/log-in")
      assert login =~ ">Log in · Cinder</title>"

      {:ok, _lv, register} = live(conn, ~p"/users/register")
      assert register =~ ">Register · Cinder</title>"
    end

    test "use the ember accent token, not the undefined text-brand class", %{conn: conn} do
      {:ok, _lv, login} = live(conn, ~p"/users/log-in")
      refute login =~ "text-brand"
      assert login =~ "text-primary"

      {:ok, _lv, register} = live(conn, ~p"/users/register")
      refute register =~ "text-brand"
      assert register =~ "text-primary"
    end
  end
end
