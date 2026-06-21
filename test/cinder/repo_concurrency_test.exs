defmodule Cinder.RepoConcurrencyTest do
  @moduledoc """
  Proves the WAL + busy_timeout pin (M0): a writer racing a held write lock waits
  it out instead of erroring with "database busy".

  Why not drive this through `Catalog.transition`: the Ecto SQL Sandbox multiplexes
  a single connection, so two writers through `Cinder.Repo` serialize at the
  connection layer and never reach SQLite's busy handler — the race we care about
  can't happen there. So the behaviour is proven against two real connections
  (`set_busy_timeout/2` is the exact NIF the Repo's `:busy_timeout` option calls).
  """
  use Cinder.DataCase, async: false

  alias Exqlite.Sqlite3

  test "Cinder.Repo is configured with the pinned WAL + busy_timeout" do
    config = Application.get_env(:cinder, Cinder.Repo)
    assert config[:busy_timeout] == 5_000
    assert config[:journal_mode] == :wal

    # WAL is observable on the live connection. busy_timeout is not — exqlite applies
    # it through a custom busy handler (not sqlite3_busy_timeout), so PRAGMA
    # busy_timeout reads 0; that handler is exercised in the two-connection test below.
    assert %{rows: [["wal"]]} = Repo.query!("PRAGMA journal_mode")
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

      # Confirm the writer is in flight, give it a beat to enter the busy handler,
      # then assert it's genuinely blocked before releasing the lock — otherwise the
      # INSERT would race an already-free lock and pass without exercising the wait
      # (the same check fails fast if busy_timeout were 0, turning the wait into an error).
      assert_receive :writing, 1_000
      Process.sleep(50)
      refute Task.yield(writer, 0), "writer should still be blocked on the held lock"

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
