defmodule Cinder.ExqliteBusyWaitTest do
  @moduledoc """
  A connection that waits for SQLite's write lock holds back only its own caller (#1310).

  In exqlite 0.37.0, `execute/2` runs on a dirty IO scheduler and holds the connection's mutex
  for the whole call, the busy handler's sleeps included. The statement destructor, which the VM
  runs on a normal scheduler when a process frees the last reference to a prepared statement,
  took that same mutex. So a process that freed a statement of the waiting connection blocked a
  normal scheduler until the wait ended, and the whole VM stalled with it, the lock holder too.
  On prod that stall lasted the 5 s busy timeout and failed the waiter with
  `database is locked`. exqlite 0.42.0 made the destructor try the lock and defer the finalize
  when the lock is taken.

  The test drives `Exqlite.Sqlite3` on two real connections to one file, not `Cinder.Repo`: the
  Sandbox runs one connection, so two writers through the Repo never race the lock
  (`Cinder.RepoConcurrencyTest`). Its processes start with `Task.async/1`
  (`test/code_health/raw_spawn_test.exs`).
  """
  use ExUnit.Case, async: false

  alias Exqlite.Sqlite3

  @moduletag :tmp_dir

  @busy_timeout_ms 3_000
  @sleep_ms 50

  setup %{tmp_dir: dir} do
    path = Path.join(dir, "busy.db")

    {:ok, holder} = Sqlite3.open(path)
    :ok = Sqlite3.execute(holder, "PRAGMA journal_mode=WAL")
    :ok = Sqlite3.execute(holder, "CREATE TABLE t (id INTEGER PRIMARY KEY)")

    {:ok, waiting} = Sqlite3.open(path)
    :ok = Sqlite3.set_busy_timeout(waiting, @busy_timeout_ms)

    on_exit(fn ->
      Sqlite3.close(waiting)
      Sqlite3.close(holder)
    end)

    %{holder: holder, waiting: waiting}
  end

  test "freeing a statement of a connection that waits for the write lock stalls no other process",
       %{holder: holder, waiting: waiting} do
    slept = sleep_while_waiting(holder, waiting, :drop)

    assert slept < div(@busy_timeout_ms, 2),
           "Process.sleep(#{@sleep_ms}) took #{slept} ms while another connection waited " <>
             "for the write lock"
  end

  # The control keeps the statement alive in the test process until the wait is over, so no
  # destructor runs during it. It passes on every exqlite release: what stalls the VM is the
  # destructor, not the wait.
  test "control: a statement kept past the wait stalls no other process",
       %{holder: holder, waiting: waiting} do
    slept = sleep_while_waiting(holder, waiting, :keep)

    assert slept < div(@busy_timeout_ms, 2),
           "Process.sleep(#{@sleep_ms}) took #{slept} ms while another connection waited " <>
             "for the write lock"
  end

  # Holds the write lock on `holder`, prepares a statement on `waiting` in another process, then
  # makes `waiting` wait for the lock. Once it waits, the other process collects its garbage,
  # which frees the statement unless `mode` is `:keep`. Returns how long the test process's own
  # `Process.sleep/1` took meanwhile.
  defp sleep_while_waiting(holder, waiting, mode) do
    :ok = Sqlite3.execute(holder, "BEGIN IMMEDIATE")
    test_pid = self()

    dropper =
      Task.async(fn ->
        {:ok, statement} = Sqlite3.prepare(waiting, "SELECT 1")
        kept = if mode == :keep, do: statement
        send(test_pid, {:prepared, self()})

        receive do
          :collect -> :ok
        end

        :erlang.garbage_collect()
        kept
      end)

    dropper_pid = dropper.pid
    assert_receive {:prepared, ^dropper_pid}

    waiter = Task.async(fn -> Sqlite3.execute(waiting, "BEGIN IMMEDIATE") end)
    refute Task.yield(waiter, 100)

    send(dropper_pid, :collect)
    started = System.monotonic_time(:millisecond)
    Process.sleep(@sleep_ms)
    slept = System.monotonic_time(:millisecond) - started

    assert {:error, _reason} = Task.await(waiter, @busy_timeout_ms * 3)
    :ok = Sqlite3.execute(holder, "ROLLBACK")
    _kept = Task.await(dropper)

    slept
  end
end
