defmodule Cinder.Acquisition.IndexerSource.NativeTestIndexerTest do
  # The per-indexer Test (`Native.test_indexer/1`, #1657, #1619 point 11, #1625 point 3) through
  # the real Newznab and Torznab adapters behind the `Cinder.NewznabStub` plug
  # (`Cinder.NewznabFixtures.route/1`), whose stub tells the test process of every request, so a
  # refused Test shows as a request that never came. A blocking stub `receive`s, since
  # `req_stub_sleep_test.exs` refuses a sleep. Every expected time is a literal.
  #
  # Not async: Native's clock and budget, the adapter map and the lease are global config.
  use Cinder.DataCase, async: false

  import Cinder.NewznabFixtures

  alias Cinder.Acquisition.IndexerSource.Native
  alias Cinder.Acquisition.IndexerSource.Native.{IndexerCaps, IndexerState, IndexerStatus, Lease}
  alias Cinder.ConfigCase
  alias Cinder.Indexers
  alias Cinder.Repo

  @now ~U[2026-11-26 12:00:00Z]

  setup do
    ConfigCase.put_env(Native, clock: fn -> @now end)
    :ok
  end

  defp at(seconds), do: DateTime.add(@now, seconds, :second)
  defp status(indexer), do: IndexerStatus.read([indexer])[indexer.id]

  # Every request the stub got for `host` so far, caps included, in order.
  defp requests(host) do
    receive_requests([])
    |> Enum.filter(fn {request_host, _query} -> request_host == host end)
    |> Enum.map(&elem(&1, 1))
  end

  defp receive_requests(acc) do
    receive do
      {:newznab_request, host, query} -> receive_requests([{host, query} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # Answers the Test's `t=search` with `answer`, every caps request with the default caps.
  defp search_route(answer) do
    fn conn, query ->
      case query do
        %{"t" => "search"} -> respond(conn, answer)
        _caps -> :default
      end
    end
  end

  # Native reads the clock between `before` and `after_call`, so a budget of exactly 90,000 ms
  # puts the deadline at least 90,000 ms past `before` and at most 90,000 ms past `after_call`.
  test "the app runs the Test with a 90 s budget, handed to the adapter" do
    indexer = indexer!(:newznab, "nzb.example")
    ConfigCase.put_env(:indexer_adapters, %{newznab: Cinder.Acquisition.IndexerAdapterMock})
    test_pid = self()

    Mox.stub(Cinder.Acquisition.IndexerAdapterMock, :test, fn _indexer, context, _record ->
      send(test_pid, {:context, context})
      {:not_run, {:skipped, :deadline}}
    end)

    before = System.monotonic_time(:millisecond)
    Native.test_indexer(indexer.id)
    after_call = System.monotonic_time(:millisecond)

    assert_received {:context, %{deadline_at: deadline_at, priority: :interactive}}
    assert deadline_at - before >= 90_000
    assert deadline_at - after_call <= 90_000
  end

  describe "a passing Test" do
    test "refetches the caps, then sends one keyed t=search with no query terms" do
      indexer = indexer!(:newznab, "nzb.example")
      route(%{"nzb.example" => search_route(rss())})

      assert Native.test_indexer(indexer.id) == {:ok, %{outcome: :success, at: @now}}

      assert [%{"t" => "caps"}, search] = requests("nzb.example")
      assert search == %{"t" => "search", "cat" => "2000,2040", "apikey" => key()}
    end

    test "a Torznab Test scopes its search to TV, listed sub-categories included" do
      indexer = indexer!(:torznab, "tracker.example")

      route(%{
        "tracker.example" => fn conn, query ->
          case query do
            %{"t" => "caps"} -> respond(conn, caps(categories: [2000, 5000, 5070]))
            %{"t" => "search"} -> respond(conn, rss())
          end
        end
      })

      assert {:ok, %{outcome: :success}} = Native.test_indexer(indexer.id)
      assert [_caps, %{"cat" => "5000,5070"}] = requests("tracker.example")
    end

    test "with caps that list no category under the type's, sends no cat" do
      indexer = indexer!(:newznab, "nzb.example")

      route(%{
        "nzb.example" => fn conn, query ->
          case query do
            %{"t" => "caps"} -> respond(conn, caps(categories: [7020]))
            %{"t" => "search"} -> respond(conn, rss())
          end
        end
      })

      assert {:ok, %{outcome: :success}} = Native.test_indexer(indexer.id)
      assert [_caps, search] = requests("nzb.example")
      refute Map.has_key?(search, "cat")
    end

    test "ends a failure backoff" do
      indexer = indexer!(:newznab, "nzb.example")
      :written = IndexerStatus.record(indexer, {:http_status, 500}, at(-10))
      route(%{"nzb.example" => search_route(rss())})

      assert {:ok, %{outcome: :success}} = Native.test_indexer(indexer.id)

      assert %{backoff: :none, failures_in_row: 0, last_success_at: @now} = status(indexer)
    end

    test "ends rejected credentials" do
      indexer = indexer!(:newznab, "nzb.example")
      :written = IndexerStatus.record(indexer, {:rejected_credentials, {:code, 100}}, at(-10))
      route(%{"nzb.example" => search_route(rss())})

      assert {:ok, %{outcome: :success}} = Native.test_indexer(indexer.id)
      assert %{credentials_rejected: false} = status(indexer)
    end

    test "keeps a running limit backoff, and stores the Test's outcome during it" do
      indexer = indexer!(:newznab, "nzb.example")
      :written = IndexerStatus.record(indexer, {:limit, at(3_600)}, at(-10))
      route(%{"nzb.example" => search_route(rss())})

      assert Native.test_indexer(indexer.id) == {:ok, %{outcome: :success, at: @now}}

      assert %{backoff: :limit, backoff_until: ~U[2026-11-26 13:00:00Z]} = status(indexer)
      assert IndexerStatus.last_test(status(indexer)) == %{outcome: :success, at: @now}

      assert [%{state: {:limit_backoff, ~U[2026-11-26 13:00:00Z]}, last_test: last_test}] =
               IndexerState.list()

      assert last_test == %{outcome: :success, at: @now}
    end

    test "reaches a disabled indexer and stores its outcome" do
      indexer = indexer!(:newznab, "off.example")
      {:ok, off} = Indexers.set_enabled(nil, indexer.id, indexer.lock_version, false)
      route(%{"off.example" => search_route(rss())})

      assert Native.test_indexer(off.id) == {:ok, %{outcome: :success, at: @now}}
      assert [_caps, _search] = requests("off.example")
      assert IndexerStatus.last_test(status(off)) == %{outcome: :success, at: @now}

      assert [%{state: :disabled, last_test: %{outcome: :success, at: @now}}] =
               IndexerState.list()
    end
  end

  describe "a failing Test" do
    test "a limit answer starts a limit backoff" do
      indexer = indexer!(:newznab, "nzb.example")
      route(%{"nzb.example" => search_route({429, [{"retry-after", "600"}], ""})})

      assert Native.test_indexer(indexer.id) == {:ok, %{outcome: :limit, at: @now}}
      assert %{backoff: :limit, backoff_until: ~U[2026-11-26 12:10:00Z]} = status(indexer)
    end

    test "a failure climbs one step of the ladder" do
      indexer = indexer!(:newznab, "nzb.example")
      :written = IndexerStatus.record(indexer, {:http_status, 500}, at(-600))
      route(%{"nzb.example" => search_route({410, ""})})

      assert Native.test_indexer(indexer.id) ==
               {:ok, %{outcome: {:http_status, 410}, at: @now}}

      assert %{level: 2, failures_in_row: 2, backoff_until: ~U[2026-11-26 12:05:00Z]} =
               status(indexer)
    end

    test "asks an indexer in a failure backoff and with rejected credentials" do
      indexer = indexer!(:newznab, "nzb.example")
      :written = IndexerStatus.record(indexer, :timeout, at(-10))
      :written = IndexerStatus.record(indexer, :rejected_credentials, at(-5))
      route(%{"nzb.example" => search_route({401, ""})})

      assert {:ok, %{outcome: :rejected_credentials}} = Native.test_indexer(indexer.id)
      assert [_caps, %{"t" => "search"}] = requests("nzb.example")
    end

    test "a caps fetch that fails records a failure and sends no search" do
      indexer = indexer!(:newznab, "nzb.example")

      route(%{
        "nzb.example" => fn conn, %{"t" => "caps"} -> respond(conn, {500, ""}) end
      })

      assert Native.test_indexer(indexer.id) ==
               {:ok, %{outcome: {:http_status, 500}, at: @now}}

      assert [%{"t" => "caps"}] = requests("nzb.example")
      assert %{level: 1, last_failure: :http_status, last_failure_code: 500} = status(indexer)
    end

    test "a stub that never answers ends the Test as a timeout failure at its budget" do
      ConfigCase.put_env(Native, clock: fn -> @now end, test_budget_ms: 500)
      indexer = indexer!(:newznab, "slow.example")

      route(%{
        "slow.example" => fn _conn, _query ->
          receive do
            :never_sent -> :default
          end
        end
      })

      assert Native.test_indexer(indexer.id) == {:ok, %{outcome: :timeout, at: @now}}
      assert %{level: 1, last_failure: :timeout} = status(indexer)
    end

    # The caps answer gets the 10 s budget's headroom. The search's 503 asks for a retry 60 s
    # later, past the budget, so `Indexer.request/3` answers `:deadline` at once and sends no
    # retry: the Test ends well before half its budget.
    test "a search the budget cut after its caps answered ends the Test as a timeout failure" do
      ConfigCase.put_env(Native, clock: fn -> @now end, test_budget_ms: 10_000)

      ConfigCase.put_env(
        Cinder.Acquisition.Indexer,
        :cinder
        |> Application.get_env(Cinder.Acquisition.Indexer, [])
        |> Keyword.merge(retry_delay_ms: 60_000)
      )

      indexer = indexer!(:newznab, "slow.example")
      route(%{"slow.example" => search_route({503, ""})})

      {elapsed_us, answer} = :timer.tc(fn -> Native.test_indexer(indexer.id) end)
      assert answer == {:ok, %{outcome: :timeout, at: @now}}
      assert elapsed_us < 5_000_000
      assert [%{"t" => "caps"}, %{"t" => "search"}] = requests("slow.example")
      assert %{level: 1, last_failure: :timeout} = status(indexer)
    end
  end

  describe "the caps" do
    test "an expired caps row is replaced by the Test's fetch" do
      indexer = indexer!(:newznab, "nzb.example")
      ConfigCase.put_env(Native, clock: fn -> at(-8 * 24 * 3_600) end)
      {:ok, _caps} = IndexerCaps.refetch(indexer, fn -> {:ok, %{"old" => true}} end)
      ConfigCase.put_env(Native, clock: fn -> @now end)
      route(%{"nzb.example" => search_route(rss())})

      assert {:ok, %{outcome: :success}} = Native.test_indexer(indexer.id)

      row = Repo.get(IndexerCaps, indexer.id)
      refute Map.has_key?(row.caps, "old")
      assert DateTime.truncate(row.fetched_at, :second) == @now
    end

    test "a caps row still usable is fetched again" do
      indexer = indexer!(:newznab, "nzb.example")
      {:ok, _caps} = IndexerCaps.refetch(indexer, fn -> {:ok, %{"fresh" => true}} end)
      route(%{"nzb.example" => search_route(rss())})

      assert {:ok, %{outcome: :success}} = Native.test_indexer(indexer.id)
      assert [%{"t" => "caps"}, _search] = requests("nzb.example")
      refute Map.has_key?(Repo.get(IndexerCaps, indexer.id).caps, "fresh")
    end
  end

  describe "a refused Test sends no request" do
    test "for an indexer whose secrets do not decrypt" do
      indexer = indexer!(:newznab, "locked.example")
      :ok = undecryptable!(indexer)
      route(%{"locked.example" => search_route(rss())})

      assert Native.test_indexer(indexer.id) == {:error, :undecryptable_secrets}
      refute_received {:newznab_request, "locked.example", _query}
      assert Repo.get(IndexerStatus, indexer.id) == nil
    end

    test "for a FlareSolverr indexer and a type with no adapter" do
      flare = indexer!(:torznab, "flare.example", %{flaresolverr: true})
      torrent = indexer!(:torznab, "tracker.example")
      route(%{"flare.example" => search_route(rss()), "tracker.example" => search_route(rss())})

      assert Native.test_indexer(flare.id) == {:error, {:not_supported, :flaresolverr}}

      ConfigCase.put_env(:indexer_adapters, %{newznab: Cinder.Acquisition.Indexer.Newznab})
      assert Native.test_indexer(torrent.id) == {:error, {:not_supported, :torznab}}

      refute_received {:newznab_request, _host, _query}
      assert Repo.get(IndexerStatus, flare.id) == nil
    end

    test "for an id no configured indexer has" do
      assert Native.test_indexer(999_999) == {:error, :not_found}
    end

    test "the control: the same indexer's Test reaches the stub once it decrypts" do
      indexer = indexer!(:newznab, "ok.example")
      route(%{"ok.example" => search_route(rss())})

      assert {:ok, %{outcome: :success}} = Native.test_indexer(indexer.id)
      assert_received {:newznab_request, "ok.example", %{"t" => "search"}}
    end
  end

  describe "an edit while the Test runs" do
    test "a config_version rise leaves the status row and the last Test unchanged" do
      indexer = indexer!(:newznab, "nzb.example")
      {:written, before} = IndexerStatus.record_test(indexer, {:http_status, 503}, at(-60))
      before_status = status(indexer)

      route(%{
        "nzb.example" => fn conn, query ->
          case query do
            %{"t" => "search"} ->
              {:ok, _edited} =
                Indexers.update(nil, indexer.id, indexer.lock_version, %{api_path: "/v2/api"})

              respond(conn, rss())

            _caps ->
              :default
          end
        end
      })

      assert Native.test_indexer(indexer.id) == {:error, :dropped}

      edited = Repo.get!(Cinder.Indexers.ConfiguredIndexer, indexer.id)
      assert edited.config_version == indexer.config_version + 1
      stored = Repo.get!(IndexerStatus, indexer.id)
      assert IndexerStatus.last_test(stored) == before
      assert Map.delete(stored, :__meta__) == Map.delete(before_status, :__meta__)
    end
  end

  describe "the slot" do
    # Holds `indexer`'s slot in a supervised task until it gets `:finish`.
    defp hold_slot(indexer) do
      test_pid = self()

      holder =
        start_supervised!(
          {Task,
           fn ->
             Lease.run(
               indexer.id,
               [deadline_at: System.monotonic_time(:millisecond) + 60_000],
               fn ->
                 send(test_pid, :holding)

                 receive do
                   :finish -> :ok
                 end
               end
             )
           end}
        )

      assert_receive :holding
      holder
    end

    # Polls the app's lease until `indexer`'s entry satisfies `ready?`, and answers that entry.
    defp await_lease(indexer, ready?, rounds \\ 400) do
      entry = Map.get(:sys.get_state(Lease).indexers, indexer.id)

      cond do
        entry != nil and ready?.(entry) -> entry
        rounds > 0 -> Process.sleep(5) && await_lease(indexer, ready?, rounds - 1)
        true -> flunk("the lease never reached the awaited state: #{inspect(entry)}")
      end
    end

    defp lease_holder(%{holder: {pid, _ref, _monitor, _delay}}), do: pid
    defp lease_holder(_entry), do: nil

    test "waits for a running request to the indexer" do
      indexer = indexer!(:newznab, "nzb.example")
      route(%{"nzb.example" => search_route(rss())})
      holder = hold_slot(indexer)

      run = Task.async(fn -> Native.test_indexer(indexer.id) end)
      waiting = await_lease(indexer, &(:queue.len(&1.interactive) == 1))
      assert lease_holder(waiting) == holder
      refute_received {:newznab_request, "nzb.example", _query}

      send(holder, :finish)
      assert {:ok, %{outcome: :success}} = Task.await(run, 10_000)
      assert [%{"t" => "caps"}, %{"t" => "search"}] = requests("nzb.example")
    end

    test "goes ahead of a background request queued before it" do
      indexer = indexer!(:newznab, "nzb.example")
      test_pid = self()

      # The Test's caps request holds the slot until the test sends `:go`, so the lease's state
      # stays put while the test reads it.
      route(%{
        "nzb.example" => fn conn, query ->
          case query do
            %{"t" => "caps"} ->
              send(test_pid, {:caps_holding, self()})

              receive do
                :go -> :default
              end

            _search ->
              respond(conn, rss())
          end
        end
      })

      holder = hold_slot(indexer)

      background =
        start_supervised!(
          {Task,
           fn ->
             Lease.run(
               indexer.id,
               [deadline_at: System.monotonic_time(:millisecond) + 60_000, priority: :background],
               fn -> send(test_pid, :background_ran) end
             )
           end},
          id: :background
        )

      # A cast from another process can reach the lease after the test's own reads of its state
      # (testing.md), so each wait polls the state until the lease holds the request.
      await_lease(indexer, &(:queue.len(&1.background) == 1))
      run = Task.async(fn -> Native.test_indexer(indexer.id) end)
      await_lease(indexer, &(:queue.len(&1.interactive) == 1))

      send(holder, :finish)
      assert_receive {:caps_holding, stub}, 10_000

      # The Test holds the slot and the background request still waits for it.
      granted = await_lease(indexer, &(lease_holder(&1) not in [nil, holder]))
      assert lease_holder(granted) != background
      assert :queue.len(granted.background) == 1

      send(stub, :go)
      assert {:ok, %{outcome: :success}} = Task.await(run, 10_000)
      assert_receive :background_ran, 10_000
    end

    test "a Test still waiting for the slot at its budget sends nothing and records nothing" do
      ConfigCase.put_env(Native, clock: fn -> @now end, test_budget_ms: 300)
      indexer = indexer!(:newznab, "nzb.example")
      route(%{"nzb.example" => search_route(rss())})
      holder = hold_slot(indexer)

      assert Native.test_indexer(indexer.id) == {:error, :deadline}
      refute_received {:newznab_request, "nzb.example", _query}
      assert Repo.get(IndexerStatus, indexer.id) == nil

      # The control: once the slot frees, the same Test reaches the stub and records.
      send(holder, :finish)
      ConfigCase.put_env(Native, clock: fn -> @now end, test_budget_ms: 10_000)
      assert {:ok, %{outcome: :success}} = Native.test_indexer(indexer.id)
      assert [%{"t" => "caps"}, %{"t" => "search"}] = requests("nzb.example")
    end
  end

  describe "Native.health/0" do
    test "sends no request, while a Test of the same indexer reaches the stub" do
      indexer = indexer!(:newznab, "nzb.example")
      route(%{"nzb.example" => search_route(rss())})

      assert {:error, {:native_indexers, [_entry], 0, @now}} = Native.health()
      refute_received {:newznab_request, _host, _query}

      assert {:ok, %{outcome: :success}} = Native.test_indexer(indexer.id)
      assert [%{"t" => "caps"}, %{"t" => "search"}] = requests("nzb.example")
      assert Native.health() == :ok
      refute_received {:newznab_request, _host, _query}
    end
  end
end
