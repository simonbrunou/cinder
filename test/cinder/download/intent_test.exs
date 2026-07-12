defmodule Cinder.Download.IntentTest do
  use Cinder.DataCase, async: false

  import Mox

  alias Cinder.Acquisition.Release
  alias Cinder.Catalog
  alias Cinder.Catalog.Grab
  alias Cinder.Download
  alias Cinder.Download.Intent
  alias Cinder.Download.IntentEpisode
  alias Cinder.Repo

  import Cinder.CatalogFixtures

  setup :set_mox_global
  setup :verify_on_exit!

  test "reserve_intent/1 generates a unique key and stores only resubmission fields" do
    release = %Release{
      title: "Movie.1080p.WEB-GRP",
      size: 8_000_000_000,
      download_url: "magnet:?xt=urn:btih:abc",
      protocol: :torrent,
      codec: "x264"
    }

    assert {:ok, intent} =
             Download.reserve_intent(%{
               kind: :movie,
               target_id: 42,
               episode_ids: [],
               protocol: :torrent,
               release: release
             })

    assert {:ok, _uuid} = Ecto.UUID.cast(intent.operation_key)
    assert intent.status == :reserved
    assert intent.remote_id == nil

    assert intent.release["title"] == "Movie.1080p.WEB-GRP"
    refute inspect(intent.release) =~ "magnet:?xt=urn:btih:abc"

    assert {:ok, ciphertext} = Base.decode64(intent.release["download_url_ciphertext"])
    assert {:ok, "magnet:?xt=urn:btih:abc"} = Cinder.Vault.decrypt(ciphertext)
  end

  test "operation keys are unique" do
    attrs = %{
      operation_key: Ecto.UUID.generate(),
      kind: :movie,
      target_id: 42,
      episode_ids: [],
      protocol: :torrent,
      release: %{"title" => "R", "download_url" => "magnet:?x"}
    }

    assert {:ok, _} = %Intent{} |> Intent.changeset(attrs) |> Repo.insert()

    assert {:error, changeset} =
             %Intent{} |> Intent.changeset(%{attrs | target_id: 43}) |> Repo.insert()

    assert "has already been taken" in errors_on(changeset).operation_key
  end

  test "source-origin provenance survives durable reservation and submission" do
    movie = movie_fixture(%{status: :searching})

    release = %Release{
      title: "Movie.1080p.WEB-GRP",
      download_url: "http://prowlarr:9696/download/1",
      download_url_origin: "http://prowlarr:9696",
      protocol: :torrent
    }

    assert {:ok, intent} = reserve_movie_intent(movie.id, release)
    assert intent.release["download_url_origin"] == "http://prowlarr:9696"

    expect(Cinder.Download.ClientMock, :find_by_operation_key, fn _key -> :not_found end)

    expect(Cinder.Download.ClientMock, :add, fn submitted, _opts ->
      assert submitted.download_url_origin == "http://prowlarr:9696"
      {:ok, "hash-provenance"}
    end)

    assert {:ok, %{download_id: "hash-provenance"}} = Download.reconcile_intent(intent)
  end

  test "concurrent reservations allow only one intent for the same movie" do
    movie = movie_fixture(%{status: :searching})
    release = release("Movie.A")

    results = concurrently(fn -> reserve_movie_intent(movie.id, release) end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :download_intent_busy})) == 1
    assert Repo.aggregate(Intent, :count) == 1
  end

  test "concurrent reservations reject overlapping TV episode assignments" do
    series = series_fixture(%{monitor_strategy: :all})
    season = season_fixture(series)
    e1 = episode_fixture(season, %{episode_number: 1})
    e2 = episode_fixture(season, %{episode_number: 2})
    e3 = episode_fixture(season, %{episode_number: 3})

    results =
      concurrently(
        fn -> reserve_episode_intent([e1.id, e2.id], release("Pack.A")) end,
        fn -> reserve_episode_intent([e2.id, e3.id], release("Pack.B")) end
      )

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :download_intent_busy})) == 1
    assert Repo.aggregate(IntentEpisode, :count) == 2
  end

  test "submit_intent serializes lookup through remote-id persistence" do
    movie = movie_fixture(%{status: :searching})
    {:ok, intent} = reserve_movie_intent(movie.id)
    parent = self()

    stub(Cinder.Download.ClientMock, :find_by_operation_key, fn _key ->
      send(parent, {:lookup, self()})
      receive do: (:continue -> :not_found)
    end)

    stub(Cinder.Download.ClientMock, :add, fn _release, _opts -> {:ok, "hash-single"} end)

    first = Task.async(fn -> Download.submit_intent(intent) end)
    assert_receive {:lookup, first_pid}
    second = Task.async(fn -> Download.submit_intent(intent) end)

    second_lookup =
      receive do
        {:lookup, pid} -> pid
      after
        150 -> nil
      end

    send(first_pid, :continue)
    if second_lookup, do: send(second_lookup, :continue)
    Task.await(first)
    Task.await(second)

    assert second_lookup == nil
  end

  test "permanent pre-submission errors release the intent and TV reservations" do
    series = series_fixture(%{monitor_strategy: :all})
    season = season_fixture(series)
    episode = episode_fixture(season)
    {:ok, intent} = reserve_episode_intent([episode.id], release("Bad"))

    expect(Cinder.Download.ClientMock, :find_by_operation_key, fn _ -> :not_found end)

    expect(Cinder.Download.ClientMock, :add, fn _release, _opts ->
      {:error, :unsupported_download_url}
    end)

    assert {:error, :unsupported_download_url} = Download.reconcile_intent(intent)
    refute Repo.get(Intent, intent.id)
    assert Repo.all(IntentEpisode) == []

    assert {:ok, _replacement} = reserve_episode_intent([episode.id], release("Replacement"))
  end

  test "invalid encrypted payload releases a pre-submission intent" do
    movie = movie_fixture(%{status: :searching})
    {:ok, intent} = reserve_movie_intent(movie.id)
    intent = intent |> Intent.changeset(%{release: %{"title" => "broken"}}) |> Repo.update!()

    expect(Cinder.Download.ClientMock, :find_by_operation_key, fn _ -> :not_found end)

    assert {:error, :invalid_intent_release} = Download.reconcile_intent(intent)
    refute Repo.get(Intent, intent.id)
  end

  test "transient submission errors retain the key with bounded retry metadata" do
    movie = movie_fixture(%{status: :searching})
    {:ok, intent} = reserve_movie_intent(movie.id)
    expect(Cinder.Download.ClientMock, :find_by_operation_key, fn _ -> {:error, :timeout} end)

    assert {:error, :timeout} = Download.reconcile_intent(intent)
    saved = Repo.get!(Intent, intent.id)
    assert saved.attempt_count == 1
    assert DateTime.after?(saved.next_attempt_at, DateTime.utc_now())
    assert saved.last_error == ":timeout"

    assert {:error, :intent_backoff} = Download.reconcile_intent(saved)
    assert Repo.get!(Intent, intent.id).attempt_count == 1

    due =
      saved
      |> Intent.changeset(%{attempt_count: 100, next_attempt_at: nil})
      |> Repo.update!()

    expect(Cinder.Download.ClientMock, :find_by_operation_key, fn _ ->
      {:error, {:http_error, "https://user:secret@example.test"}}
    end)

    before_retry = DateTime.utc_now(:second)

    assert {:error, {:http_error, _secret}} = Download.reconcile_intent(due)
    capped = Repo.get!(Intent, intent.id)
    assert capped.attempt_count == 101
    assert DateTime.diff(capped.next_attempt_at, before_retry, :second) in 299..300
    assert capped.last_error == ":http_error"
    refute capped.last_error =~ "secret"
  end

  test "a committed movie retry generation is charged once across crash replay" do
    movie = movie_fixture(%{status: :searching})
    {:ok, movie} = Catalog.transition(movie, %{status: :searching, search_attempts: 3})
    {:ok, intent} = reserve_movie_intent(movie.id)

    expect(Cinder.Download.ClientMock, :find_by_operation_key, fn _ -> {:error, :timeout} end)

    # A caller may die as soon as reconcile_intent/1 returns. The intent generation and
    # movie budget therefore have to be committed before control returns to that caller.
    assert {:error, :timeout} = Download.reconcile_intent(intent)
    assert Repo.get!(Intent, intent.id).attempt_count == 1
    assert Repo.get!(Cinder.Catalog.Movie, movie.id).search_attempts == 4

    # Replaying recovery while that persisted generation is in backoff cannot charge it again.
    assert :ok = Download.reconcile_pending_intents([:movie])
    assert Repo.get!(Intent, intent.id).attempt_count == 1
    assert Repo.get!(Cinder.Catalog.Movie, movie.id).search_attempts == 4
  end

  test "concurrent reconciliation charges one movie attempt for one intent generation" do
    movie = movie_fixture(%{status: :searching})
    {:ok, movie} = Catalog.transition(movie, %{status: :searching, search_attempts: 3})
    {:ok, intent} = reserve_movie_intent(movie.id)
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    stub(Cinder.Download.ClientMock, :find_by_operation_key, fn _ ->
      Agent.update(calls, &(&1 + 1))
      {:error, :timeout}
    end)

    assert [first, second] = concurrently(fn -> Download.reconcile_intent(intent) end)

    assert Enum.sort([first, second]) ==
             Enum.sort([{:error, :timeout}, {:error, :intent_backoff}])

    assert Agent.get(calls, & &1) == 1
    assert Repo.get!(Intent, intent.id).attempt_count == 1
    assert Repo.get!(Cinder.Catalog.Movie, movie.id).search_attempts == 4
  end

  test "the exhausting movie retry generation atomically becomes its cleanup carrier" do
    Cinder.TestNotifier.subscribe()
    Catalog.subscribe()

    movie = movie_fixture(%{status: :searching})
    {:ok, movie} = Catalog.transition(movie, %{status: :searching, search_attempts: 9})
    {:ok, intent} = reserve_movie_intent(movie.id)

    stub(Cinder.Download.ClientMock, :find_by_operation_key, fn _ -> {:error, :timeout} end)

    assert {:error, :timeout} = Download.reconcile_intent(intent)

    assert %{status: :search_failed, search_attempts: 9} =
             Repo.get!(Cinder.Catalog.Movie, movie.id)

    cleanup = Repo.get!(Intent, intent.id)
    assert cleanup.status == :cleanup_pending
    assert cleanup.operation_key == intent.operation_key

    assert_receive {:movie_updated, %{id: movie_id, status: :search_failed}}
    assert_receive {:notify, {:movie_failed, %{id: ^movie_id, status: :search_failed}, :timeout}}
    assert movie_id == movie.id
  end

  test "an exhausting retry publishes once before fatal cleanup and retains its fence" do
    Cinder.TestNotifier.subscribe()

    movie = movie_fixture(%{status: :searching})
    {:ok, movie} = Catalog.transition(movie, %{status: :searching, search_attempts: 9})
    {:ok, intent} = reserve_movie_intent(movie.id)
    {:ok, calls} = Agent.start_link(fn -> 0 end)
    Catalog.subscribe()

    stub(Cinder.Download.ClientMock, :find_by_operation_key, fn _ ->
      case Agent.get_and_update(calls, &{&1, &1 + 1}) do
        0 -> {:error, :timeout}
        _ -> Process.exit(self(), :kill)
      end
    end)

    {pid, ref} = spawn_monitor(fn -> Download.reconcile_intent(intent) end)

    assert_receive {:movie_updated, %{id: movie_id, status: :search_failed}}
    assert_receive {:notify, {:movie_failed, %{id: ^movie_id, status: :search_failed}, :timeout}}
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    refute_receive {:movie_updated, %{id: ^movie_id}}
    refute_receive {:notify, {:movie_failed, %{id: ^movie_id}, _reason}}

    assert movie_id == movie.id
    assert Repo.get!(Intent, intent.id).status == :cleanup_pending
    assert Repo.get!(Cinder.Catalog.Movie, movie.id).status == :search_failed
  end

  test "cleanup lookup failure retains the only operation key" do
    movie = movie_fixture(%{status: :searching})
    {:ok, intent} = reserve_movie_intent(movie.id)
    cleanup = mark_cleanup(intent)
    expect(Cinder.Download.ClientMock, :find_by_operation_key, fn _ -> {:error, :timeout} end)

    assert {:error, :timeout} = Download.reconcile_intent(cleanup)
    saved = Repo.get!(Intent, intent.id)
    assert saved.status == :cleanup_pending
    assert saved.attempt_count == 1
    assert saved.operation_key == intent.operation_key
  end

  test "cleanup remove failure retains a retryable cleanup record" do
    movie = movie_fixture(%{status: :searching})
    intent = submitted_movie_intent(movie.id, "hash-remove-failed")
    cleanup = mark_cleanup(intent)
    expect(Cinder.Download.ClientMock, :remove, fn _id, _opts -> {:error, :timeout} end)

    assert {:error, :timeout} = Download.reconcile_intent(cleanup)
    saved = Repo.get!(Intent, intent.id)
    assert saved.status == :cleanup_pending
    assert saved.remote_id == "hash-remove-failed"
    assert saved.attempt_count == 1
  end

  test "cleanup deletes the record after direct remove succeeds" do
    movie = movie_fixture(%{status: :searching})
    intent = submitted_movie_intent(movie.id, "hash-remove-ok")
    cleanup = mark_cleanup(intent)
    expect(Cinder.Download.ClientMock, :remove, fn _id, _opts -> :ok end)

    assert {:ok, :removed} = Download.reconcile_intent(cleanup)
    refute Repo.get(Intent, intent.id)
  end

  test "cleanup converges after process death during remote removal" do
    movie = movie_fixture(%{status: :searching})
    intent = submitted_movie_intent(movie.id, "hash-cleanup-crash")
    cleanup = mark_cleanup(intent)
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    stub(Cinder.Download.ClientMock, :remove, fn _id, _opts ->
      case Agent.get_and_update(calls, &{&1, &1 + 1}) do
        0 -> Process.exit(self(), :kill)
        _ -> :ok
      end
    end)

    {pid, ref} = spawn_monitor(fn -> Download.reconcile_intent(cleanup) end)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    assert Repo.get!(Intent, intent.id).status == :cleanup_pending

    assert :ok = Download.reconcile_pending_intents([:movie])
    refute Repo.get(Intent, intent.id)
    assert Agent.get(calls, & &1) == 2
  end

  test "cancellation racing a submission fences it before add or attachment" do
    movie = movie_fixture(%{status: :searching})
    actor = Cinder.AccountsFixtures.admin_fixture()
    {:ok, intent} = reserve_movie_intent(movie.id)
    parent = self()

    stub(Cinder.Download.ClientMock, :find_by_operation_key, fn _ ->
      send(parent, {:lookup_blocked, self()})
      receive do: (:continue -> :not_found)
    end)

    submit = Task.async(fn -> Download.reconcile_intent(intent) end)
    assert_receive {:lookup_blocked, lookup_pid}
    cancel = Task.async(fn -> Catalog.cancel_movie(movie, actor) end)
    Process.sleep(25)
    send(lookup_pid, :continue)

    assert {:error, :stale_target} = Task.await(submit)
    assert {:ok, %Cinder.Catalog.Movie{status: :cancelled}} = Task.await(cancel)
  end

  test "movie cancellation commits before cleanup and a cleanup crash keeps its fence" do
    movie = movie_fixture(%{status: :searching})
    actor = Cinder.AccountsFixtures.admin_fixture()
    intent = submitted_movie_intent(movie.id, "hash-cancel-after-commit")
    {:ok, calls} = Agent.start_link(fn -> 0 end)
    parent = self()

    stub(Cinder.Download.ClientMock, :remove, fn _id, _opts ->
      send(parent, {:remove_observed_movie, Repo.get!(Cinder.Catalog.Movie, movie.id).status})

      case Agent.get_and_update(calls, &{&1, &1 + 1}) do
        0 -> Process.exit(self(), :kill)
        _ -> :ok
      end
    end)

    {pid, ref} = spawn_monitor(fn -> Catalog.cancel_movie(movie, actor) end)
    assert_receive {:remove_observed_movie, :cancelled}
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    assert Repo.get!(Intent, intent.id).status == :cleanup_pending

    assert :ok = Download.reconcile_pending_intents([:movie])
    refute Repo.get(Intent, intent.id)
  end

  test "cancel_grab is idempotent when the poller deletes the re-read grab first" do
    series = series_fixture(%{monitor_strategy: :all})
    season = season_fixture(series)
    episode = episode_fixture(season)
    {:ok, grab} = Catalog.create_grab("hash-already-finished", :torrent, [episode.id])

    # Simulate the poller winning after the LiveView re-read but before cancel_grab's transaction.
    assert {:ok, _deleted} = Repo.delete(grab)
    refute Repo.get(Grab, grab.id)
    assert Repo.get!(Cinder.Catalog.Episode, episode.id).grab_id == nil

    assert {:ok, %Grab{id: id}} = Catalog.cancel_grab(grab)
    assert id == grab.id
    assert Repo.aggregate(Intent, :count) == 0
    assert Repo.aggregate(IntentEpisode, :count) == 0
  end

  test "series cancellation commits unmonitoring before cleanup and preserves a crashed fence" do
    series = series_fixture(%{monitor_strategy: :all})
    season = season_fixture(series)
    episode = episode_fixture(season)
    actor = Cinder.AccountsFixtures.admin_fixture()
    {:ok, intent} = reserve_episode_intent([episode.id], release("Show.Cancel"))

    intent =
      intent
      |> Intent.changeset(%{status: :submitted, remote_id: "hash-tv-fence"})
      |> Repo.update!()

    {:ok, calls} = Agent.start_link(fn -> 0 end)
    parent = self()

    stub(Cinder.Download.ClientMock, :remove, fn _id, _opts ->
      send(
        parent,
        {:remove_observed_episode, Repo.get!(Cinder.Catalog.Episode, episode.id).monitored}
      )

      case Agent.get_and_update(calls, &{&1, &1 + 1}) do
        0 -> Process.exit(self(), :kill)
        _ -> :ok
      end
    end)

    {pid, ref} = spawn_monitor(fn -> Catalog.cancel_series(series, actor) end)
    assert_receive {:remove_observed_episode, false}
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    assert Repo.get!(Intent, intent.id).status == :cleanup_pending

    assert :ok = Download.reconcile_pending_intents([:episode, :season_pack])
    refute Repo.get(Intent, intent.id)
  end

  test "movie and series deletion commit before pending-intent cleanup" do
    movie = movie_fixture(%{status: :searching})
    movie_intent = submitted_movie_intent(movie.id, "hash-delete-fence")

    series = series_fixture(%{monitor_strategy: :all})
    season = season_fixture(series)
    episode = episode_fixture(season)
    {:ok, tv_intent} = reserve_episode_intent([episode.id], release("Show.Delete"))

    tv_intent =
      tv_intent
      |> Intent.changeset(%{status: :submitted, remote_id: "hash-tv-delete"})
      |> Repo.update!()

    parent = self()

    stub(Cinder.Download.ClientMock, :remove, fn id, _opts ->
      send(
        parent,
        {:delete_cleanup_state, id, Repo.get(Cinder.Catalog.Movie, movie.id),
         Repo.get(Cinder.Catalog.Series, series.id)}
      )

      :ok
    end)

    assert {:ok, _} = Catalog.delete_movie(movie, nil)
    assert_receive {:delete_cleanup_state, "hash-delete-fence", nil, %Cinder.Catalog.Series{}}
    refute Repo.get(Intent, movie_intent.id)

    assert {:ok, _} = Catalog.delete_series(series, nil)
    assert_receive {:delete_cleanup_state, "hash-tv-delete", nil, nil}
    refute Repo.get(Intent, tv_intent.id)
  end

  test "a live movie submission cannot add or attach after cancellation commits" do
    movie = movie_fixture(%{status: :searching})
    actor = Cinder.AccountsFixtures.admin_fixture()
    {:ok, intent} = reserve_movie_intent(movie.id)
    {:ok, lookups} = Agent.start_link(fn -> 0 end)
    {:ok, adds} = Agent.start_link(fn -> 0 end)
    parent = self()

    stub(Cinder.Download.ClientMock, :find_by_operation_key, fn _ ->
      case Agent.get_and_update(lookups, &{&1, &1 + 1}) do
        0 ->
          send(parent, {:submission_lookup_blocked, self()})
          receive do: (:continue -> :not_found)

        _ ->
          :not_found
      end
    end)

    stub(Cinder.Download.ClientMock, :add, fn _release, _opts ->
      Agent.update(adds, &(&1 + 1))
      {:ok, "must-not-be-added"}
    end)

    submit = Task.async(fn -> Download.reconcile_intent(intent) end)
    assert_receive {:submission_lookup_blocked, lookup_pid}
    cancel = Task.async(fn -> Catalog.cancel_movie(movie, actor) end)

    assert eventually(fn -> Repo.get!(Cinder.Catalog.Movie, movie.id).status == :cancelled end)
    send(lookup_pid, :continue)

    assert {:ok, %Cinder.Catalog.Movie{status: :cancelled}} = Task.await(cancel)
    assert {:error, _reason} = Task.await(submit)
    assert Agent.get(adds, & &1) == 0
    refute Repo.get(Intent, intent.id)
  end

  test "an accepted movie submission racing cancellation is removed without attachment" do
    movie = movie_fixture(%{status: :searching})
    actor = Cinder.AccountsFixtures.admin_fixture()
    {:ok, intent} = reserve_movie_intent(movie.id)
    parent = self()

    expect(Cinder.Download.ClientMock, :find_by_operation_key, fn _ -> :not_found end)

    expect(Cinder.Download.ClientMock, :add, fn _release, _opts ->
      send(parent, {:movie_remote_accepted, self()})
      receive do: (:return_remote -> {:ok, "hash-racing-cancel"})
    end)

    expect(Cinder.Download.ClientMock, :remove, fn "hash-racing-cancel", _opts -> :ok end)

    submit = Task.async(fn -> Download.reconcile_intent(intent) end)
    assert_receive {:movie_remote_accepted, add_pid}
    cancel = Task.async(fn -> Catalog.cancel_movie(movie, actor) end)
    assert eventually(fn -> Repo.get!(Cinder.Catalog.Movie, movie.id).status == :cancelled end)
    send(add_pid, :return_remote)

    assert {:ok, :removed} = Task.await(submit)
    assert {:ok, %Cinder.Catalog.Movie{status: :cancelled}} = Task.await(cancel)
    refute Repo.get(Intent, intent.id)
    assert Repo.get!(Cinder.Catalog.Movie, movie.id).download_id == nil
  end

  test "an accepted TV submission racing series cancellation is removed without a grab" do
    series = series_fixture(%{monitor_strategy: :all})
    season = season_fixture(series)
    episode = episode_fixture(season)
    actor = Cinder.AccountsFixtures.admin_fixture()
    {:ok, intent} = reserve_episode_intent([episode.id], release("Show.Race"))
    parent = self()

    expect(Cinder.Download.ClientMock, :find_by_operation_key, fn _ -> :not_found end)

    expect(Cinder.Download.ClientMock, :add, fn _release, _opts ->
      send(parent, {:tv_remote_accepted, self()})
      receive do: (:return_remote -> {:ok, "hash-tv-racing-cancel"})
    end)

    expect(Cinder.Download.ClientMock, :remove, fn "hash-tv-racing-cancel", _opts -> :ok end)

    submit = Task.async(fn -> Download.reconcile_intent(intent) end)
    assert_receive {:tv_remote_accepted, add_pid}
    cancel = Task.async(fn -> Catalog.cancel_series(series, actor) end)
    assert eventually(fn -> Repo.get!(Cinder.Catalog.Episode, episode.id).monitored == false end)
    send(add_pid, :return_remote)

    assert {:ok, :removed} = Task.await(submit)
    assert {:ok, _series} = Task.await(cancel)
    refute Repo.get(Intent, intent.id)
    assert Repo.all(Grab) == []
    assert Repo.get!(Cinder.Catalog.Episode, episode.id).grab_id == nil
  end

  test "manual movie release returns busy instead of submitting an older intent" do
    movie = movie_fixture(%{status: :no_match})
    {:ok, _intent} = reserve_movie_intent(movie.id, release("Old.Movie"))

    assert {:error, :download_intent_busy} = Download.grab_movie(movie, release("Chosen.Movie"))
  end

  test "manual TV release returns busy instead of submitting an older overlapping intent" do
    series = series_fixture(%{monitor_strategy: :all})
    season = season_fixture(series)
    episode = episode_fixture(season)
    {:ok, _intent} = reserve_episode_intent([episode.id], release("Old.Show"))

    assert {:error, :download_intent_busy} =
             Download.grab_episodes(release("Chosen.Show"), [episode.id])
  end

  test "a definite add rejection releases movie and TV targets for another search" do
    movie = movie_fixture(%{status: :no_match})
    {:ok, movie_intent} = reserve_movie_intent(movie.id, release("Rejected.Movie"))

    series = series_fixture(%{monitor_strategy: :all})
    season = season_fixture(series)
    episode = episode_fixture(season)
    {:ok, tv_intent} = reserve_episode_intent([episode.id], release("Rejected.Show"))

    expect(Cinder.Download.ClientMock, :find_by_operation_key, 2, fn _ -> :not_found end)
    expect(Cinder.Download.ClientMock, :add, 2, fn _release, _opts -> {:error, :add_rejected} end)

    assert {:error, :add_rejected} = Download.reconcile_intent(movie_intent)
    assert {:error, :add_rejected} = Download.reconcile_intent(tv_intent)
    refute Repo.get(Intent, movie_intent.id)
    refute Repo.get(Intent, tv_intent.id)

    assert {:ok, _next_movie_search} = reserve_movie_intent(movie.id, release("Next.Movie"))
    assert {:ok, _next_tv_search} = reserve_episode_intent([episode.id], release("Next.Show"))
  end

  test "a reserved intent survives process death and later submits once" do
    movie = movie_fixture(%{status: :searching})
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        {:ok, intent} = reserve_movie_intent(movie.id)
        send(parent, {:reserved, intent.id})
        Process.exit(self(), :kill)
      end)

    assert_receive {:reserved, intent_id}
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    intent = Repo.get!(Intent, intent_id)

    expect(Cinder.Download.ClientMock, :find_by_operation_key, fn _ -> :not_found end)
    expect(Cinder.Download.ClientMock, :add, fn _release, _opts -> {:ok, "hash-reserved"} end)

    assert {:ok, _movie} = Download.reconcile_intent(intent)
    assert Repo.get!(Cinder.Catalog.Movie, movie.id).download_id == "hash-reserved"
  end

  test "process death after lookup re-runs lookup before one add" do
    movie = movie_fixture(%{status: :searching})
    {:ok, intent} = reserve_movie_intent(movie.id)
    {:ok, lookups} = Agent.start_link(fn -> 0 end)
    {:ok, adds} = Agent.start_link(fn -> 0 end)

    stub(Cinder.Download.ClientMock, :find_by_operation_key, fn _ ->
      case Agent.get_and_update(lookups, &{&1, &1 + 1}) do
        0 -> Process.exit(self(), :kill)
        _ -> :not_found
      end
    end)

    stub(Cinder.Download.ClientMock, :add, fn _release, _opts ->
      Agent.update(adds, &(&1 + 1))
      {:ok, "hash-after-lookup"}
    end)

    {pid, ref} = spawn_monitor(fn -> Download.reconcile_intent(intent) end)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    assert {:ok, _movie} = Download.reconcile_intent(intent)
    assert Agent.get(lookups, & &1) == 2
    assert Agent.get(adds, & &1) == 1
  end

  test "process death after movie ownership commit converges without add or orphan cleanup" do
    movie = movie_fixture(%{status: :searching})
    intent = submitted_movie_intent(movie.id, "hash-owned")
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        {:ok, downloading} =
          Catalog.transition(movie, %{
            status: :downloading,
            download_id: "hash-owned",
            download_protocol: :torrent
          })

        send(parent, {:movie_owner_committed, downloading.id})
        Process.exit(self(), :kill)
      end)

    assert_receive {:movie_owner_committed, movie_id}
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    assert {:ok, reconciled} = Download.reconcile_intent(intent)
    assert reconciled.id == movie_id
    assert reconciled.download_id == "hash-owned"
    refute Repo.get(Intent, intent.id)
  end

  test "process death after remote-id persistence resumes from submitted without adding again" do
    movie = movie_fixture(%{status: :searching})
    {:ok, intent} = reserve_movie_intent(movie.id)
    parent = self()

    expect(Cinder.Download.ClientMock, :find_by_operation_key, fn _ -> :not_found end)
    expect(Cinder.Download.ClientMock, :add, fn _release, _opts -> {:ok, "hash-submitted"} end)

    {pid, ref} =
      spawn_monitor(fn ->
        {:ok, submitted} = Download.submit_intent(intent)
        send(parent, {:remote_stored, submitted.id})
        Process.exit(self(), :kill)
      end)

    assert_receive {:remote_stored, intent_id}
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    submitted = Repo.get!(Intent, intent_id)
    assert submitted.status == :submitted

    assert {:ok, _movie} = Download.reconcile_intent(submitted)
    assert Repo.get!(Cinder.Catalog.Movie, movie.id).download_id == "hash-submitted"
  end

  test "process death after grab ownership commit removes only the intent on recovery" do
    series = series_fixture(%{monitor_strategy: :all})
    season = season_fixture(series)
    episode = episode_fixture(season)
    {:ok, intent} = reserve_episode_intent([episode.id], release("Owned.Show"))

    intent =
      intent
      |> Intent.changeset(%{status: :submitted, remote_id: "hash-grab-owned"})
      |> Repo.update!()

    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        {:ok, grab} = Catalog.create_grab("hash-grab-owned", :torrent, [episode.id], "Owned.Show")
        send(parent, {:grab_committed, grab.id})
        Process.exit(self(), :kill)
      end)

    assert_receive {:grab_committed, grab_id}
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    assert {:ok, %Grab{id: ^grab_id}} = Download.reconcile_intent(intent)
    refute Repo.get(Intent, intent.id)
    assert Repo.get!(Grab, grab_id).download_id == "hash-grab-owned"
  end

  test "cancelling a movie removes its submitted remote job and intent" do
    movie = movie_fixture(%{status: :searching})
    actor = Cinder.AccountsFixtures.admin_fixture()

    assert {:ok, intent} = reserve_movie_intent(movie.id)

    intent =
      intent
      |> Intent.changeset(%{status: :submitted, remote_id: "hash-cancel"})
      |> Repo.update!()

    expect(Cinder.Download.ClientMock, :remove, fn "hash-cancel", _opts -> :ok end)

    assert {:ok, _movie} = Catalog.cancel_movie(movie, actor)
    refute Repo.get(Intent, intent.id)
  end

  test "cancelling a series removes its submitted remote job and intent" do
    series = series_fixture(%{monitor_strategy: :all})
    season = season_fixture(series)
    episode = episode_fixture(season)
    actor = Cinder.AccountsFixtures.admin_fixture()

    release = %Release{title: "Show.S01E01", download_url: "magnet:?x", protocol: :torrent}

    assert {:ok, intent} =
             Download.reserve_intent(%{
               kind: :episode,
               target_id: episode.id,
               episode_ids: [episode.id],
               protocol: :torrent,
               release: release
             })

    intent =
      intent
      |> Intent.changeset(%{status: :submitted, remote_id: "hash-tv-cancel"})
      |> Repo.update!()

    expect(Cinder.Download.ClientMock, :remove, fn "hash-tv-cancel", _opts -> :ok end)

    assert {:ok, _series} = Catalog.cancel_series(series, actor)
    refute Repo.get(Intent, intent.id)
  end

  test "reconciliation cannot link an episode that became unmonitored" do
    series = series_fixture(%{monitor_strategy: :all})
    season = season_fixture(series)
    episode = episode_fixture(season)
    release = %Release{title: "Show.S01E01", download_url: "magnet:?x", protocol: :torrent}

    assert {:ok, intent} =
             Download.reserve_intent(%{
               kind: :episode,
               target_id: episode.id,
               episode_ids: [episode.id],
               protocol: :torrent,
               release: release
             })

    intent =
      intent
      |> Intent.changeset(%{status: :submitted, remote_id: "hash-unmonitored"})
      |> Repo.update!()

    Repo.update_all(Cinder.Catalog.Episode, set: [monitored: false])
    expect(Cinder.Download.ClientMock, :remove, fn "hash-unmonitored", _opts -> :ok end)

    assert {:error, :no_episodes_linked} = Download.reconcile_intent(intent)
    assert Repo.all(Grab) == []
    refute Repo.get(Intent, intent.id)
  end

  defp reserve_movie_intent(movie_id, chosen \\ release("Movie")) do
    Download.reserve_intent(%{
      kind: :movie,
      target_id: movie_id,
      episode_ids: [],
      protocol: :torrent,
      release: chosen
    })
  end

  defp reserve_episode_intent(episode_ids, chosen) do
    Download.reserve_intent(%{
      kind: if(length(episode_ids) == 1, do: :episode, else: :season_pack),
      target_id: hd(episode_ids),
      episode_ids: episode_ids,
      protocol: :torrent,
      release: chosen
    })
  end

  defp submitted_movie_intent(movie_id, remote_id) do
    {:ok, intent} = reserve_movie_intent(movie_id)

    intent
    |> Intent.changeset(%{status: :submitted, remote_id: remote_id})
    |> Repo.update!()
  end

  defp mark_cleanup(intent) do
    intent
    |> Intent.changeset(%{
      status: :cleanup_pending,
      attempt_count: 0,
      next_attempt_at: nil,
      last_error: nil
    })
    |> Repo.update!()
  end

  defp release(title),
    do: %Release{title: title, download_url: "magnet:?xt=urn:btih:#{title}", protocol: :torrent}

  defp concurrently(first, second \\ nil) do
    parent = self()
    second = second || first

    tasks =
      for fun <- [first, second] do
        Task.async(fn ->
          send(parent, {:ready, self()})
          receive do: (:go -> fun.())
        end)
      end

    pids =
      for _ <- 1..2,
          do:
            (
              assert_receive {:ready, pid}
              pid
            )

    Enum.each(pids, &send(&1, :go))
    Enum.map(tasks, &Task.await/1)
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(5)
      eventually(fun, attempts - 1)
    end
  end
end
