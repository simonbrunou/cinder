defmodule Cinder.Download.PollerSearchSkipTest do
  @moduledoc """
  The movie poller's search pass skips some `Cinder.Download.start/1` errors without a write, and
  its write-back skips a movie that left the search pass (#848). Each test here goes red when its
  skip is removed from `Cinder.Download.Poller`.

  Each reason arrives only when something changes the movie or its download intent while the
  unit runs, so a mock hook makes that change mid-unit. Every movie starts one strike short of
  the budget the leak would spend, so a skip that leaked into
  `Cinder.Catalog.MovieLifecycle.record_failure/2` would park it. The `:intent_backoff` skip is
  pinned in `PollerTest` ("a movie whose previous download's cleanup is backing off takes no
  strike").
  """
  use Cinder.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import Mox

  @moduletag :capture_log

  alias Cinder.Catalog.Movie
  alias Cinder.Download.{Intent, Poller}
  alias Cinder.Repo

  import Cinder.CatalogFixtures
  import Cinder.PollerHelpers

  # The poller runs in its own process, so the mocks must be global.
  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    on_exit(fn -> :persistent_term.erase({Poller, :last_run}) end)
    stub_clean_content()
  end

  defp requested_movie(imdb_id, attrs) do
    {:ok, movie} = seed_movie_state(movie_fixture(%{imdb_id: imdb_id}), attrs)
    movie
  end

  defp set_status(movie_id, attrs) do
    {1, _} = Repo.update_all(from(m in Movie, where: m.id == ^movie_id), set: attrs)
    :ok
  end

  defp reserved_intent(movie_id, title) do
    Repo.insert!(%Intent{
      operation_key: Ecto.UUID.generate(),
      kind: :movie,
      target_id: movie_id,
      protocol: :torrent,
      release: %{"title" => title},
      status: :reserved
    })
  end

  defp one_release(title) do
    {:ok, [%{title: title, size: 2_000_000_000, download_url: "magnet:?x", seeders: 10}]}
  end

  defp poll do
    start_supervised!({Poller, interval: 60_000, search_retry_after: 0})
    assert :ok = Poller.poll()
  end

  # The search moved the row to `:searching`, and the row is back at `:requested` when the search
  # records its result, so `MovieLifecycle.no_match/2`'s compare-and-swap misses. The row is still
  # in the search pass, so the write-back would count a strike.
  test ":stale_status from a search whose row changed under it takes no strike" do
    movie = requested_movie("tt0848001", %{search_attempts: 9})
    test_pid = self()

    stub(Cinder.Acquisition.IndexerMock, :search, fn "tt0848001" ->
      set_status(movie.id, status: :requested)
      send(test_pid, :row_changed)
      {:ok, []}
    end)

    poll()

    assert_received :row_changed
    assert %Movie{status: :requested, search_attempts: 9} = Repo.get!(Movie, movie.id)
  end

  # A download intent for the movie appeared after `Download.start/1` found none, for another
  # release, so `Download.grab_movie/2` refuses this one as busy. The row stays `:searching`.
  test ":download_intent_busy from an intent that appeared mid-search takes no strike" do
    movie = requested_movie("tt0848002", %{search_attempts: 9})
    test_pid = self()

    stub(Cinder.Acquisition.IndexerMock, :search, fn "tt0848002" ->
      send(test_pid, {:intent, reserved_intent(movie.id, "Other.Release.1080p-GRP")})
      one_release("Inception.2010.1080p.BluRay.x264-GRP")
    end)

    poll()

    assert_received {:intent, intent}
    assert %Movie{status: :searching, search_attempts: 9} = Repo.get!(Movie, movie.id)
    assert %Intent{status: :reserved} = Repo.get!(Intent, intent.id)
  end

  # The intent appears mid-tick, after the tick's own intent reconciliation (a downloading
  # sibling's status check makes it), so the search pass's `Download.start/1` submits it. It is
  # gone when the submission stores the remote id, and the movie is still `:requested`.
  test ":intent_completed from an intent removed mid-submission takes no strike" do
    movie = requested_movie("tt0848003", %{search_attempts: 9})
    sibling = movie_fixture(%{status: :downloading, download_id: "hash-848-sibling"})
    test_pid = self()

    stub(Cinder.Download.ClientMock, :status, fn "hash-848-sibling" ->
      reserved_intent(movie.id, "Completed.2020.1080p-GRP")
      {:ok, %{state: :downloading, progress: 0.1}}
    end)

    stub(Cinder.Download.ClientMock, :find_by_operation_key, fn _key ->
      {1, _} = Repo.delete_all(from(i in Intent, where: i.target_id == ^movie.id))
      send(test_pid, :intent_removed)
      {:ok, "hash-848-completed"}
    end)

    stub(Cinder.Acquisition.IndexerMock, :search, fn imdb_id ->
      send(test_pid, {:searched, imdb_id})
      {:ok, []}
    end)

    poll()

    assert_received :intent_removed
    refute_received {:searched, _imdb_id}
    assert %Movie{status: :requested, search_attempts: 9} = Repo.get!(Movie, movie.id)
    assert %Movie{status: :downloading} = Repo.get!(Movie, sibling.id)
  end

  # The movie left the search pass while its search ran (here: a download attached), then the
  # search failed. The write-back's re-read skips it: it neither crashes on the row nor counts
  # the search failure against the download's import budget.
  test "a search failure for a movie that left the search pass is not recorded" do
    movie = requested_movie("tt0848004", %{import_attempts: 9})
    test_pid = self()

    stub(Cinder.Acquisition.IndexerMock, :search, fn "tt0848004" ->
      set_status(movie.id, status: :downloading, download_id: "hash-848-moved")
      send(test_pid, :moved_on)
      {:error, :prowlarr_down}
    end)

    log = capture_log(fn -> poll() end)

    assert_received :moved_on

    assert %Movie{status: :downloading, import_attempts: 9, search_attempts: 0} =
             Repo.get!(Movie, movie.id)

    refute log =~ "poller skipped movie #{movie.id}"
  end
end
