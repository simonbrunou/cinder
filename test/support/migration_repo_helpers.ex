defmodule Cinder.MigrationRepoHelpers do
  @moduledoc """
  Starts a migration test's private repo and waits for its one connection to open (#963).

  DBConnection opens a pool's connections after `start_supervised!/1` returns, so a statement
  sent straight away queues behind the open. A private repo runs on DBConnection's default queue
  limits (`queue_target` 50 ms, `queue_interval` 2000 ms), so on a loaded runner whose open takes
  over about 4 s the pool dropped that first statement with `DBConnection.ConnectionError`
  `:queue_timeout`. A longer per-query `:timeout` does not help, since the drop comes from the
  pool's queue limits. Raising those limits only moves the bound: the statement's own deadline
  (15 s for an Ecto query) counts from when it queues, so an open that outlasts it still fails
  the statement.

  `start_repo!/2` subscribes the test process to the pool's connection events instead, and
  returns once DBConnection reports the connection open. DBConnection sends that report from the
  step that then checks the connection into the pool, so the first statement queues only until
  that step ends, not for the whole open.
  `test/code_health_test.exs` fences every test that defines its own `Ecto.Repo` onto it.
  """

  import ExUnit.Assertions, only: [flunk: 1]
  import ExUnit.Callbacks, only: [start_supervised!: 1]

  @doc """
  Starts `repo` under the test supervisor with `opts` and one connection, then waits for that
  connection to open.

  The repo always runs on `pool_size: 1`, since several migration tests assert on what one
  connection sees, such as its `PRAGMA foreign_keys` state. The wait lasts ExUnit's per-test
  timeout (`ExUnit.configuration()[:timeout]`) and fails the test with a message naming the
  repo when the connection has not opened by then.
  `:connect_wait` overrides that bound for the helper's own test.
  """
  def start_repo!(repo, opts) do
    {bound, opts} = Keyword.pop(opts, :connect_wait, ExUnit.configuration()[:timeout])
    tag = make_ref()

    start_supervised!(
      {repo, Keyword.merge(opts, pool_size: 1, connection_listeners: {[self()], tag})}
    )

    receive do
      {:connected, _conn, ^tag} -> :ok
    after
      bound -> flunk("#{inspect(repo)} did not open its connection within #{bound} ms")
    end
  end
end
