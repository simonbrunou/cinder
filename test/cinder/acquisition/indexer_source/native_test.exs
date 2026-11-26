defmodule Cinder.Acquisition.IndexerSource.NativeTest do
  # The built-in indexer source (#1651): which configured indexers it asks, the order and identity
  # of the rows, what each seam call returns, the deadline, the heap cap and the progress stamps.
  # Each configured indexer's type reaches a Mox mock of the per-type seam through the
  # `:indexer_adapters` map, set here per test. Not async: that map and Native's config are global.
  use Cinder.DataCase, async: false

  import ExUnit.CaptureLog
  import Mox

  alias Cinder.Acquisition.{IndexerAdapterMock, OtherIndexerAdapterMock}
  alias Cinder.Acquisition.IndexerSource.{Native, Report}
  alias Cinder.ConfigCase
  alias Cinder.Download.PollerProgress
  alias Cinder.HTTPPolicy
  alias Cinder.Indexers
  alias Cinder.Indexers.ConfiguredIndexer
  alias Cinder.Test.SilentServer

  setup :verify_on_exit!

  defmodule HeapReports do
    @moduledoc false
    # A `:logger` handler that tells the test process when the VM reports a heap kill.
    def log(%{msg: {format, _args}}, %{config: pid}) when is_list(format) do
      if :string.find(format, ~c"maximum heap size reached") != :nomatch,
        do: send(pid, :heap_report)

      :ok
    end

    def log(_event, _config), do: :ok
  end

  setup do
    ConfigCase.put_env(:indexer_adapters, %{})
    ConfigCase.put_env(Native, [])
    :ok
  end

  defp adapters(map), do: ConfigCase.put_env(:indexer_adapters, map)
  defp native_config(config), do: ConfigCase.put_env(Native, config)

  defp indexer!(overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          name: "Indexer #{System.unique_integer([:positive])}",
          type: :newznab,
          base_url: "https://indexer.example",
          api_path: "/api"
        },
        overrides
      )

    {:ok, row} = Indexers.create(nil, attrs, %{"api_key" => "nzb-key-0123456789"})
    row
  end

  # A Cardigann row the write path refuses until definitions can be pinned.
  defp cardigann!(overrides) do
    Repo.insert!(
      struct!(
        %ConfiguredIndexer{
          name: "Cardigann #{System.unique_integer([:positive])}",
          type: :cardigann,
          definition: "nyaasi",
          base_url: "https://cardigann.example"
        },
        overrides
      )
    )
  end

  defp row(title, origin, extra \\ %{}) do
    Map.merge(
      %{
        title: title,
        download_url: "https://indexer.example/dl/#{title}",
        protocol: :usenet,
        query_origins: [origin]
      },
      extra
    )
  end

  # Answers each indexer by id from `by_id`: `{rows, outcome}` or a function of the context.
  defp answer_by_id(mock, by_id) do
    stub(mock, :search, fn indexer, _query, context ->
      case Map.fetch!(by_id, indexer.id) do
        fun when is_function(fun, 1) -> fun.(context)
        answer -> answer
      end
    end)
  end

  # Tells the cut indexer's search process once its peer has answered, in either arrival order.
  defp peer_barrier do
    receive do
      {:cut_waiting, cut} ->
        receive do
          :peer_answered -> send(cut, :peer_answered)
        end
    end
  end

  # Returns once the monotonic clock reaches `deadline_at`.
  defp wait_past(deadline_at) do
    receive do
    after
      max(deadline_at - System.monotonic_time(:millisecond), 0) -> :ok
    end
  end

  defp outcomes(%Report{indexers: indexers}),
    do: Map.new(indexers, fn {{"native", id}, %{outcome: outcome}} -> {id, outcome} end)

  describe "an indexer whose type has no adapter" do
    test "is not supported, gets no request, and leaves the search an empty answer" do
      a = indexer!()
      b = indexer!(%{type: :torznab})
      c = cardigann!(%{})
      adapters(%{})

      {result, events} =
        Cinder.TelemetryHelpers.capture([:cinder, :http, :request_task], fn ->
          Native.search_tv(1, "Show", 1)
        end)

      assert {:ok, [], report} = result

      assert outcomes(report) == %{
               a.id => {:not_asked, {:not_supported, :newznab}},
               b.id => {:not_asked, {:not_supported, :torznab}},
               c.id => {:not_asked, {:not_supported, :cardigann}}
             }

      assert for({_m, %{host: "indexer.example"}} <- events, do: :request) == []
      refute Report.incomplete?(report)
    end

    test "two enabled Newznab indexers both read not supported with an empty adapter map" do
      a = indexer!()
      b = indexer!()

      assert {:ok, [], report} = Native.search_tv(1, "Show", 1)

      assert outcomes(report) == %{
               a.id => {:not_asked, {:not_supported, :newznab}},
               b.id => {:not_asked, {:not_supported, :newznab}}
             }
    end

    test "is reported by its own name" do
      a = indexer!(%{name: "Alpha"})

      assert {:ok, [], %Report{indexers: indexers}} = Native.search("tt0000001")
      assert Map.keys(indexers) == [{"native", a.id}]
      assert %{name: "Alpha"} = indexers[{"native", a.id}]
    end
  end

  describe "the FlareSolverr toggle" do
    test "leaves an indexer of a type with an adapter not asked, and its adapter uncalled" do
      solver = indexer!(%{flaresolverr: true})
      plain = indexer!()
      adapters(%{newznab: IndexerAdapterMock})
      test_pid = self()

      stub(IndexerAdapterMock, :search, fn indexer, _query, _context ->
        send(test_pid, {:searched, indexer.id})
        {[row("a", :id_scoped)], :asked}
      end)

      assert {:ok, [_row], report} = Native.search("tt0000001")

      assert outcomes(report) == %{
               solver.id => {:not_asked, {:not_supported, :flaresolverr}},
               plain.id => :asked
             }

      assert_received {:searched, id}
      assert id == plain.id
      refute_received {:searched, _id}
    end

    test "on an indexer whose type has no adapter reads as that type" do
      solver = cardigann!(%{flaresolverr: true})
      adapters(%{newznab: IndexerAdapterMock})

      assert {:ok, [], report} = Native.search("tt0000001")
      assert outcomes(report) == %{solver.id => {:not_asked, {:not_supported, :cardigann}}}
    end
  end

  describe "each type" do
    test "reaches the adapter its type names" do
      nzb = indexer!()
      tor = indexer!(%{type: :torznab})
      adapters(%{newznab: IndexerAdapterMock, torznab: OtherIndexerAdapterMock})
      test_pid = self()

      for mock <- [IndexerAdapterMock, OtherIndexerAdapterMock] do
        stub(mock, :search, fn indexer, query, _context ->
          send(test_pid, {mock, indexer.id, query})
          {[], :asked}
        end)
      end

      assert {:ok, [], _report} = Native.search_ebook("Author", "Title", categories: [7020])

      query = {:search_ebook, "Author", "Title", [categories: [7020]]}
      assert_received {IndexerAdapterMock, nzb_id, ^query}
      assert_received {OtherIndexerAdapterMock, tor_id, ^query}
      assert {nzb_id, tor_id} == {nzb.id, tor.id}
    end
  end

  describe "rows" do
    test "come id-scoped first, then by priority and id, whatever order the indexers answer in" do
      late = indexer!(%{priority: 10, name: "Late"})
      indexer!(%{priority: 20, name: "Early"})
      adapters(%{newznab: IndexerAdapterMock})
      test_pid = self()

      stub(IndexerAdapterMock, :search, fn indexer, _query, _context ->
        if indexer.id == late.id do
          send(test_pid, {:late_waiting, self()})

          receive do
            :answer -> :ok
          end
        else
          send(test_pid, {:early_answering, self()})
        end

        {[row("#{indexer.name}-id", :id_scoped), row("#{indexer.name}-text", :free_text)], :asked}
      end)

      task = Task.async(fn -> Native.search_tv(1, "Show", 1) end)

      assert_receive {:late_waiting, late_pid}, 5_000
      assert_receive {:early_answering, early_pid}, 5_000
      ref = Process.monitor(early_pid)
      assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 5_000
      send(late_pid, :answer)

      assert {:ok, rows, _report} = Task.await(task)
      assert Enum.map(rows, & &1.title) == ~w(Late-id Early-id Late-text Early-text)
    end

    test "of indexers with equal priority come in id order" do
      first = indexer!(%{priority: 25, name: "First"})
      second = indexer!(%{priority: 25, name: "Second"})
      adapters(%{newznab: IndexerAdapterMock})

      answer_by_id(IndexerAdapterMock, %{
        first.id => {[row("First-text", :free_text), row("First-id", :id_scoped)], :asked},
        second.id => {[row("Second-id", :id_scoped), row("Second-text", :free_text)], :asked}
      })

      assert first.id < second.id
      assert {:ok, rows, _report} = Native.search_tv(1, "Show", 1)
      assert Enum.map(rows, & &1.title) == ~w(First-id Second-id First-text Second-text)
    end

    test "keep the adapter's order inside one indexer" do
      only = indexer!()
      adapters(%{newznab: IndexerAdapterMock})

      answer_by_id(IndexerAdapterMock, %{
        only.id => {[row("b", :free_text), row("a", :free_text), row("c", :free_text)], :asked}
      })

      assert {:ok, rows, _report} = Native.search_movie_query("Title", [])
      assert Enum.map(rows, & &1.title) == ~w(b a c)
    end

    test "carry the configured indexer's identity over any value the adapter set" do
      indexer = indexer!(%{name: "Stamped"})

      {:ok, indexer} =
        Indexers.update(nil, indexer.id, indexer.lock_version, %{
          base_url: "https://moved.example"
        })

      assert indexer.credentials_version == 2
      adapters(%{newznab: IndexerAdapterMock})

      forged = %{
        indexer_id: 999,
        indexer_name: "Forged",
        indexer_source: "prowlarr",
        credentials_version: 7
      }

      answer_by_id(IndexerAdapterMock, %{
        indexer.id => {[row("x", :id_scoped, forged), row("y", :free_text)], :asked}
      })

      assert {:ok, rows, _report} = Native.search("tt0000001")

      assert Enum.map(rows, &Map.take(&1, Map.keys(forged))) ==
               List.duplicate(
                 %{
                   indexer_id: indexer.id,
                   indexer_name: "Stamped",
                   indexer_source: "native",
                   credentials_version: 2
                 },
                 2
               )
    end

    test "without exactly one query origin are dropped" do
      only = indexer!()
      adapters(%{newznab: IndexerAdapterMock})

      answer_by_id(IndexerAdapterMock, %{
        only.id =>
          {[
             row("kept", :id_scoped),
             Map.delete(row("none", :id_scoped), :query_origins),
             row("both", :id_scoped, %{query_origins: [:id_scoped, :free_text]}),
             row("other", :somewhere)
           ], :asked}
      })

      assert {:ok, [%{title: "kept"}], _report} = Native.search("tt0000001")
    end
  end

  describe "what a search returns" do
    setup do
      adapters(%{newznab: IndexerAdapterMock})
      %{a: indexer!(%{priority: 1}), b: indexer!(%{priority: 2})}
    end

    test "with every enabled indexer failed: no indexer answered", %{a: a, b: b} do
      answer_by_id(IndexerAdapterMock, %{
        a.id => {[], {:failed, :timeout}},
        b.id => {[], {:failed, {:http_status, 503}}}
      })

      assert {:error, {:no_indexer_answered, report}} = Native.search("tt0000001")

      assert outcomes(report) == %{
               a.id => {:failed, :timeout},
               b.id => {:failed, {:http_status, 503}}
             }
    end

    test "with one failed and one cut by the deadline: no indexer answered", %{a: a, b: b} do
      answer_by_id(IndexerAdapterMock, %{
        a.id => {[], {:failed, :dns}},
        b.id => {[], {:failed, :deadline}}
      })

      assert {:error, {:no_indexer_answered, report}} = Native.search("tt0000001")
      assert outcomes(report) == %{a.id => {:failed, :dns}, b.id => {:skipped, :deadline}}
    end

    test "with a failed indexer that has rows and none asked: no indexer answered", %{a: a, b: b} do
      answer_by_id(IndexerAdapterMock, %{
        a.id => {[row("partial", :id_scoped)], {:failed, :bad_response}},
        b.id => {[], {:skipped, :deadline}}
      })

      assert {:error, {:no_indexer_answered, _report}} = Native.search("tt0000001")
    end

    test "with every indexer cut by the deadline: backing off until 60 s after the search",
         %{a: a, b: b} do
      clock = ~U[2026-11-25 12:00:00Z]
      native_config(clock: fn -> clock end)

      answer_by_id(IndexerAdapterMock, %{
        a.id => {[], {:failed, :deadline}},
        b.id => {[row("cut", :id_scoped)], {:skipped, :deadline}}
      })

      assert Native.search("tt0000001") ==
               {:error, {:indexers_backing_off, ~U[2026-11-25 12:01:00Z]}}
    end

    test "with one not asked and one cut by the deadline: backing off" do
      solver = indexer!(%{flaresolverr: true})
      native_config(clock: fn -> ~U[2026-11-25 12:00:00Z] end)

      stub(IndexerAdapterMock, :search, fn _indexer, _query, _context ->
        {[], {:failed, :deadline}}
      end)

      assert {:error, {:indexers_backing_off, ~U[2026-11-25 12:01:00Z]}} = Native.search("tt1")
      assert solver.flaresolverr
    end

    test "with one not asked and one failed: no indexer answered" do
      solver = indexer!(%{flaresolverr: true})

      stub(IndexerAdapterMock, :search, fn _indexer, _query, _context ->
        {[], {:failed, :too_large}}
      end)

      assert {:error, {:no_indexer_answered, report}} = Native.search("tt1")
      assert outcomes(report)[solver.id] == {:not_asked, {:not_supported, :flaresolverr}}
    end

    test "with no enabled indexer: no indexers", %{a: a, b: b} do
      for row <- [a, b],
          do: {:ok, _row} = Indexers.set_enabled(nil, row.id, row.lock_version, false)

      stub(IndexerAdapterMock, :search, fn _indexer, _query, _context -> flunk("asked") end)

      assert Native.search("tt0000001") == {:error, :no_indexers}
    end

    test "with one failed and one answered: the rows, the failed one's included, and the report",
         %{a: a, b: b} do
      answer_by_id(IndexerAdapterMock, %{
        a.id => {[row("before-failure", :id_scoped)], {:failed, :timeout}},
        b.id => {[row("answered", :id_scoped)], :asked}
      })

      assert {:ok, rows, report} = Native.search("tt0000001")
      assert Enum.map(rows, & &1.title) == ~w(before-failure answered)
      assert outcomes(report) == %{a.id => {:failed, :timeout}, b.id => :asked}
      assert Report.incomplete?(report)
    end

    test "with an answer outside the contract: that indexer crashed", %{a: a, b: b} do
      answer_by_id(IndexerAdapterMock, %{
        a.id => {[row("x", :id_scoped)], {:failed, :not_a_reason}},
        b.id => {[row("ok", :id_scoped)], :asked}
      })

      assert {:ok, [%{title: "ok"}], report} = Native.search("tt0000001")
      assert outcomes(report)[a.id] == {:failed, :crashed}
    end

    test "with an adapter that raises: that indexer crashed, and nothing logs the message",
         %{a: a, b: b} do
      answer_by_id(IndexerAdapterMock, %{
        a.id => fn _context ->
          raise "GET https://indexer.example/api?apikey=leaked-key failed"
        end,
        b.id => {[row("ok", :id_scoped)], :asked}
      })

      {result, log} = with_log(fn -> Native.search("tt0000001") end)

      assert {:ok, [%{title: "ok"}], report} = result
      assert outcomes(report)[a.id] == {:failed, :crashed}
      assert log =~ "native search of indexer #{a.id} ended on error"
      refute log =~ "leaked-key"
      refute inspect(result) =~ "leaked-key"
    end
  end

  describe "the deadline" do
    setup do
      adapters(%{newznab: IndexerAdapterMock})
      :ok
    end

    # Native reads the clock between `before` and `after_call`, so a deadline of exactly 90,000 ms
    # lies at least 90,000 ms past `before` and at most 90,000 ms past `after_call`.
    test "is 90 s from the call, handed to the adapter" do
      indexer!()
      test_pid = self()

      stub(IndexerAdapterMock, :search, fn _indexer, _query, context ->
        send(test_pid, {:deadline_at, context.deadline_at})
        {[], :asked}
      end)

      before = System.monotonic_time(:millisecond)
      Native.search("tt0000001")
      after_call = System.monotonic_time(:millisecond)

      assert_received {:deadline_at, deadline_at}
      assert deadline_at - before >= 90_000
      assert deadline_at - after_call <= 90_000
    end

    # The adapter's request waits on a socket that never answers, under a 60 s budget of its own,
    # so only Native's kill ends the search process and only the caller's watcher ends the request
    # task. A Native that waits for the adapter fails the elapsed bound; a request task left alive
    # fails the `:DOWN` wait. The 2 s deadline is headroom for the search process to start and
    # send its request before the kill; one that starts later fails the `:search_process` read.
    test "kills a search still running one second past it, and the request it started" do
      indexer!()
      native_config(deadline_ms: 2_000)
      url = SilentServer.start!()
      test_pid = self()

      stub(IndexerAdapterMock, :search, fn _indexer, _query, _context ->
        send(test_pid, {:search_process, self()})
        HTTPPolicy.bounded_request([url: url, retry: false, receive_timeout: 60_000], 64, 60_000)
        {[], :asked}
      end)

      started_at = System.monotonic_time(:millisecond)

      {result, events} =
        Cinder.TelemetryHelpers.capture([:cinder, :http, :request_task], fn ->
          Native.search("tt0000001")
        end)

      elapsed = System.monotonic_time(:millisecond) - started_at

      assert {:error, {:indexers_backing_off, _retry_at}} = result
      assert elapsed >= 3_000
      assert elapsed < 15_000

      assert_received {:search_process, search_pid}
      refute Process.alive?(search_pid)

      assert [task_pid] =
               for({_m, %{caller: ^search_pid, task_pid: pid}} <- events, do: pid)

      ref = Process.monitor(task_pid)
      assert_receive {:DOWN, ^ref, :process, ^task_pid, _reason}, 5_000
    end

    # The cut indexer answers once its peer has answered and the deadline has passed, as an
    # adapter whose request the deadline cut does; the 2 s deadline is headroom for both to start.
    test "lets a search cut by its own request answer with its rows within the grace" do
      indexer = indexer!(%{priority: 1})
      other = indexer!(%{priority: 2})
      native_config(deadline_ms: 2_000)
      barrier = start_supervised!({Task, &peer_barrier/0}, id: make_ref())

      answer_by_id(IndexerAdapterMock, %{
        indexer.id => fn context ->
          send(barrier, {:cut_waiting, self()})
          assert_receive :peer_answered, 10_000
          wait_past(context.deadline_at)
          {[row("before-cut", :id_scoped)], {:failed, :deadline}}
        end,
        other.id => fn _context ->
          send(barrier, :peer_answered)
          {[row("answered", :free_text)], :asked}
        end
      })

      assert {:ok, rows, report} = Native.search("tt0000001")
      assert Enum.map(rows, & &1.title) == ~w(before-cut answered)
      assert outcomes(report)[indexer.id] == {:skipped, :deadline}
    end
  end

  describe "a search process" do
    setup do
      adapters(%{newznab: IndexerAdapterMock})
      :ok
    end

    test "runs under a 16 Mi-word heap cap that kills it" do
      indexer!()
      test_pid = self()

      stub(IndexerAdapterMock, :search, fn _indexer, _query, _context ->
        send(test_pid, {:max_heap_size, Process.info(self(), :max_heap_size)})
        {[], :asked}
      end)

      Native.search("tt0000001")

      assert_received {:max_heap_size, {:max_heap_size, %{size: 16_777_216, kill: true}}}
    end

    test "killed for its heap reads as crashed while the others answer" do
      greedy = indexer!(%{priority: 1})
      modest = indexer!(%{priority: 2})

      answer_by_id(IndexerAdapterMock, %{
        greedy.id => fn _context ->
          heap = Enum.to_list(1..20_000_000)
          {[row("never #{length(heap)}", :id_scoped)], :asked}
        end,
        modest.id => {[row("modest", :id_scoped)], :asked}
      })

      # The VM sends its heap report to the logger after the kill, so the capture waits for it:
      # a report that comes later lands in another test's capture.
      :ok = :logger.add_handler(:native_heap_report, __MODULE__.HeapReports, %{config: self()})
      on_exit(fn -> :logger.remove_handler(:native_heap_report) end)

      {result, _log} =
        with_log(fn ->
          result = Native.search("tt0000001")
          assert_receive :heap_report, 5_000
          result
        end)

      assert {:ok, [%{title: "modest"}], report} = result
      assert outcomes(report) == %{greedy.id => {:failed, :crashed}, modest.id => :asked}
    end
  end

  describe "progress" do
    test "stamps the calling process's tick each time one indexer's search ends" do
      ids = for priority <- 1..3, do: indexer!(%{priority: priority}).id
      adapters(%{newznab: IndexerAdapterMock})
      test_pid = self()
      poller = Module.concat(__MODULE__, Poller)
      PollerProgress.reset(poller)

      stub(IndexerAdapterMock, :search, fn indexer, _query, _context ->
        send(test_pid, {:waiting, indexer.id, self()})

        receive do
          :answer -> {[], :asked}
        end
      end)

      task =
        Task.async(fn ->
          PollerProgress.tick_started(poller, 0)
          result = Native.search("tt0000001")
          PollerProgress.tick_finished(poller)
          result
        end)

      waiting =
        for _id <- ids, into: %{} do
          assert_receive {:waiting, id, pid}, 5_000
          {id, pid}
        end

      stamps =
        for id <- ids do
          before = PollerProgress.read(poller).progress_at
          Process.sleep(5)
          send(Map.fetch!(waiting, id), :answer)
          wait_for_stamp_after(poller, before)
        end

      assert {:ok, [], _report} = Task.await(task)
      assert stamps == Enum.sort(stamps)
      assert length(Enum.uniq(stamps)) == 3
    end
  end

  # The stamp that replaces `before`, read for up to 5 s.
  defp wait_for_stamp_after(poller, before, tries \\ 500) do
    case PollerProgress.read(poller) do
      %{progress_at: stamp} when stamp != before ->
        stamp

      _snapshot when tries > 0 ->
        Process.sleep(10)
        wait_for_stamp_after(poller, before, tries - 1)

      snapshot ->
        flunk("no new progress stamp after #{inspect(before)}: #{inspect(snapshot)}")
    end
  end

  describe "the other callbacks" do
    test "fetch_download/3 answers not supported with no request" do
      {result, events} =
        Cinder.TelemetryHelpers.capture([:cinder, :http, :request_task], fn ->
          Native.fetch_download("https://indexer.example/dl/1", nil, indexer_source: "native")
        end)

      assert result == {:error, :not_supported}
      assert for({_m, %{caller: caller}} <- events, caller == self(), do: caller) == []
    end

    test "health/0 answers from the recorded state with no request" do
      {result, events} =
        Cinder.TelemetryHelpers.capture([:cinder, :http, :request_task], fn -> Native.health() end)

      assert result == {:error, :no_indexer_added}
      assert for({_m, %{caller: caller}} <- events, caller == self(), do: caller) == []
    end
  end
end
