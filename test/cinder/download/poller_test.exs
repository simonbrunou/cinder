defmodule Cinder.Download.PollerTest do
  use Cinder.DataCase, async: false

  import Mox

  alias Cinder.{Catalog, Download}
  alias Cinder.Catalog.Movie
  alias Cinder.Download.Poller
  alias Cinder.Repo

  # The poller runs in its own process (and a fresh pid after a crash), so the
  # mock must be global. Shared Sandbox (async: false) lets those processes use
  # the test-owned DB connection.
  setup :set_mox_global

  defp downloading_movie(tmdb_id, download_id) do
    {:ok, movie} = Catalog.add_to_watchlist(%{tmdb_id: tmdb_id, title: "M"})
    {:ok, movie} = Catalog.transition(movie, %{status: :downloading, download_id: download_id})
    movie
  end

  defp await_restart(name, old_pid) do
    case GenServer.whereis(name) do
      new_pid when is_pid(new_pid) and new_pid != old_pid ->
        new_pid

      _ ->
        Process.sleep(10)
        await_restart(name, old_pid)
    end
  end

  test "a poll advances a :downloading movie to :downloaded and broadcasts" do
    movie = downloading_movie(1, "hash-1")
    Catalog.subscribe()
    start_supervised!({Poller, interval: 60_000})

    stub(Cinder.Download.ClientMock, :status, fn "hash-1" -> {:ok, %{state: :completed}} end)

    assert :ok = Poller.poll()

    assert %Movie{status: :downloaded} = Repo.get!(Movie, movie.id)
    assert_receive {:movie_updated, %Movie{status: :downloaded}}
  end

  test "a non-completed status leaves the movie :downloading" do
    movie = downloading_movie(2, "hash-2")
    start_supervised!({Poller, interval: 60_000})

    stub(Cinder.Download.ClientMock, :status, fn "hash-2" -> {:ok, %{state: :downloading}} end)

    assert :ok = Poller.poll()
    assert %Movie{status: :downloading} = Repo.get!(Movie, movie.id)
  end

  test "drives a movie through the full state machine: requested -> downloaded" do
    {:ok, movie} =
      Catalog.add_to_watchlist(%{tmdb_id: 3, title: "Inception", imdb_id: "tt1375666"})

    assert movie.status == :requested
    hash = "deadbeef"

    stub(Cinder.Acquisition.IndexerMock, :search, fn "tt1375666" ->
      {:ok,
       [
         %{
           title: "Inception.2010.1080p.BluRay.x264-GRP",
           size: 8_000_000_000,
           download_url: "magnet:?x",
           seeders: 10
         }
       ]}
    end)

    stub(Cinder.Download.ClientMock, :add, fn _release -> {:ok, hash} end)
    stub(Cinder.Download.ClientMock, :status, fn ^hash -> {:ok, %{state: :completed}} end)

    start_supervised!({Poller, interval: 60_000})

    assert {:ok, %Movie{status: :downloading, download_id: ^hash}} = Download.start(movie)
    assert :ok = Poller.poll()
    assert %Movie{status: :downloaded} = Repo.get!(Movie, movie.id)
  end

  test "the poller recovers from a crash and still advances work (OTP payoff)" do
    movie = downloading_movie(4, "hash-4")
    pid = start_supervised!({Poller, interval: 60_000})

    stub(Cinder.Download.ClientMock, :status, fn "hash-4" -> {:ok, %{state: :completed}} end)

    Process.exit(pid, :kill)
    new_pid = await_restart(Poller, pid)
    assert new_pid != pid

    assert :ok = Poller.poll(new_pid)
    assert %Movie{status: :downloaded} = Repo.get!(Movie, movie.id)
  end
end
