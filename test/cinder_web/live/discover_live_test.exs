defmodule CinderWeb.DiscoverLiveTest do
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import ExUnit.CaptureLog
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

  @inception %{
    tmdb_id: 27_205,
    title: "Inception",
    year: 2010,
    poster_path: "/p.jpg",
    original_language: "en"
  }
  @got %{tmdb_id: 1399, title: "Game of Thrones", year: 2011, poster_path: "/got.jpg"}

  defp stub_movies(results),
    do: stub(Cinder.Catalog.TMDBMock, :search, fn _ -> {:ok, results} end)

  defp stub_tv(results),
    do: stub(Cinder.Catalog.TMDBMock, :search_tv, fn _ -> {:ok, results} end)

  test "first load shows an accessible search field", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/")
    assert has_element?(lv, "label[for='query']", "Search movies and TV")
    assert has_element?(lv, "input#query")
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

  test "a TV card shows the user's season-request state and keeps the season-picker link", %{
    conn: _conn
  } do
    user = Cinder.AccountsFixtures.user_fixture()
    conn = log_in_user(Phoenix.ConnTest.build_conn(), user)

    {:ok, _} =
      Requests.create_request(user, %{
        target_type: "season",
        target_id: 1399,
        season_number: 1,
        title: "Game of Thrones",
        year: 2011,
        poster_path: "/got.jpg"
      })

    stub_tv([@got])
    {:ok, lv, _html} = live(conn, ~p"/")

    lv |> form("#search-form", %{"query" => "thrones"}) |> render_change()

    assert has_element?(lv, "#results", "Pending")
    # The badge is additive — the season picker stays reachable for more seasons.
    assert has_element?(lv, ~s(#results a[href="/series/tmdb/1399"]))
  end

  test "a single query returns movies AND TV together in one grid", %{conn: conn} do
    stub_movies([@inception])
    stub_tv([@got])
    {:ok, lv, _html} = live(conn, ~p"/")

    html = lv |> form("#search-form", %{"query" => "x"}) |> render_change()

    assert html =~ "Inception"
    assert html =~ "Game of Thrones"
    # movie → inline Add form; TV → season-picker link
    assert has_element?(lv, "#add-form-27205")
    assert has_element?(lv, ~s(#results a[href="/series/tmdb/1399"]))
  end

  test "admin add creates a :requested movie and flips the result card off Add", %{conn: conn} do
    stub_movies([@inception])
    {:ok, lv, _html} = live(conn, ~p"/")

    lv |> form("#search-form", %{"query" => "inception"}) |> render_change()
    lv |> form("#add-form-27205") |> render_submit()

    assert [%Movie{tmdb_id: 27_205, status: :requested}] = Catalog.list_movies()
    refute has_element?(lv, "#add-form-27205")
  end

  # Regression (UX-3 Done-when): a non-admin add creates a pending request, NO :requested movie.
  test "non-admin add creates a pending request, no :requested movie row", %{conn: conn} do
    stub_movies([@inception])
    user = Cinder.AccountsFixtures.user_fixture()
    conn = log_in_user(conn, user)
    {:ok, lv, _html} = live(conn, ~p"/")

    lv |> form("#search-form", %{"query" => "inception"}) |> render_change()
    html = lv |> form("#add-form-27205") |> render_submit()

    assert html =~ "Awaiting approval"
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
    refute has_element?(lv, "#add-form-27205")
  end

  # An :upgrading movie still has a playable library file, so it reads as Available —
  # it must NOT re-show the Request affordance (which would file a redundant request).
  test "an upgrading movie shows the Available state, not a Request affordance", %{conn: conn} do
    Cinder.CatalogFixtures.movie_fixture(
      tmdb_id: 27_205,
      title: "Inception",
      status: :upgrading,
      download_id: "dl-up",
      download_protocol: :torrent,
      file_path: "/lib/Inception (2010)/Inception (2010).mkv"
    )

    stub_movies([@inception])
    {:ok, lv, _html} = live(conn, ~p"/")

    lv |> form("#search-form", %{"query" => "inception"}) |> render_change()

    assert has_element?(lv, "#results", "Available")
    refute has_element?(lv, "#add-form-27205")
  end

  test "a quota-exceeded add shows the quota flash", %{conn: _conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()
    user = Cinder.AccountsFixtures.user_fixture()
    {:ok, _} = Cinder.Accounts.update_user_quota(admin, user, 0)
    conn = log_in_user(Phoenix.ConnTest.build_conn(), user)

    stub_movies([@inception])
    {:ok, lv, _html} = live(conn, ~p"/")

    lv |> form("#search-form", %{"query" => "inception"}) |> render_change()
    html = lv |> form("#add-form-27205") |> render_submit()

    assert html =~ "request limit"
    assert Requests.list_for_user(user) == []
  end

  test "adding a movie carries the chosen language", %{conn: conn} do
    stub_movies([@inception])
    {:ok, lv, _html} = live(conn, ~p"/")

    lv |> form("#search-form", %{"query" => "inception"}) |> render_change()
    lv |> form("#add-form-27205", %{"preferred_language" => "french"}) |> render_submit()

    movie = Cinder.Catalog.get_movie_by_tmdb_id(27_205)
    assert movie.preferred_language == "french"
    assert movie.original_language == "en"
  end

  test "a total TMDB failure flashes and shows 'Search failed', not 'No matches'", %{conn: conn} do
    stub(Cinder.Catalog.TMDBMock, :search, fn _ -> {:error, :timeout} end)
    stub(Cinder.Catalog.TMDBMock, :search_tv, fn _ -> {:error, :nxdomain} end)
    {:ok, lv, _html} = live(conn, ~p"/")

    log =
      capture_log(fn ->
        html = lv |> form("#search-form", %{"query" => "boom"}) |> render_change()

        assert html =~ "Search failed"
        refute html =~ "No matches"
      end)

    assert log =~ "Discover search failed entirely:"
    assert log =~ "movies={:error, :timeout} tv={:error, :nxdomain}"
    assert render(lv) =~ "search-form"
  end

  test "an add with a non-numeric tmdb_id is ignored, not a crash", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/")
    assert render_hook(lv, "add", %{"tmdb_id" => "not-a-number"}) =~ "search-form"
    assert Catalog.list_movies() == []
  end

  test "a malformed (non-binary) add payload is ignored, not a crash", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/")
    assert render_hook(lv, "add", %{"tmdb_id" => ["x"]}) =~ "search-form"
    assert Catalog.list_movies() == []
  end

  test "a searched movie flips to Available live when it finishes downloading", %{conn: conn} do
    {:ok, movie} = Catalog.add_movie(@inception)
    stub_movies([@inception])
    {:ok, lv, _html} = live(conn, ~p"/")
    lv |> form("#search-form", %{"query" => "inception"}) |> render_change()

    {:ok, _} =
      Catalog.transition(movie, %{
        status: :available,
        download_id: "h",
        download_protocol: :torrent,
        file_path: "/lib/Inception (2010)/Inception (2010).mkv"
      })

    assert has_element?(lv, "#results", "Available")
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

    assert Cinder.Repo.get(Cinder.Catalog.Series, series.id) != nil
  end

  test "the old /series route redirects to /", %{conn: conn} do
    conn = get(conn, ~p"/series")
    assert redirected_to(conn) == ~p"/"
  end
end
