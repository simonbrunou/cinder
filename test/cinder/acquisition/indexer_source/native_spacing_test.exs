defmodule Cinder.Acquisition.IndexerSource.NativeSpacingTest do
  # The per-indexer slot lease (`Cinder.Acquisition.IndexerSource.Native.Lease`, #1655) through
  # the real `Cinder.Acquisition.IndexerSource.Native` and the app's named lease: configured
  # Newznab indexers behind the `Cinder.NewznabStub` plug (`Cinder.NewznabFixtures.route/1`).
  # A blocking stub holds a request until the test sends it `:go`, so the test decides when the
  # request in the slot ends; a stub `receive`s, since `req_stub_sleep_test.exs` refuses a sleep.
  #
  # Not async: Native's clock, its deadline and the lease's spacing are global config.
  use Cinder.DataCase, async: false

  import Cinder.NewznabFixtures

  alias Cinder.Acquisition.Indexer.Newznab
  alias Cinder.Acquisition.IndexerSource
  alias Cinder.Acquisition.IndexerSource.{Native, Report}
  alias Cinder.Acquisition.IndexerSource.Native.{IndexerStatus, Lease}
  alias Cinder.ConfigCase
  alias Cinder.Repo

  @now ~U[2026-11-26 12:00:00Z]

  setup do
    ConfigCase.put_env(Native, clock: fn -> @now end)
    :ok
  end

  defp outcomes(%Report{indexers: indexers}),
    do: Map.new(indexers, fn {{"native", id}, %{outcome: outcome}} -> {id, outcome} end)

  # Answers each movie search with one row titled by its IMDb digits, after telling the test
  # `{:search, digits, stub_pid, at}` (`at` the monotonic time it arrived) and, for the digits in
  # `block`, waiting for the test's `{:go, answer}`.
  defp movie_route(block \\ []) do
    test_pid = self()

    fn conn, query ->
      case query do
        %{"t" => "movie", "imdbid" => digits} -> movie_answer(conn, digits, block, test_pid)
        _caps -> :default
      end
    end
  end

  defp movie_answer(conn, digits, block, test_pid) do
    send(test_pid, {:search, digits, self(), System.monotonic_time(:millisecond)})
    if digits in block, do: await_go(conn), else: row(conn, digits)
  end

  defp await_go(conn) do
    receive do
      {:go, answer} -> respond(conn, answer)
    end
  end

  defp row(conn, digits),
    do: rss([item("Row #{digits}", {:nzb, "https://#{conn.host}/#{digits}"})])

  # Runs one search first so the caps are stored and later searches send their search request
  # alone.
  defp warm!(indexer_host) do
    {:ok, _rows, _report} = Native.search("tt9999999")
    assert_receive {:search, "9999999", _pid, _at}
    _drained = searches(indexer_host)
    :ok
  end

  defp search_async(imdb_id), do: Task.async(fn -> Native.search(imdb_id) end)

  defp interactive_search_async(imdb_id),
    do: Task.async(fn -> IndexerSource.interactive(fn -> Native.search(imdb_id) end) end)

  defp await_search(task), do: Task.await(task, 30_000)

  # Waits until the named lease has `count` requests of `queue` waiting for `id`.
  defp await_queued(id, queue, count, rounds \\ 400) do
    queued =
      case :sys.get_state(Lease).indexers do
        %{^id => entry} -> entry |> Map.fetch!(queue) |> :queue.len()
        _none -> 0
      end

    cond do
      queued == count -> :ok
      rounds > 0 -> Process.sleep(5) && await_queued(id, queue, count, rounds - 1)
      true -> flunk("#{queued} #{queue} requests queued for #{id}, not #{count}")
    end
  end

  # A process that holds `id`'s slot until the test sends it `:finish`.
  defp hold_slot(id) do
    test_pid = self()

    pid =
      start_supervised!(
        {Task,
         fn ->
           Lease.run(id, [deadline_at: System.monotonic_time(:millisecond) + 60_000], fn ->
             send(test_pid, {:holding, id})

             receive do
               :finish -> :ok
             end
           end)
         end},
        id: make_ref()
      )

    assert_receive {:holding, ^id}
    pid
  end

  describe "one request at a time" do
    test "two seam calls to one indexer send it their requests in turn, the spacing apart" do
      ConfigCase.put_env(Lease, spacing_ms: 300)
      indexer = indexer!(:newznab, "one.example")
      route(%{"one.example" => movie_route(["0000001"])})
      warm!("one.example")

      first = search_async("tt0000001")
      assert_receive {:search, "0000001", stub, _at}, 5_000
      second = search_async("tt0000002")
      await_queued(indexer.id, :background, 1)

      # The second request waits while the first is in the slot.
      refute_received {:search, "0000002", _pid, _at}
      ended = System.monotonic_time(:millisecond)
      send(stub, {:go, rss()})

      assert {:ok, [], _report} = await_search(first)
      assert {:ok, [%{title: "Row 0000002"}], _report} = await_search(second)
      assert_received {:search, "0000002", _pid, started}
      assert started - ended >= 300
    end

    test "two configured indexers on one host are asked at once" do
      first = indexer!(:newznab, "shared.example", %{name: "First", api_path: "/first"})
      second = indexer!(:newznab, "shared.example", %{name: "Second", api_path: "/second"})
      test_pid = self()

      route(%{
        "shared.example" => fn conn, query ->
          if query["t"] == "movie" do
            send(test_pid, {:arrived, conn.request_path, self()})

            receive do
              :go -> respond(conn, rss())
            end
          else
            :default
          end
        end
      })

      task = search_async("tt0000001")

      # Both requests reach the stub while neither has answered.
      assert_receive {:arrived, path_a, stub_a}, 5_000
      assert_receive {:arrived, path_b, stub_b}, 5_000
      assert Enum.sort([path_a, path_b]) == ["/first", "/second"]
      send(stub_a, :go)
      send(stub_b, :go)

      assert {:ok, [], report} = await_search(task)
      assert outcomes(report) == %{first.id => :asked, second.id => :asked}
    end
  end

  describe "priority" do
    test "a manual-search request queued after a background one is sent before it" do
      indexer = indexer!(:newznab, "one.example")
      route(%{"one.example" => movie_route(["0000001"])})
      warm!("one.example")

      running = search_async("tt0000001")
      assert_receive {:search, "0000001", stub, _at}, 5_000
      background = search_async("tt0000002")
      await_queued(indexer.id, :background, 1)
      interactive = interactive_search_async("tt0000003")
      await_queued(indexer.id, :interactive, 1)

      send(stub, {:go, rss()})

      assert {:ok, _rows, _report} = await_search(running)
      assert {:ok, [%{title: "Row 0000003"}], _report} = await_search(interactive)
      assert {:ok, [%{title: "Row 0000002"}], _report} = await_search(background)
      assert_received {:search, interactive_digits, _pid, interactive_at}
      assert_received {:search, background_digits, _pid, background_at}
      assert {interactive_digits, background_digits} == {"0000003", "0000002"}
      assert interactive_at <= background_at
    end

    test "a search outside interactive/1 queues as background" do
      indexer = indexer!(:newznab, "one.example")
      route(%{"one.example" => movie_route(["0000001"])})
      warm!("one.example")

      running = search_async("tt0000001")
      assert_receive {:search, "0000001", stub, _at}, 5_000
      plain = search_async("tt0000002")
      await_queued(indexer.id, :background, 1)
      assert :queue.len(:sys.get_state(Lease).indexers[indexer.id].interactive) == 0

      send(stub, {:go, rss()})
      assert {:ok, _rows, _report} = await_search(running)
      assert {:ok, _rows, _report} = await_search(plain)
    end
  end

  describe "the outcome before the release" do
    test "a failure answer makes the request queued behind it skip the indexer, sending nothing" do
      indexer = indexer!(:newznab, "one.example")
      route(%{"one.example" => movie_route(["0000001"])})
      warm!("one.example")

      failing = search_async("tt0000001")
      assert_receive {:search, "0000001", stub, _at}, 5_000
      queued = search_async("tt0000002")
      await_queued(indexer.id, :background, 1)

      # A 500, which `Indexer.request/3` does not retry.
      send(stub, {:go, {500, "down"}})

      assert {:error, {:no_indexer_answered, _report}} = await_search(failing)
      until = ~U[2026-11-26 12:01:00Z]
      assert {:error, {:indexers_backing_off, ^until}} = await_search(queued)
      refute_received {:search, "0000002", _pid, _at}

      assert %{backoff: :failure, backoff_until: ^until} =
               IndexerStatus.read([indexer])[indexer.id]
    end

    test "rejected credentials make the request queued behind it report them, sending nothing" do
      indexer = indexer!(:newznab, "one.example")
      route(%{"one.example" => movie_route(["0000001"])})
      warm!("one.example")

      rejected = search_async("tt0000001")
      assert_receive {:search, "0000001", stub, _at}, 5_000
      queued = search_async("tt0000002")
      await_queued(indexer.id, :background, 1)

      send(stub, {:go, {401, ""}})

      assert {:error, {:no_indexer_answered, _report}} = await_search(rejected)
      assert {:error, {:no_indexer_answered, report}} = await_search(queued)
      assert outcomes(report) == %{indexer.id => {:failed, :rejected_credentials}}
      refute_received {:search, "0000002", _pid, _at}
    end

    # The id query answers a query error after `record` writes an answer to the indexer's state,
    # as another search's request would between the two queries of this one.
    defp tv_search_after(record) do
      indexer = indexer!(:newznab, "one.example")
      test_pid = self()

      route(%{
        "one.example" => fn _conn, query ->
          case query do
            %{"tvdbid" => _id} ->
              record.(indexer)
              error(300, "No such item")

            %{"q" => _q} ->
              send(test_pid, :text_query_sent)
              rss()

            _caps ->
              :default
          end
        end
      })

      context = %{deadline_at: System.monotonic_time(:millisecond) + 30_000}
      Newznab.search(indexer, {:search_tv, 81_189, "Show", 1}, context)
    end

    test "a backoff recorded between two queries sends no second one; the query error stays" do
      answer =
        tv_search_after(fn indexer ->
          :written = IndexerStatus.record(indexer, {:http_status, 500}, @now)
        end)

      assert answer == {[], {:failed, {:indexer_error, 300}}}
      refute_received :text_query_sent
    end

    test "credentials rejected between two queries send no second one and win the outcome" do
      answer =
        tv_search_after(fn indexer ->
          :written = IndexerStatus.record(indexer, {:rejected_credentials, {:code, 100}}, @now)
        end)

      assert answer == {[], {:failed, :rejected_credentials}}
      refute_received :text_query_sent
    end

    test "with nothing recorded between them, the second query is sent (positive control)" do
      assert tv_search_after(fn _indexer -> :ok end) == {[], {:failed, {:indexer_error, 300}}}
      assert_received :text_query_sent
    end

    test "a caps fetch queued behind a slot holder skips the indexer a failure backed off meanwhile" do
      indexer = indexer!(:newznab, "one.example")
      route(%{"one.example" => movie_route()})
      holder = hold_slot(indexer.id)

      task = search_async("tt0000001")
      await_queued(indexer.id, :background, 1)
      :written = IndexerStatus.record(indexer, {:http_status, 500}, @now)
      send(holder, :finish)

      assert await_search(task) ==
               {:error, {:indexers_backing_off, ~U[2026-11-26 12:01:00Z]}}

      refute_received {:newznab_request, "one.example", _query}
    end

    test "after a success, the request queued behind it is sent (positive control)" do
      indexer = indexer!(:newznab, "one.example")
      route(%{"one.example" => movie_route(["0000001"])})
      warm!("one.example")

      first = search_async("tt0000001")
      assert_receive {:search, "0000001", stub, _at}, 5_000
      queued = search_async("tt0000002")
      await_queued(indexer.id, :background, 1)

      send(stub, {:go, rss()})

      assert {:ok, [], _report} = await_search(first)
      assert {:ok, [%{title: "Row 0000002"}], _report} = await_search(queued)
      assert_received {:search, "0000002", _pid, _at}
    end
  end

  test "a process killed while it holds an indexer's slot frees it for the next request" do
    indexer = indexer!(:newznab, "one.example")
    route(%{"one.example" => movie_route()})
    warm!("one.example")

    holder = hold_slot(indexer.id)
    task = search_async("tt0000002")
    await_queued(indexer.id, :background, 1)
    refute_received {:search, "0000002", _pid, _at}

    Process.exit(holder, :kill)

    assert {:ok, [%{title: "Row 0000002"}], _report} = await_search(task)
    assert_received {:search, "0000002", _pid, _at}
  end

  describe "a request still queued at the deadline" do
    setup do
      ConfigCase.put_env(Native, clock: fn -> @now end, deadline_ms: 300)
      :ok
    end

    test "is never sent, changes no status row and reads as skipped by the deadline" do
      # The healthy indexer's search has to end inside the deadline that the held one waits out:
      # its caps are stored first, so it sends one request, with 2 s for it. At 300 ms, a cold
      # caps fetch and the search missed it under load in 1 of 369 runs.
      ConfigCase.put_env(Native, clock: fn -> @now end, deadline_ms: 2_000)
      route(%{"held.example" => movie_route(), "ok.example" => movie_route()})
      healthy = indexer!(:newznab, "ok.example")
      warm!("ok.example")
      held = indexer!(:newznab, "held.example")
      holder = hold_slot(held.id)

      assert {:ok, [%{title: "Row 0133093"}], report} = Native.search("tt0133093")

      assert outcomes(report) == %{held.id => {:skipped, :deadline}, healthy.id => :asked}
      refute Report.incomplete?(report)
      refute_received {:newznab_request, "held.example", _query}
      # The control: the healthy indexer's stub reported its requests in the same search.
      assert_received {:newznab_request, "ok.example", %{"t" => "movie"}}
      assert Repo.get(IndexerStatus, held.id) == nil
      send(holder, :finish)
    end

    test "with every query never started and no backoff, holds 60 s after the search" do
      held = indexer!(:newznab, "held.example")
      route(%{"held.example" => movie_route()})
      holder = hold_slot(held.id)

      assert Native.search("tt0133093") ==
               {:error, {:indexers_backing_off, ~U[2026-11-26 12:01:00Z]}}

      refute_received {:newznab_request, "held.example", _query}
      assert Repo.get(IndexerStatus, held.id) == nil
      send(holder, :finish)
    end

    test "with one indexer in a backoff that ends sooner, holds until that end" do
      held = indexer!(:newznab, "held.example")
      backing_off = indexer!(:newznab, "off.example")
      route(%{"held.example" => movie_route(), "off.example" => movie_route()})
      :written = IndexerStatus.record(backing_off, {:http_status, 500}, ~U[2026-11-26 11:59:30Z])
      holder = hold_slot(held.id)

      assert Native.search("tt0133093") ==
               {:error, {:indexers_backing_off, ~U[2026-11-26 12:00:30Z]}}

      refute_received {:newznab_request, _host, _query}
      send(holder, :finish)
    end

    test "with one indexer in a backoff that ends later, holds 60 s after the search" do
      held = indexer!(:newznab, "held.example")
      backing_off = indexer!(:newznab, "off.example")
      route(%{"held.example" => movie_route(), "off.example" => movie_route()})
      :written = IndexerStatus.record(backing_off, {:http_status, 500}, ~U[2026-11-26 11:59:30Z])
      :written = IndexerStatus.record(backing_off, {:http_status, 500}, ~U[2026-11-26 11:59:30Z])
      holder = hold_slot(held.id)

      # The second failure backs it off 5 min, to 12:04:30.
      assert Native.search("tt0133093") ==
               {:error, {:indexers_backing_off, ~U[2026-11-26 12:01:00Z]}}

      send(holder, :finish)
    end
  end

  describe "an indexer that answered before its next query was held back" do
    # A TV search on one warmed indexer: its id query answers one row, and while it holds the
    # slot the test queues `holder` ahead of the text query. `holder` runs inside the slot.
    defp answered_then_held(holder) do
      indexer = indexer!(:newznab, "one.example")
      test_pid = self()

      route(%{
        "one.example" => fn _conn, query ->
          case query do
            %{"tvdbid" => _id} ->
              send(test_pid, {:id_query, self()})

              receive do
                :holder_queued -> rss([item("Show S01E01", {:nzb, "https://one.example/1"})])
              end

            %{"q" => _q} ->
              send(test_pid, :text_query_sent)
              rss()

            _caps_or_warm ->
              :default
          end
        end
      })

      {:ok, [], _report} = Native.search("tt9999999")
      search = Task.async(fn -> Native.search_tv(81_189, "Show", 1) end)
      assert_receive {:id_query, stub}, 5_000

      start_supervised!(
        {Task,
         fn ->
           Lease.run(
             indexer.id,
             [deadline_at: System.monotonic_time(:millisecond) + 60_000],
             fn ->
               holder.(indexer)
             end
           )
         end},
        id: make_ref()
      )

      await_queued(indexer.id, :background, 1)
      send(stub, :holder_queued)
      {indexer, await_search(search)}
    end

    test "a text query the deadline cut keeps the id query's rows and reads as asked" do
      ConfigCase.put_env(Native, clock: fn -> @now end, deadline_ms: 1_000)

      {indexer, answer} =
        answered_then_held(fn _indexer ->
          receive do
            :finish -> :ok
          end
        end)

      assert {:ok, [%{title: "Show S01E01"}], report} = answer
      assert outcomes(report) == %{indexer.id => :asked}
      refute_received :text_query_sent
    end

    test "a text query a backoff held back keeps the id query's rows and reads as asked" do
      {indexer, answer} =
        answered_then_held(fn indexer ->
          :written = IndexerStatus.record(indexer, {:http_status, 500}, @now)
        end)

      assert {:ok, [%{title: "Show S01E01"}], report} = answer
      assert outcomes(report) == %{indexer.id => :asked}
      refute_received :text_query_sent
      # The control: the holder's failure backed the indexer off before the text query's turn.
      assert {:skipped, {:backoff, _until}} =
               IndexerStatus.gate(IndexerStatus.read([indexer])[indexer.id], @now)
    end
  end
end
