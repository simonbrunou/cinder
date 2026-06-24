defmodule CinderWeb.WatchlistLiveTest do
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox

  alias Cinder.Catalog
  alias Cinder.Catalog.Movie
  alias Cinder.Requests

  # The LiveView runs in its own process, so the mock must be global (requires async: false).
  setup :register_and_log_in_admin
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

  # Admin path: add creates a :requested movie (via auto-approved request)
  test "admin add creates a :requested movie and shows it in the watchlist", %{conn: conn} do
    stub_search([@inception])
    {:ok, lv, _html} = live(conn, ~p"/")

    lv |> form("#search-form", %{"query" => "inception"}) |> render_change()
    lv |> element("#add-27205") |> render_click()

    assert has_element?(lv, "#watchlist", "Inception")
    assert [%Movie{tmdb_id: 27_205, status: :requested}] = Catalog.list_watchlist()
  end

  # Non-admin path: add creates a pending request, no movie created
  test "non-admin add creates a pending request, no movie", %{conn: conn} do
    stub_search([@inception])
    user = Cinder.AccountsFixtures.user_fixture()
    conn = log_in_user(conn, user)
    {:ok, lv, _html} = live(conn, ~p"/")

    lv |> form("#search-form", %{"query" => "inception"}) |> render_change()
    html = lv |> element("#add-27205") |> render_click()

    assert html =~ "awaiting approval"
    assert Catalog.list_by_status(:requested) == []
    assert [%Requests.Request{status: :pending}] = Requests.list_for_user(user)
  end

  # A title the user already has pending shows a Pending badge, not an Add button —
  # the badge is the dup guard at the UI layer (the request layer enforces it too).
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

    stub_search([@inception])
    {:ok, lv, _html} = live(conn, ~p"/")

    lv |> form("#search-form", %{"query" => "inception"}) |> render_change()

    assert has_element?(lv, "#results", "Pending")
    refute has_element?(lv, "#add-27205")
  end

  test "a quota-exceeded add shows the quota flash", %{conn: _conn} do
    user = Cinder.AccountsFixtures.user_fixture()
    {:ok, _} = Cinder.Accounts.update_user_quota(user, 0)
    conn = log_in_user(Phoenix.ConnTest.build_conn(), user)

    stub_search([@inception])
    {:ok, lv, _html} = live(conn, ~p"/")

    lv |> form("#search-form", %{"query" => "inception"}) |> render_change()
    html = lv |> element("#add-27205") |> render_click()

    assert html =~ "request limit"
    assert Requests.list_for_user(user) == []
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

  test "a malformed (non-binary) add payload is ignored, not a crash", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/")

    assert render_hook(lv, "add", %{"tmdb_id" => ["x"]}) =~ "search-form"
    assert Catalog.list_watchlist() == []
  end

  test "watchlist renders a colour-coded status badge", %{conn: conn} do
    {:ok, _movie} = Cinder.Catalog.add_to_watchlist(%{tmdb_id: 8100, title: "M"})
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
    {:ok, movie} = Cinder.Catalog.add_to_watchlist(%{tmdb_id: 9500, title: "Gone Soon"})

    {:ok, lv, html} = live(conn, ~p"/")
    assert html =~ "Gone Soon"

    Cinder.Catalog.broadcast_movie_deleted(movie.id)
    refute render(lv) =~ "Gone Soon"
  end
end
