defmodule CinderWeb.SeriesLiveTest do
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox
  import Cinder.AccountsFixtures

  # The LiveView (and the start_async add Task) run in their own processes, so the
  # mock must be global (requires async: false).
  setup :register_and_log_in_admin
  setup :set_mox_global

  @show %{tmdb_id: 1399, title: "Game of Thrones", year: 2011, poster_path: "/got.jpg"}

  defp stub_search(results) do
    stub(Cinder.Catalog.TMDBMock, :search_tv, fn _query -> {:ok, results} end)
  end

  test "first load shows the empty state and an accessible search field", %{conn: conn} do
    {:ok, lv, html} = live(conn, ~p"/series")
    assert html =~ "No series added yet."
    assert has_element?(lv, "input#tv-query[aria-label='Search TV series']")
  end

  test "searching renders TMDB TV results", %{conn: conn} do
    stub_search([@show])
    {:ok, lv, _html} = live(conn, ~p"/series")

    html = lv |> form("#tv-search-form", %{"query" => "thrones"}) |> render_change()

    assert html =~ "Game of Thrones"
    assert html =~ "2011"
  end

  test "search results link to the discovery detail page (by tmdb_id)", %{conn: conn} do
    stub_search([@show])
    {:ok, lv, _html} = live(conn, ~p"/series")

    html = lv |> form("#tv-search-form", %{"query" => "thrones"}) |> render_change()

    assert has_element?(lv, ~s(a[href="/series/tmdb/1399"]))
    assert html =~ ~s(href="/series/tmdb/1399")
  end

  test "an unknown event does not crash the LiveView", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/series")
    render_hook(lv, "bogus", %{})
    assert render(lv) =~ "TV series"
  end

  test "a non-admin can load /series but NOT the admin local detail /series/:id", %{conn: conn} do
    user = user_fixture()
    conn = log_in_user(conn, user)
    {:ok, _lv, _html} = live(conn, ~p"/series")
    assert {:error, {:redirect, _}} = live(conn, ~p"/series/1")
  end
end
