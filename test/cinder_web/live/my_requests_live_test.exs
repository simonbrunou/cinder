defmodule CinderWeb.MyRequestsLiveTest do
  use CinderWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest

  alias Cinder.Requests

  setup do
    stub(Cinder.Catalog.TMDBMock, :get_movie, fn _ -> {:error, :unavailable} end)
    stub(Cinder.Catalog.TMDBMock, :get_series, fn _ -> {:error, :unavailable} end)
    :ok
  end

  test "shows the current user's requests with status, not other users'", %{conn: conn} do
    user = Cinder.AccountsFixtures.user_fixture()
    other = Cinder.AccountsFixtures.user_fixture()

    {:ok, _} =
      Requests.create_request(user, %{
        target_type: "movie",
        target_id: 1,
        title: "Mine",
        year: 2001,
        poster_path: "/a.jpg"
      })

    {:ok, _} =
      Requests.create_request(other, %{
        target_type: "movie",
        target_id: 2,
        title: "Theirs",
        year: 2002,
        poster_path: "/b.jpg"
      })

    conn = log_in_user(conn, user)
    {:ok, lv, _html} = live(conn, ~p"/my-requests")

    assert has_element?(lv, "#my-requests", "Mine")
    refute has_element?(lv, "#my-requests", "Theirs")
    assert render(lv) =~ "Pending"
  end

  test "renders request and matching movie download progress", %{conn: conn} do
    user = Cinder.AccountsFixtures.user_fixture()
    tmdb_id = System.unique_integer([:positive])

    {:ok, _} =
      Requests.create_request(user, %{
        target_type: "movie",
        target_id: tmdb_id,
        title: "Progress",
        year: 2001
      })

    {:ok, movie} = Cinder.Catalog.add_movie(%{tmdb_id: tmdb_id, title: "Progress", year: 2001})
    {:ok, movie} = Cinder.Catalog.transition(movie, %{status: :downloading})

    {:ok, _} =
      Cinder.Catalog.update_movie_download_metrics(movie, %{
        download_progress: 0.42,
        download_speed: 1_500_000,
        download_eta: 90
      })

    conn = log_in_user(conn, user)
    {:ok, lv, _html} = live(conn, ~p"/my-requests")

    assert render(lv) =~ "Pending"
    assert render(lv) =~ "42%"
  end

  test "a season request shows the show title and season number", %{conn: conn} do
    user = Cinder.AccountsFixtures.user_fixture()

    {:ok, _} =
      Requests.create_request(user, %{
        target_type: "season",
        target_id: 1399,
        season_number: 3,
        title: "GoT",
        year: 2011
      })

    conn = log_in_user(conn, user)
    {:ok, _lv, html} = live(conn, ~p"/my-requests")
    assert html =~ "GoT"
    assert html =~ "Season 3"
  end

  test "season request row does not show movie pipeline badge even when a movie shares the same tmdb_id",
       %{conn: conn} do
    user = Cinder.AccountsFixtures.user_fixture()

    # season request with target_id 777
    {:ok, _} =
      Requests.create_request(user, %{
        target_type: "season",
        target_id: 777,
        season_number: 2,
        title: "Collision Show",
        year: 2020
      })

    # movie whose tmdb_id numerically matches the series tmdb_id
    {:ok, movie} =
      Cinder.Catalog.add_movie(%{
        tmdb_id: 777,
        title: "Collision Movie",
        year: 2019,
        poster_path: "/col.jpg"
      })

    {:ok, _} = Cinder.Catalog.transition(movie, %{status: :downloading})

    conn = log_in_user(conn, user)
    {:ok, _lv, html} = live(conn, ~p"/my-requests")

    # season row renders correctly
    assert html =~ "Collision Show"
    assert html =~ "Season 2"
    assert html =~ "Pending"

    # movie pipeline badge must NOT appear on the season row
    refute html =~ "Downloading"
  end

  test "live-updates when the user's request is approved", %{conn: conn} do
    user = Cinder.AccountsFixtures.user_fixture()
    admin = Cinder.AccountsFixtures.admin_fixture()

    {:ok, req} =
      Requests.create_request(user, %{
        target_type: "movie",
        target_id: 3,
        title: "Live",
        year: 2003,
        poster_path: "/c.jpg"
      })

    conn = log_in_user(conn, user)
    {:ok, lv, _html} = live(conn, ~p"/my-requests")

    stub(Cinder.Catalog.TMDBMock, :get_movie, fn id ->
      {:ok,
       %{
         tmdb_id: id,
         imdb_id: nil,
         title: "Live",
         year: 2003,
         poster_path: "/c.jpg",
         original_language: "en"
       }}
    end)

    stub(Cinder.Catalog.TMDBMock, :get_movie_alternative_titles, fn _ -> {:ok, []} end)

    {:ok, _} = Requests.approve_request(req, admin, :standard)
    assert render(lv) =~ "Approved"
  end

  test "survives a {:movie_deleted, id} broadcast (reloads, no crash)", %{conn: conn} do
    user = Cinder.AccountsFixtures.user_fixture()
    conn = log_in_user(conn, user)
    {:ok, movie} = Cinder.Catalog.add_movie(%{tmdb_id: 9600, title: "Vanish"})

    {:ok, lv, _html} = live(conn, ~p"/my-requests")
    Cinder.Catalog.broadcast_movie_deleted(movie.id)
    # still alive after reload
    assert render(lv)
  end

  test "shows a plain-English hint for a parked movie", %{conn: conn} do
    user = Cinder.AccountsFixtures.user_fixture()
    tmdb_id = System.unique_integer([:positive])

    {:ok, _} =
      Requests.create_request(user, %{
        target_type: "movie",
        target_id: tmdb_id,
        title: "Solaris",
        year: 1972
      })

    {:ok, movie} = Cinder.Catalog.add_movie(%{tmdb_id: tmdb_id, title: "Solaris", year: 1972})
    {:ok, _movie} = Cinder.Catalog.transition(movie, %{status: :no_match})

    conn = log_in_user(conn, user)
    {:ok, _lv, html} = live(conn, ~p"/my-requests")

    assert html =~ "No release matched"
  end

  test "a requester can cancel their own pending request", %{conn: conn} do
    user = Cinder.AccountsFixtures.user_fixture()

    {:ok, req} =
      Requests.create_request(user, %{target_type: "movie", target_id: 42, title: "Cancel me"})

    conn = log_in_user(conn, user)
    {:ok, lv, _html} = live(conn, ~p"/my-requests")

    lv |> element("#cancel-request-#{req.id}") |> render_click()
    lv |> element("#confirm-cancel-request-#{req.id} button", "Cancel request") |> render_click()

    refute has_element?(lv, "#request-#{req.id}")
    assert Cinder.Repo.get(Cinder.Requests.Request, req.id) == nil
  end

  test "a denied request offers Request again, which re-submits through the gate", %{conn: conn} do
    user = Cinder.AccountsFixtures.user_fixture()
    admin = Cinder.AccountsFixtures.admin_fixture()

    {:ok, req} =
      Requests.create_request(user, %{target_type: "movie", target_id: 77, title: "Try again"})

    {:ok, _} = Requests.deny_request(req, admin, "not now")

    conn = log_in_user(conn, user)
    {:ok, lv, _html} = live(conn, ~p"/my-requests")

    assert has_element?(lv, "#request-again-#{req.id}")

    lv |> element("#request-again-#{req.id}") |> render_click()
    render_async(lv)

    # The denied row stays (its partial index slot is free), and a fresh pending request for the
    # same target now exists — the quota + approval gate ran, not a status flip.
    requests = Requests.list_for_user(user)
    assert Enum.any?(requests, &(&1.status == :pending and &1.target_id == 77))
    assert Enum.any?(requests, &(&1.id == req.id and &1.status == :denied))
  end

  test "a pending request offers no Request again action", %{conn: conn} do
    user = Cinder.AccountsFixtures.user_fixture()

    {:ok, req} =
      Requests.create_request(user, %{target_type: "movie", target_id: 88, title: "Pending"})

    conn = log_in_user(conn, user)
    {:ok, lv, _html} = live(conn, ~p"/my-requests")

    refute has_element?(lv, "#request-again-#{req.id}")
  end

  test "every request row shows a relative requested-time line", %{conn: conn} do
    user = Cinder.AccountsFixtures.user_fixture()

    {:ok, _} =
      Requests.create_request(user, %{target_type: "movie", target_id: 55, title: "Freshly"})

    conn = log_in_user(conn, user)
    {:ok, _lv, html} = live(conn, ~p"/my-requests")

    # Just created, so the coarse bucket reads "just now".
    assert html =~ "Requested just now"
  end

  describe "season pipeline progress" do
    test "shows episode progress and a downloading badge while a season is still filling",
         %{conn: conn} do
      user = Cinder.AccountsFixtures.user_fixture()

      series = Cinder.CatalogFixtures.series_fixture(%{title: "Prog Show"})
      season = Cinder.CatalogFixtures.season_fixture(series, %{season_number: 2})

      Cinder.CatalogFixtures.episode_fixture(season, %{
        episode_number: 1,
        file_path: "/lib/Prog Show/Season 02/s02e01.mkv"
      })

      downloading = Cinder.CatalogFixtures.episode_fixture(season, %{episode_number: 2})
      Cinder.CatalogFixtures.episode_fixture(season, %{episode_number: 3})

      # An active grab on episode 2 → the season reads as downloading.
      {:ok, _grab} = Cinder.Catalog.create_grab("season-dl", :torrent, [downloading.id])

      {:ok, req} =
        Requests.create_request(user, %{
          target_type: "season",
          target_id: series.tmdb_id,
          season_number: 2,
          title: "Prog Show",
          year: 2008
        })

      conn = log_in_user(conn, user)
      {:ok, lv, _html} = live(conn, ~p"/my-requests")

      assert has_element?(
               lv,
               "#request-#{req.id}-season-progress",
               "1 of 3 episodes available"
             )

      assert has_element?(lv, "#request-#{req.id} .badge", "Downloading")
    end

    test "no progress line for a season with no episodes yet (still pending approval)",
         %{conn: conn} do
      user = Cinder.AccountsFixtures.user_fixture()

      {:ok, req} =
        Requests.create_request(user, %{
          target_type: "season",
          target_id: 4242,
          season_number: 1,
          title: "Not Yet",
          year: 2024
        })

      conn = log_in_user(conn, user)
      {:ok, lv, _html} = live(conn, ~p"/my-requests")

      refute has_element?(lv, "#request-#{req.id}-season-progress")
    end
  end

  describe "Open in media server on an available row" do
    test "an available movie row links to the media server", %{conn: conn} do
      put_media_server_web_url("https://plex.example.com")
      user = Cinder.AccountsFixtures.user_fixture()
      tmdb_id = System.unique_integer([:positive])

      {:ok, _} =
        Requests.create_request(user, %{
          target_type: "movie",
          target_id: tmdb_id,
          title: "Watchable",
          year: 2020
        })

      {:ok, movie} = Cinder.Catalog.add_movie(%{tmdb_id: tmdb_id, title: "Watchable", year: 2020})
      {:ok, _} = Cinder.Catalog.transition(movie, %{status: :available})

      conn = log_in_user(conn, user)
      {:ok, lv, html} = live(conn, ~p"/my-requests")

      assert has_element?(lv, ~s(a[href="https://plex.example.com"]), "Open in Plex")
      assert html =~ "opens in a new tab"
      assert html =~ ~s(rel="noopener")
    end

    test "an available season row links to the media server", %{conn: conn} do
      put_media_server_web_url("https://plex.example.com")
      user = Cinder.AccountsFixtures.user_fixture()

      series = Cinder.CatalogFixtures.series_fixture(%{title: "Done Show"})
      season = Cinder.CatalogFixtures.season_fixture(series, %{season_number: 1})

      Cinder.CatalogFixtures.episode_fixture(season, %{
        episode_number: 1,
        file_path: "/lib/Done Show/Season 01/s01e01.mkv"
      })

      {:ok, _} =
        Requests.create_request(user, %{
          target_type: "season",
          target_id: series.tmdb_id,
          season_number: 1,
          title: "Done Show",
          year: 2008
        })

      conn = log_in_user(conn, user)
      {:ok, lv, _html} = live(conn, ~p"/my-requests")

      assert has_element?(lv, ".badge", "Available")
      assert has_element?(lv, ~s(a[href="https://plex.example.com"]), "Open in Plex")
    end

    test "no media-server link when no web URL is configured", %{conn: conn} do
      user = Cinder.AccountsFixtures.user_fixture()
      tmdb_id = System.unique_integer([:positive])

      {:ok, _} =
        Requests.create_request(user, %{target_type: "movie", target_id: tmdb_id, title: "NoLink"})

      {:ok, movie} = Cinder.Catalog.add_movie(%{tmdb_id: tmdb_id, title: "NoLink"})
      {:ok, _} = Cinder.Catalog.transition(movie, %{status: :available})

      conn = log_in_user(conn, user)
      {:ok, lv, _html} = live(conn, ~p"/my-requests")

      refute has_element?(lv, "a", "Open in")
    end
  end

  # Mirrors movie_discovery_live_test: writes the media_server_type row directly (Settings.put/2
  # would run load_into_env/0 and flip the global :media_server impl off the Mox mock for the
  # rest of the run). media_server_web_link/0 reads the row plus the impl's :web_url.
  defp put_media_server_web_url(url) do
    module = Cinder.Library.MediaServer.Plex
    previous = Application.get_env(:cinder, module, [])
    on_exit(fn -> Application.put_env(:cinder, module, previous) end)

    Cinder.Repo.insert!(%Cinder.Settings.Setting{
      key: "media_server_type",
      value: "plex",
      is_secret: false
    })

    Application.put_env(:cinder, module, Keyword.put(previous, :web_url, url))
  end
end
