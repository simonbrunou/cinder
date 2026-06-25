defmodule CinderWeb.DiscoverLiveTest do
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox

  alias Cinder.Catalog
  alias Cinder.Catalog.Movie
  alias Cinder.Requests

  # The LiveView runs in its own process, so the mock must be global (async: false).
  setup :register_and_log_in_admin
  setup :set_mox_global

  setup do
    # search_discover always hits both endpoints; default both to empty.
    stub(Cinder.Catalog.TMDBMock, :search, fn _ -> {:ok, []} end)
    stub(Cinder.Catalog.TMDBMock, :search_tv, fn _ -> {:ok, []} end)
    :ok
  end

  @inception %{tmdb_id: 27_205, title: "Inception", year: 2010, poster_path: "/p.jpg"}
  @got %{tmdb_id: 1399, title: "Game of Thrones", year: 2011, poster_path: "/got.jpg"}

  defp stub_movies(results),
    do: stub(Cinder.Catalog.TMDBMock, :search, fn _ -> {:ok, results} end)

  defp stub_tv(results),
    do: stub(Cinder.Catalog.TMDBMock, :search_tv, fn _ -> {:ok, results} end)

  test "first load shows an empty-watchlist state and an accessible search field", %{conn: conn} do
    {:ok, lv, html} = live(conn, ~p"/")
    assert html =~ "watchlist is empty"
    assert has_element?(lv, "input#query[aria-label='Search movies and TV']")
  end

  test "typing a query renders movie results", %{conn: conn} do
    stub_movies([@inception])
    {:ok, lv, _html} = live(conn, ~p"/")

    html = lv |> form("#search-form", %{"query" => "inception"}) |> render_change()

    assert html =~ "Inception"
    assert html =~ "2010"
    assert html =~ "Film"
  end

  test "typing a query renders TV results that link to the season picker", %{conn: conn} do
    stub_tv([@got])
    {:ok, lv, _html} = live(conn, ~p"/")

    html = lv |> form("#search-form", %{"query" => "thrones"}) |> render_change()

    assert html =~ "Game of Thrones"
    assert html =~ "TV"
    assert has_element?(lv, ~s(#results a[href="/series/tmdb/1399"]))
  end

  test "a single query returns movies AND TV together in one grid", %{conn: conn} do
    stub_movies([@inception])
    stub_tv([@got])
    {:ok, lv, _html} = live(conn, ~p"/")

    html = lv |> form("#search-form", %{"query" => "x"}) |> render_change()

    assert html =~ "Inception"
    assert html =~ "Game of Thrones"
    # movie → inline Add; TV → season-picker link
    assert has_element?(lv, "#add-27205")
    assert has_element?(lv, ~s(#results a[href="/series/tmdb/1399"]))
  end

  test "admin add creates a :requested movie and shows it in the watchlist", %{conn: conn} do
    stub_movies([@inception])
    {:ok, lv, _html} = live(conn, ~p"/")

    lv |> form("#search-form", %{"query" => "inception"}) |> render_change()
    lv |> element("#add-27205") |> render_click()

    assert has_element?(lv, "#watchlist", "Inception")
    assert [%Movie{tmdb_id: 27_205, status: :requested}] = Catalog.list_watchlist()
  end

  # Regression (UX-3 Done-when): a non-admin add creates a pending request, NO :requested movie.
  test "non-admin add creates a pending request, no :requested movie row", %{conn: conn} do
    stub_movies([@inception])
    user = Cinder.AccountsFixtures.user_fixture()
    conn = log_in_user(conn, user)
    {:ok, lv, _html} = live(conn, ~p"/")

    lv |> form("#search-form", %{"query" => "inception"}) |> render_change()
    html = lv |> element("#add-27205") |> render_click()

    assert html =~ "awaiting approval"
    assert Catalog.list_by_status(:requested) == []
    assert [%Requests.Request{status: :pending}] = Requests.list_for_user(user)
  end

  test "a pending request shows a Pending badge instead of Add", %{conn: _conn} do
    user = Cinder.AccountsFixtures.user_fixture()
    conn = log_in_user(Phoenix.ConnTest.build_conn(), user)

    {:ok, _} =
      Requests.create_request(user, %{
        target_type: "movie",
        target_id: 27_205,
        title: "Inception",
        year: 2010,
        poster_path: "/p.jpg"
      })

    stub_movies([@inception])
    {:ok, lv, _html} = live(conn, ~p"/")

    lv |> form("#search-form", %{"query" => "inception"}) |> render_change()

    assert has_element?(lv, "#results", "Pending")
    refute has_element?(lv, "#add-27205")
  end

  test "a quota-exceeded add shows the quota flash", %{conn: _conn} do
    user = Cinder.AccountsFixtures.user_fixture()
    {:ok, _} = Cinder.Accounts.update_user_quota(user, user, 0)
    conn = log_in_user(Phoenix.ConnTest.build_conn(), user)

    stub_movies([@inception])
    {:ok, lv, _html} = live(conn, ~p"/")

    lv |> form("#search-form", %{"query" => "inception"}) |> render_change()
    html = lv |> element("#add-27205") |> render_click()

    assert html =~ "request limit"
    assert Requests.list_for_user(user) == []
  end

  test "a total TMDB failure flashes and shows 'Search failed', not 'No matches'", %{conn: conn} do
    stub(Cinder.Catalog.TMDBMock, :search, fn _ -> {:error, :timeout} end)
    stub(Cinder.Catalog.TMDBMock, :search_tv, fn _ -> {:error, :nxdomain} end)
    {:ok, lv, _html} = live(conn, ~p"/")

    html = lv |> form("#search-form", %{"query" => "boom"}) |> render_change()

    assert html =~ "Search failed"
    refute html =~ "No matches"
    assert render(lv) =~ "search-form"
  end

  test "an add with a non-numeric tmdb_id is ignored, not a crash", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/")
    assert render_hook(lv, "add", %{"tmdb_id" => "not-a-number"}) =~ "search-form"
    assert Catalog.list_watchlist() == []
  end

  test "a malformed (non-binary) add payload is ignored, not a crash", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/")
    assert render_hook(lv, "add", %{"tmdb_id" => ["x"]}) =~ "search-form"
    assert Catalog.list_watchlist() == []
  end

  test "watchlist renders a colour-coded status badge", %{conn: conn} do
    {:ok, _movie} = Catalog.add_to_watchlist(%{tmdb_id: 8100, title: "M"})
    {:ok, _lv, html} = live(conn, ~p"/")
    assert html =~ "badge-neutral"
  end

  test "a movie's status change updates its badge live", %{conn: conn} do
    {:ok, movie} = Catalog.add_to_watchlist(@inception)
    {:ok, lv, _html} = live(conn, ~p"/")
    assert has_element?(lv, "#watchlist", "Requested")

    {:ok, _} = Catalog.transition(movie, %{status: :downloading, download_id: "h"})

    assert render(lv) =~ "Downloading"
    refute has_element?(lv, "#watchlist .badge", "Requested")
  end

  test "drops a deleted movie from the watchlist on {:movie_deleted, id}", %{conn: conn} do
    {:ok, movie} = Catalog.add_to_watchlist(%{tmdb_id: 9500, title: "Gone Soon"})
    {:ok, lv, html} = live(conn, ~p"/")
    assert html =~ "Gone Soon"

    Catalog.broadcast_movie_deleted(movie.id)
    refute render(lv) =~ "Gone Soon"
  end

  test "a forged series event from a non-admin on / is a harmless no-op", %{conn: conn} do
    conn = log_in_user(conn, Cinder.AccountsFixtures.user_fixture())

    series =
      Cinder.Repo.insert!(%Cinder.Catalog.Series{
        tmdb_id: 7777,
        title: "Severance",
        monitor_strategy: :future
      })

    {:ok, lv, _html} = live(conn, ~p"/")
    render_hook(lv, "confirm_delete_series", %{"id" => to_string(series.id)})

    assert Cinder.Catalog.get_series_by_id(series.id) != nil
  end

  test "the old /series route redirects to /", %{conn: conn} do
    conn = get(conn, ~p"/series")
    assert redirected_to(conn) == ~p"/"
  end
end
