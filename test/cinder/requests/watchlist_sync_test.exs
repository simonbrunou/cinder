defmodule Cinder.Requests.WatchlistSyncTest do
  # async: false — the sweep runs in its own GenServer, so it needs Mox in global mode
  # (set_mox_from_context) and the shared DataCase sandbox to see this test's setup.
  use Cinder.DataCase, async: false

  import Mox
  import Cinder.AccountsFixtures

  alias Cinder.Accounts
  alias Cinder.Accounts.PlexAuthMock
  alias Cinder.Catalog.Movie
  alias Cinder.Requests
  alias Cinder.Requests.Request
  alias Cinder.Requests.SyncedWatchlistEntry
  alias Cinder.Requests.WatchlistSync

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    on_exit(fn -> :persistent_term.erase({WatchlistSync, :last_run}) end)

    stub(Cinder.Catalog.TMDBMock, :get_movie, fn id ->
      {:ok,
       %{
         tmdb_id: id,
         imdb_id: nil,
         title: "Movie #{id}",
         year: 1999,
         poster_path: "/p.jpg",
         original_language: "en"
       }}
    end)

    stub(Cinder.Catalog.TMDBMock, :get_movie_alternative_titles, fn _id -> {:ok, []} end)
    :ok
  end

  defp opted_in_user(user) do
    {:ok, user} = Accounts.store_plex_token(user, "plex-token-#{user.id}")
    {:ok, user} = Accounts.update_user_plex_watchlist_sync(user, %{plex_watchlist_sync: true})
    user
  end

  defp entry(tmdb_id, opts \\ []) do
    %{
      tmdb_id: tmdb_id,
      type: Keyword.get(opts, :type, "movie"),
      title: Keyword.get(opts, :title, "Movie #{tmdb_id}"),
      year: Keyword.get(opts, :year, 1999)
    }
  end

  # One supervised sweeper per test, reused across ticks: a second start_supervised would
  # collide on the child spec id, and the tests that poll twice are exactly the dedupe cases.
  defp sync! do
    pid =
      case Process.whereis(:watchlist_sync_test) do
        nil -> start_supervised!({WatchlistSync, name: :watchlist_sync_test})
        pid -> pid
      end

    assert :ok = WatchlistSync.poll(pid)
  end

  test "a new watchlist entry becomes that user's pending request, and creates no movie" do
    user = opted_in_user(user_fixture())

    expect(PlexAuthMock, :watchlist, fn token ->
      assert token == "plex-token-#{user.id}"
      {:ok, [entry(603)]}
    end)

    sync!()

    assert [request] = Requests.list_for_user(user)
    assert request.status == :pending
    assert request.target_type == "movie"
    assert request.target_id == 603
    assert request.user_id == user.id

    # The approval gate is intact: no movie row exists until an admin approves.
    assert Repo.aggregate(Movie, :count) == 0
  end

  test "an admin's watchlist entry auto-approves exactly like their manual request would" do
    admin = opted_in_user(admin_fixture())

    expect(PlexAuthMock, :watchlist, fn _token -> {:ok, [entry(603)]} end)

    sync!()

    assert [request] = Requests.list_for_user(admin)
    assert request.status == :approved
    assert %Movie{status: :requested} = Repo.get_by(Movie, tmdb_id: 603)
  end

  test "the per-user quota applies exactly as it does to a manual request" do
    user = opted_in_user(user_fixture())
    {:ok, user} = user |> Ecto.Changeset.change(request_quota: 1) |> Repo.update()

    expect(PlexAuthMock, :watchlist, fn _token -> {:ok, [entry(603), entry(604)]} end)

    sync!()

    assert [%Request{target_id: 603}] = Requests.list_for_user(user)
  end

  test "the same entry is never requested twice across polls" do
    user = opted_in_user(user_fixture())

    expect(PlexAuthMock, :watchlist, 2, fn _token -> {:ok, [entry(603)]} end)

    sync!()
    sync!()

    assert [_only_one] = Requests.list_for_user(user)
  end

  # Catalog.delete_movie/3 deliberately reaps the title's :approved request in the same
  # transaction, so a request row alone can't carry "already synced" — without the durable
  # marker the sweep would treat a still-watchlisted deleted movie as new and silently
  # re-download it, every 15 minutes, forever.
  test "a movie the admin deleted is not re-requested while it stays on the watchlist" do
    admin = opted_in_user(admin_fixture())

    expect(PlexAuthMock, :watchlist, 2, fn _token -> {:ok, [entry(603)]} end)

    sync!()
    assert %Movie{} = movie = Repo.get_by(Movie, tmdb_id: 603)
    assert {:ok, %Movie{}} = Cinder.Catalog.delete_movie(movie, admin)
    # The reap really did remove the request row this dedupe used to rely on.
    assert Requests.list_for_user(admin) == []

    sync!()

    assert Repo.get_by(Movie, tmdb_id: 603) == nil
    assert Requests.list_for_user(admin) == []
  end

  test "an entry the admin already denied is not re-requested on the next poll" do
    user = opted_in_user(user_fixture())
    admin = admin_fixture()

    expect(PlexAuthMock, :watchlist, 2, fn _token -> {:ok, [entry(603)]} end)

    sync!()
    [request] = Requests.list_for_user(user)
    {:ok, _denied} = Requests.deny_request(request, admin, "no")

    sync!()

    assert [%Request{status: :denied}] = Requests.list_for_user(user)
  end

  test "a rejected token disables only that user's sync and leaves everyone else syncing" do
    revoked = opted_in_user(user_fixture())
    healthy = opted_in_user(user_fixture())

    stub(PlexAuthMock, :watchlist, fn
      "plex-token-" <> _rest = token ->
        if token == "plex-token-#{revoked.id}",
          do: {:error, :unauthorized},
          else: {:ok, [entry(603)]}
    end)

    sync!()

    disabled = Repo.get!(Accounts.User, revoked.id)
    refute disabled.plex_watchlist_sync
    # The dead credential is dropped with the opt-in, not left lying around.
    refute disabled.plex_token
    assert Requests.list_for_user(revoked) == []

    assert Repo.get!(Accounts.User, healthy.id).plex_watchlist_sync
    assert [%Request{target_id: 603}] = Requests.list_for_user(healthy)
  end

  test "a transient lookup failure keeps the opt-in and retries on the next tick" do
    user = opted_in_user(user_fixture())

    expect(PlexAuthMock, :watchlist, fn _token -> {:error, :timeout} end)
    sync!()

    assert Repo.get!(Accounts.User, user.id).plex_watchlist_sync
    assert Requests.list_for_user(user) == []

    expect(PlexAuthMock, :watchlist, fn _token -> {:ok, [entry(603)]} end)
    sync!()

    assert [%Request{target_id: 603}] = Requests.list_for_user(user)
  end

  test "a raising watchlist lookup is isolated to that user and does not wedge the tick" do
    boom = opted_in_user(user_fixture())
    healthy = opted_in_user(user_fixture())

    stub(PlexAuthMock, :watchlist, fn token ->
      if token == "plex-token-#{boom.id}",
        do: raise("plex.tv exploded"),
        else: {:ok, [entry(603)]}
    end)

    ExUnit.CaptureLog.capture_log(fn -> sync!() end)

    assert [%Request{target_id: 603}] = Requests.list_for_user(healthy)
  end

  test "a user who has not opted in is never read" do
    user = user_fixture()
    {:ok, _user} = Accounts.store_plex_token(user, "plex-token-#{user.id}")

    # No expect/stub for :watchlist at all: any call would fail the test.
    sync!()

    assert Requests.list_for_user(user) == []
  end

  test "an inactive user's watchlist is not read" do
    user = opted_in_user(user_fixture())
    {:ok, _user} = user |> Ecto.Changeset.change(active: false) |> Repo.update()

    sync!()

    assert Requests.list_for_user(user) == []
  end

  test "watchlisted shows are skipped (Cinder requests TV per season)" do
    user = opted_in_user(user_fixture())

    expect(PlexAuthMock, :watchlist, fn _token ->
      {:ok, [entry(1399, type: "show"), entry(603)]}
    end)

    sync!()

    assert [%Request{target_type: "movie", target_id: 603}] = Requests.list_for_user(user)
  end

  test "an undecryptable stored token disables that user's sync instead of looping on it" do
    user = opted_in_user(user_fixture())

    {:ok, _user} =
      user |> Ecto.Changeset.change(plex_token: "not-base64-ciphertext") |> Repo.update()

    ExUnit.CaptureLog.capture_log(fn -> sync!() end)

    refute Repo.get!(Accounts.User, user.id).plex_watchlist_sync
  end

  # The sweep's marker write relies on both halves of this: the unique index makes a racing
  # second tick a no-op rather than a duplicate, and `unique_constraint/2` must name that index
  # exactly as exqlite reports it or a collision would RAISE inside the tick instead of
  # returning a changeset (the same trap requests_pending_unique documents).
  test "a marker is unique per user and tmdb_id, and re-inserting it is a no-op" do
    user = user_fixture()

    changeset = fn ->
      SyncedWatchlistEntry.changeset(%SyncedWatchlistEntry{}, %{user_id: user.id, tmdb_id: 7})
    end

    assert {:ok, _} = Repo.insert(changeset.())

    assert {:ok, _} =
             Repo.insert(changeset.(),
               on_conflict: :nothing,
               conflict_target: [:user_id, :tmdb_id]
             )

    assert {:error, %Ecto.Changeset{}} = Repo.insert(changeset.())
    assert Repo.aggregate(SyncedWatchlistEntry, :count) == 1
  end

  test "unlinking Plex clears the token and switches sync off" do
    user = opted_in_user(user_fixture())

    {:ok, unlinked} = Accounts.unlink_plex_from_user(user)

    refute unlinked.plex_token
    refute unlinked.plex_watchlist_sync
    assert Accounts.list_plex_watchlist_users() == []
  end
end
