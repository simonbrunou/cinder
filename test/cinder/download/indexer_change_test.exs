defmodule Cinder.Download.IndexerChangeTest do
  @moduledoc """
  A grab reserved through a native indexer that was deleted, whose secrets no longer decrypt, or
  whose credentials changed after the search is dropped as `:indexer_changed` with no fetch, and
  so is a grab whose source is no longer the selected one when its fetch fails (#1656). An
  `:indexer_auth_failed` grab is dropped and counted as a failed grab.

  The `ClientMock.add/2` stub is the fetch stub: a client fetches the link only inside `add/2`
  (`Cinder.Download.Client`), so a grab whose `add/2` never runs made no fetch. Each stub reports
  its call to the test process, and a test of a dropped grab runs `refute_received` on it.
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
  alias Cinder.Catalog.{BlockedRelease, Movie}
  alias Cinder.ConfigCase
  alias Cinder.Download
  alias Cinder.Download.{ClientMock, Intent, Poller, PollerProgress, TvPoller}
  alias Cinder.Indexers
  alias Cinder.Indexers.ConfiguredIndexer
  alias Cinder.Repo
  alias Cinder.TorrentFixture

  @moduletag :capture_log

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    stub_clean_content()
  end

  @link "magnet:?xt=urn:btih:indexer-change"

  # Each condition sets up a native configured indexer and returns the intent's provenance
  # `{indexer_id, credentials_version}`.
  @conditions %{
    "a deleted configured indexer" => :deleted,
    "an older credentials version" => :older,
    "no credentials version" => :missing,
    "secrets that no longer decrypt" => :undecryptable,
    "no indexer id" => :no_id
  }

  describe "the pending pass" do
    for kind <- [:movie, :episode, :season_pack, :book_target],
        {name, condition} <- @conditions do
      @kind kind
      @condition condition

      test "#{kind}: #{name} drops the grab with no add/2, no strike and no block" do
        target = target(@kind)
        provenance = provenance(@condition)
        intent = reserve(target, native_release(target, provenance))
        watch_client()

        assert :ok = Download.reconcile_pending_intents([intent.kind])

        refute_received {:added, _link}
        assert Repo.get(Intent, intent.id) == nil
        assert_dropped(target, "indexer_changed")
      end
    end

    for kind <- [:movie, :episode, :season_pack, :book_target] do
      @kind kind

      test "#{kind}: a disabled configured indexer at the current version reaches add/2" do
        target = target(@kind)
        row = indexer!(enabled: false)
        intent = reserve(target, native_release(target, {row.id, row.credentials_version}))
        watch_client()

        assert :ok = Download.reconcile_pending_intents([intent.kind])

        assert_received {:added, @link}
        assert Repo.get(Intent, intent.id) == nil
      end
    end
  end

  describe "a movie whose indexer changed" do
    # One strike short of the budget: a strike would park it at :search_failed.
    test "takes no strike when the poller's own search grabs it" do
      movie = poller_movie("tt1656001", 9)
      deleted = provenance(:deleted)
      stub_movie_search("tt1656001", [native_result(title(:movie), deleted)])
      watch_client()

      poll_movies()

      refute_received {:added, _link}
      assert %Movie{status: :searching, search_attempts: 9} = Repo.reload!(movie)
      assert Repo.all(Intent) == []
    end

    test "searches afresh when start/1 finds its stored intent" do
      {:movie, movie} = target = target(:movie)
      intent = reserve(target, native_release(target, provenance(:deleted)))
      test_pid = self()
      watch_client()

      stub(Cinder.Acquisition.IndexerMock, :search_movie, fn imdb_id, _query, _opts ->
        send(test_pid, {:searched, imdb_id})
        {:ok, []}
      end)

      Download.start(Repo.reload!(movie))

      refute_received {:added, _link}
      assert_received {:searched, _imdb_id}
      assert Repo.get(Intent, intent.id) == nil
      assert Repo.reload!(movie).search_attempts == 3
    end

    test "answers a manual grab with :indexer_changed and no fetch" do
      {:ok, movie} = seed_movie_state(movie_fixture(), %{status: :no_match})
      target = {:movie, movie}
      watch_client()

      assert {:error, :indexer_changed} =
               Catalog.manual_grab_movie(movie, native_release(target, provenance(:deleted)))

      refute_received {:added, _link}
      assert Repo.reload!(movie).status == :no_match
      assert Repo.all(Intent) == []
    end

    test "answers a grab that finds its matching intent with :indexer_changed" do
      {:movie, movie} = target = target(:movie)
      release = native_release(target, provenance(:deleted))
      intent = reserve(target, release)
      watch_client()

      assert {:error, :indexer_changed} = Download.grab_movie(movie, release)

      refute_received {:added, _link}
      assert Repo.get(Intent, intent.id) == nil
      assert_dropped(target, "indexer_changed")
    end

    test "is adopted when the client already holds its job" do
      {:movie, movie} = target = target(:movie)
      intent = reserve(target, native_release(target, provenance(:deleted)))
      watch_client()
      stub(ClientMock, :find_by_operation_key, fn _key -> {:ok, "remote-adopted"} end)

      assert :ok = Download.reconcile_pending_intents([:movie])

      refute_received {:added, _link}
      assert Repo.get(Intent, intent.id) == nil
      assert %Movie{status: :downloading, download_id: "remote-adopted"} = Repo.reload!(movie)
    end
  end

  describe "an episode whose indexer changed" do
    test "spends no search attempt and writes no block over two sweeps" do
      deleted = provenance(:deleted)
      {_kind, %{series: series, episodes: [episode]}} = target(:episode)
      stub_tv_search([native_result(title(:episode), deleted)])
      watch_client()

      poll_tv(2)

      refute_received {:added, _link}
      assert Repo.reload!(episode).search_attempts == 0
      assert blocked(series.id) == []
      assert Repo.all(Intent) == []
    end

    test "answers a manual grab with :indexer_changed and no fetch" do
      {:episode, %{series: series}} = target = target(:episode)
      watch_client()

      assert {:error, :indexer_changed} =
               Catalog.manual_grab_tv(series, 1, native_release(target, provenance(:deleted)))

      refute_received {:added, _link}
      assert_dropped(target, nil)
      assert Repo.all(Intent) == []
    end

    test "answers a grab that finds its matching intent with :indexer_changed" do
      {:season_pack, %{episodes: episodes}} = target = target(:season_pack)
      release = native_release(target, provenance(:deleted))
      intent = reserve(target, release)
      watch_client()

      assert {:error, :indexer_changed} =
               Download.grab_episodes(release, Enum.map(episodes, & &1.id))

      refute_received {:added, _link}
      assert Repo.get(Intent, intent.id) == nil
      assert_dropped(target, nil)
    end
  end

  describe "a book target whose indexer changed" do
    test "is held under indexer_changed by a manual grab, with no fetch and no block row" do
      {:book_target, book} = target = target(:book_target)
      watch_client()

      assert {:error, :indexer_changed} =
               Download.grab_book_target(book, native_release(target, provenance(:deleted)))

      refute_received {:added, _link}
      assert_dropped(target, "indexer_changed")
      assert Repo.all(Intent) == []
    end

    test "is held by a grab that finds its matching intent" do
      {:book_target, book} = target = target(:book_target)
      release = native_release(target, provenance(:deleted))
      intent = reserve(target, release)
      watch_client()

      assert {:error, :indexer_changed} = Download.grab_book_target(book, release)

      refute_received {:added, _link}
      assert Repo.get(Intent, intent.id) == nil
      assert_dropped(target, "indexer_changed")
    end
  end

  describe "a source switch in flight" do
    @http_link "https://indexer.example/dl/1.torrent"

    test "a Prowlarr intent whose fetch times out while Native is selected is dropped" do
      ConfigCase.put_env(:indexer_source, IndexerSource.Native)
      {:movie, movie} = target = target(:movie)
      intent = reserve(target, release(title(:movie), "prowlarr", {7, nil}, @http_link))
      fetching_client(&Req.Test.transport_error(&1, :timeout))

      assert :ok = Download.reconcile_pending_intents([:movie])

      assert_received {:fetched, {:error, :indexer_changed}}
      assert Repo.get(Intent, intent.id) == nil
      assert %Movie{status: :searching, search_attempts: 3} = Repo.reload!(movie)
    end

    test "a Prowlarr intent whose fetch times out while Prowlarr is selected retries with a strike" do
      ConfigCase.put_env(:indexer_source, IndexerSource.Prowlarr)
      {:movie, movie} = target = target(:movie)
      intent = reserve(target, release(title(:movie), "prowlarr", {7, nil}, @http_link))
      fetching_client(&Req.Test.transport_error(&1, :timeout))

      assert :ok = Download.reconcile_pending_intents([:movie])

      assert_received {:fetched, {:error, %Req.TransportError{reason: :timeout}}}
      assert %Intent{status: :reserved, attempt_count: 1} = Repo.get(Intent, intent.id)
      assert Repo.reload!(movie).search_attempts == 4
    end

    test "a fetch refused for good keeps its permanent path while Native is selected" do
      ConfigCase.put_env(:indexer_source, IndexerSource.Native)
      {:episode, %{series: series}} = target = target(:episode)
      intent = reserve(target, release(title(:episode), "prowlarr", {7, nil}, @http_link))

      # A redirect to a magnet link, which this fetch does not allow.
      fetching_client(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "magnet:?xt=urn:btih:abc")
        |> Plug.Conn.send_resp(302, "")
      end)

      assert :ok = Download.reconcile_pending_intents([:episode])

      assert_received {:fetched, {:error, :unsupported_download_url}}
      assert Repo.get(Intent, intent.id) == nil
      assert blocked(series.id) == ["unsupported_download_url"]
    end

    for kind <- [:movie, :episode, :book_target] do
      @kind kind

      test "#{kind}: a client that refuses the fetched release keeps the permanent path" do
        ConfigCase.put_env(:indexer_source, IndexerSource.Native)
        target = target(@kind)
        intent = reserve(target, prowlarr_release(target, @http_link))
        torrent = TorrentFixture.minimal()
        fetching_client(&Plug.Conn.send_resp(&1, 200, torrent), {:error, :add_rejected})

        assert {:error, :add_rejected} = submit(target, intent)

        assert_received {:fetched, {:ok, ^torrent}}
        assert Repo.get(Intent, intent.id) == nil
        assert_refused(target)
      end
    end
  end

  describe ":indexer_auth_failed" do
    test "a movie takes one strike per grab from its search" do
      movie = poller_movie("tt1656002", 0)
      stub_movie_search("tt1656002", [prowlarr_result(title(:movie))])
      watch_client({:error, :indexer_auth_failed})

      poll_movies()

      assert_received {:added, @link}
      assert %Movie{status: :searching, search_attempts: 1} = Repo.reload!(movie)
      assert Repo.all(Intent) == []
    end

    # A park writes the status and leaves the count, so the parked row reads 9.
    for {strikes, status} <- [{8, :searching}, {9, :search_failed}] do
      @strikes strikes
      @status status

      test "a movie with #{strikes} strikes is #{status} after one more" do
        movie = poller_movie("tt165600#{@strikes}", @strikes)
        stub_movie_search("tt165600#{@strikes}", [prowlarr_result(title(:movie))])
        watch_client({:error, :indexer_auth_failed})

        poll_movies()

        assert_received {:added, @link}
        assert Repo.reload!(movie).status == @status
      end
    end

    test "the pending pass drops a movie intent with no strike" do
      {:movie, movie} = target = target(:movie)
      intent = reserve(target, prowlarr_release(target, @link))
      watch_client({:error, :indexer_auth_failed})

      assert :ok = Download.reconcile_pending_intents([:movie])

      assert_received {:added, @link}
      assert Repo.get(Intent, intent.id) == nil
      assert %Movie{status: :searching, search_attempts: 3} = Repo.reload!(movie)
    end

    test "an episode spends one search attempt and writes no block" do
      {_kind, %{series: series, episodes: [episode]}} = target(:episode)
      stub_tv_search([prowlarr_result(title(:episode))])
      watch_client({:error, :indexer_auth_failed})

      poll_tv(1)

      assert_received {:added, @link}
      assert Repo.reload!(episode).search_attempts == 1
      assert blocked(series.id) == []
      assert Repo.all(Intent) == []
    end

    test "a book target is held with no block row" do
      {:book_target, book} = target = target(:book_target)
      watch_client({:error, :indexer_auth_failed})

      assert {:error, :indexer_auth_failed} =
               Download.grab_book_target(book, prowlarr_book_release())

      assert_received {:added, @link}
      assert_dropped(target, "indexer_auth_failed")
      assert Repo.all(Intent) == []
    end
  end

  describe "the pending pass's progress" do
    setup do
      on_exit(fn -> :persistent_term.erase({__MODULE__, :progress}) end)
    end

    # The stub reads the tick's stamp at each fetch, then puts it back to `idle`, so each later
    # fetch, and the end of the pass, sees a stamp the pass wrote after the fetch before it.
    test "stamps the tick's progress after each intent" do
      idle = PollerProgress.now_ms() - 1_000_000
      PollerProgress.tick_started(__MODULE__, idle)
      on_exit(fn -> PollerProgress.tick_finished(__MODULE__) end)

      for _ <- 1..3, do: reserve(target(:movie), release(title(:movie), "prowlarr", {7, nil}))

      test_pid = self()
      stub(ClientMock, :find_by_operation_key, fn _key -> :not_found end)

      stub(ClientMock, :add, fn _release, _opts ->
        send(test_pid, {:stamp, PollerProgress.read(__MODULE__).progress_at})
        PollerProgress.mark(__MODULE__, idle)
        {:error, :timeout}
      end)

      assert :ok = Download.reconcile_pending_intents([:movie])

      assert_received {:stamp, ^idle}
      assert_received {:stamp, second}
      assert_received {:stamp, third}
      assert second != idle and third != idle
      assert PollerProgress.read(__MODULE__).progress_at != idle
    end
  end

  # --- helpers ---------------------------------------------------------------------------------

  defp target(:movie) do
    movie = movie_fixture(%{imdb_id: "tt1656#{System.unique_integer([:positive])}"})
    {:ok, movie} = seed_movie_state(movie, %{status: :searching, search_attempts: 3})
    {:movie, movie}
  end

  defp target(kind) when kind in [:episode, :season_pack] do
    series = series_fixture(%{tvdb_id: 99, monitor_strategy: :all})
    season = season_fixture(series)
    numbers = if kind == :episode, do: [1], else: [1, 2]
    episodes = Enum.map(numbers, &episode_fixture(season, %{episode_number: &1}))
    {kind, %{series: series, episodes: episodes}}
  end

  defp target(:book_target), do: {:book_target, monitored_book_target()}

  defp provenance(:deleted) do
    row = indexer!()
    :ok = Indexers.delete(nil, row.id)
    {row.id, row.credentials_version}
  end

  defp provenance(:older) do
    row = indexer!()
    old = row.credentials_version

    {:ok, %{credentials_version: new}} =
      Indexers.update(nil, row.id, row.lock_version, %{base_url: "https://moved.example"})

    assert new > old
    {row.id, old}
  end

  defp provenance(:missing), do: {indexer!().id, nil}

  defp provenance(:undecryptable) do
    row = indexer!()

    {1, _} =
      Repo.update_all(from(c in ConfiguredIndexer, where: c.id == ^row.id),
        set: [secrets_ciphertext: "not a ciphertext"]
      )

    assert Indexers.fetch_with_secrets(row.id) == {:error, :undecryptable_secrets}
    {row.id, row.credentials_version}
  end

  defp provenance(:no_id), do: {nil, indexer!().credentials_version}

  defp indexer!(overrides \\ []) do
    attrs =
      Map.merge(
        %{
          name: "Indexer #{System.unique_integer([:positive])}",
          type: :newznab,
          base_url: "https://indexer.example",
          api_path: "/api"
        },
        Map.new(overrides)
      )

    {:ok, row} = Indexers.create(nil, attrs, %{"api_key" => "nzb-key-0123456789"})
    row
  end

  defp native_release({:book_target, _target}, {id, version}) do
    %EbookRelease{
      title: "Le Guin - The Dispossessed (EPUB)",
      download_url: @link,
      protocol: :torrent,
      formats: [:epub],
      indexer_source: "native",
      indexer_id: id,
      credentials_version: version
    }
  end

  defp native_release({kind, _target}, provenance),
    do: release(title(kind), "native", provenance)

  defp prowlarr_release({:book_target, _target}, link),
    do: Release.from_book(%{prowlarr_book_release() | download_url: link})

  defp prowlarr_release({kind, _target}, link),
    do: release(title(kind), "prowlarr", {7, nil}, link)

  defp prowlarr_book_release do
    %EbookRelease{
      title: "Le Guin - The Dispossessed (EPUB)",
      download_url: @link,
      protocol: :torrent,
      formats: [:epub],
      indexer_source: "prowlarr",
      indexer_id: 7
    }
  end

  defp release(title, source, {id, version}, link \\ @link) do
    %Release{
      title: title,
      download_url: link,
      protocol: :torrent,
      indexer_source: source,
      indexer_id: id,
      credentials_version: version
    }
  end

  defp title(:movie), do: "Inception.2010.1080p.WEB-DL-GRP"
  defp title(:episode), do: "Show.S01E01.1080p.WEB-DL-GRP"
  defp title(:season_pack), do: "Show.S01.1080p.WEB-DL-GRP"

  defp reserve({:movie, movie}, release), do: reserve(:movie, movie.id, [], release)

  defp reserve({kind, %{episodes: episodes}}, release) do
    ids = Enum.map(episodes, & &1.id)
    reserve(kind, hd(ids), ids, release)
  end

  defp reserve({:book_target, target}, %EbookRelease{} = release),
    do: reserve(:book_target, target.id, [], Release.from_book(release))

  defp reserve({:book_target, target}, %Release{} = release),
    do: reserve(:book_target, target.id, [], release)

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

  # The client holds no job for the intent, and its `add/2` (where a client fetches) reports its
  # call and accepts.
  defp watch_client(answer \\ {:ok, "remote-1"}) do
    test_pid = self()
    stub(ClientMock, :find_by_operation_key, fn _key -> :not_found end)
    stub(ClientMock, :status, fn _id -> {:ok, %{state: :downloading}} end)

    stub(ClientMock, :add, fn release, _opts ->
      send(test_pid, {:added, release.download_url})
      answer
    end)
  end

  # The client holds no job, and its `add/2` fetches the link through the `fetch:` function it
  # gets, against `plug`, reports the fetch's answer and returns it, or `answer` once it fetched.
  defp fetching_client(plug, answer \\ nil) do
    test_pid = self()
    Req.Test.stub(Cinder.IndexerChangeStub, plug)
    stub(ClientMock, :find_by_operation_key, fn _key -> :not_found end)

    stub(ClientMock, :add, fn release, opts ->
      fetched =
        Keyword.fetch!(opts, :fetch).(release.download_url, release.download_url_origin,
          max_bytes: 1024,
          error_tag: :torrent_fetch_status,
          plug: {Req.Test, Cinder.IndexerChangeStub},
          resolver: fn _host -> {:ok, [{93, 184, 216, 34}]} end
        )

      send(test_pid, {:fetched, fetched})

      case fetched do
        {:ok, _bytes} -> answer
        error -> error
      end
    end)
  end

  defp submit({:movie, movie}, _intent), do: Download.start(Repo.reload!(movie))
  defp submit(_target, intent), do: Download.reconcile_intent(intent)

  defp assert_refused({:movie, movie}),
    do: assert(Repo.reload!(movie).status == :searching)

  defp assert_refused({_kind, %{series: series}}),
    do: assert(blocked(series.id) == ["add_rejected"])

  defp assert_refused({:book_target, target}) do
    assert %BookTarget{status: :held, hold_reason: "add_rejected"} = Repo.reload!(target)
    assert book_blocks(target.id) == ["add_rejected"]
  end

  defp poller_movie(imdb_id, attempts) do
    {:ok, movie} =
      seed_movie_state(movie_fixture(%{imdb_id: imdb_id}), %{search_attempts: attempts})

    movie
  end

  defp stub_movie_search(imdb_id, results),
    do:
      stub(Cinder.Acquisition.IndexerMock, :search_movie, fn ^imdb_id, _query, _opts ->
        {:ok, results}
      end)

  defp stub_tv_search(results) do
    stub(Cinder.Acquisition.IndexerMock, :search_tv, fn 99, _title, 1 -> {:ok, results} end)
    stub(Cinder.Acquisition.IndexerMock, :search_tv_query, fn _query, _opts -> {:ok, results} end)
  end

  defp native_result(title, {id, version}) do
    %{prowlarr_result(title) | indexer_id: id}
    |> Map.merge(%{indexer_source: "native", credentials_version: version})
  end

  defp prowlarr_result(title),
    do: %{title: title, size: 2_000_000_000, download_url: @link, seeders: 10, indexer_id: 7}

  defp poll_movies do
    on_exit(fn -> :persistent_term.erase({Poller, :last_run}) end)
    start_supervised!({Poller, interval: 60_000, search_retry_after: 0})
    assert :ok = Poller.poll()
  end

  defp poll_tv(n) do
    on_exit(fn -> :persistent_term.erase({TvPoller, :last_run}) end)
    start_supervised!({TvPoller, interval: 60_000, search_retry_after: 0})
    for _ <- 1..n, do: assert(:ok = TvPoller.poll())
  end

  # What a dropped grab leaves, per kind: no strike, no park and no block row.
  defp assert_dropped({:movie, movie}, _code) do
    assert %Movie{status: :searching, search_attempts: 3} = Repo.reload!(movie)
  end

  defp assert_dropped({_kind, %{series: series, episodes: episodes}}, _code) do
    assert blocked(series.id) == []

    for episode <- episodes,
        do: assert(Repo.reload!(episode).search_attempts == episode.search_attempts)
  end

  defp assert_dropped({:book_target, target}, code) do
    assert %BookTarget{status: :held, hold_reason: ^code} = Repo.reload!(target)
    assert book_blocks(target.id) == []
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
