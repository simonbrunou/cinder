defmodule Cinder.Download.GrabRetryTest do
  @moduledoc """
  How a reserved grab retries a fetch failure the download check keeps (#1658,
  `Cinder.Download.GrabFailure.retry_class/1`): an indexer limit waits with no attempt counted and
  no strike, a capped failure drops the grab at its fifth attempt with no block row, and any other
  failure retries with no cap.

  Each test selects the Prowlarr source, whose `fetch_download/3` is `Fetch.bytes/3`. Most
  `ClientMock.add/2` stubs fetch the link through the `fetch:` function they get, against a
  `Req.Test` plug that answers as the test's indexer. The TV sweep tests search through the mock
  source, whose client returns the answer with no fetch. The cleanup test and the two tests of a
  limit on an intent that became a cleanup or was deleted during the add fetch nothing either.
  """
  use Cinder.DataCase, async: false

  import Ecto.Query
  import Mox
  import Cinder.CatalogFixtures
  import Cinder.PollerHelpers, only: [stub_clean_content: 0]

  alias Cinder.Acquisition.{EbookRelease, IndexerSource, Release}
  alias Cinder.Books
  alias Cinder.Books.{BookBlockedRelease, BookTarget}
  alias Cinder.Catalog
  alias Cinder.Catalog.{BlockedRelease, Episode, Movie}
  alias Cinder.ConfigCase
  alias Cinder.Download
  alias Cinder.Download.Client.Sabnzbd
  alias Cinder.Download.{ClientMock, GrabFailure, Intent, Poller, TvPoller}
  alias Cinder.Repo

  @moduletag :capture_log

  setup :set_mox_global
  setup :verify_on_exit!
  setup {Req.Test, :set_req_test_to_shared}

  setup do
    ConfigCase.put_env(:indexer_source, IndexerSource.Prowlarr)
    stub_clean_content()
  end

  # Prowlarr's base URL in the test config: a link on it records it as the link's origin.
  @origin "http://prowlarr:9696"
  @link "http://prowlarr:9696/1/download"

  describe "an indexer limit" do
    test "HTTP 429 with Retry-After: 600 waits 10 min with no attempt and no strike" do
      {:movie, movie} = target = target(:movie)
      intent = reserve(target)
      fetching_client(limited(600))

      assert :ok = Download.reconcile_pending_intents([:movie])

      assert %Intent{status: :reserved, attempt_count: 0} = waited = Repo.get!(Intent, intent.id)
      assert_in_future(waited.next_attempt_at, 600)
      assert %Movie{status: :searching, search_attempts: 3} = Repo.reload!(movie)
    end

    # The fifth attempt's own delay is 80 s (5 s doubled four times), past the 60 s limit.
    test "an own delay longer than the limit wins" do
      target = target(:movie)
      intent = target |> reserve() |> with_attempts(4)
      fetching_client(limited(60))

      assert :ok = Download.reconcile_pending_intents([:movie])

      assert %Intent{attempt_count: 4} = waited = Repo.get!(Intent, intent.id)
      assert_in_future(waited.next_attempt_at, 80)
    end

    for code <- [500, 501] do
      @code code

      test "Newznab error #{code} whose description holds \"limit\" waits the default hour" do
        {:movie, movie} = target = target(:movie)
        intent = reserve(target)
        fetching_client(newznab_error(@code, "Request Limit reached"))

        assert :ok = Download.reconcile_pending_intents([:movie])

        assert %Intent{attempt_count: 0} = waited = Repo.get!(Intent, intent.id)
        assert_in_future(waited.next_attempt_at, 3600)
        assert Repo.reload!(movie).search_attempts == 3
      end
    end

    test "Newznab error 500 without \"limit\" is a capped retry with a strike" do
      {:movie, movie} = target = target(:movie)
      intent = reserve(target)
      fetching_client(newznab_error(500, "Internal error"))

      assert :ok = Download.reconcile_pending_intents([:movie])

      assert %Intent{attempt_count: 1, last_error: "{:indexer_error, 500}"} =
               Repo.get!(Intent, intent.id)

      assert Repo.reload!(movie).search_attempts == 4
    end

    test "the movie poller's search pass takes no strike for it" do
      movie = searching_movie("tt1658001", 0)
      stub_search(title(:movie))
      fetching_client(limited(600))

      poll_movies(0)

      assert %Movie{status: :searching, search_attempts: 0} = Repo.reload!(movie)
      assert [%Intent{attempt_count: 0}] = Repo.all(Intent)
    end

    # The TV search reads the mock source, so the client returns the limit itself. The wait's log
    # line names the episodes, never the indexer's release title.
    test "the TV sweep spends no search attempt for it" do
      {:episode, %{episodes: [episode]}} = target(:episode)
      mock_tv_search(title(:episode))
      answering_client({:error, {:indexer_limit, DateTime.add(DateTime.utc_now(:second), 600)}})

      # The suite's Logger level is :warning; the module level lets this :info line through.
      Logger.put_module_level(TvPoller, :info)
      on_exit(fn -> Logger.delete_module_level(TvPoller) end)
      log = ExUnit.CaptureLog.capture_log([level: :info], &poll_tv/0)

      assert log =~ "tv grab of episodes [#{episode.id}] waits"
      refute log =~ title(:episode)
      assert Repo.reload!(episode).search_attempts == 0
      assert [%Intent{attempt_count: 0}] = Repo.all(Intent)
    end

    # A cancel that turns the intent into a cleanup while the add runs owns the row from then on.
    test "a limit leaves an intent that became a cleanup during the add as it is" do
      intent = reserve(target(:movie))
      until = DateTime.add(DateTime.utc_now(:second), 600)

      stub(ClientMock, :add, fn _release, _opts ->
        {1, _} =
          Repo.update_all(from(i in Intent, where: i.id == ^intent.id),
            set: [status: :cleanup_pending, remote_id: "hash-cancelled"]
          )

        {:error, {:indexer_limit, until}}
      end)

      stub(ClientMock, :find_by_operation_key, fn _key -> :not_found end)

      assert {:error, {:indexer_limit, ^until}} = Download.reconcile_intent(intent)

      assert %Intent{status: :cleanup_pending, next_attempt_at: nil, last_error: nil} =
               Repo.get!(Intent, intent.id)
    end

    test "a limit on an intent deleted during the add writes nothing" do
      intent = reserve(target(:movie))
      until = DateTime.add(DateTime.utc_now(:second), 600)

      stub(ClientMock, :add, fn _release, _opts ->
        Repo.delete!(intent)
        {:error, {:indexer_limit, until}}
      end)

      stub(ClientMock, :find_by_operation_key, fn _key -> :not_found end)

      assert {:error, {:indexer_limit, ^until}} = Download.reconcile_intent(intent)
      assert Repo.get(Intent, intent.id) == nil
    end
  end

  describe "a capped failure" do
    test "the cap is 5" do
      assert GrabFailure.retry_cap() == 5
    end

    test "a movie takes a strike per attempt and is dropped at the fifth with no block row" do
      {:ok, movie} =
        seed_movie_state(movie_fixture(%{imdb_id: "tt1658002"}), %{
          status: :searching,
          search_attempts: 0
        })

      intent = reserve({:movie, movie})
      fetching_client(&Plug.Conn.send_resp(&1, 503, "busy"))

      for attempt <- 1..4 do
        assert :ok = Download.reconcile_pending_intents([:movie])
        assert %Intent{attempt_count: ^attempt} = Repo.get!(Intent, intent.id)
        assert Repo.reload!(movie).search_attempts == attempt
        due!(intent)
      end

      assert :ok = Download.reconcile_pending_intents([:movie])

      assert Repo.get(Intent, intent.id) == nil
      assert %Movie{status: :searching, search_attempts: 5} = Repo.reload!(movie)
      assert Repo.all(from b in BlockedRelease, where: b.movie_id == ^movie.id) == []
    end

    # The search pass's own write-back reads the strike the intent's retry took; the fifth
    # attempt's drop answers :grab_retries_exhausted, which the search pass skips.
    test "the movie poller counts each attempt once, the fifth included" do
      movie = searching_movie("tt1658003", 0)
      stub_search(title(:movie))
      fetching_client(&Plug.Conn.send_resp(&1, 503, "busy"))

      poll_movies(3600)
      assert Repo.reload!(movie).search_attempts == 1

      for attempts <- 2..5 do
        Intent |> Repo.one!() |> due!()
        assert :ok = Poller.poll()
        assert Repo.reload!(movie).search_attempts == attempts
      end

      assert Repo.all(Intent) == []
      assert Repo.reload!(movie).status == :searching
    end

    # The pending pass stops on its lookup's raise, so the search pass reaches the stored intent
    # and its fifth attempt: one strike, taken with the drop, and none from the search pass.
    test "the search pass that reaches the fifth attempt counts it once" do
      movie = searching_movie("tt1658004", 4)
      intent = {:movie, movie} |> reserve() |> with_attempts(4)
      fetching_client(&Plug.Conn.send_resp(&1, 503, "busy"))
      calls = :counters.new(1, [])

      stub(ClientMock, :find_by_operation_key, fn _key ->
        :counters.add(calls, 1, 1)
        if :counters.get(calls, 1) == 1, do: raise("lookup failed"), else: :not_found
      end)

      poll_movies(0)

      assert Repo.get(Intent, intent.id) == nil
      assert %Movie{status: :searching, search_attempts: 5} = Repo.reload!(movie)
      assert :counters.get(calls, 1) == 2
    end

    test "an episode intent is dropped at the fifth with no block row, and its episode searches again" do
      {:episode, %{series: series, episodes: [episode]}} = target = target(:episode)
      intent = reserve(target)
      fetching_client(&Plug.Conn.send_resp(&1, 503, "busy"))

      for attempt <- 1..4 do
        assert :ok = Download.reconcile_pending_intents([:episode])
        assert %Intent{attempt_count: ^attempt} = Repo.get!(Intent, intent.id)
        due!(intent)
      end

      assert :ok = Download.reconcile_pending_intents([:episode])

      assert Repo.get(Intent, intent.id) == nil
      assert blocked(series.id) == []
      assert %Episode{grab_id: nil, search_attempts: 0} = Repo.reload!(episode)

      mock_tv_search(title(:episode))
      answering_client({:ok, "remote-1"})
      poll_tv()

      assert_received {:added, @link}
    end

    test "a book target at the cap is held under grab_retries_exhausted with no block row" do
      {:book_target, book} = target = target(:book_target)
      intent = target |> reserve() |> with_attempts(4)
      fetching_client(&Plug.Conn.send_resp(&1, 503, "busy"))

      assert :ok = Download.reconcile_pending_intents([:book_target])

      assert Repo.get(Intent, intent.id) == nil

      assert %BookTarget{status: :held, hold_reason: "grab_retries_exhausted"} =
               Repo.reload!(book)

      assert book_blocks(book.id) == []
    end

    test "a redirect from an https source to http is capped" do
      {:movie, movie} = target = target(:movie)

      intent =
        target
        |> reserve("https://indexer.example/dl/1.torrent", "https://indexer.example")
        |> with_attempts(4)

      fetching_client(plug(:downgrade))

      assert :ok = Download.reconcile_pending_intents([:movie])

      assert Repo.get(Intent, intent.id) == nil
      assert Repo.reload!(movie).search_attempts == 4
    end

    # Each answer, at the fourth attempt, drops the grab at the fifth.
    for {name, plug} <- [
          {"another 4xx", :not_found},
          {"a Newznab error 900", :error_900},
          {"a Newznab error 500 without \"limit\"", :error_500},
          {"a 429 that says the indexer is disabled", :disabled},
          {"an HTML page", :challenge},
          {"a redirect loop", :redirect_loop}
        ] do
      @plug plug

      test "#{name} is capped" do
        {:movie, movie} = target = target(:movie)
        intent = target |> reserve() |> with_attempts(4)
        fetching_client(plug(@plug))

        assert :ok = Download.reconcile_pending_intents([:movie])

        assert Repo.get(Intent, intent.id) == nil
        assert Repo.reload!(movie).search_attempts == 4
      end
    end

    # A cancel that turns the intent into a cleanup while the add runs owns the row from then on,
    # so the attempt that reaches the cap neither deletes it nor holds the book target.
    for kind <- [:episode, :book_target] do
      @kind kind

      test "the fifth attempt leaves a #{kind} intent that became a cleanup during the add as it is" do
        {_kind, owner} = target = target(@kind)
        intent = target |> reserve() |> with_attempts(4)

        stub(ClientMock, :add, fn _release, _opts ->
          {1, _} =
            Repo.update_all(from(i in Intent, where: i.id == ^intent.id),
              set: [status: :cleanup_pending, remote_id: "hash-cancelled"]
            )

          {:error, {:torrent_fetch_status, 503}}
        end)

        stub(ClientMock, :find_by_operation_key, fn _key -> :not_found end)

        assert {:error, {:torrent_fetch_status, 503}} = Download.reconcile_intent(intent)
        assert %Intent{status: :cleanup_pending} = Repo.get!(Intent, intent.id)

        if @kind == :book_target,
          do: assert(%BookTarget{status: :monitored} = Repo.reload!(owner))
      end
    end

    test "a 429 that says the indexer is disabled takes a strike for a movie" do
      {:movie, movie} = target = target(:movie)
      intent = reserve(target)
      fetching_client(plug(:disabled))

      assert :ok = Download.reconcile_pending_intents([:movie])

      assert %Intent{attempt_count: 1, last_error: ":indexer_disabled"} =
               Repo.get!(Intent, intent.id)

      assert Repo.reload!(movie).search_attempts == 4
    end

    test "earlier uncapped failures count toward the cap" do
      {:episode, _} = target = target(:episode)
      intent = reserve(target)

      fetching_client(&Req.Test.transport_error(&1, :econnrefused))

      for _ <- 1..3 do
        assert :ok = Download.reconcile_pending_intents([:episode])
        due!(intent)
      end

      fetching_client(&Plug.Conn.send_resp(&1, 503, "busy"))
      assert :ok = Download.reconcile_pending_intents([:episode])
      assert %Intent{attempt_count: 4} = Repo.get!(Intent, intent.id)
      due!(intent)

      assert :ok = Download.reconcile_pending_intents([:episode])
      assert Repo.get(Intent, intent.id) == nil
    end
  end

  describe "an uncapped failure" do
    test "retries past the cap" do
      target = target(:episode)
      intent = target |> reserve() |> with_attempts(9)
      fetching_client(&Req.Test.transport_error(&1, :econnrefused))

      assert :ok = Download.reconcile_pending_intents([:episode])

      assert %Intent{status: :reserved, attempt_count: 10} = Repo.get!(Intent, intent.id)
    end

    test "a body past the size cap retries past the cap" do
      {:movie, movie} = target = target(:movie)
      intent = target |> reserve() |> with_attempts(4)
      fetching_client(plug(:too_large))

      assert :ok = Download.reconcile_pending_intents([:movie])

      assert %Intent{status: :reserved, attempt_count: 5, last_error: ":response_too_large"} =
               Repo.get!(Intent, intent.id)

      assert Repo.reload!(movie).search_attempts == 4
    end

    # SABnzbd queued the NZB under a name that carries the operation key, but its reply grew past
    # the client's own size cap. The intent keeps the key, so the next pass finds the job.
    test "a SABnzbd reply past its size cap keeps the intent, and the next pass adopts the job" do
      {:movie, movie} = target(:movie)
      release = %{release(title(:movie), @link, @origin) | protocol: :usenet}
      intent = reserve(:movie, movie.id, [], release) |> with_attempts(4)

      {1, _} =
        Repo.update_all(from(i in Intent, where: i.id == ^intent.id), set: [protocol: :usenet])

      intent = Repo.get!(Intent, intent.id)
      test_pid = self()
      ConfigCase.put_env(:download_clients, %{usenet: Sabnzbd})

      Req.Test.stub(Cinder.SabnzbdStub, fn conn ->
        case {conn.request_path, conn.params["mode"]} do
          {"/1/download", _mode} ->
            Plug.Conn.send_resp(conn, 200, Cinder.NzbFixture.minimal())

          {"/api", "addfile"} ->
            send(test_pid, {:accepted, conn.params["nzbname"]})
            Plug.Conn.send_resp(conn, 200, :binary.copy(" ", 4 * 1024 * 1024 + 1))

          {"/api", mode} when mode in ["queue", "history"] ->
            Req.Test.json(conn, %{mode => %{"slots" => []}})
        end
      end)

      assert {:error, :response_too_large} = Download.reconcile_intent(intent)
      assert_received {:accepted, name}
      assert String.ends_with?(name, ".cinder-" <> intent.operation_key)
      assert %Intent{status: :reserved, attempt_count: 5} = Repo.get!(Intent, intent.id)

      Req.Test.stub(Cinder.SabnzbdStub, fn conn ->
        slots = [%{"filename" => name, "nzo_id" => "nzo-accepted"}]

        case conn.params["mode"] do
          "queue" -> Req.Test.json(conn, %{"queue" => %{"slots" => slots}})
          "history" -> Req.Test.json(conn, %{"history" => %{"slots" => []}})
        end
      end)

      due!(intent)
      Download.reconcile_intent(Repo.get!(Intent, intent.id))

      assert Repo.get(Intent, intent.id) == nil
      assert %Movie{download_id: "nzo-accepted"} = Repo.reload!(movie)
    end

    # A cleanup removes a job the client holds; no fetch runs, and the cap never drops it.
    test "a cleanup intent retries a capped reason at the attempt that would reach the cap" do
      {:movie, movie} = target(:movie)

      intent =
        Repo.insert!(%Intent{
          operation_key: Ecto.UUID.generate(),
          kind: :movie,
          target_id: movie.id,
          protocol: :torrent,
          release: %{"title" => "Old.Release-GRP"},
          status: :cleanup_pending,
          remote_id: "hash-old",
          attempt_count: 4
        })

      stub(ClientMock, :remove, fn "hash-old", _opts -> {:error, :too_many_redirects} end)

      assert {:error, :too_many_redirects} = Download.reconcile_intent(intent)

      assert %Intent{status: :cleanup_pending, attempt_count: 5} = Repo.get!(Intent, intent.id)
    end
  end

  # --- helpers ---------------------------------------------------------------------------------

  defp limited(seconds) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_header("retry-after", Integer.to_string(seconds))
      |> Plug.Conn.send_resp(429, "")
    end
  end

  defp newznab_error(code, description, status \\ 200) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/xml")
      |> Plug.Conn.send_resp(
        status,
        ~s(<?xml version="1.0" encoding="UTF-8"?>\n<error code="#{code}" description="#{description}"/>)
      )
    end
  end

  defp plug(:downgrade) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "http://indexer.example/dl/1.torrent")
      |> Plug.Conn.send_resp(302, "")
    end
  end

  defp plug(:not_found), do: &Plug.Conn.send_resp(&1, 404, "gone")
  defp plug(:error_900), do: newznab_error(900, "Unknown error")
  defp plug(:error_500), do: newznab_error(500, "Internal error")
  defp plug(:challenge), do: &Plug.Conn.send_resp(&1, 200, "<html>Checking your browser</html>")

  defp plug(:redirect_loop),
    do: &(&1 |> Plug.Conn.put_resp_header("location", @link) |> Plug.Conn.send_resp(302, ""))

  # One byte past `fetching_client/1`'s 64 KiB `max_bytes`.
  defp plug(:too_large), do: &Plug.Conn.send_resp(&1, 200, :binary.copy("x", 64 * 1024 + 1))

  defp plug(:disabled),
    do: newznab_error(429, "Indexer is disabled till 2026-11-27 10:00:00", 429)

  # The client holds no job for the intent, and its `add/2` fetches the link through the `fetch:`
  # function it gets, against `plug`, and accepts what the fetch returns as a file.
  defp fetching_client(plug) do
    Req.Test.stub(Cinder.GrabRetryStub, plug)
    stub(ClientMock, :find_by_operation_key, fn _key -> :not_found end)
    stub(ClientMock, :status, fn _id -> {:ok, %{state: :downloading}} end)

    stub(ClientMock, :add, fn release, opts ->
      fetched =
        Keyword.fetch!(opts, :fetch).(release.download_url, release.download_url_origin,
          max_bytes: 64 * 1024,
          error_tag: :torrent_fetch_status,
          plug: {Req.Test, Cinder.GrabRetryStub},
          resolver: fn _host -> {:ok, [{93, 184, 216, 34}]} end
        )

      with {:ok, _bytes} <- fetched, do: {:ok, "remote-#{System.unique_integer([:positive])}"}
    end)
  end

  defp assert_in_future(%DateTime{} = at, seconds) do
    diff = DateTime.diff(at, DateTime.utc_now(:second))
    assert diff in (seconds - 5)..seconds, "next attempt #{diff} s ahead, not #{seconds} s"
  end

  defp due!(intent) do
    {1, _} =
      Repo.update_all(from(i in Intent, where: i.id == ^intent.id),
        set: [next_attempt_at: DateTime.add(DateTime.utc_now(:second), -1, :second)]
      )
  end

  defp with_attempts(intent, count) do
    intent |> Intent.changeset(%{attempt_count: count}) |> Repo.update!()
  end

  defp target(:movie) do
    movie = movie_fixture(%{imdb_id: "tt1658#{System.unique_integer([:positive])}"})
    {:ok, movie} = seed_movie_state(movie, %{status: :searching, search_attempts: 3})
    {:movie, movie}
  end

  defp target(:episode) do
    series = series_fixture(%{tvdb_id: 99, monitor_strategy: :all})
    season = season_fixture(series)
    {:episode, %{series: series, episodes: [episode_fixture(season, %{episode_number: 1})]}}
  end

  defp target(:book_target), do: {:book_target, monitored_book_target()}

  defp searching_movie(imdb_id, attempts) do
    {:ok, movie} =
      seed_movie_state(movie_fixture(%{imdb_id: imdb_id}), %{
        status: :searching,
        search_attempts: attempts
      })

    movie
  end

  defp reserve(target, link \\ @link, origin \\ @origin)

  defp reserve({:movie, movie}, link, origin),
    do: reserve(:movie, movie.id, [], release(title(:movie), link, origin))

  defp reserve({:episode, %{episodes: [episode]}}, link, origin),
    do: reserve(:episode, episode.id, [episode.id], release(title(:episode), link, origin))

  defp reserve({:book_target, target}, link, origin) do
    book = %EbookRelease{
      title: "Le Guin - The Dispossessed (EPUB)",
      download_url: link,
      download_url_origin: origin,
      protocol: :torrent,
      formats: [:epub],
      indexer_source: "prowlarr",
      indexer_id: 7
    }

    reserve(:book_target, target.id, [], Release.from_book(book))
  end

  defp reserve(kind, target_id, episode_ids, release) do
    {:ok, intent} =
      Download.reserve_intent(%{
        kind: kind,
        target_id: target_id,
        episode_ids: episode_ids,
        protocol: :torrent,
        release: release
      })

    intent
  end

  defp release(title, link, origin) do
    %Release{
      title: title,
      download_url: link,
      download_url_origin: origin,
      protocol: :torrent,
      indexer_source: "prowlarr",
      indexer_id: 7
    }
  end

  defp title(:movie), do: "Inception.2010.1080p.WEB-DL-GRP"
  defp title(:episode), do: "Show.S01E01.1080p.WEB-DL-GRP"

  # Prowlarr answers every search with one release whose link is on the indexer's origin.
  defp stub_search(title) do
    Req.Test.stub(Cinder.ProwlarrStub, fn conn ->
      Req.Test.json(conn, [
        %{
          "title" => title,
          "downloadUrl" => @link,
          "protocol" => "torrent",
          "size" => 2_000_000_000,
          "seeders" => 10,
          "indexerId" => 7
        }
      ])
    end)
  end

  # The search reads the mock source, which answers the TV search with one release on Prowlarr.
  defp mock_tv_search(title) do
    ConfigCase.put_env(:indexer_source, Cinder.Acquisition.IndexerMock)
    result = %{title: title, size: 2_000_000_000, download_url: @link, seeders: 10, indexer_id: 7}
    stub(Cinder.Acquisition.IndexerMock, :search_tv, fn 99, _title, 1 -> {:ok, [result]} end)

    stub(Cinder.Acquisition.IndexerMock, :search_tv_query, fn _query, _opts -> {:ok, [result]} end)
  end

  # The client holds no job, and its `add/2` reports its call and returns `answer` with no fetch.
  defp answering_client(answer) do
    test_pid = self()
    stub(ClientMock, :find_by_operation_key, fn _key -> :not_found end)
    stub(ClientMock, :status, fn _id -> {:ok, %{state: :downloading}} end)

    stub(ClientMock, :add, fn release, _opts ->
      send(test_pid, {:added, release.download_url})
      answer
    end)
  end

  defp poll_movies(search_retry_after) do
    on_exit(fn -> :persistent_term.erase({Poller, :last_run}) end)
    start_supervised!({Poller, interval: 60_000, search_retry_after: search_retry_after})
    assert :ok = Poller.poll()
  end

  defp poll_tv do
    on_exit(fn -> :persistent_term.erase({TvPoller, :last_run}) end)
    start_supervised!({TvPoller, interval: 60_000, search_retry_after: 0})
    assert :ok = TvPoller.poll()
  end

  defp blocked(series_id),
    do: Repo.all(from b in BlockedRelease, where: b.series_id == ^series_id, select: b.reason)

  defp book_blocks(target_id),
    do:
      Repo.all(
        from b in BookBlockedRelease, where: b.book_target_id == ^target_id, select: b.reason
      )

  defp monitored_book_target do
    id = Integer.to_string(System.unique_integer([:positive]))

    {:ok, profile} =
      Catalog.create_profile(%{
        name: "Ebooks #{id}",
        kind: :ebook,
        handling: :standard,
        library_path: "/tmp/cinder-books-#{id}"
      })

    {:ok, work} =
      Books.upsert_work(%{
        title: "The Dispossessed #{id}",
        identifier: %{provider: "openlibrary", kind: "work", foreign_id: id}
      })

    {:ok, %BookTarget{} = target} = Books.monitor_target(work, :ebook, profile)
    target
  end
end
