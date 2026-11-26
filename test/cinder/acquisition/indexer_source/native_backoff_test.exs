defmodule Cinder.Acquisition.IndexerSource.NativeBackoffTest do
  # What a search through the real `Cinder.Acquisition.IndexerSource.Native` does with the
  # backoff state (#1654): configured Newznab indexers behind the `Cinder.NewznabStub` plug
  # (`Cinder.NewznabFixtures.route/1`), whose stub tells the test process of every request, so a
  # skipped indexer shows as a request that never came. Every expected time is a literal.
  #
  # Not async: Native's clock, its deadline and the retry delay are global config.
  use Cinder.DataCase, async: false

  import Cinder.NewznabFixtures
  import Mox

  alias Cinder.Acquisition.{Indexer, IndexerAdapterMock}
  alias Cinder.Acquisition.IndexerSource.{Native, Report}
  alias Cinder.Acquisition.IndexerSource.Native.IndexerStatus
  alias Cinder.ConfigCase
  alias Cinder.Indexers

  setup :verify_on_exit!

  @now ~U[2026-11-26 12:00:00Z]

  setup do
    {:ok, clock} = Agent.start_link(fn -> @now end)
    ConfigCase.put_env(Native, clock: fn -> Agent.get(clock, & &1) end)
    %{clock: clock}
  end

  defp set_clock(clock, at), do: Agent.update(clock, fn _now -> at end)

  defp outcomes(%Report{indexers: indexers}),
    do: Map.new(indexers, fn {{"native", id}, %{outcome: outcome}} -> {id, outcome} end)

  defp status(indexer), do: IndexerStatus.read([indexer])[indexer.id]

  defp healthy_route,
    do: fn _conn, query ->
      if query["t"] == "movie",
        do: rss([item("Healthy", {:nzb, "https://ok.example/1"})]),
        else: :default
    end

  # Every request the stub got for `host` so far, caps included.
  defp requests(host) do
    receive_requests([])
    |> Enum.filter(fn {request_host, _query} -> request_host == host end)
  end

  defp receive_requests(acc) do
    receive do
      {:newznab_request, host, query} -> receive_requests([{host, query} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "rejected credentials" do
    for {name, answer} <- [
          {"code 100", {200, [], error(100, "Incorrect user credentials")}},
          {"code 101", {200, [], error(101, "Account suspended")}},
          {"code 102", {200, [], error(102, "Insufficient privileges")}},
          {"code 910", {200, [], error(910, "API disabled")}},
          {"HTTP 401", {401, [], ""}}
        ] do
      @answer answer

      test "#{name}: the next search sends the indexer no request and reports it failed" do
        rejected = indexer!(:newznab, "bad.example")
        healthy = indexer!(:newznab, "ok.example")

        route(%{
          "bad.example" => fn conn, query ->
            if query["t"] == "caps", do: :default, else: respond(conn, @answer)
          end,
          "ok.example" => healthy_route()
        })

        assert {:ok, [_row], first} = Native.search("tt0133093")
        assert outcomes(first)[rejected.id] == {:failed, :rejected_credentials}
        assert %{credentials_rejected: true, backoff_until: nil} = status(rejected)
        _drained = requests("bad.example")

        assert {:ok, [%{title: "Healthy"}], report} = Native.search("tt0133093")

        assert outcomes(report) == %{
                 rejected.id => {:failed, :rejected_credentials},
                 healthy.id => :asked
               }

        assert Report.incomplete?(report)
        refute_received {:newznab_request, "bad.example", _query}
        # The control: the healthy indexer's stub reported its request in the same search.
        assert_received {:newznab_request, "ok.example", %{"t" => "movie"}}
      end
    end

    test "with every indexer rejected, the search answers no indexer answered, not a hold" do
      rejected = indexer!(:newznab, "bad.example")
      route(%{"bad.example" => fn _conn, _query -> {401, ""} end})

      assert {:error, {:no_indexer_answered, _report}} = Native.search("tt0133093")

      assert {:error, {:no_indexer_answered, report}} = Native.search("tt0133093")
      assert outcomes(report) == %{rejected.id => {:failed, :rejected_credentials}}
    end

    test "a passing Test's :test_success or a config_version rise asks the indexer again" do
      rejected = indexer!(:newznab, "bad.example")

      route(%{
        "bad.example" => fn _conn, query ->
          if query["t"] == "caps", do: :default, else: {401, ""}
        end
      })

      assert {:error, {:no_indexer_answered, _report}} = Native.search("tt0133093")

      # A passing Test records `:test_success` through the same transitions (#1657 is to call them).
      :written = IndexerStatus.record(rejected, :test_success, @now)
      route(%{"bad.example" => fn _conn, _query -> :default end})
      _drained = requests("bad.example")
      assert {:ok, [], _report} = Native.search("tt0133093")
      assert [_request | _rest] = requests("bad.example")

      route(%{
        "bad.example" => fn _conn, query ->
          if query["t"] == "caps", do: :default, else: {401, ""}
        end
      })

      assert {:error, {:no_indexer_answered, _report}} = Native.search("tt0133093")
      assert status(rejected).credentials_rejected

      {:ok, _row} =
        Indexers.update(nil, rejected.id, rejected.lock_version, %{}, %{
          "api_key" => "new-key-0123"
        })

      route(%{"bad.example" => fn _conn, _query -> :default end})
      _drained = requests("bad.example")
      assert {:ok, [], _report} = Native.search("tt0133093")
      assert [_request | _rest] = requests("bad.example")
    end
  end

  describe "a backoff" do
    test "skips the indexer in it, keeps the other's rows, and reports the until-time", %{
      clock: clock
    } do
      failing = indexer!(:newznab, "down.example")
      healthy = indexer!(:newznab, "ok.example")

      route(%{
        "down.example" => fn _conn, query ->
          if query["t"] == "caps", do: :default, else: {500, "down"}
        end,
        "ok.example" => healthy_route()
      })

      assert {:ok, [_row], first} = Native.search("tt0133093")
      assert outcomes(first)[failing.id] == {:failed, {:http_status, 500}}
      _drained = requests("down.example")

      set_clock(clock, ~U[2026-11-26 12:00:59Z])
      assert {:ok, [%{title: "Healthy"}], report} = Native.search("tt0133093")

      assert outcomes(report) == %{
               failing.id => {:skipped, {:backoff, ~U[2026-11-26 12:01:00Z]}},
               healthy.id => :asked
             }

      refute Report.incomplete?(report)
      refute_received {:newznab_request, "down.example", _query}
      assert_received {:newznab_request, "ok.example", %{"t" => "movie"}}

      # At its until-time the backoff has ended: the indexer is asked again, its level kept.
      set_clock(clock, ~U[2026-11-26 12:01:00Z])
      assert {:ok, [_row], again} = Native.search("tt0133093")
      assert outcomes(again)[failing.id] == {:failed, {:http_status, 500}}
      assert [_request | _rest] = requests("down.example")

      assert %{level: 2, backoff_until: ~U[2026-11-26 12:06:00Z]} = status(failing)
    end

    # The stubs move the clock 40 s on before they answer, as a slow indexer would.
    test "counts its until-time and the recorded times from the answer, not the request", %{
      clock: clock
    } do
      failing = indexer!(:newznab, "slow-down.example")
      limited = indexer!(:newznab, "slow-limit.example")
      no_caps = indexer!(:newznab, "slow-caps.example")
      answered = ~U[2026-11-26 12:00:40Z]

      slow = fn answer ->
        fn _conn, query ->
          if query["t"] == "caps", do: :default, else: set_clock(clock, answered) && answer
        end
      end

      route(%{
        "slow-down.example" => slow.({500, "down"}),
        "slow-limit.example" => slow.({429, [{"retry-after", "120"}], ""}),
        "slow-caps.example" => fn _conn, _query -> set_clock(clock, answered) && {500, "down"} end
      })

      assert {:error, {:no_indexer_answered, report}} = Native.search("tt0133093")
      assert outcomes(report)[limited.id] == {:failed, {:limit, ~U[2026-11-26 12:02:40Z]}}

      assert %{backoff_until: ~U[2026-11-26 12:01:40Z], last_failure_at: ^answered} =
               status(failing)

      assert %{backoff_until: ~U[2026-11-26 12:02:40Z], last_failure_at: ^answered} =
               status(limited)

      assert %{backoff_until: ~U[2026-11-26 12:01:40Z], last_failure_at: ^answered} =
               status(no_caps)
    end

    test "on every indexer holds the search until the earliest until-time, with no request", %{
      clock: clock
    } do
      short = indexer!(:newznab, "short.example")
      long = indexer!(:newznab, "long.example")
      :written = IndexerStatus.record(long, :timeout, @now)
      :written = IndexerStatus.record(long, :timeout, @now)
      :written = IndexerStatus.record(short, {:limit, ~U[2026-11-26 12:03:00Z]}, @now)

      route(%{
        "short.example" => fn _conn, _query -> :default end,
        "long.example" => fn _conn, _query -> :default end
      })

      set_clock(clock, ~U[2026-11-26 12:02:00Z])

      assert Native.search("tt0133093") ==
               {:error, {:indexers_backing_off, ~U[2026-11-26 12:03:00Z]}}

      refute_received {:newznab_request, _host, _query}

      # The control: once the limit has ended, the same search sends that indexer its requests.
      set_clock(clock, ~U[2026-11-26 12:03:00Z])
      assert {:ok, [], report} = Native.search("tt0133093")
      assert outcomes(report)[long.id] == {:skipped, {:backoff, ~U[2026-11-26 12:05:00Z]}}
      assert [_request | _rest] = requests("short.example")
      assert requests("long.example") == []
    end

    test "a limit reports and records its end, and a passing Test's :test_success leaves it", %{
      clock: clock
    } do
      limited = indexer!(:newznab, "limit.example")
      healthy = indexer!(:newznab, "ok.example")

      route(%{
        "limit.example" => fn _conn, query ->
          if query["t"] == "caps", do: :default, else: {429, [{"retry-after", "120"}], ""}
        end,
        "ok.example" => healthy_route()
      })

      assert {:ok, [_row], report} = Native.search("tt0133093")
      assert outcomes(report)[limited.id] == {:failed, {:limit, ~U[2026-11-26 12:02:00Z]}}

      assert %{backoff: :limit, backoff_until: ~U[2026-11-26 12:02:00Z], level: 0} =
               status(limited)

      # A passing Test records `:test_success`: the limit stays, and the next search skips it.
      set_clock(clock, ~U[2026-11-26 12:01:00Z])
      :written = IndexerStatus.record(limited, :test_success, ~U[2026-11-26 12:01:00Z])
      assert {:ok, [_row], report} = Native.search("tt0133093")
      assert outcomes(report)[limited.id] == {:skipped, {:backoff, ~U[2026-11-26 12:02:00Z]}}
      assert outcomes(report)[healthy.id] == :asked
    end

    test "Indexer is disabled till ends at its Retry-After, and a Test's :test_success ends it",
         %{
           clock: clock
         } do
      disabled = indexer!(:newznab, "prowlarr.example")
      healthy = indexer!(:newznab, "ok.example")

      route(%{
        "prowlarr.example" => fn _conn, query ->
          if query["t"] == "caps",
            do: :default,
            else:
              {429, [{"retry-after", "600"}],
               error(429, "Indexer is disabled till 11/26/2026 12:10:00 due to recent failures.")}
        end,
        "ok.example" => healthy_route()
      })

      assert {:ok, [_row], _report} = Native.search("tt0133093")

      assert %{backoff: :failure, backoff_until: ~U[2026-11-26 12:10:00Z], level: 1} =
               status(disabled)

      set_clock(clock, ~U[2026-11-26 12:05:00Z])
      assert {:ok, [_row], report} = Native.search("tt0133093")
      assert outcomes(report)[disabled.id] == {:skipped, {:backoff, ~U[2026-11-26 12:10:00Z]}}

      :written = IndexerStatus.record(disabled, :test_success, ~U[2026-11-26 12:05:00Z])
      assert %{backoff: :none} = status(disabled)
      _drained = requests("prowlarr.example")
      assert {:ok, [_row], report} = Native.search("tt0133093")
      assert outcomes(report)[disabled.id] == {:failed, {:http_status, 429}}
      assert outcomes(report)[healthy.id] == :asked
      assert [_request | _rest] = requests("prowlarr.example")
    end
  end

  describe "a query error" do
    test "codes 200 to 203 and 300 leave the row byte for byte as it was" do
      indexer = indexer!(:newznab, "a.example")
      :written = IndexerStatus.record(indexer, :timeout, ~U[2026-11-26 11:00:00Z])
      before = raw_row(indexer.id)

      for code <- [200, 201, 202, 203, 300] do
        route(%{
          "a.example" => fn _conn, query ->
            if query["t"] == "caps", do: :default, else: {400, [], error(code, "Bad query")}
          end
        })

        assert {:error, {:no_indexer_answered, report}} = Native.search("tt0133093")
        assert {code, outcomes(report)[indexer.id]} == {code, {:failed, {:indexer_error, code}}}
        assert {code, raw_row(indexer.id)} == {code, before}
      end
    end
  end

  describe "the one retry" do
    test "a 502 then a 200 records a success, the second request 2 s after the first" do
      ConfigCase.put_env(Indexer, [])
      indexer = indexer!(:newznab, "a.example")
      test_pid = self()
      {:ok, answers} = Agent.start_link(fn -> [{502, "bad gateway"}] end)

      route(%{
        "a.example" => fn _conn, query ->
          case query do
            %{"t" => "caps"} ->
              :default

            _search ->
              send(test_pid, {:search_at, System.monotonic_time(:millisecond)})

              Agent.get_and_update(answers, fn
                [answer] -> {answer, []}
                [] -> {rss(), []}
              end)
          end
        end
      })

      assert {:ok, [], report} = Native.search("tt0133093")
      assert outcomes(report) == %{indexer.id => :asked}
      assert_received {:search_at, first}
      assert_received {:search_at, second}
      assert (second - first) in 2_000..2_999
      assert %{last_success_at: @now, level: 0, backoff: :none} = status(indexer)
    end

    test "a 502 twice records one failure step, and a 500 is sent once" do
      for {code, searches} <- [{502, 2}, {500, 1}] do
        indexer = indexer!(:newznab, "s#{code}.example")

        route(%{
          "s#{code}.example" => fn _conn, query ->
            if query["t"] == "caps", do: :default, else: {code, "down"}
          end
        })

        assert {:error, {:no_indexer_answered, _report}} = Native.search("tt0133093")
        assert {code, length(searches("s#{code}.example"))} == {code, searches}

        assert {code, status(indexer).level, status(indexer).backoff_until} ==
                 {code, 1, ~U[2026-11-26 12:01:00Z]}

        :ok = Indexers.delete(nil, indexer.id)
      end
    end
  end

  describe "a request the deadline cuts" do
    test "changes no row" do
      ConfigCase.put_env(Native, clock: fn -> @now end, deadline_ms: 2_000)
      indexer = indexer!(:newznab, "slow.example")
      :written = IndexerStatus.record(indexer, :success, ~U[2026-11-26 11:00:00Z])
      before = raw_row(indexer.id)
      test_pid = self()

      route(%{
        "slow.example" => fn _conn, query ->
          case query do
            %{"t" => "caps"} ->
              :default

            _search ->
              send(test_pid, :search_sent)
              Process.sleep(:infinity)
          end
        end
      })

      assert {:error, {:indexers_backing_off, _retry_at}} = Native.search("tt0133093")
      # The control: the search was sent, so the deadline, not a skip, ended it.
      assert_received :search_sent
      assert raw_row(indexer.id) == before
    end
  end

  describe "the hold's retry_at beside a deadline cut" do
    test "is the earlier of the backoff's end and 60 s after the search" do
      ConfigCase.put_env(:indexer_adapters, %{newznab: IndexerAdapterMock})
      backing_off = indexer!(:newznab, "off.example")
      cut = indexer!(:newznab, "cut.example")
      test_pid = self()

      stub(IndexerAdapterMock, :search, fn indexer, _query, _context ->
        send(test_pid, {:searched, indexer.id})
        {[], {:failed, :deadline}}
      end)

      for {until, retry_at} <- [
            {~U[2026-11-26 12:05:00Z], ~U[2026-11-26 12:01:00Z]},
            {~U[2026-11-26 12:00:30Z], ~U[2026-11-26 12:00:30Z]}
          ] do
        :written = IndexerStatus.record(backing_off, {:limit, until}, ~U[2026-11-26 11:59:00Z])

        assert {until, Native.search("tt0133093")} ==
                 {until, {:error, {:indexers_backing_off, retry_at}}}

        assert_received {:searched, id}
        assert id == cut.id
        refute_received {:searched, _id}
      end
    end
  end

  describe "a database error while recording" do
    # The table is dropped inside the test's sandbox transaction, after the gate read it, so each
    # status read or write the search makes then raises an `Exqlite.Error`.
    test "keeps the search's rows and its outcome, and logs the indexer id only" do
      indexer = indexer!(:newznab, "ok.example")

      route(%{
        "ok.example" => fn _conn, query ->
          if query["t"] == "movie" do
            Repo.query!("DROP TABLE native_indexer_status")
            rss([item("Healthy", {:nzb, "https://ok.example/1"})])
          else
            :default
          end
        end
      })

      {result, log} = ExUnit.CaptureLog.with_log(fn -> Native.search("tt0133093") end)

      assert {:ok, [%{title: "Healthy"}], report} = result
      assert outcomes(report) == %{indexer.id => :asked}
      assert log =~ "native indexer status of indexer #{indexer.id} not recorded: Exqlite.Error"
      refute log =~ "ok.example"
    end

    test "leaves a crashed search reported as crashed" do
      ConfigCase.put_env(:indexer_adapters, %{newznab: IndexerAdapterMock})
      indexer = indexer!(:newznab, "crash.example")

      stub(IndexerAdapterMock, :search, fn _indexer, _query, _context ->
        Repo.query!("DROP TABLE native_indexer_status")
        raise "boom"
      end)

      {result, _log} = ExUnit.CaptureLog.with_log(fn -> Native.search("tt0133093") end)
      assert {:error, {:no_indexer_answered, report}} = result
      assert outcomes(report) == %{indexer.id => {:failed, :crashed}}
    end
  end

  describe "a crashed search" do
    test "is recorded as a failure step" do
      ConfigCase.put_env(:indexer_adapters, %{newznab: IndexerAdapterMock})
      indexer = indexer!(:newznab, "crash.example")
      stub(IndexerAdapterMock, :search, fn _indexer, _query, _context -> raise "boom" end)

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:no_indexer_answered, _report}} = Native.search("tt0133093")
      end)

      assert %{backoff: :failure, level: 1, last_failure: :crashed} = status(indexer)
    end

    # A kill, as the heap cap gives, ends the process with no answer: Native reads its `:DOWN`.
    test "is recorded as a failure step when its process is killed" do
      ConfigCase.put_env(:indexer_adapters, %{newznab: IndexerAdapterMock})
      indexer = indexer!(:newznab, "killed.example")

      stub(IndexerAdapterMock, :search, fn _indexer, _query, _context ->
        Process.exit(self(), :kill)
      end)

      assert {:error, {:no_indexer_answered, _report}} = Native.search("tt0133093")
      assert %{backoff: :failure, level: 1, last_failure: :crashed} = status(indexer)
    end
  end

  defp raw_row(id) do
    %{rows: rows} =
      Repo.query!("SELECT * FROM native_indexer_status WHERE configured_indexer_id = ?", [id])

    rows
  end
end
