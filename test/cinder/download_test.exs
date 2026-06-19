defmodule Cinder.DownloadTest do
  use Cinder.DataCase, async: true

  import Mox

  alias Cinder.{Catalog, Download}
  alias Cinder.Catalog.Movie
  alias Cinder.Repo

  setup :verify_on_exit!

  defp requested(attrs) do
    {:ok, movie} =
      Catalog.add_to_watchlist(
        Map.merge(%{tmdb_id: System.unique_integer([:positive]), title: "Inception"}, attrs)
      )

    movie
  end

  # A raw indexer result that survives the default scorer (1080p, no size band configured).
  defp survivable_result do
    %{
      title: "Inception.2010.1080p.BluRay.x264-GRP",
      size: 8_000_000_000,
      download_url: "magnet:?xt=urn:btih:abc",
      seeders: 10
    }
  end

  test "hands a requested movie off and advances it to :downloading" do
    movie = requested(%{imdb_id: "tt1375666"})

    expect(Cinder.Acquisition.IndexerMock, :search, fn "tt1375666" ->
      {:ok, [survivable_result()]}
    end)

    # The mock receives the chosen %Cinder.Acquisition.Release{}; we don't assert its internals here.
    expect(Cinder.Download.ClientMock, :add, fn _release -> {:ok, "hash-1"} end)

    assert {:ok, %Movie{status: :downloading, download_id: "hash-1"}} = Download.start(movie)
    assert %Movie{status: :downloading, download_id: "hash-1"} = Repo.get!(Movie, movie.id)
  end

  test "lazily resolves a missing imdb_id from TMDB and persists it" do
    movie = requested(%{imdb_id: nil})
    refute movie.imdb_id

    expect(Cinder.Catalog.TMDBMock, :get_movie, fn tmdb_id ->
      assert tmdb_id == movie.tmdb_id
      {:ok, %{tmdb_id: movie.tmdb_id, imdb_id: "tt1375666"}}
    end)

    expect(Cinder.Acquisition.IndexerMock, :search, fn "tt1375666" ->
      {:ok, [survivable_result()]}
    end)

    expect(Cinder.Download.ClientMock, :add, fn _ -> {:ok, "hash-2"} end)

    assert {:ok, %Movie{status: :downloading, imdb_id: "tt1375666"}} = Download.start(movie)
  end

  test "parks the movie at :no_match when no release survives scoring" do
    movie = requested(%{imdb_id: "tt1375666"})
    expect(Cinder.Acquisition.IndexerMock, :search, fn _ -> {:ok, []} end)

    assert {:ok, %Movie{status: :no_match}} = Download.start(movie)
  end

  test "parks the movie at :no_match when the imdb_id can't be resolved" do
    movie = requested(%{imdb_id: nil})
    expect(Cinder.Catalog.TMDBMock, :get_movie, fn _ -> {:ok, %{imdb_id: nil}} end)

    assert {:ok, %Movie{status: :no_match}} = Download.start(movie)
  end

  test "returns the client error and leaves the movie :searching on add failure" do
    movie = requested(%{imdb_id: "tt1375666"})
    expect(Cinder.Acquisition.IndexerMock, :search, fn _ -> {:ok, [survivable_result()]} end)
    expect(Cinder.Download.ClientMock, :add, fn _ -> {:error, :qbittorrent_down} end)

    assert {:error, :qbittorrent_down} = Download.start(movie)
    assert %Movie{status: :searching} = Repo.get!(Movie, movie.id)
  end
end
