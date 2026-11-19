defmodule Cinder.Download.PermanentSubmissionErrorsTest do
  @moduledoc """
  What each of `Cinder.Download.permanent_submission_errors/0` does to a movie, a TV episode, a
  season pack, an anime episode and a book target, through the path each poller takes: the
  download intent submits the release and `abandon_reserved/2` drops the reservation, holding a
  book target or blocking a TV release first; then the movie or TV poller's own failure handling
  runs (#1449, #1492).

  A reason the client returns on `add` reaches the movie and TV pollers on a fresh grab from their
  search pass. `:invalid_intent_release` comes only from an intent stored on an earlier tick whose
  saved download link `Download` cannot read back, so its cells start from such an intent (its
  stored release holds no link ciphertext) and the poller's pending-intent pass submits it. A book
  target has no search pass, so each of its cells starts from a stored intent that `BookPoller`'s
  pending-intent pass submits.
  """
  use Cinder.DataCase, async: false

  import Ecto.Query
  import Mox
  import Cinder.CatalogFixtures
  import Cinder.PollerHelpers, only: [stub_clean_content: 0]

  alias Cinder.Acquisition.Release
  alias Cinder.Books
  alias Cinder.Books.BookTarget
  alias Cinder.Catalog
  alias Cinder.Catalog.{BlockedRelease, Episode, Movie}
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

  # For each reason the client returns: the searching movie parks at once; a book target is held
  # with the reason. A TV episode, a season pack and an anime episode each run two polls: each poll
  # spends one search attempt and blocks the refused release for the series under the reason, so
  # the second poll adds the other release and the episodes stay wanted (#1492). A stored intent
  # whose link cannot be read back is dropped by the movie and TV pending-intent pass, and the
  # search pass that follows grabs the release its search finds (one add), so neither the movie nor
  # the episodes record a failure or a block (#1491).
  @episode_first "Show.S01E01.1080p.WEB-DL-GRP"
  @episode_second "Show.S01E01.1080p.WEB-DL-OTHER"
  @pack_first "Show.S01.1080p.WEB-DL-GRP"
  @pack_second "Show.S01.1080p.WEB-DL-OTHER"
  @anime_first "[GRP] Show S01E01 [1080p]"
  @anime_second "[OTHER] Show S01E01 [1080p]"

  @expected (for reason <- [:unsupported_download_url, :bad_torrent, :add_rejected], into: %{} do
               code = to_string(reason)

               {reason,
                %{
                  movie: %{status: :search_failed, search_attempts: 0, adds: 1},
                  episode: %{
                    states: [:wanted],
                    search_attempts: [2],
                    added: [@episode_first, @episode_second],
                    blocked: [{@episode_first, code}, {@episode_second, code}]
                  },
                  season_pack: %{
                    states: [:wanted, :wanted],
                    search_attempts: [2, 2],
                    added: [@pack_first, @pack_second],
                    blocked: [{@pack_first, code}, {@pack_second, code}]
                  },
                  anime_episode: %{
                    states: [:wanted],
                    search_attempts: [2],
                    added: [@anime_first, @anime_second],
                    blocked: [{@anime_first, code}, {@anime_second, code}]
                  },
                  book_target: %{status: :held, hold_reason: code, adds: 1}
                }}
             end)
            |> Map.put(:invalid_intent_release, %{
              movie: %{status: :downloading, search_attempts: 0, adds: 1},
              episode: %{
                states: [:downloading],
                search_attempts: [0],
                added: [@episode_first],
                blocked: []
              },
              season_pack: %{
                states: [:downloading, :downloading],
                search_attempts: [0, 0],
                added: [@pack_first],
                blocked: []
              },
              anime_episode: %{
                states: [:downloading],
                search_attempts: [0],
                added: [@anime_first],
                blocked: []
              },
              book_target: %{status: :held, hold_reason: "invalid_intent_release", adds: 0}
            })

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

  # A client error that is not permanent keeps the stored intent, and the TV pending-intent pass
  # submits the same release again once its retry is due: nothing is blocked (#1492).
  test "episode on a transient client error retries the same release" do
    %{series: series, episode_ids: [id]} = wanted_episodes([1])

    stub(Cinder.Acquisition.IndexerMock, :search_tv, fn 99, "Show", 1 ->
      {:ok, [indexer_result(@episode_first, 20), indexer_result(@episode_second, 10)]}
    end)

    stub_client(:timeout, "hash-transient")
    start_supervised!({TvPoller, interval: 60_000, search_retry_after: 0})
    assert :ok = TvPoller.poll()

    assert [%Intent{} = intent] = Repo.all(Intent)
    intent |> Intent.changeset(%{next_attempt_at: DateTime.utc_now(:second)}) |> Repo.update!()
    assert :ok = TvPoller.poll()

    assert added() == [@episode_first, @episode_first]
    assert blocked(series.id) == []
    assert %Episode{grab_id: nil} = Repo.get!(Episode, id)
  end

  # A refusal for good on a stored intent's retry blocks the release too, so the search pass of the
  # same poll picks the other one (#1492).
  test "episode on a permanent refusal after a transient one blocks the release on the retry" do
    %{series: series, episode_ids: [id]} = wanted_episodes([1])

    stub(Cinder.Acquisition.IndexerMock, :search_tv, fn 99, "Show", 1 ->
      {:ok, [indexer_result(@episode_first, 20), indexer_result(@episode_second, 10)]}
    end)

    test_pid = self()
    {:ok, calls} = Agent.start_link(fn -> 0 end)
    stub(Cinder.Download.ClientMock, :find_by_operation_key, fn _key -> :not_found end)
    stub(Cinder.Download.ClientMock, :status, fn _id -> {:ok, %{state: :downloading}} end)

    stub(Cinder.Download.ClientMock, :add, fn release, _opts ->
      send(test_pid, {:add, release.title})

      case {release.title, Agent.get_and_update(calls, &{&1, &1 + 1})} do
        {@episode_first, 0} -> {:error, :timeout}
        {@episode_first, _} -> {:error, :bad_torrent}
        {@episode_second, _} -> {:ok, "hash-second"}
      end
    end)

    start_supervised!({TvPoller, interval: 60_000, search_retry_after: 0})
    assert :ok = TvPoller.poll()

    assert [%Intent{} = intent] = Repo.all(Intent)
    intent |> Intent.changeset(%{next_attempt_at: DateTime.utc_now(:second)}) |> Repo.update!()
    assert :ok = TvPoller.poll()

    assert added() == [@episode_first, @episode_first, @episode_second]
    assert blocked(series.id) == [{@episode_first, "bad_torrent"}]
    assert Catalog.episode_state(Repo.get!(Episode, id)) == :downloading
  end

  # A release the operator picked by hand is not blocked when the client refuses it (#1492).
  test "an operator-picked episode release the client refuses for good is not blocked" do
    %{series: series, episode_ids: ids} = wanted_episodes([1])
    stub_client(:bad_torrent, "hash-manual")

    assert {:error, :bad_torrent} =
             Download.grab_episodes(release(@episode_first), ids, operator_initiated: true)

    assert added() == [@episode_first]
    assert blocked(series.id) == []
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

  # --- TV episode, season pack and anime episode ---------------------------------------------------

  # The indexer offers two releases that cover the wanted episodes, the first with more seeders, so
  # a search picks it while it is not blocked.
  defp outcome(:episode, reason),
    do: tv_outcome(reason, :episode, :standard, [1], [@episode_first, @episode_second])

  defp outcome(:season_pack, reason),
    do: tv_outcome(reason, :season_pack, :standard, [1, 2], [@pack_first, @pack_second])

  defp outcome(:anime_episode, reason),
    do: tv_outcome(reason, :episode, :anime, [1], [@anime_first, @anime_second])

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

  # --- TV helpers ----------------------------------------------------------------------------------

  defp tv_outcome(reason, kind, media_profile, numbers, [first, second]) do
    %{series: series, episode_ids: ids} = wanted_episodes(numbers, media_profile)
    if from_stored_intent?(reason), do: store_broken_intent(kind, hd(ids), ids)
    results = [indexer_result(first, 20), indexer_result(second, 10)]

    stub(Cinder.Acquisition.IndexerMock, :search_tv, fn 99, _title, 1 -> {:ok, results} end)
    stub(Cinder.Acquisition.IndexerMock, :search_tv_query, fn _query, _opts -> {:ok, results} end)

    stub_client(reason, "hash-#{kind}")
    start_supervised!({TvPoller, interval: 60_000, search_retry_after: 0})
    assert :ok = TvPoller.poll()
    assert :ok = TvPoller.poll()

    episodes = Enum.map(ids, &Repo.get!(Episode, &1))

    %{
      states: Enum.map(episodes, &Catalog.episode_state/1),
      search_attempts: Enum.map(episodes, & &1.search_attempts),
      added: added(),
      blocked: blocked(series.id)
    }
  end

  defp wanted_episodes(numbers, media_profile \\ :standard) do
    series =
      series_fixture(%{tvdb_id: 99, monitor_strategy: :all, media_profile: media_profile})

    season = season_fixture(series)
    ids = Enum.map(numbers, &episode_fixture(season, %{episode_number: &1}).id)
    %{series: series, episode_ids: ids}
  end

  defp blocked(series_id),
    do:
      Repo.all(
        from b in BlockedRelease,
          where: b.series_id == ^series_id,
          order_by: b.id,
          select: {b.release_title, b.reason}
      )

  # --- helpers -------------------------------------------------------------------------------------

  # Every `add` reports to the test, so a cell whose poller never reached the client (a raise that
  # the poller's `isolate/2` only logs) shows `adds: 0` instead of passing on an untouched row. A
  # client reason fails every `add`. A stored intent with an unreadable link never reaches `add`,
  # and the client accepts the release the search pass grabs after it.
  defp stub_client(reason, remote_id) do
    test_pid = self()
    stub(Cinder.Download.ClientMock, :find_by_operation_key, fn _key -> :not_found end)

    stub(Cinder.Download.ClientMock, :add, fn release, _opts ->
      send(test_pid, {:add, release.title})
      if from_stored_intent?(reason), do: {:ok, remote_id}, else: {:error, reason}
    end)

    stub(Cinder.Download.ClientMock, :status, fn _id -> {:ok, %{state: :downloading}} end)
  end

  defp adds, do: length(added())

  # The release titles the client was asked to add, in order.
  defp added, do: collect_added([])

  defp collect_added(titles) do
    receive do
      {:add, title} -> collect_added([title | titles])
    after
      0 -> Enum.reverse(titles)
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

  defp indexer_result(title, seeders \\ 10),
    do: %{title: title, size: 2_000_000_000, download_url: "magnet:?#{title}", seeders: seeders}

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
