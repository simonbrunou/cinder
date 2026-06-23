defmodule CinderWeb.SeriesLiveTest do
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox
  import Cinder.AccountsFixtures

  alias Cinder.Catalog
  alias Cinder.Catalog.Series

  # The LiveView (and the start_async add Task) run in their own processes, so the
  # mock must be global (requires async: false).
  setup :register_and_log_in_admin
  setup :set_mox_global

  @show %{tmdb_id: 1399, title: "Game of Thrones", year: 2011, poster_path: "/got.jpg"}

  defp stub_search(results) do
    stub(Cinder.Catalog.TMDBMock, :search_tv, fn _query -> {:ok, results} end)
  end

  defp stub_series_tree(tmdb_id) do
    stub(Cinder.Catalog.TMDBMock, :get_series, fn ^tmdb_id ->
      {:ok,
       %{
         tmdb_id: tmdb_id,
         tvdb_id: nil,
         title: "Game of Thrones",
         year: 2011,
         poster_path: "/got.jpg",
         seasons: [%{season_number: 1}]
       }}
    end)

    stub(Cinder.Catalog.TMDBMock, :get_season, fn ^tmdb_id, 1 ->
      {:ok,
       %{
         season_number: 1,
         episodes: [
           %{tmdb_episode_id: 1, episode_number: 1, title: "Winter Is Coming", air_date: nil}
         ]
       }}
    end)
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

  test "adding a series persists it and shows it in the list", %{conn: conn} do
    stub_search([@show])
    stub_series_tree(1399)
    {:ok, lv, _html} = live(conn, ~p"/series")

    lv |> form("#tv-search-form", %{"query" => "thrones"}) |> render_change()
    lv |> element("#add-1399") |> render_click()

    # The add runs in a start_async Task; render_async awaits it.
    render_async(lv)
    assert has_element?(lv, "#series-list", "Game of Thrones")
    assert [%Series{tmdb_id: 1399}] = Catalog.list_series()
  end

  test "a malformed add event does not crash the LiveView", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/series")
    render_hook(lv, "add", %{"tmdb_id" => "not-a-number"})
    assert render(lv) =~ "TV series"
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
