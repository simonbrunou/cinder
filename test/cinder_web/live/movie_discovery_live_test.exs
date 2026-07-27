defmodule CinderWeb.MovieDiscoveryLiveTest do
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox

  alias Cinder.Catalog
  alias Cinder.Requests

  # The LiveView runs in its own process, so the mock must be global (async: false).
  setup :set_mox_global

  # mount/3 fetches the movie, and a successful "add" fetches it a SECOND time to snapshot the
  # title (Requests.snapshot_request/1) — hence stub, not expect.
  setup do
    stub(Cinder.Catalog.TMDBMock, :get_movie, fn id ->
      {:ok,
       %{
         tmdb_id: id,
         imdb_id: nil,
         title: "Inception",
         year: 2010,
         poster_path: "/p.jpg",
         original_language: "en",
         overview: "A thief who steals corporate secrets.",
         runtime: 148,
         genres: ["Science Fiction", "Action"],
         vote_average: 8.4,
         release_date: ~D[2010-07-16]
       }}
    end)

    stub(Cinder.Catalog.TMDBMock, :get_movie_alternative_titles, fn _ -> {:ok, []} end)

    :ok
  end

  describe "rendering" do
    setup :register_and_log_in_user

    test "renders the movie's metadata", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/movie/tmdb/27205")

      assert html =~ "Inception"
      assert html =~ "2010"
      assert html =~ "A thief who steals corporate secrets."
      assert html =~ "Science Fiction"
      assert html =~ "148"
      assert html =~ "8.4"
    end

    test "renders a cast strip linking to person pages and a collection link", %{conn: conn} do
      stub(Cinder.Catalog.TMDBMock, :get_movie, fn id ->
        {:ok,
         %{
           tmdb_id: id,
           imdb_id: nil,
           title: "Inception",
           year: 2010,
           poster_path: "/p.jpg",
           original_language: "en",
           overview: "A thief.",
           runtime: 148,
           genres: ["Action"],
           vote_average: 8.4,
           release_date: ~D[2010-07-16],
           cast: [
             %{
               tmdb_id: 6193,
               name: "Leonardo DiCaprio",
               character: "Cobb",
               profile_path: "/l.jpg"
             }
           ],
           collection: %{tmdb_id: 8945, title: "The Inception Collection"}
         }}
      end)

      {:ok, lv, html} = live(conn, ~p"/movie/tmdb/27205")

      assert html =~ "Leonardo DiCaprio"
      assert html =~ "Cobb"
      assert has_element?(lv, ~s(a[href="/person/tmdb/6193"]))
      assert has_element?(lv, ~s(a[href="/collection/tmdb/8945"]), "Part of")
    end

    # The Mox stub in setup returns no :cast / :collection keys — the page must render without
    # them, not crash on a missing key.
    test "degrades gracefully when TMDB omits cast and collection", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/movie/tmdb/27205")

      refute html =~ "Top cast"
      refute html =~ "Part of"
    end

    test "a non-integer tmdb_id redirects to Discover instead of crashing", %{conn: conn} do
      assert {:error, {kind, %{to: "/"}}} = live(conn, ~p"/movie/tmdb/not-a-number")
      assert kind in [:redirect, :live_redirect]
    end

    test "a TMDB 404 says not found", %{conn: conn} do
      stub(Cinder.Catalog.TMDBMock, :get_movie, fn _ -> {:error, {:tmdb_status, 404}} end)

      assert {:error, {_kind, %{to: "/", flash: flash}}} = live(conn, ~p"/movie/tmdb/27205")
      assert flash["error"] =~ "not found"
    end

    # An outage must not claim the movie doesn't exist — that sends the user away from a page
    # that loads fine once TMDB is back.
    test "a TMDB outage says outage, not not-found", %{conn: conn} do
      stub(Cinder.Catalog.TMDBMock, :get_movie, fn _ -> {:error, :timeout} end)

      assert {:error, {_kind, %{to: "/", flash: flash}}} = live(conn, ~p"/movie/tmdb/27205")
      assert flash["error"] =~ "TMDB"
      refute flash["error"] =~ "not found"
    end
  end

  describe "requesting" do
    setup :register_and_log_in_user

    test "a non-admin add creates a pending request", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/movie/tmdb/27205")

      lv |> form("#add-form-27205") |> render_submit()
      render_async(lv)

      assert [%{target_type: "movie", target_id: 27_205, status: :pending}] =
               Requests.list_for_user(user)
    end

    test "an existing request replaces the add form with a badge", %{conn: conn, user: user} do
      {:ok, _} =
        Requests.create_request(user, %{
          target_type: "movie",
          target_id: 27_205,
          year: 2010,
          poster_path: "/p.jpg"
        })

      {:ok, lv, _html} = live(conn, ~p"/movie/tmdb/27205")

      refute has_element?(lv, "#add-form-27205")
      assert has_element?(lv, ".badge", "Pending")
    end

    # phx-value is client-controlled: a forged id for a DIFFERENT movie must not request the
    # movie this page is showing.
    test "an add for another tmdb_id is ignored", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/movie/tmdb/27205")

      render_hook(lv, "add", %{"tmdb_id" => "99999"})
      render_async(lv)

      assert Requests.list_for_user(user) == []
    end
  end

  describe "media server link" do
    setup :register_and_log_in_admin

    defp make_available(tmdb_id) do
      {:ok, movie} =
        Catalog.add_movie(%{tmdb_id: tmdb_id, title: "Inception", year: 2010, status: :requested})

      {:ok, movie} = Catalog.transition(movie, %{status: :available})
      movie
    end

    test "is hidden when no media-server web URL is configured", %{conn: conn} do
      make_available(27_205)

      {:ok, lv, _html} = live(conn, ~p"/movie/tmdb/27205")

      assert has_element?(lv, ".badge", "Available")
      refute has_element?(lv, "a", "Open in Plex")
    end

    test "is shown for an available movie once a web URL is configured", %{conn: conn} do
      put_media_server_web_url("https://plex.example.com")
      make_available(27_205)

      {:ok, lv, html} = live(conn, ~p"/movie/tmdb/27205")

      assert has_element?(lv, ~s(a[href="https://plex.example.com"]), "Open in Plex")
      # It leaves the app, so say so for anyone who can't see the new tab open.
      assert html =~ "opens in a new tab"
      assert html =~ ~s(rel="noopener")
    end

    # A movie nobody has yet is not watchable, however the media server is configured.
    test "is hidden for a movie that is not in the library", %{conn: conn} do
      put_media_server_web_url("https://plex.example.com")

      {:ok, lv, _html} = live(conn, ~p"/movie/tmdb/27205")

      refute has_element?(lv, "a", "Open in Plex")
    end

    # An admin switching media server must not leave an open page pointing at the old one.
    # Note there is deliberately NO movie or request event here: the settings write alone has
    # to reach the page, which is what the Settings PubSub topic is for.
    test "an open page stops linking at the old server after a type switch", %{conn: conn} do
      put_media_server_web_url("https://plex.example.com")
      make_available(27_205)

      {:ok, lv, _html} = live(conn, ~p"/movie/tmdb/27205")
      assert has_element?(lv, ~s(a[href="https://plex.example.com"]), "Open in Plex")

      # The admin switches to Jellyfin, which has no web URL configured.
      previous_impl = Application.get_env(:cinder, :media_server)
      on_exit(fn -> Application.put_env(:cinder, :media_server, previous_impl) end)
      Cinder.Settings.put("media_server_type", "jellyfin")

      refute render(lv) =~ "Open in Plex"
    end

    # The whole point of the page being live: someone opens it while the movie is still
    # downloading, and the badge plus the link appear without a reload.
    test "the badge and the link appear live when the movie becomes available", %{conn: conn} do
      put_media_server_web_url("https://plex.example.com")

      {:ok, movie} =
        Catalog.add_movie(%{
          tmdb_id: 27_205,
          title: "Inception",
          year: 2010,
          status: :requested
        })

      {:ok, lv, _html} = live(conn, ~p"/movie/tmdb/27205")
      refute has_element?(lv, "a", "Open in Plex")

      {:ok, _} = Catalog.transition(movie, %{status: :available})

      assert render_async(lv) =~ "Open in Plex"
      assert has_element?(lv, ~s(a[href="https://plex.example.com"]), "Open in Plex")
    end

    # The type row is written directly rather than via Settings.put/2: put triggers
    # load_into_env/0, which would flip the global :media_server impl away from the Mox mock
    # for the rest of the run. media_server_web_link/0 reads the row, not the impl.
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
end
