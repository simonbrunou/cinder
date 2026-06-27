defmodule Cinder.DownloadTest do
  use Cinder.DataCase, async: true

  import Mox

  alias Cinder.Catalog.Movie
  alias Cinder.Download
  alias Cinder.Repo

  import Cinder.CatalogFixtures

  setup :verify_on_exit!

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
    movie = movie_fixture(%{imdb_id: "tt1375666"})

    expect(Cinder.Acquisition.IndexerMock, :search, fn "tt1375666" ->
      {:ok, [survivable_result()]}
    end)

    # The mock receives the chosen %Cinder.Acquisition.Release{}; we don't assert its internals here.
    expect(Cinder.Download.ClientMock, :add, fn _release -> {:ok, "hash-1"} end)

    assert {:ok, %Movie{status: :downloading, download_id: "hash-1", download_protocol: :torrent}} =
             Download.start(movie)

    assert %Movie{status: :downloading, download_id: "hash-1", download_protocol: :torrent} =
             Repo.get!(Movie, movie.id)
  end

  test "client_for/1 resolves the configured client per protocol (nil -> :torrent)" do
    assert {:ok, Cinder.Download.ClientMock} = Download.client_for(:torrent)
    assert {:ok, Cinder.Download.SabnzbdClientMock} = Download.client_for(:usenet)
    assert {:ok, Cinder.Download.ClientMock} = Download.client_for(nil)
    assert :error = Download.client_for(:carrier_pigeon)
  end

  test "available_protocols/0 lists the configured protocols" do
    assert Enum.sort(Download.available_protocols()) == [:torrent, :usenet]
  end

  test "routes a usenet release to the usenet client and persists the protocol" do
    movie = movie_fixture(%{imdb_id: "tt1375666"})

    expect(Cinder.Acquisition.IndexerMock, :search, fn "tt1375666" ->
      {:ok,
       [
         %{
           title: "Inception.2010.1080p.WEB-DL-GRP",
           size: 9_000_000_000,
           download_url: "http://prowlarr/getnzb/1",
           seeders: nil,
           protocol: :usenet
         }
       ]}
    end)

    # Only the usenet client may be called; ClientMock has no expectation, so
    # verify_on_exit! fails the test if a usenet release is misrouted to it.
    expect(Cinder.Download.SabnzbdClientMock, :add, fn release ->
      assert release.protocol == :usenet
      {:ok, "SABnzbd_nzo_1"}
    end)

    assert {:ok,
            %Movie{
              status: :downloading,
              download_id: "SABnzbd_nzo_1",
              download_protocol: :usenet
            }} = Download.start(movie)

    assert %Movie{download_protocol: :usenet} = Repo.get!(Movie, movie.id)
  end

  test "lazily resolves a missing imdb_id from TMDB and persists it" do
    movie = movie_fixture(%{imdb_id: nil})
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
    movie = movie_fixture(%{imdb_id: "tt1375666"})
    expect(Cinder.Acquisition.IndexerMock, :search, fn _ -> {:ok, []} end)

    assert {:ok, %Movie{status: :no_match}} = Download.start(movie)
  end

  test "returns {:error, :no_imdb_id} and leaves the movie :requested when imdb is genuinely missing" do
    movie = movie_fixture(%{imdb_id: nil})
    expect(Cinder.Catalog.TMDBMock, :get_movie, fn _ -> {:ok, %{imdb_id: nil}} end)

    assert {:error, :no_imdb_id} = Download.start(movie)
    assert %Movie{status: :requested} = Repo.get!(Movie, movie.id)
  end

  test "returns {:error, :tmdb_unavailable} on a transient TMDB error, movie stays :requested" do
    movie = movie_fixture(%{imdb_id: nil})
    expect(Cinder.Catalog.TMDBMock, :get_movie, fn _ -> {:error, {:tmdb_status, 503}} end)

    assert {:error, :tmdb_unavailable} = Download.start(movie)
    assert %Movie{status: :requested} = Repo.get!(Movie, movie.id)
  end

  test "returns the client error and leaves the movie :searching on add failure" do
    movie = movie_fixture(%{imdb_id: "tt1375666"})
    expect(Cinder.Acquisition.IndexerMock, :search, fn _ -> {:ok, [survivable_result()]} end)
    expect(Cinder.Download.ClientMock, :add, fn _ -> {:error, :qbittorrent_down} end)

    assert {:error, :qbittorrent_down} = Download.start(movie)
    assert %Movie{status: :searching} = Repo.get!(Movie, movie.id)
  end
end
