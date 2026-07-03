defmodule CinderWeb.MovieDetailLiveTest do
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox
  import Cinder.CatalogFixtures

  alias Cinder.Catalog

  @moduletag :capture_log

  setup :register_and_log_in_admin
  # Global: the enrich backfill runs in a start_async task (separate process).
  setup :set_mox_global

  defp stub_details(tmdb_id) do
    stub(Cinder.Catalog.TMDBMock, :get_movie, fn ^tmdb_id ->
      {:ok,
       %{
         tmdb_id: tmdb_id,
         title: "Inception",
         year: 2010,
         poster_path: "/p.jpg",
         imdb_id: "tt1375666",
         original_language: "en",
         overview: "A thief who steals corporate secrets through dream-sharing.",
         runtime: 148,
         genres: ["Action", "Science Fiction"],
         vote_average: 8.4,
         release_date: ~D[2010-07-16]
       }}
    end)
  end

  test "lazily backfills and renders descriptive metadata", %{conn: conn} do
    movie = movie_fixture(%{title: "Inception"})
    stub_details(movie.tmdb_id)

    {:ok, lv, _html} = live(conn, ~p"/movies/#{movie.id}")
    html = render_async(lv)

    assert html =~ "A thief who steals corporate secrets"
    assert html =~ "Action"
    assert html =~ "Science Fiction"
    assert html =~ "148 min"
    assert html =~ "8.4"
  end

  test "renders the downloaded-file panel from the imported_* fields", %{conn: conn} do
    movie =
      movie_fixture(%{
        title: "Inception",
        status: :available,
        file_path: "/library/Inception (2010)/Inception (2010).mkv",
        imported_resolution: "1080p",
        # 2 GiB → "2.0 GB"
        imported_size: 2_147_483_648,
        imported_source: "BluRay",
        imported_language: "en",
        release_title: "Inception.2010.1080p.BluRay.x264-GRP"
      })

    stub_details(movie.tmdb_id)

    {:ok, lv, _html} = live(conn, ~p"/movies/#{movie.id}")
    html = render_async(lv)

    assert html =~ "Downloaded file"
    assert html =~ "1080p"
    assert html =~ "2.0 GB"
    assert html =~ "BluRay"
    assert html =~ "Inception.2010.1080p.BluRay.x264-GRP"
  end

  test "a non-integer id redirects to the library instead of crashing", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/library"}}} = live(conn, ~p"/movies/not-an-id")
  end

  test "a stale {:movie_updated} broadcast doesn't blank the metadata (re-reads fresh)", %{
    conn: conn
  } do
    # `movie` is captured pre-enrichment (vote_average/overview nil) — the same stale snapshot an
    # unguarded transition/2 echoes on its broadcast.
    movie = movie_fixture(%{title: "Inception"})
    stub_details(movie.tmdb_id)

    {:ok, lv, _html} = live(conn, ~p"/movies/#{movie.id}")
    assert render_async(lv) =~ "A thief who steals corporate secrets"

    # Unguarded transition on the stale struct broadcasts {:movie_updated, stale} (nil metadata).
    {:ok, _} = Catalog.transition(movie, %{status: :downloading})
    html = render(lv)

    assert html =~ "A thief who steals corporate secrets",
           "metadata must survive a stale broadcast"

    assert html =~ "Downloading"
  end

  test "a movie whose TMDB runtime is 0 hides the runtime chip", %{conn: conn} do
    movie = movie_fixture(%{title: "Obscure"})

    stub(Cinder.Catalog.TMDBMock, :get_movie, fn tmdb_id ->
      {:ok,
       %{
         tmdb_id: tmdb_id,
         title: "Obscure",
         year: 2010,
         poster_path: nil,
         imdb_id: nil,
         original_language: "en",
         overview: "No runtime on file.",
         runtime: 0,
         genres: [],
         vote_average: 6.0,
         release_date: ~D[2010-01-01]
       }}
    end)

    {:ok, lv, _html} = live(conn, ~p"/movies/#{movie.id}")
    html = render_async(lv)

    refute html =~ "0 min"
  end
end
