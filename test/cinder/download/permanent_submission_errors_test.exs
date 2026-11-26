defmodule Cinder.Download.PermanentSubmissionErrorsTest do
  @moduledoc """
  What each of `Cinder.Download.permanent_submission_errors/0` does to a movie, a TV episode, a
  season pack, an anime episode and a book target, through the path each poller takes: the
  download intent submits the release and `abandon_reserved/2` drops the reservation, holding a
  book target or blocking a TV release first; then the movie or TV poller's own failure handling
  runs (#1449, #1492).

  A reason the client returns on `add` reaches `abandon_reserved/2` on a fresh grab from the movie
  or TV search pass, and on a stored intent's retry from either poller's pending-intent pass. Such
  a reason on a retry from the pending-intent pass never reaches the poller's own failure
  handling: a movie's is dropped (the `stored_movie_intent` cells), and a TV retry's is dropped
  once `abandon_reserved/2` tries to block a release the search pass picked (the episode retry
  tests below the table). `:invalid_intent_release` comes from a stored intent whose saved
  download link `Download` cannot read back, so its cells start from such an intent (its stored
  release holds no link ciphertext) and the poller's pending-intent pass submits it. A book target
  has no search pass, so each of its cells starts from a stored intent that `BookPoller`'s
  pending-intent pass submits.

  The movie poller's search pass reaches a stored intent itself when the pending-intent pass
  stopped short on a raise or the intent's retry came due after that pass ran. The tests in the
  "a stored movie intent the search pass reaches" block start from one or the other: a link that
  cannot be read back goes on to a fresh search and grab, and a reason the client returns parks
  the movie on the stored release's add (#1564).
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
  # the episodes record a failure or a block (#1491). A movie whose first add fails with a transient
  # error keeps its intent; when the client refuses that intent's release for good on the next
  # poll, the pending-intent pass drops it without parking the movie, the search pass of the same
  # poll adds the release its search finds, and that refusal parks the movie (#1491).
  @movie_stored "Inception.2010.1080p.WEB-DL-STORED"
  @movie_found "Inception.2010.1080p.BluRay.x264-GRP"
  @episode_first "Show.S01E01.1080p.WEB-DL-GRP"
  @episode_second "Show.S01E01.1080p.WEB-DL-OTHER"
  @pack_first "Show.S01.1080p.WEB-DL-GRP"
  @pack_second "Show.S01.1080p.WEB-DL-OTHER"
  @anime_first "[GRP] Show S01E01 [1080p]"
  @anime_second "[OTHER] Show S01E01 [1080p]"

  @expected (for reason <- [
                   :unsupported_download_url,
                   :bad_torrent,
                   :add_rejected,
                   :bad_download_file
                 ],
                 into: %{} do
               code = to_string(reason)

               {reason,
                %{
                  movie: %{status: :search_failed, search_attempts: 0, adds: 1},
                  stored_movie_intent: %{
                    status: :search_failed,
                    search_attempts: 1,
                    added: [@movie_stored, @movie_stored, @movie_found],
                    intents: 0
                  },
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

  # The search pass, not the pending-intent pass, reaches a movie's stored intent when that pass
  # stopped short or the intent's retry came due after it ran. A stored link that cannot be read
  # back then goes on to a fresh search and grab in the same `Download.start/1` call, as the
  # pending-intent pass lets the search pass do (#1564).
  describe "a stored movie intent the search pass reaches" do
    @alpha_stored "A.Stored"
    @bravo_stored "B.Stored"
    @bravo_found "Bravo.2010.1080p.WEB-DL-GRP"

    test "whose link cannot be read back grabs a fresh release after the pending pass stopped" do
      bravo = interrupted_pending_pass(:unreadable)
      stub_movie_search()
      stub_add(fn _title -> {:ok, "hash-#{System.unique_integer([:positive])}"} end)

      start_supervised!({Poller, interval: 60_000, search_retry_after: 0})
      assert :ok = Poller.poll()

      assert movie_state(bravo.id) == %{status: :downloading, search_attempts: 0}
      assert added() == [@alpha_stored, @bravo_found]
      assert_received {:search, "tt0000002"}
      refute_received {:search, "tt0000001"}
      assert Repo.aggregate(Intent, :count) == 0
    end

    # The intent waits out a retry delay when the pending-intent pass runs. A downloading movie's
    # client `status` call, between the two passes, makes it due.
    test "whose link cannot be read back grabs a fresh release once its retry comes due mid-poll" do
      bravo = searching_movie("Bravo", "tt0000002")
      later = DateTime.add(DateTime.utc_now(:second), 3600)
      intent = bravo.id |> stored_movie_intent(@bravo_stored, later) |> break_payload()
      movie_fixture(%{title: "Charlie", status: :downloading, download_id: "hash-charlie"})

      stub_movie_search()
      stub_find_by_operation_key(fn _call -> :not_found end)
      stub_add(fn _title -> {:ok, "hash-bravo"} end)

      stub(Cinder.Download.ClientMock, :status, fn "hash-charlie" ->
        make_due(intent)
        {:ok, %{state: :downloading}}
      end)

      start_supervised!({Poller, interval: 60_000, search_retry_after: 0})
      assert :ok = Poller.poll()

      assert movie_state(bravo.id) == %{status: :downloading, search_attempts: 0}
      assert added() == [@bravo_found]
      assert Repo.aggregate(Intent, :count) == 0
    end

    # The fall-through runs once per call: when the fresh grab's own link cannot be read back
    # either, that error parks the movie as before. The vault's key changes between the fresh
    # link's encryption and its decryption, at the fresh intent's lookup (the third: the first is
    # the pending pass's, the second the stored intent's in the search pass). Each search puts the
    # key back before its grab encrypts, so a second fresh grab would add its release.
    test "parks the movie when the fresh grab's own link cannot be read back" do
      bravo = searching_movie("Bravo", "tt0000002")
      bravo.id |> stored_movie_intent(@bravo_stored) |> break_payload()

      vault_config = :sys.get_state(Cinder.Vault)
      on_exit(fn -> put_vault_config(vault_config) end)
      test_pid = self()

      stub(Cinder.Acquisition.IndexerMock, :search, fn "tt0000002" ->
        put_vault_config(vault_config)
        {:ok, [indexer_result(@bravo_found)]}
      end)

      stub_find_by_operation_key(fn
        1 ->
          raise "lookup failed"

        3 ->
          put_vault_config(with_other_key(vault_config))
          send(test_pid, :vault_key_changed)
          :not_found

        _call ->
          :not_found
      end)

      stub_add(fn _title -> {:ok, "hash-bravo"} end)

      start_supervised!({Poller, interval: 60_000, search_retry_after: 0})
      assert :ok = Poller.poll()
      put_vault_config(vault_config)

      assert_received :vault_key_changed
      assert movie_state(bravo.id) == %{status: :search_failed, search_attempts: 0}
      assert added() == []
      assert Repo.aggregate(Intent, :count) == 0
      assert {:ok, "x"} = "x" |> Cinder.Vault.encrypt!() |> Cinder.Vault.decrypt()
    end

    # A client's refusal for good of the stored release (each permanent submission error but
    # `:invalid_intent_release`) parks the movie on that add, with no fresh search, as the fresh
    # add after the pending-intent pass would (#1491). The first test in this block shows the
    # search stub reports each search.
    for reason <- [:unsupported_download_url, :bad_torrent, :add_rejected] do
      @reason reason

      test "whose release the client refuses with #{reason} parks the movie with no fresh search" do
        bravo = interrupted_pending_pass(:readable)
        stub_movie_search()
        stub_add(fn _title -> {:error, @reason} end)

        start_supervised!({Poller, interval: 60_000, search_retry_after: 0})
        assert :ok = Poller.poll()

        assert movie_state(bravo.id) == %{status: :search_failed, search_attempts: 0}
        assert added() == [@alpha_stored, @bravo_stored]
        refute_received {:search, _imdb_id}
        assert Repo.aggregate(Intent, :count) == 0
      end
    end
  end

  # --- movie ---------------------------------------------------------------------------------------

  defp outcome(:movie, reason) do
    prepare =
      if unreadable_intent?(reason),
        do: &store_broken_intent(:movie, &1, []),
        else: fn _movie_id -> :ok end

    %{status: status, search_attempts: attempts} = movie_outcome(reason, prepare)
    %{status: status, search_attempts: attempts, adds: adds()}
  end

  # A first poll's add fails with a transient error and stores the intent. On the second poll the
  # pending-intent pass submits that intent's release before the search pass runs.
  defp outcome(:stored_movie_intent, reason) do
    %{status: status, search_attempts: attempts} =
      movie_outcome(reason, &poll_transient_failure/1)

    %{
      status: status,
      search_attempts: attempts,
      added: added(),
      intents: Repo.aggregate(Intent, :count)
    }
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

    if unreadable_intent?(reason), do: break_payload(intent)

    stub_client(reason, "hash-book")
    start_supervised!({BookPoller, interval: 60_000})
    assert :ok = BookPoller.poll()

    %BookTarget{status: status, hold_reason: hold_reason} = Repo.get!(BookTarget, target.id)
    %{status: status, hold_reason: hold_reason, adds: adds()}
  end

  # --- movie helpers -------------------------------------------------------------------------------

  # A poll of a requested movie whose search finds `@movie_found`. `prepare` runs once the poller
  # has started and before that poll, to set up what an earlier poll left for the movie.
  defp movie_outcome(reason, prepare) do
    {:ok, movie} = Catalog.add_movie(%{tmdb_id: 900, title: "Inception", imdb_id: "tt1375666"})
    start_supervised!({Poller, interval: 60_000, search_retry_after: 0})
    prepare.(movie.id)

    stub(Cinder.Acquisition.IndexerMock, :search, fn "tt1375666" ->
      {:ok, [indexer_result(@movie_found)]}
    end)

    stub_client(reason, "hash-movie")
    assert :ok = Poller.poll()

    Repo.get!(Movie, movie.id)
  end

  # A poll whose search finds `@movie_stored` and whose add the client fails with a transient
  # error: the search pass counts one search attempt and keeps the intent for a retry, which this
  # helper then makes due.
  defp poll_transient_failure(_movie_id) do
    test_pid = self()

    stub(Cinder.Acquisition.IndexerMock, :search, fn "tt1375666" ->
      {:ok, [indexer_result(@movie_stored)]}
    end)

    stub(Cinder.Download.ClientMock, :find_by_operation_key, fn _key -> :not_found end)

    stub(Cinder.Download.ClientMock, :add, fn release, _opts ->
      send(test_pid, {:add, release.title})
      {:error, :timeout}
    end)

    assert :ok = Poller.poll()

    assert [%Intent{attempt_count: 1} = intent] = Repo.all(Intent)
    intent |> Intent.changeset(%{next_attempt_at: DateTime.utc_now(:second)}) |> Repo.update!()
  end

  defp searching_movie(title, imdb_id),
    do: movie_fixture(%{title: title, imdb_id: imdb_id, status: :searching})

  # An intent reserved for `movie_id` and seeded as if an earlier add had failed with a transient
  # error: `attempt_count: 1`, the retry due at `next_attempt_at`. A real transient failure would
  # also have counted one search attempt on the movie; these movies start at none.
  defp stored_movie_intent(movie_id, title, next_attempt_at \\ DateTime.utc_now(:second)) do
    {:ok, intent} =
      Download.reserve_intent(%{
        kind: :movie,
        target_id: movie_id,
        episode_ids: [],
        protocol: :torrent,
        release: release(title)
      })

    intent
    |> Intent.changeset(%{attempt_count: 1, next_attempt_at: next_attempt_at})
    |> Repo.update!()
  end

  defp make_due(intent) do
    Intent
    |> Repo.get!(intent.id)
    |> Intent.changeset(%{next_attempt_at: DateTime.utc_now(:second)})
    |> Repo.update!()
  end

  # Alpha and Bravo, both searching, each with a due stored intent, Bravo's link `:readable` or
  # `:unreadable`. The first lookup, Alpha's in the pending-intent pass, raises, and the poller's
  # `isolate/2` ends that pass there, so the search pass reaches Bravo's intent. Returns Bravo.
  defp interrupted_pending_pass(bravo_link) do
    alpha = searching_movie("Alpha", "tt0000001")
    bravo = searching_movie("Bravo", "tt0000002")
    stored_movie_intent(alpha.id, @alpha_stored)
    intent = stored_movie_intent(bravo.id, @bravo_stored)
    if bravo_link == :unreadable, do: break_payload(intent)
    stub_find_by_operation_key(&raise_on_first_call/1)
    bravo
  end

  # Each search reports its IMDb id to the test. Only Bravo's finds a release.
  defp stub_movie_search do
    test_pid = self()

    stub(Cinder.Acquisition.IndexerMock, :search, fn imdb_id ->
      send(test_pid, {:search, imdb_id})
      if imdb_id == "tt0000002", do: {:ok, [indexer_result(@bravo_found)]}, else: {:ok, []}
    end)
  end

  # `answer` gets the call's number, counted from 1 across every intent's lookup.
  defp stub_find_by_operation_key(answer) do
    calls = :counters.new(1, [])

    stub(Cinder.Download.ClientMock, :find_by_operation_key, fn _key ->
      :counters.add(calls, 1, 1)
      answer.(:counters.get(calls, 1))
    end)
  end

  defp raise_on_first_call(1), do: raise("lookup failed")
  defp raise_on_first_call(_call), do: :not_found

  defp stub_add(answer) do
    test_pid = self()

    stub(Cinder.Download.ClientMock, :add, fn release, _opts ->
      send(test_pid, {:add, release.title})
      answer.(release.title)
    end)

    stub(Cinder.Download.ClientMock, :status, fn _id -> {:ok, %{state: :downloading}} end)
  end

  defp movie_state(movie_id) do
    %Movie{status: status, search_attempts: attempts} = Repo.get!(Movie, movie_id)
    %{status: status, search_attempts: attempts}
  end

  defp put_vault_config(config) do
    :sys.replace_state(Cinder.Vault, fn _config -> config end)
    :ok = GenServer.call(Cinder.Vault, :save_config)
  end

  defp with_other_key(config) do
    Keyword.update!(config, :ciphers, fn ciphers ->
      Keyword.update!(ciphers, :default, fn {cipher, opts} ->
        {cipher, Keyword.put(opts, :key, :crypto.strong_rand_bytes(32))}
      end)
    end)
  end

  # --- TV helpers ----------------------------------------------------------------------------------

  defp tv_outcome(reason, kind, media_profile, numbers, [first, second]) do
    %{series: series, episode_ids: ids} = wanted_episodes(numbers, media_profile)
    if unreadable_intent?(reason), do: store_broken_intent(kind, hd(ids), ids)
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
      if unreadable_intent?(reason), do: {:ok, remote_id}, else: {:error, reason}
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

  # The one reason no client returns: it comes from the stored intent itself, so its cells set up an
  # intent whose link cannot be read back, and the client accepts every `add`.
  defp unreadable_intent?(reason), do: reason == :invalid_intent_release

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
