defmodule Cinder.RepoWatchTest do
  # The `db watch:` lines of #1310. Each test attaches its own handler with an injected clock or
  # threshold and never sleeps for one. The clock reads the calling process's dictionary, and the
  # handler runs in the process that queries, so a test moves time for its own transaction alone.
  # `async: false`: a telemetry handler sees every process's queries, and two tests change the
  # VM's backtrace depth or the app env.
  use Cinder.DataCase, async: false

  import ExUnit.CaptureLog

  alias Cinder.Accounts.User
  alias Cinder.{ConfigCase, GuardedWrite, RepoWatch}
  alias Cinder.RepoWatch.{Stall, Thresholds}
  alias Exqlite.Sqlite3

  @now :repo_watch_test_now
  @secret "repo-watch-secret-param@example.com"

  defmodule ProbeRepo do
    use Ecto.Repo, otp_app: :cinder, adapter: Ecto.Adapters.SQLite3
  end

  # Attaches a handler on `Cinder.Repo` (or `opts[:event]`) whose clock is `at/1`. Queue lines
  # stay off unless a test lowers `:queue_ms`.
  defp watch(opts \\ []) do
    id = {__MODULE__, make_ref()}
    clock = fn -> Process.get(@now, 0) end
    :ok = RepoWatch.attach([handler_id: id, clock: clock, queue_ms: 60_000] ++ opts)
    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp at(ms), do: Process.put(@now, ms)

  defp watch_lines(log) do
    log |> String.split("\n") |> Enum.filter(&String.contains?(&1, RepoWatch.prefix()))
  end

  defp task_supervisor, do: start_supervised!(Task.Supervisor)

  defp test_fun(ctx), do: Exception.format_mfa(__MODULE__, ctx.test, 1)

  defp native(ms), do: System.convert_time_unit(ms, :millisecond, :native)

  describe "hold lines for transactions" do
    test "a transaction held past the threshold logs one line with its opener, hold and commit",
         ctx do
      watch()

      log =
        capture_log(fn ->
          at(0)

          assert {:ok, :done} =
                   Repo.transaction(fn ->
                     at(1_500)
                     :done
                   end)
        end)

      assert [line] = watch_lines(log)
      assert line =~ "db watch: hold 1500 ms, committed (begin wait "
      assert line =~ ~r/in SQL \d+ ms, commit \d+ ms\) by /
      assert line =~ test_fun(ctx)
      assert line =~ ~r/test\/cinder\/repo_watch_test\.exs:\d+\)/
      assert line =~ ~r/ in :erlang\.apply\/2 #PID<[\d.]+>$/
    end

    test "a transaction under the threshold logs nothing" do
      watch()

      log =
        capture_log(fn ->
          at(0)
          assert {:ok, _} = Repo.transaction(fn -> at(999) end)
        end)

      assert watch_lines(log) == []
    end

    test "a rolled-back transaction says it rolled back", ctx do
      watch()

      log =
        capture_log(fn ->
          at(0)

          assert {:error, :nope} =
                   Repo.transaction(fn ->
                     at(1_500)
                     Repo.rollback(:nope)
                   end)
        end)

      assert [line] = watch_lines(log)
      assert line =~ "db watch: hold 1500 ms, rolled back ("
      assert line =~ ~r/rollback \d+ ms\) by /
      assert line =~ test_fun(ctx)
    end

    test "a nested pair of Repo.transaction logs once, for the outermost", ctx do
      watch()

      log =
        capture_log(fn ->
          at(0)

          assert {:ok, {:ok, _}} =
                   Repo.transaction(fn -> Repo.transaction(fn -> at(1_500) end) end)
        end)

      assert [line] = watch_lines(log)
      assert line =~ "hold 1500 ms, committed"
      assert line =~ test_fun(ctx)
    end

    test "a nested pair of GuardedWrite.transaction logs once and names its caller, not the wrapper",
         ctx do
      watch()

      log =
        capture_log(fn ->
          at(0)

          assert {:ok, {:ok, _}} =
                   GuardedWrite.transaction(fn ->
                     GuardedWrite.transaction(fn -> at(1_500) end)
                   end)
        end)

      assert [line] = watch_lines(log)
      assert line =~ "hold 1500 ms, committed"
      assert line =~ test_fun(ctx)
      refute line =~ "by Cinder.GuardedWrite"
    end

    # A statement inside a transaction is part of its hold: with the hold threshold at 0, a
    # statement that read as outside a transaction would log a line of its own.
    test "a slow statement inside a slow transaction logs only the transaction" do
      watch(hold_ms: 0)

      log =
        capture_log(fn ->
          at(0)
          assert {:ok, _} = Repo.transaction(fn -> Repo.all(User) end)
        end)

      assert [line] = watch_lines(log)
      assert line =~ "committed"
      refute line =~ ", statement "
    end

    test "the line sums the statements inside and prints BEGIN's wait apart from the hold" do
      watch()
      config = %{hold_ms: 1_000, queue_ms: 60_000, clock: fn -> Process.get(@now, 0) end}
      inside = %{query: "SELECT 1", repo: Repo, result: {:ok, nil}, source: nil}

      log =
        capture_log(fn ->
          at(0)

          assert {:ok, _} =
                   Repo.transaction(fn ->
                     RepoWatch.handle_event([], %{query_time: native(400)}, inside, config)
                     RepoWatch.handle_event([], %{query_time: native(250)}, inside, config)
                     at(1_500)
                   end)
        end)

      assert [line] = watch_lines(log)
      assert line =~ "in SQL 650 ms"

      metadata = %{repo: Repo, stacktrace: nil, result: {:ok, nil}}
      begin = Map.put(metadata, :query, "begin")
      commit = Map.put(metadata, :query, "commit")

      log =
        capture_log(fn ->
          at(0)
          RepoWatch.handle_event([], %{query_time: native(700)}, begin, config)
          at(1_500)
          RepoWatch.handle_event([], %{query_time: native(30)}, commit, config)
        end)

      assert [line] = watch_lines(log)

      assert line =~
               "db watch: hold 1500 ms, committed (begin wait 700 ms, in SQL 0 ms, commit 30 ms) " <>
                 "by unknown in "
    end

    test "a COMMIT or ROLLBACK that fails says so" do
      watch()
      config = %{hold_ms: 1_000, queue_ms: 60_000, clock: fn -> Process.get(@now, 0) end}
      metadata = %{repo: Repo, stacktrace: nil}

      log =
        capture_log(fn ->
          at(0)

          RepoWatch.handle_event(
            [],
            %{query_time: native(1)},
            Map.merge(metadata, %{query: "begin", result: {:ok, nil}}),
            config
          )

          at(1_500)

          RepoWatch.handle_event(
            [],
            %{query_time: native(1)},
            Map.merge(metadata, %{query: "commit", result: {:error, :busy}}),
            config
          )
        end)

      assert [line] = watch_lines(log)
      assert line =~ "hold 1500 ms, commit failed ("

      log =
        capture_log(fn ->
          at(0)

          RepoWatch.handle_event(
            [],
            %{query_time: native(1)},
            Map.merge(metadata, %{query: "begin", result: {:ok, nil}}),
            config
          )

          at(1_500)

          RepoWatch.handle_event(
            [],
            %{query_time: native(1)},
            Map.merge(metadata, %{query: "rollback", result: {:error, :closed}}),
            config
          )
        end)

      assert [line] = watch_lines(log)
      assert line =~ "hold 1500 ms, rollback failed ("
    end

    test "no transaction line holds a bound parameter or a row value" do
      watch()

      log =
        capture_log(fn ->
          at(0)

          assert {:ok, _} =
                   Repo.transaction(fn ->
                     Repo.all(from u in User, where: u.email == ^@secret)
                     at(1_500)
                   end)
        end)

      assert [_line] = watch_lines(log)
      refute log =~ @secret
      refute log =~ "users"
    end

    # Prod runs the OTP default backtrace depth, 8, where ExUnit raises it. The stack Ecto keeps
    # must still reach the caller through GuardedWrite's frames.
    test "the opener is named at the VM's default backtrace depth", ctx do
      old = :erlang.system_flag(:backtrace_depth, 8)
      on_exit(fn -> :erlang.system_flag(:backtrace_depth, old) end)
      watch()

      log =
        capture_log(fn ->
          at(0)
          assert {:ok, _} = GuardedWrite.transaction(fn -> at(1_500) end)
        end)

      assert [line] = watch_lines(log)
      assert line =~ test_fun(ctx)
    end
  end

  describe "hold lines for statements outside a transaction" do
    test "a statement at or past the threshold logs one line with its keyword, table and opener",
         ctx do
      watch(hold_ms: 0)

      log = capture_log(fn -> Repo.all(from u in User, where: u.email == ^@secret) end)

      assert [line] = watch_lines(log)
      assert line =~ ~r/db watch: hold \d+ ms, statement SELECT on users by /
      assert line =~ test_fun(ctx)
      refute log =~ @secret
    end

    test "raw SQL logs its keyword and an unknown opener, never its parameters" do
      watch(hold_ms: 0)

      log = capture_log(fn -> Repo.query!("SELECT ? AS x", [@secret]) end)

      assert [line] = watch_lines(log)
      assert line =~ ~r/db watch: hold \d+ ms, statement SELECT by unknown in /
      refute log =~ @secret
      refute log =~ "AS x"
    end

    # The hold is the statement's query time alone: its queue wait is the queue line's, and the
    # event's total time adds the two.
    test "a statement's hold is its query time, not its queue wait or total time" do
      config = %{hold_ms: 1_000, queue_ms: 60_000, clock: &RepoWatch.monotonic_ms/0}
      metadata = %{query: "SELECT 1", repo: Repo, result: {:ok, nil}, stacktrace: nil}

      queued =
        capture_log(fn ->
          measurements = %{queue_time: native(1_500), query_time: native(1)}
          measurements = Map.put(measurements, :total_time, native(1_501))
          RepoWatch.handle_event([], measurements, metadata, config)
        end)

      slow =
        capture_log(fn ->
          measurements = %{query_time: native(1_500), total_time: native(1_500)}
          RepoWatch.handle_event([], measurements, metadata, config)
        end)

      assert watch_lines(queued) == []
      assert [line] = watch_lines(slow)
      assert line =~ "db watch: hold 1500 ms, statement SELECT by unknown in "
    end

    test "a statement under the threshold logs nothing" do
      watch(hold_ms: 60_000)

      log = capture_log(fn -> Repo.all(from u in User, where: u.email == ^@secret) end)

      assert watch_lines(log) == []
    end
  end

  describe "the process a line names" do
    test "a registered process by its name" do
      watch()

      log =
        capture_log(fn ->
          task =
            Task.Supervisor.async(task_supervisor(), fn ->
              Process.register(self(), :repo_watch_test_named)
              {:ok, _} = Repo.transaction(fn -> at(1_500) end)
            end)

          Task.await(task)
        end)

      assert [line] = watch_lines(log)
      assert line =~ ~r/ in :repo_watch_test_named #PID<[\d.]+>$/
    end

    test "an unregistered process by its initial call", ctx do
      watch()

      log =
        capture_log(fn ->
          task =
            Task.Supervisor.async(task_supervisor(), fn ->
              {:ok, _} = Repo.transaction(fn -> at(1_500) end)
            end)

          Task.await(task)
        end)

      assert [line] = watch_lines(log)
      assert line =~ ~r/ in anonymous fn\/0 in .+ #PID<[\d.]+>$/
      assert line =~ "in anonymous fn/0 in #{test_fun(ctx)}"
    end
  end

  describe "queue lines" do
    # The Sandbox's one connection cannot queue a checkout for a second without a sleep, so these
    # drive the handler with the measurements a checkout's first event carries.
    setup do
      config = %{hold_ms: 60_000, queue_ms: 1_000, clock: &RepoWatch.monotonic_ms/0}
      %{config: config, metadata: %{query: "SELECT 1", repo: Repo, result: {:ok, nil}}}
    end

    test "a checkout that queued past the threshold logs one line with the waiter", ctx do
      {:current_stacktrace, stack} = Process.info(self(), :current_stacktrace)
      metadata = Map.put(ctx.metadata, :stacktrace, stack)

      log =
        capture_log(fn ->
          RepoWatch.handle_event(
            [:cinder, :repo, :query],
            %{queue_time: native(1_500), query_time: native(1)},
            metadata,
            ctx.config
          )
        end)

      assert [line] = watch_lines(log)
      assert line =~ "db watch: queue 1500 ms, then SELECT 1 ms, by "
      assert line =~ test_fun(ctx)
      assert line =~ ~r/ in :erlang\.apply\/2 #PID<[\d.]+>$/
    end

    # A Repo call in a tail position or a library callback can leave no Cinder frame. A frame from
    # an exception's stack carries the call's arguments, which the line counts but never prints.
    test "with no Cinder frame, the opener is the first frame outside Ecto, DBConnection, the repo and GuardedWrite",
         ctx do
      stack = [
        {Ecto.Repo.Supervisor, :tuplet, 2, [file: ~c"lib/ecto/repo/supervisor.ex", line: 185]},
        {Repo, :transact, 2, [file: ~c"lib/cinder/repo.ex", line: 2]},
        {DBConnection, :run, 3, []},
        {Cinder.GuardedWrite, :outermost, 2, []},
        {Enum, :each, [[@secret], :fun], [file: ~c"lib/enum.ex", line: 987]},
        {:lists, :foreach, 2, []}
      ]

      log =
        capture_log(fn ->
          RepoWatch.handle_event(
            [],
            %{queue_time: native(1_500)},
            Map.put(ctx.metadata, :stacktrace, stack),
            ctx.config
          )
        end)

      assert [line] = watch_lines(log)

      assert line =~
               "db watch: queue 1500 ms, then SELECT 0 ms, by Enum.each/2 (lib/enum.ex:987) in "

      refute log =~ @secret
    end

    test "a failed BEGIN still reports the queue it waited in", ctx do
      metadata = %{ctx.metadata | query: "begin", result: {:error, :busy}}

      log =
        capture_log(fn ->
          RepoWatch.handle_event(
            [],
            %{queue_time: native(2_000), query_time: native(5_000)},
            metadata,
            ctx.config
          )
        end)

      assert [line] = watch_lines(log)
      assert line =~ "db watch: queue 2000 ms, then BEGIN 5000 ms, by "
    end

    test "a checkout that queued exactly the threshold logs", ctx do
      log =
        capture_log(fn ->
          RepoWatch.handle_event([], %{queue_time: native(1_000)}, ctx.metadata, ctx.config)
        end)

      assert [line] = watch_lines(log)
      assert line =~ "db watch: queue 1000 ms, then SELECT 0 ms, by unknown in "
    end

    test "a checkout under the threshold, or an event with no queue time, logs nothing", ctx do
      log =
        capture_log(fn ->
          RepoWatch.handle_event([], %{queue_time: native(999)}, ctx.metadata, ctx.config)
          RepoWatch.handle_event([], %{query_time: native(1)}, ctx.metadata, ctx.config)
          RepoWatch.handle_event([], %{}, ctx.metadata, %{ctx.config | queue_ms: 0})
        end)

      assert watch_lines(log) == []
    end

    # Ecto always names the query; an event that names none still logs its queue.
    test "an event with no query text logs its queue with ? for the keyword", ctx do
      metadata = Map.delete(ctx.metadata, :query)

      log =
        capture_log(fn ->
          RepoWatch.handle_event([], %{queue_time: native(1_500)}, metadata, ctx.config)
        end)

      assert [line] = watch_lines(log)
      assert line =~ "db watch: queue 1500 ms, then ? 0 ms, by unknown in "
    end
  end

  describe "a real connection, outside the Sandbox" do
    setup do
      database =
        Path.join(System.tmp_dir!(), "cinder-repo-watch-#{System.unique_integer([:positive])}.db")

      on_exit(fn -> Enum.each(["", "-wal", "-shm"], &File.rm(database <> &1)) end)

      :ok =
        Cinder.MigrationRepoHelpers.start_repo!(ProbeRepo,
          database: database,
          telemetry_prefix: [:cinder, :repo_watch_test],
          journal_mode: :wal,
          default_transaction_mode: :immediate,
          busy_timeout: 50,
          stacktrace: true
        )

      %{database: database}
    end

    test "a BEGIN IMMEDIATE transaction logs its hold, commit and opener", ctx do
      watch(event: [:cinder, :repo_watch_test, :query])

      log =
        capture_log(fn ->
          at(0)

          assert {:ok, _} =
                   ProbeRepo.transaction(fn ->
                     ProbeRepo.query!("CREATE TABLE t (x)")
                     at(1_500)
                   end)
        end)

      assert [line] = watch_lines(log)
      assert line =~ "db watch: hold 1500 ms, committed"
      assert line =~ test_fun(ctx)
      refute line =~ "ProbeRepo"
    end

    # With the hold threshold at 0, a failed BEGIN read as a statement or a hold would log.
    # The commit sent afterwards would close a transaction the failed BEGIN had opened, had it
    # opened one.
    test "a BEGIN refused the lock is a waiter, logs no hold and opens no transaction", ctx do
      event = [:cinder, :repo_watch_test, :query]
      watch(event: event, hold_ms: 0)
      release = hold_write_lock(ctx.database)

      log =
        capture_log(fn ->
          at(0)

          assert_raise Exqlite.Error, ~r/database is locked/, fn ->
            ProbeRepo.transaction(fn -> :never end)
          end

          at(1_500)
          commit = %{query: "commit", repo: ProbeRepo, result: {:ok, nil}, stacktrace: nil}
          :telemetry.execute(event, %{query_time: 0}, commit)
        end)

      release.()
      assert watch_lines(log) == []
    end
  end

  describe "stall lines" do
    setup do
      now = :atomics.new(1, signed: true)
      test = self()

      opts = [
        name: nil,
        clock: fn -> :atomics.get(now, 1) end,
        schedule: fn delay -> send(test, {:scheduled, delay}) end
      ]

      %{now: now, opts: opts}
    end

    defp tick(pid) do
      send(pid, :tick)
      :sys.get_state(pid)
    end

    test "a tick 1.5 s late logs one line with the lateness", ctx do
      pid = start_supervised!({Stall, ctx.opts})
      assert_received {:scheduled, 1_000}
      :atomics.put(ctx.now, 1, 2_500)

      log = capture_log(fn -> tick(pid) end)

      assert [line] = watch_lines(log)
      assert line =~ ~r/db watch: stall, tick 1500 ms late$/
      assert_received {:scheduled, 1_000}
    end

    # The one test that waits on the real timer: the ticker must tick every second.
    test "with no injected scheduler, the ticker gets a tick about a second after it starts" do
      start = System.monotonic_time(:millisecond)
      pid = start_supervised!({Stall, name: nil, threshold_ms: 60_000})
      :erlang.trace(pid, true, [:receive])
      on_exit(fn -> if Process.alive?(pid), do: :erlang.trace(pid, false, [:receive]) end)

      assert_receive {:trace, ^pid, :receive, :tick}, 10_000
      assert System.monotonic_time(:millisecond) - start >= 900
    end

    test "an on-time tick, or one late by less than the threshold, logs nothing", ctx do
      pid = start_supervised!({Stall, ctx.opts})

      log =
        capture_log(fn ->
          :atomics.put(ctx.now, 1, 1_000)
          tick(pid)
          :atomics.put(ctx.now, 1, 2_999)
          tick(pid)
        end)

      assert watch_lines(log) == []
    end
  end

  describe "thresholds" do
    test "each threshold is 1 s by default" do
      ConfigCase.put_env(RepoWatch, [])

      assert RepoWatch.thresholds() == %Thresholds{hold: 1_000, queue: 1_000, stall: 1_000}
    end

    test "app config overrides each threshold, and the handler and the ticker read it" do
      ConfigCase.put_env(RepoWatch, hold_ms: 200, queue_ms: 300, stall_ms: 400)
      assert RepoWatch.thresholds() == %Thresholds{hold: 200, queue: 300, stall: 400}

      id = {__MODULE__, make_ref()}
      :ok = RepoWatch.attach(handler_id: id, clock: fn -> Process.get(@now, 0) end)
      on_exit(fn -> :telemetry.detach(id) end)
      [%{config: config}] = Enum.filter(:telemetry.list_handlers([]), &(&1.id == id))
      assert %RepoWatch{hold_ms: 200, queue_ms: 300} = config

      log =
        capture_log(fn ->
          at(0)
          assert {:ok, _} = Repo.transaction(fn -> at(199) end)
          at(0)
          assert {:ok, _} = Repo.transaction(fn -> at(200) end)
        end)

      assert [line] = watch_lines(log)
      assert line =~ "hold 200 ms"

      now = :atomics.new(1, signed: true)
      opts = [name: nil, clock: fn -> :atomics.get(now, 1) end, schedule: fn _ -> :ok end]
      pid = start_supervised!({Stall, opts})
      :atomics.put(now, 1, 1_399)
      quiet = capture_log(fn -> tick(pid) end)
      :atomics.put(now, 1, 2_799)
      loud = capture_log(fn -> tick(pid) end)

      assert watch_lines(quiet) == []
      assert [stall] = watch_lines(loud)
      assert stall =~ "tick 400 ms late"
    end
  end

  describe "the application" do
    test "the test env attaches no handler and starts no ticker" do
      assert Application.get_env(:cinder, :start_repo_watch) == false
      assert Cinder.Application.repo_watch_children() == []
      refute Enum.any?(:telemetry.list_handlers([:cinder, :repo, :query]), &(&1.id == RepoWatch))
      refute Process.whereis(Stall)
    end

    test "the watch starts with the application, before the Repo, when :start_repo_watch is on" do
      ConfigCase.put_env(:start_repo_watch, true)
      assert Cinder.Application.repo_watch_children() == [RepoWatch, Stall]

      children = Cinder.Application.children()
      index = &Enum.find_index(children, fn child -> child == &1 end)
      assert index.(RepoWatch) < index.(Stall)
      assert index.(Stall) < index.(Cinder.Repo)
    end

    test "the watch starts by default when :start_repo_watch is unset" do
      # put_env/2 registers the restore of the test env's value; the delete then unsets the key.
      ConfigCase.put_env(:start_repo_watch, false)
      Application.delete_env(:cinder, :start_repo_watch)

      assert Cinder.Application.repo_watch_children() == [RepoWatch, Stall]
    end

    test "holds and stalls are measured on the monotonic clock in milliseconds" do
      before = System.monotonic_time(:millisecond)
      now = RepoWatch.monotonic_ms()
      assert before <= now and now <= System.monotonic_time(:millisecond)

      id = {__MODULE__, make_ref()}
      :ok = RepoWatch.attach(handler_id: id)
      on_exit(fn -> :telemetry.detach(id) end)
      [%{config: config}] = Enum.filter(:telemetry.list_handlers([]), &(&1.id == id))
      assert config.clock == (&RepoWatch.monotonic_ms/0)

      pid = start_supervised!({Stall, name: nil, schedule: fn _ -> :ok end})
      assert :sys.get_state(pid).clock == (&RepoWatch.monotonic_ms/0)
    end

    test "the RepoWatch child attaches the handler and starts no process" do
      on_exit(fn -> :telemetry.detach(RepoWatch) end)

      assert :ignore = RepoWatch.start_link([])

      assert [%{function: function}] =
               Enum.filter(
                 :telemetry.list_handlers([:cinder, :repo, :query]),
                 &(&1.id == RepoWatch)
               )

      assert function == (&RepoWatch.handle_event/4)
    end
  end

  test "the handler survives an event it cannot read and logs one error line" do
    id = {__MODULE__, make_ref()}
    :ok = RepoWatch.attach(handler_id: id, event: [:cinder, :repo_watch_test, :bad])
    on_exit(fn -> :telemetry.detach(id) end)

    log =
      capture_log(fn ->
        :telemetry.execute([:cinder, :repo_watch_test, :bad], %{query_time: 1}, %{
          query: "SELECT 1"
        })

        :telemetry.execute([:cinder, :repo_watch_test, :bad], %{query_time: 1}, %{
          query: "SELECT 1"
        })
      end)

    assert [first, second] = watch_lines(log)

    quiet =
      capture_log(fn ->
        :telemetry.execute([:cinder, :repo_watch_test, :bad], %{query_time: 1}, %{repo: Repo})
      end)

    assert watch_lines(quiet) == []
    assert first =~ "db watch: handler failed with error KeyError"
    assert second =~ "handler failed"
    assert Enum.any?(:telemetry.list_handlers([:cinder, :repo_watch_test, :bad]), &(&1.id == id))
  end

  # Takes SQLite's write lock on `database` from a raw handle in a process of its own and holds it
  # until the returned function is called.
  defp hold_write_lock(database) do
    test = self()

    holder =
      start_supervised!(
        {Task,
         fn ->
           {:ok, conn} = Sqlite3.open(database)
           :ok = Sqlite3.execute(conn, "BEGIN IMMEDIATE")
           send(test, {:locked, self()})

           receive do
             :release -> :ok
           end

           :ok = Sqlite3.execute(conn, "ROLLBACK")
           :ok = Sqlite3.close(conn)
         end},
        id: make_ref()
      )

    assert_receive {:locked, ^holder}
    fn -> send(holder, :release) end
  end
end
