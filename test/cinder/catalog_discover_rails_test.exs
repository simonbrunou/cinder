defmodule Cinder.CatalogDiscoverRailsTest do
  use Cinder.DataCase, async: true

  import Mox

  alias Cinder.Catalog

  setup :verify_on_exit!

  @movie %{tmdb_id: 27_205, title: "Inception", year: 2010, poster_path: "/p.jpg", type: :movie}

  test "popular_movies/1 delegates to the TMDB behaviour" do
    expect(Cinder.Catalog.TMDBMock, :popular_movies, fn "en" -> {:ok, [@movie]} end)
    assert {:ok, [@movie]} == Catalog.popular_movies("en")
  end

  test "popular_movies/1 propagates a TMDB error" do
    expect(Cinder.Catalog.TMDBMock, :popular_movies, fn "en" -> {:error, :timeout} end)
    assert {:error, :timeout} = Catalog.popular_movies("en")
  end

  test "top_rated_movies/1 delegates to the TMDB behaviour" do
    expect(Cinder.Catalog.TMDBMock, :top_rated_movies, fn "en" -> {:ok, [@movie]} end)
    assert {:ok, [@movie]} == Catalog.top_rated_movies("en")
  end

  test "now_playing_movies/1 delegates to the TMDB behaviour" do
    expect(Cinder.Catalog.TMDBMock, :now_playing_movies, fn "en" -> {:ok, [@movie]} end)
    assert {:ok, [@movie]} == Catalog.now_playing_movies("en")
  end

  test "movies_by_genre/2 delegates the genre id to the TMDB behaviour" do
    expect(Cinder.Catalog.TMDBMock, :discover_movies, fn 28, "en" -> {:ok, [@movie]} end)
    assert {:ok, [@movie]} == Catalog.movies_by_genre(28, "en")
  end

  test "movies_by_genre/2 propagates a TMDB error" do
    expect(Cinder.Catalog.TMDBMock, :discover_movies, fn 28, "en" -> {:error, :nxdomain} end)
    assert {:error, :nxdomain} = Catalog.movies_by_genre(28, "en")
  end
end
