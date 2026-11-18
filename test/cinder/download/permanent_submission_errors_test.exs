defmodule Cinder.Download.PermanentSubmissionErrorsTest do
  @moduledoc """
  What each of `Cinder.Download.permanent_submission_errors/0` does to a movie, a TV episode and
  a book target, through the path each poller takes: the download intent submits the release and
  `abandon_reserved/2` drops the reservation, holding a book target first; then the movie or TV
  poller's own failure handling runs (#1449).

  A reason the client returns on `add` reaches the movie and TV pollers on a fresh grab from their
  search pass. `:invalid_intent_release` comes only from an intent stored on an earlier tick whose
  saved download link `Download` cannot read back, so its cells start from such an intent (its
  stored release holds no link ciphertext) and the poller's pending-intent pass submits it. A book
  target has no search pass, so each of its cells starts from a stored intent that `BookPoller`'s
  pending-intent pass submits.
  """
  use Cinder.DataCase, async: false

  import Mox
  import Cinder.CatalogFixtures
  import Cinder.PollerHelpers, only: [stub_clean_content: 0]

  alias Cinder.Acquisition.Release
  alias Cinder.Books
  alias Cinder.Books.BookTarget
  alias Cinder.Catalog
  alias Cinder.Catalog.{Episode, Movie}
  alias Cinder.Download
  alias Cinder.Download.{BookPoller, Intent, Poller, TvPoller}
  alias Cinder.Repo

  @moduletag :capture_log

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    on_exit(fn ->
      for poller <- [Poller, TvPoller, BookPoller],
          do: :persistent_term.erase({poller, :last_run})

      :persistent_term.erase({BookPoller, :audiobookshelf_scan_failed})
    end)

    stub_clean_content()
  end

  # For each reason the client returns: the searching movie parks at once; a TV episode spends one
  # search attempt and stays wanted; a book target is held with the reason. A stored intent whose
  # link cannot be read back is dropped by the movie and TV pending-intent pass, and the search
  # pass that follows grabs the release its search finds (`adds: 1`), so neither the movie nor the
  # episode records a failure (#1491).
  @expected %{
    unsupported_download_url: %{
      movie: %{status: :search_failed, search_attempts: 0, adds: 1},
      episode: %{grabbed: false, search_attempts: 1, adds: 1},
      book_target: %{status: :held, hold_reason: "unsupported_download_url", adds: 1}
    },
    bad_torrent: %{
      movie: %{status: :search_failed, search_attempts: 0, adds: 1},
      episode: %{grabbed: false, search_attempts: 1, adds: 1},
      book_target: %{status: :held, hold_reason: "bad_torrent", adds: 1}
    },
    add_rejected: %{
      movie: %{status: :search_failed, search_attempts: 0, adds: 1},
      episode: %{grabbed: false, search_attempts: 1, adds: 1},
      book_target: %{status: :held, hold_reason: "add_rejected", adds: 1}
    },
    invalid_intent_release: %{
      movie: %{status: :downloading, search_attempts: 0, adds: 1},
      episode: %{grabbed: true, search_attempts: 0, adds: 1},
      book_target: %{status: :held, hold_reason: "invalid_intent_release", adds: 0}
    }
  }

  test "the table covers every permanent submission error" do
    assert Enum.sort(Map.keys(@expected)) == Enum.sort(Download.permanent_submission_errors())
  end

  for {reason, by_kind} <- @expected, {kind, expected} <- by_kind do
    @reason reason
    @kind kind
    @cell expected

    test "#{kind} on #{reason}" do
      assert outcome(@kind, @reason) == @cell
    end
  end

  # --- movie ---------------------------------------------------------------------------------------

  defp outcome(:movie, reason) do
    {:ok, movie} = Catalog.add_movie(%{tmdb_id: 900, title: "Inception", imdb_id: "tt1375666"})
    if from_stored_intent?(reason), do: store_broken_intent(:movie, movie.id, [])

    stub(Cinder.Acquisition.IndexerMock, :search, fn "tt1375666" ->
      {:ok, [indexer_result("Inception.2010.1080p.BluRay.x264-GRP")]}
    end)

    stub_client(reason, "hash-movie")
    start_supervised!({Poller, interval: 60_000, search_retry_after: 0})
    assert :ok = Poller.poll()

    %Movie{status: status, search_attempts: attempts} = Repo.get!(Movie, movie.id)
    %{status: status, search_attempts: attempts, adds: adds()}
  end

  # --- TV episode ----------------------------------------------------------------------------------

  defp outcome(:episode, reason) do
    series = series_fixture(%{tvdb_id: 99, monitor_strategy: :all})
    season = season_fixture(series)
    episode = episode_fixture(season, %{episode_number: 1})

    if from_stored_intent?(reason), do: store_broken_intent(:episode, episode.id, [episode.id])

    stub(Cinder.Acquisition.IndexerMock, :search_tv, fn 99, "Show", 1 ->
      {:ok, [indexer_result("Show.S01E01.1080p.WEB-DL-GRP")]}
    end)

    stub_client(reason, "hash-episode")
    start_supervised!({TvPoller, interval: 60_000, search_retry_after: 0})
    assert :ok = TvPoller.poll()

    %Episode{grab_id: grab_id, search_attempts: attempts} = Repo.get!(Episode, episode.id)
    %{grabbed: not is_nil(grab_id), search_attempts: attempts, adds: adds()}
  end

  # --- book target ---------------------------------------------------------------------------------

  defp outcome(:book_target, reason) do
    target = monitored_book_target()

    {:ok, intent} =
      Download.reserve_intent(%{
        kind: :book_target,
        target_id: target.id,
        episode_ids: [],
        protocol: :torrent,
        release: release("Le Guin - The Dispossessed (EPUB)")
      })

    if from_stored_intent?(reason), do: break_payload(intent)

    stub_client(reason, "hash-book")
    start_supervised!({BookPoller, interval: 60_000})
    assert :ok = BookPoller.poll()

    %BookTarget{status: status, hold_reason: hold_reason} = Repo.get!(BookTarget, target.id)
    %{status: status, hold_reason: hold_reason, adds: adds()}
  end

  # --- helpers -------------------------------------------------------------------------------------

  # Every `add` reports to the test, so a cell whose poller never reached the client (a raise that
  # the poller's `isolate/2` only logs) shows `adds: 0` instead of passing on an untouched row. A
  # client reason fails every `add`. A stored intent with an unreadable link never reaches `add`,
  # and the client accepts the release the search pass grabs after it.
  defp stub_client(reason, remote_id) do
    test_pid = self()
    stub(Cinder.Download.ClientMock, :find_by_operation_key, fn _key -> :not_found end)

    stub(Cinder.Download.ClientMock, :add, fn _release, _opts ->
      send(test_pid, :add)
      if from_stored_intent?(reason), do: {:ok, remote_id}, else: {:error, reason}
    end)

    stub(Cinder.Download.ClientMock, :status, fn _id -> {:ok, %{state: :downloading}} end)
  end

  defp adds, do: count_adds(0)

  defp count_adds(n) do
    receive do
      :add -> count_adds(n + 1)
    after
      0 -> n
    end
  end

  # The one reason no client returns: it comes from the stored intent itself, so its cells set one
  # up and the client accepts every `add`.
  defp from_stored_intent?(reason), do: reason == :invalid_intent_release

  # The intent an earlier tick reserved, whose saved download link cannot be read back.
  defp store_broken_intent(kind, target_id, episode_ids) do
    {:ok, intent} =
      Download.reserve_intent(%{
        kind: kind,
        target_id: target_id,
        episode_ids: episode_ids,
        protocol: :torrent,
        release: release("Stored.Release.1080p-GRP")
      })

    break_payload(intent)
  end

  defp break_payload(intent),
    do: intent |> Intent.changeset(%{release: %{"title" => "broken"}}) |> Repo.update!()

  defp release(title),
    do: %Release{title: title, download_url: "magnet:?xt=urn:btih:#{title}", protocol: :torrent}

  defp indexer_result(title),
    do: %{title: title, size: 2_000_000_000, download_url: "magnet:?x", seeders: 10}

  defp monitored_book_target do
    {:ok, profile} =
      Catalog.create_profile(%{
        name: "Ebooks",
        kind: :ebook,
        handling: :standard,
        library_path: "/tmp/cinder-books-1449"
      })

    {:ok, work} =
      Books.upsert_work(%{
        title: "The Dispossessed",
        identifier: %{provider: "openlibrary", kind: "work", foreign_id: "1449"}
      })

    {:ok, %BookTarget{} = target} = Books.monitor_target(work, :ebook, profile)
    target
  end
end
