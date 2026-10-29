defmodule Cinder.MigrationRepoHelpersTest do
  # A migration test's private repo dropped its first statement on `queue_timeout` when its
  # connection was slow to open on a loaded runner (#963). Each test here makes the open slow on
  # purpose: a raw handle holds an exclusive lock on the fresh database file, so the repo's
  # connect waits in SQLite's busy handler until the lock goes. The repo's queue limits are
  # tightened so a statement queued behind the open drops within milliseconds, not seconds.
  # `async: false`, since one test lowers ExUnit's configured timeout while it runs.
  use ExUnit.Case, async: false

  alias Cinder.MigrationRepoHelpers
  alias Ecto.Adapters.SQL
  alias Exqlite.Sqlite3

  defmodule Repo do
    use Ecto.Repo, otp_app: :cinder, adapter: Ecto.Adapters.SQLite3
  end

  @fast_drop [queue_target: 10, queue_interval: 10]

  setup do
    database =
      Path.join(
        System.tmp_dir!(),
        "cinder-migration-repo-helpers-#{System.unique_integer([:positive])}.db"
      )

    on_exit(fn -> File.rm(database) end)

    %{
      database: database,
      opts:
        [database: database, telemetry_prefix: [:cinder, :migration_repo_helpers_test]] ++
          @fast_drop
    }
  end

  test "a repo started straight away drops a statement queued behind a slow open", ctx do
    release = hold_lock(ctx.database)

    start_supervised!({Repo, [pool_size: 1] ++ ctx.opts})

    error = assert_raise DBConnection.ConnectionError, fn -> SQL.query!(Repo, "SELECT 1") end
    assert error.reason == :queue_timeout

    release.()
  end

  test "start_repo!/2 returns once the slow open is done, so the first statement runs", ctx do
    release = hold_lock(ctx.database)

    Task.start_link(fn ->
      Process.sleep(500)
      release.()
    end)

    :ok = MigrationRepoHelpers.start_repo!(Repo, ctx.opts)

    assert %{rows: [[1]]} = SQL.query!(Repo, "SELECT 1")
  end

  test "start_repo!/2 fails the test, not on queue_timeout, when the open outlasts its bound",
       ctx do
    release = hold_lock(ctx.database)

    error =
      assert_raise ExUnit.AssertionError, fn ->
        MigrationRepoHelpers.start_repo!(Repo, [connect_wait: 200] ++ ctx.opts)
      end

    assert error.message == "#{inspect(Repo)} did not open its connection within 200 ms"

    # Let the pending connect finish, so the repo stops cleanly with the test.
    release.()
  end

  # The runner copies its timeout when the run starts, so lowering the configured value changes
  # only what `start_repo!/2` reads, not this test's own timeout.
  test "start_repo!/2 waits for ExUnit's configured per-test timeout by default", ctx do
    timeout = ExUnit.configuration()[:timeout]
    on_exit(fn -> ExUnit.configure(timeout: timeout) end)
    ExUnit.configure(timeout: 300)
    release = hold_lock(ctx.database)

    error =
      assert_raise ExUnit.AssertionError, fn ->
        MigrationRepoHelpers.start_repo!(Repo, ctx.opts)
      end

    assert error.message == "#{inspect(Repo)} did not open its connection within 300 ms"

    release.()
  end

  test "start_repo!/2 runs the repo on one connection, whatever the caller asks", ctx do
    :ok = MigrationRepoHelpers.start_repo!(Repo, [pool_size: 4] ++ ctx.opts)

    assert Ecto.Adapter.lookup_meta(Repo).opts[:pool_size] == 1
  end

  # Opens `database` in a process of its own, takes an exclusive lock on it and holds it until
  # the returned function is called. The handle and the lock stay in that one process.
  defp hold_lock(database) do
    test = self()

    holder =
      start_supervised!(
        {Task,
         fn ->
           {:ok, conn} = Sqlite3.open(database)
           :ok = Sqlite3.execute(conn, "BEGIN EXCLUSIVE")
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
