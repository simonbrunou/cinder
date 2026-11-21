defmodule Cinder.RepoConcurrencyTest do
  @moduledoc """
  Proves the WAL + busy_timeout pin (M0): a writer racing a held write lock waits
  it out instead of erroring with "database busy".

  Why not drive this through a `MovieLifecycle` verb: the Ecto SQL Sandbox multiplexes
  a single connection, so two writers through `Cinder.Repo` serialize at the
  connection layer and never reach SQLite's busy handler — the race we care about
  can't happen there. So the behaviour is proven against two real connections
  (`set_busy_timeout/2` is the exact NIF the Repo's `:busy_timeout` option calls).
  """
  use Cinder.DataCase, async: false

  alias Exqlite.Sqlite3

  test "Cinder.Repo is configured with the pinned WAL + busy_timeout" do
    config = Application.get_env(:cinder, Cinder.Repo)
    assert config[:busy_timeout] == 10_000
    assert config[:journal_mode] == :wal

    # WAL is observable on the live connection. busy_timeout is not — exqlite applies
    # it through a custom busy handler (not sqlite3_busy_timeout), so PRAGMA
    # busy_timeout reads 0; that handler is exercised in the two-connection test below.
    assert %{rows: [["wal"]]} = Repo.query!("PRAGMA journal_mode")
  end

  # Every DataCase and ConnCase test holds the one Sandbox connection for its whole run, so an
  # async test's checkout queues behind the other cases' tests. DBConnection drops a request that
  # has queued past 2 x queue_target, and on a loaded CI runner that drop failed tests in
  # `setup_sandbox/1` while ExUnit would still have let them run (#947). A `--timeout` above
  # 2 x queue_target fails this test on purpose: raise queue_target with it. `--trace` passes,
  # since the runner, not the configuration, swaps in its `:infinity` timeout.
  test "Cinder.Repo's queue limit cannot drop a sandbox checkout before ExUnit's test timeout" do
    config = Application.get_env(:cinder, Cinder.Repo)
    assert config[:pool_size] == 1
    assert config[:queue_interval] == config[:queue_target]
    assert 2 * config[:queue_target] >= ExUnit.configuration()[:timeout]
  end

  # A checkout held past the Repo's `timeout` is disconnected, and the transaction's next query
  # fails on the closed connection (#1510). `Keyword.fetch!/2` fails a missing key, and the
  # literal pins the value the suite runs with (docs/agents/testing.md), which also fails
  # `:infinity`, an atom that compares above any integer.
  test "Cinder.Repo's checkout timeout is 60 s, no shorter than ExUnit's configured test timeout" do
    timeout = Application.get_env(:cinder, Cinder.Repo) |> Keyword.fetch!(:timeout)
    assert timeout == 60_000
    assert timeout >= ExUnit.configuration()[:timeout]
  end

  # The test-env checkout timeout above is the test env's own: dev and prod keep DBConnection's
  # 15 s default. `busy_timeout` is the control that each read reached the shared Repo config.
  test "the dev and prod Cinder.Repo configs set no checkout timeout" do
    previous = Map.new(~w(SECRET_KEY_BASE DATABASE_PATH), &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    System.put_env("SECRET_KEY_BASE", String.duplicate("k", 64))
    System.put_env("DATABASE_PATH", "/tmp/cinder_repo_concurrency_test.db")

    for env <- [:dev, :prod] do
      repo =
        "config/config.exs"
        |> Config.Reader.read!(env: env)
        |> Config.Reader.merge(Config.Reader.read!("config/runtime.exs", env: env))
        |> get_in([:cinder, Cinder.Repo])

      assert repo[:busy_timeout] == 5_000, "#{env}: #{inspect(repo)}"
      refute Keyword.has_key?(repo, :timeout), "#{env}: #{inspect(repo)}"
    end
  end

  describe "two real connections racing a write lock" do
    setup do
      path = Path.join(System.tmp_dir!(), "cinder_busy_#{System.unique_integer([:positive])}.db")

      on_exit(fn ->
        for f <- [path, path <> "-wal", path <> "-shm"], do: File.rm(f)
      end)

      {:ok, conn} = Sqlite3.open(path)
      :ok = Sqlite3.execute(conn, "PRAGMA journal_mode=WAL")
      :ok = Sqlite3.execute(conn, "CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)")
      :ok = Sqlite3.close(conn)

      %{path: path}
    end

    test "busy_timeout 5000: the second writer waits out the lock and succeeds", %{path: path} do
      a = open(path, 5_000)
      b = open(path, 5_000)

      :ok = Sqlite3.execute(a, "BEGIN IMMEDIATE")
      :ok = Sqlite3.execute(a, "INSERT INTO t (v) VALUES (1)")

      parent = self()

      writer =
        Task.async(fn ->
          send(parent, :writing)
          Sqlite3.execute(b, "INSERT INTO t (v) VALUES (2)")
        end)

      # Confirm the writer is in flight, then give it a 50ms window to complete: with the lock
      # held it can't, so `yield` returns nil and the refute passes; it exits the window early
      # only if the INSERT raced an already-free lock or busy_timeout were 0 (turning the wait
      # into an error), which is exactly the failure this guards against.
      assert_receive :writing
      refute Task.yield(writer, 50), "writer should still be blocked on the held lock"

      :ok = Sqlite3.execute(a, "COMMIT")

      assert :ok = Task.await(writer, 6_000)

      Sqlite3.close(a)
      Sqlite3.close(b)
    end

    test "control: busy_timeout 0 turns the same race into a busy error", %{path: path} do
      a = open(path, 0)
      b = open(path, 0)

      :ok = Sqlite3.execute(a, "BEGIN IMMEDIATE")
      :ok = Sqlite3.execute(a, "INSERT INTO t (v) VALUES (1)")

      assert {:error, reason} = Sqlite3.execute(b, "INSERT INTO t (v) VALUES (2)")
      assert to_string(reason) =~ ~r/busy|locked/i

      :ok = Sqlite3.execute(a, "COMMIT")
      Sqlite3.close(a)
      Sqlite3.close(b)
    end
  end

  defp open(path, busy_timeout) do
    {:ok, conn} = Sqlite3.open(path)
    :ok = Sqlite3.execute(conn, "PRAGMA journal_mode=WAL")
    :ok = Sqlite3.set_busy_timeout(conn, busy_timeout)
    conn
  end
end
