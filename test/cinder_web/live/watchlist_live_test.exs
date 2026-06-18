defmodule CinderWeb.WatchlistLiveTest do
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox

  alias Cinder.Catalog
  alias Cinder.Catalog.Movie

  # The LiveView runs in its own process, so the mock must be global (requires async: false).
  setup :set_mox_global

  @inception %{tmdb_id: 27_205, title: "Inception", year: 2010, poster_path: "/p.jpg"}

  defp stub_search(results) do
    stub(Cinder.Catalog.TMDBMock, :search, fn _query -> {:ok, results} end)
  end

  test "first load shows an empty-watchlist state with an accessible search field", %{conn: conn} do
    {:ok, lv, html} = live(conn, ~p"/")
    assert html =~ "watchlist is empty"
    assert has_element?(lv, "input#query[aria-label='Search movies']")
  end

  test "typing a query renders TMDB results", %{conn: conn} do
    stub_search([@inception])
    {:ok, lv, _html} = live(conn, ~p"/")

    html = lv |> form("#search-form", %{"query" => "inception"}) |> render_change()

    assert html =~ "Inception"
    assert html =~ "2010"
  end

  test "adding a result persists a :requested movie and shows it in the watchlist", %{conn: conn} do
    stub_search([@inception])
    {:ok, lv, _html} = live(conn, ~p"/")

    lv |> form("#search-form", %{"query" => "inception"}) |> render_change()
    lv |> element("#add-27205") |> render_click()

    assert has_element?(lv, "#watchlist", "Inception")
    assert [%Movie{tmdb_id: 27_205, status: :requested}] = Catalog.list_watchlist()
  end

  test "adding a movie already on the watchlist flashes and does not duplicate", %{conn: conn} do
    {:ok, _} = Catalog.add_to_watchlist(@inception)
    stub_search([@inception])
    {:ok, lv, _html} = live(conn, ~p"/")

    lv |> form("#search-form", %{"query" => "inception"}) |> render_change()
    html = lv |> element("#add-27205") |> render_click()

    assert html =~ "already on your watchlist"
    assert length(Catalog.list_watchlist()) == 1
  end

  test "a TMDB error flashes without crashing, and doesn't claim 'No matches'", %{conn: conn} do
    stub(Cinder.Catalog.TMDBMock, :search, fn _ -> {:error, :timeout} end)
    {:ok, lv, _html} = live(conn, ~p"/")

    html = lv |> form("#search-form", %{"query" => "boom"}) |> render_change()

    assert html =~ "TMDB search failed"
    refute html =~ "No matches"
    # Still alive and responsive.
    assert render(lv) =~ "search-form"
  end

  test "an add event with a non-numeric tmdb_id is ignored, not a crash", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/")

    assert render_hook(lv, "add", %{"tmdb_id" => "not-a-number"}) =~ "search-form"
    assert Catalog.list_watchlist() == []
  end
end
