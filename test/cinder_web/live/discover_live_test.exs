defmodule CinderWeb.DiscoverLiveTest do
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import ExUnit.CaptureLog
  import Mox

  alias Cinder.Catalog
  alias Cinder.Catalog.Movie
  alias Cinder.Requests
  alias Cinder.Settings

  # The LiveView runs in its own process, so the mock must be global (async: false).
  setup :register_and_log_in_admin
  setup :set_mox_global
  setup :reset_cinder_env

  setup do
    # search_discover always hits all four endpoints; default all to empty.
    stub(Cinder.Catalog.TMDBMock, :search, fn _, _ -> {:ok, []} end)
    stub(Cinder.Catalog.TMDBMock, :search_tv, fn _, _ -> {:ok, []} end)
    stub(Cinder.Catalog.TMDBMock, :search_person, fn _, _ -> {:ok, []} end)
    stub(Cinder.Catalog.TMDBMock, :search_collection, fn _, _ -> {:ok, []} end)
    # mount always fetches the landing rails (async); default them all empty.
    stub(Cinder.Catalog.TMDBMock, :trending, fn _ -> {:ok, []} end)
    stub(Cinder.Catalog.TMDBMock, :popular_movies, fn _ -> {:ok, []} end)
    stub(Cinder.Catalog.TMDBMock, :top_rated_movies, fn _ -> {:ok, []} end)
    stub(Cinder.Catalog.TMDBMock, :now_playing_movies, fn _ -> {:ok, []} end)
    stub(Cinder.Catalog.TMDBMock, :popular_tv, fn _ -> {:ok, []} end)
    stub(Cinder.Catalog.TMDBMock, :top_rated_tv, fn _ -> {:ok, []} end)

    stub(Cinder.Catalog.TMDBMock, :get_movie, fn id ->
      {:ok,
       %{
         tmdb_id: id,
         imdb_id: nil,
         title: "Inception",
         year: 2010,
         poster_path: "/p.jpg",
         original_language: "en"
       }}
    end)

    stub(Cinder.Catalog.TMDBMock, :get_movie_alternative_titles, fn _ -> {:ok, []} end)

    stub(Cinder.Catalog.TMDBMock, :get_series, fn id ->
      {:ok,
       %{
         tmdb_id: id,
         title: "Game of Thrones",
         year: 2011,
         poster_path: "/got.jpg",
         seasons: []
       }}
    end)

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
    do: stub(Cinder.Catalog.TMDBMock, :search, fn _, _ -> {:ok, results} end)

  defp stub_tv(results),
    do: stub(Cinder.Catalog.TMDBMock, :search_tv, fn _, _ -> {:ok, results} end)

  defp stub_trending(results),
    do: stub(Cinder.Catalog.TMDBMock, :trending, fn _ -> {:ok, results} end)

  defp stub_popular(results),
    do: stub(Cinder.Catalog.TMDBMock, :popular_movies, fn _ -> {:ok, results} end)

  defp stub_top_rated(results),
    do: stub(Cinder.Catalog.TMDBMock, :top_rated_movies, fn _ -> {:ok, results} end)

  defp stub_now_playing(results),
    do: stub(Cinder.Catalog.TMDBMock, :now_playing_movies, fn _ -> {:ok, results} end)

  defp stub_popular_tv(results),
    do: stub(Cinder.Catalog.TMDBMock, :popular_tv, fn _ -> {:ok, results} end)

  defp stub_top_rated_tv(results),
    do: stub(Cinder.Catalog.TMDBMock, :top_rated_tv, fn _ -> {:ok, results} end)

  defp stub_persons(results),
    do: stub(Cinder.Catalog.TMDBMock, :search_person, fn _, _ -> {:ok, results} end)

  defp stub_collections(results),
    do: stub(Cinder.Catalog.TMDBMock, :search_collection, fn _, _ -> {:ok, results} end)

  @nolan %{
    tmdb_id: 500,
    title: "Christopher Nolan",
    year: nil,
    poster_path: "/cn.jpg",
    department: nil
  }
  @dark_knight_collection %{
    tmdb_id: 10,
    title: "The Dark Knight Collection",
    year: nil,
    poster_path: "/dkc.jpg"
  }

  test "an empty query shows the trending grid with the usual actions", %{conn: conn} do
    stub_trending([Map.put(@inception, :type, :movie), Map.put(@got, :type, :tv)])
    {:ok, lv, _html} = live(conn, ~p"/")

    html = render_async(lv)

    assert html =~ "Trending this week"
    assert html =~ "Inception"
    assert html =~ "Game of Thrones"
    # Same affordances as search results: movie → inline Add, TV → season picker.
    assert has_element?(lv, "#trending #add-form-27205")
    assert has_element?(lv, ~s(#trending a[href="/series/tmdb/1399"]))
  end

  test "typing a query replaces trending; clearing it brings trending back", %{conn: conn} do
    stub_trending([Map.put(@inception, :type, :movie)])
    stub_movies([@inception])
    {:ok, lv, _html} = live(conn, ~p"/")
    render_async(lv)

    html = lv |> form("#search-form", %{"query" => "inception"}) |> render_change()
    refute html =~ "Trending this week"
    assert has_element?(lv, "#results")

    html = lv |> form("#search-form", %{"query" => ""}) |> render_change()
    assert html =~ "Trending this week"
  end

  test "a trending movie can be requested straight from the landing grid", %{conn: conn} do
    stub_trending([Map.put(@inception, :type, :movie)])
    {:ok, lv, _html} = live(conn, ~p"/")
    render_async(lv)

    lv |> form("#add-form-27205") |> render_submit()
    render_async(lv)

    assert [%Movie{tmdb_id: 27_205, status: :requested}] = Catalog.list_movies()
    refute has_element?(lv, "#add-form-27205")
  end

  test "a trending failure leaves the page search-only", %{conn: conn} do
    stub(Cinder.Catalog.TMDBMock, :trending, fn _ -> {:error, :tmdb_down} end)

    log =
      capture_log(fn ->
        {:ok, lv, _html} = live(conn, ~p"/")
        html = render_async(lv)

        refute html =~ "Trending this week"
        assert has_element?(lv, "input#query")
      end)

    assert log =~ "Trending fetch failed"
  end

  @popular_pick %{
    tmdb_id: 100,
    title: "Popular Pick",
    year: 2020,
    poster_path: "/pop.jpg",
    original_language: "en",
    type: :movie
  }
  @new_release %{
    tmdb_id: 200,
    title: "New Release",
    year: 2026,
    poster_path: "/np.jpg",
    original_language: "en",
    type: :movie
  }

  test "the popular/top-rated/now-playing rails render from mock data with the usual actions", %{
    conn: conn
  } do
    stub_popular([@popular_pick])
    stub_top_rated([Map.put(@got, :type, :tv)])
    stub_now_playing([@new_release])
    {:ok, lv, _html} = live(conn, ~p"/")

    html = render_async(lv)

    assert html =~ "Popular movies"
    assert html =~ "Top rated movies"
    assert html =~ "Now playing"
    assert has_element?(lv, "#popular #add-form-100")
    assert has_element?(lv, ~s(#top-rated a[href="/series/tmdb/1399"]))
    assert has_element?(lv, "#now-playing #add-form-200")
  end

  # TMDB's lists commonly overlap (a blockbuster is often trending AND popular); the same
  # movie must render exactly once so its Add form's id (keyed only by tmdb_id) never
  # duplicates on the page — regression for `DiscoverLive.dedupe/2`.
  test "a movie in both trending and popular renders once, kept in the earlier rail", %{
    conn: conn
  } do
    stub_trending([Map.put(@inception, :type, :movie)])
    stub_popular([Map.put(@inception, :type, :movie)])
    {:ok, lv, _html} = live(conn, ~p"/")

    render_async(lv)

    assert has_element?(lv, "#trending #add-form-27205")
    refute has_element?(lv, "#popular #add-form-27205")
  end

  # Regression: the add handler used to search only results ++ trending, making the
  # Add button on the popular/top-rated/now-playing/genre rails a silent no-op for a
  # movie that appears nowhere else.
  test "a rail-only movie can be requested from the popular rail", %{conn: conn} do
    stub_popular([@popular_pick])
    {:ok, lv, _html} = live(conn, ~p"/")
    render_async(lv)

    lv |> form("#add-form-100") |> render_submit()
    render_async(lv)

    assert [%Movie{tmdb_id: 100, status: :requested}] = Catalog.list_movies()
  end

  test "a popular-movies failure leaves the other rails intact and the page still 200s", %{
    conn: conn
  } do
    stub_trending([Map.put(@inception, :type, :movie)])
    stub(Cinder.Catalog.TMDBMock, :popular_movies, fn _ -> {:error, :tmdb_down} end)

    log =
      capture_log(fn ->
        {:ok, lv, _html} = live(conn, ~p"/")
        html = render_async(lv)

        assert html =~ "Trending this week"
        refute html =~ "Popular movies"
      end)

    assert log =~ "Popular movies fetch failed"
  end

  @severance %{tmdb_id: 95_396, title: "Severance", year: 2022, poster_path: "/sev.jpg"}

  test "the Popular TV and Top rated TV rails render TV cards linking to the season picker", %{
    conn: conn
  } do
    stub_popular_tv([Map.put(@got, :type, :tv)])
    stub_top_rated_tv([Map.put(@severance, :type, :tv)])
    {:ok, lv, _html} = live(conn, ~p"/")

    html = render_async(lv)

    assert html =~ "Popular TV"
    assert html =~ "Top rated TV"
    assert html =~ "Game of Thrones"
    assert html =~ "Severance"
    # TV cards carry the season-picker link, not an Add form — same affordance as trending TV.
    assert has_element?(lv, ~s(#popular-tv a[href="/series/tmdb/1399"]))
    assert has_element?(lv, ~s(#top-rated-tv a[href="/series/tmdb/95396"]))
  end

  test "a Popular TV failure leaves the other rails intact and the page still 200s", %{conn: conn} do
    stub_trending([Map.put(@inception, :type, :movie)])
    stub(Cinder.Catalog.TMDBMock, :popular_tv, fn _ -> {:error, :tmdb_down} end)

    log =
      capture_log(fn ->
        {:ok, lv, _html} = live(conn, ~p"/")
        html = render_async(lv)

        assert html =~ "Trending this week"
        refute html =~ "Popular TV"
      end)

    assert log =~ "Popular TV fetch failed"
  end

  # A show trending AND in the Popular TV rail renders once (kept in the earlier rail) — the
  # {type, tmdb_id} dedupe covers TV too, not just movies.
  test "a show in both trending and Popular TV renders once", %{conn: conn} do
    stub_trending([Map.put(@got, :type, :tv)])
    stub_popular_tv([Map.put(@got, :type, :tv)])
    {:ok, lv, _html} = live(conn, ~p"/")

    render_async(lv)

    assert has_element?(lv, ~s(#trending a[href="/series/tmdb/1399"]))
    refute has_element?(lv, ~s(#popular-tv a[href="/series/tmdb/1399"]))
  end

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

  test "a person result shows the department and links to the person's drill-in page", %{
    conn: conn
  } do
    stub_persons([Map.put(@nolan, :department, "Directing")])
    {:ok, lv, _html} = live(conn, ~p"/")

    html = lv |> form("#search-form", %{"query" => "nolan"}) |> render_change()

    assert html =~ "Christopher Nolan"
    assert html =~ "Director"
    assert html =~ "Person"
    assert has_element?(lv, ~s(#results a[href="/person/tmdb/500"]))
  end

  test "a collection result links to the collection's drill-in page", %{conn: conn} do
    stub_collections([@dark_knight_collection])
    {:ok, lv, _html} = live(conn, ~p"/")

    html = lv |> form("#search-form", %{"query" => "dark knight"}) |> render_change()

    assert html =~ "The Dark Knight Collection"
    assert html =~ "Collection"
    assert has_element?(lv, ~s(#results a[href="/collection/tmdb/10"]))
  end

  test "the People and Collections filter chips isolate their own result type", %{conn: conn} do
    stub_movies([@inception])
    stub_tv([@got])
    stub_persons([@nolan])
    stub_collections([@dark_knight_collection])
    {:ok, lv, _html} = live(conn, ~p"/")

    lv |> form("#search-form", %{"query" => "x"}) |> render_change()

    html = lv |> element(~s(button[phx-value-type="person"])) |> render_click()
    assert html =~ "Christopher Nolan"
    refute html =~ "Inception"
    refute html =~ "Game of Thrones"
    refute html =~ "The Dark Knight Collection"

    html = lv |> element(~s(button[phx-value-type="collection"])) |> render_click()
    assert html =~ "The Dark Knight Collection"
    refute html =~ "Christopher Nolan"
  end

  test "admin add creates a :requested movie and flips the result card off Add", %{conn: conn} do
    stub_movies([@inception])
    {:ok, lv, _html} = live(conn, ~p"/")

    lv |> form("#search-form", %{"query" => "inception"}) |> render_change()
    lv |> form("#add-form-27205") |> render_submit()
    render_async(lv)

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
    lv |> form("#add-form-27205") |> render_submit()
    html = render_async(lv)

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
    lv |> form("#add-form-27205") |> render_submit()
    html = render_async(lv)

    assert html =~ "request limit"
    assert Requests.list_for_user(user) == []
  end

  test "adding a movie carries the chosen language", %{conn: conn} do
    stub_movies([@inception])
    {:ok, lv, _html} = live(conn, ~p"/")

    lv |> form("#search-form", %{"query" => "inception"}) |> render_change()
    lv |> form("#add-form-27205", %{"preferred_language" => "french"}) |> render_submit()
    render_async(lv)

    movie = Cinder.Catalog.get_movie_by_tmdb_id(27_205)
    assert movie.preferred_language == "french"
    assert movie.original_language == "en"
  end

  test "movie request forms carry a validated media profile proposal", %{conn: _conn} do
    user = Cinder.AccountsFixtures.user_fixture()
    conn = log_in_user(Phoenix.ConnTest.build_conn(), user)
    stub_movies([@inception])
    {:ok, lv, _html} = live(conn, ~p"/")
    lv |> form("#search-form", %{"query" => "inception"}) |> render_change()

    assert has_element?(lv, "#add-form-27205 select[name='proposed_media_profile']")

    lv
    |> form("#add-form-27205", %{"proposed_media_profile" => "anime"})
    |> render_submit()

    render_async(lv)
    assert [%{proposed_media_profile: :anime}] = Requests.list_for_user(user)

    other = Map.put(@inception, :tmdb_id, 27_206)
    stub_movies([other])
    lv |> form("#search-form", %{"query" => "other"}) |> render_change()

    render_hook(lv, "add", %{
      "tmdb_id" => "27206",
      "proposed_media_profile" => "forged"
    })

    assert length(Requests.list_for_user(user)) == 1
  end

  test "an unconfigured TMDB failure links to setup while setup is incomplete", %{conn: conn} do
    stub(Cinder.Catalog.TMDBMock, :search, fn _, _ -> {:error, :unauthorized} end)
    stub(Cinder.Catalog.TMDBMock, :search_tv, fn _, _ -> {:error, :unauthorized} end)
    {:ok, lv, _html} = live(conn, ~p"/")

    capture_log(fn ->
      lv |> form("#search-form", %{"query" => "boom"}) |> render_change()
    end)

    assert has_element?(lv, "p", "TMDB isn't configured yet.")

    assert has_element?(
             lv,
             ~s(#configure-tmdb-link[href="/setup"]),
             "Add your API key in Setup →"
           )

    assert has_element?(lv, "#flash-error", "TMDB isn't configured yet.")
    refute has_element?(lv, "p", "TMDB didn't respond. Try again.")
  end

  test "an unconfigured TMDB failure links to settings after setup is complete", %{conn: conn} do
    Settings.mark_setup_complete()
    stub(Cinder.Catalog.TMDBMock, :search, fn _, _ -> {:error, :unauthorized} end)
    stub(Cinder.Catalog.TMDBMock, :search_tv, fn _, _ -> {:error, :unauthorized} end)
    {:ok, lv, _html} = live(conn, ~p"/")

    capture_log(fn ->
      lv |> form("#search-form", %{"query" => "boom"}) |> render_change()
    end)

    assert has_element?(
             lv,
             ~s(#configure-tmdb-link[href="/settings"]),
             "Add your API key in Settings →"
           )
  end

  test "a configured TMDB failure keeps the transient error and not 'No matches'", %{conn: conn} do
    Settings.put("tmdb_token", "configured-token")
    stub(Cinder.Catalog.TMDBMock, :search, fn _, _ -> {:error, :timeout} end)
    stub(Cinder.Catalog.TMDBMock, :search_tv, fn _, _ -> {:error, :nxdomain} end)
    {:ok, lv, _html} = live(conn, ~p"/")

    log =
      capture_log(fn ->
        html = lv |> form("#search-form", %{"query" => "boom"}) |> render_change()

        assert html =~ "Search failed"
        refute html =~ "No matches"
      end)

    assert has_element?(lv, "p", "TMDB didn't respond. Try again.")
    refute has_element?(lv, "#configure-tmdb-link")
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

  test "selecting a genre chip loads a genre-filtered grid and marks it pressed", %{conn: conn} do
    stub(Cinder.Catalog.TMDBMock, :discover_movies, fn 28, _ ->
      {:ok, [Map.put(@inception, :type, :movie)]}
    end)

    {:ok, lv, _html} = live(conn, ~p"/")
    render_async(lv)

    refute has_element?(lv, ~s(button[phx-value-id="28"][aria-pressed="true"]))

    html = lv |> element(~s(button[phx-value-id="28"])) |> render_click()

    assert html =~ "Inception"
    assert has_element?(lv, ~s(button[phx-value-id="28"][aria-pressed="true"]))
  end

  test "a genre-fetch failure flashes but leaves the rest of the page intact", %{conn: conn} do
    stub(Cinder.Catalog.TMDBMock, :discover_movies, fn 28, _ -> {:error, :timeout} end)
    {:ok, lv, _html} = live(conn, ~p"/")
    render_async(lv)

    html = lv |> element(~s(button[phx-value-id="28"])) |> render_click()

    assert html =~ "TMDB search failed"
    assert has_element?(lv, "input#query")
  end

  test "a non-numeric genre id is ignored, not a crash", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/")
    render_async(lv)
    assert render_hook(lv, "select_genre", %{"id" => "not-a-number"}) =~ "search-form"
  end

  test "a malformed (non-binary) genre payload is ignored, not a crash", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/")
    render_async(lv)
    assert render_hook(lv, "select_genre", %{"id" => ["x"]}) =~ "search-form"
  end

  # A well-formed but unknown genre id (not in Cinder.Catalog.Genres.list/0) must not reach
  # Catalog.movies_by_genre/2 — no stub is set for :discover_movies, so a Mox call would raise.
  test "an unknown (but numeric) genre id is ignored, not a crash", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/")
    render_async(lv)
    assert render_hook(lv, "select_genre", %{"id" => "999999"}) =~ "search-form"
  end

  test "switching the genre browser to TV loads a TV-genre grid of TV cards", %{conn: conn} do
    stub(Cinder.Catalog.TMDBMock, :discover_tv, fn 10_759, _ ->
      {:ok, [Map.put(@got, :type, :tv)]}
    end)

    {:ok, lv, _html} = live(conn, ~p"/")
    render_async(lv)

    lv |> element(~s(button[phx-click="genre_media_type"][phx-value-type="tv"])) |> render_click()
    # The TV genre chips now render (Action & Adventure = 10759 is TV-only).
    assert has_element?(lv, ~s(button[phx-value-id="10759"]))

    html = lv |> element(~s(button[phx-value-id="10759"])) |> render_click()

    assert html =~ "Game of Thrones"
    assert has_element?(lv, ~s(#genre-results a[href="/series/tmdb/1399"]))
    assert has_element?(lv, ~s(button[phx-value-id="10759"][aria-pressed="true"]))
  end

  # In TV mode a movie-only genre id (28 = Action, absent from the TV list) must not reach
  # Catalog.tv_by_genre/2 — no :discover_tv stub is set, so a Mox call would raise.
  test "a movie-only genre id is ignored while the genre browser is in TV mode", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/")
    render_async(lv)

    lv |> element(~s(button[phx-click="genre_media_type"][phx-value-type="tv"])) |> render_click()

    assert render_hook(lv, "select_genre", %{"id" => "28"}) =~ "search-form"
  end

  test "the old /series route redirects to /", %{conn: conn} do
    conn = get(conn, ~p"/series")
    assert redirected_to(conn) == ~p"/"
  end
end
