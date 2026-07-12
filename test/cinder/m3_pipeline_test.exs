defmodule Cinder.M3PipelineTest do
  # The M3 done-when: a non-admin request → admin approval → :available, attributed
  # to the requester, with a notifier event emitted.
  use Cinder.DataCase, async: false

  import Mox
  import Cinder.AccountsFixtures

  alias Cinder.{Catalog, Requests}
  alias Cinder.Catalog.Movie
  alias Cinder.Download.Poller
  alias Cinder.Repo
  alias Cinder.Requests.Request

  @moduletag :capture_log
  setup :set_mox_global

  @attrs %{
    target_type: "movie",
    target_id: 3,
    title: "Inception",
    year: 2010,
    poster_path: "/i.jpg"
  }

  test "non-admin request → admin approval → :available, attributed, with a notifier event" do
    Cinder.TestNotifier.subscribe()
    user = user_fixture()
    admin = admin_fixture()

    # Gate: a non-admin request creates no movie row.
    {:ok, req} = Requests.create_request(user, @attrs)
    assert req.status == :pending
    assert Repo.aggregate(Movie, :count) == 0

    # The approved movie carries no imdb_id, so the search pass resolves it via TMDB.
    stub(Cinder.Catalog.TMDBMock, :get_movie, fn 3 -> {:ok, %{imdb_id: "tt1375666"}} end)

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

    stub(Cinder.Download.ClientMock, :add, fn _, _opts -> {:ok, "hash-3"} end)

    stub(Cinder.Download.ClientMock, :status, fn "hash-3" ->
      {:ok, %{state: :completed, content_path: "/downloads/Inception.mkv"}}
    end)

    stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)
    stub(Cinder.Library.FilesystemMock, :lstat, fn _ -> {:ok, %File.Stat{size: 1, inode: 1}} end)
    stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    stub(Cinder.Library.FilesystemMock, :ln, fn _src, _dest -> :ok end)
    stub(Cinder.Library.MediaServerMock, :scan, fn _kind -> :ok end)

    # Admin approval creates the movie at :requested.
    {:ok, approved} = Requests.approve_request(req, admin)
    assert approved.status == :approved
    assert [%Movie{status: :requested, tmdb_id: 3}] = Catalog.list_by_status(:requested)

    start_supervised!({Poller, interval: 60_000, search_retry_after: 0})

    # search runs last in a tick: poll 1 → :downloading, poll 2 → :downloaded → :available
    assert :ok = Poller.poll()
    assert :ok = Poller.poll()

    assert %Movie{status: :available} = Repo.get_by!(Movie, tmdb_id: 3)
    assert_receive {:notify, {:movie_available, %Movie{tmdb_id: 3}}}

    # Attribution: the request still points at the requester.
    reloaded = Repo.get!(Request, req.id)
    assert reloaded.status == :approved
    assert reloaded.user_id == user.id
  end
end
