defmodule Cinder.PollerHelpers do
  @moduledoc """
  Shared helpers for the poller tests: crash recovery, and one-off polls a page test runs.
  """

  alias Cinder.Library.MediaServer.Reconciler

  @doc """
  Stubs both download clients' `files/1` with an empty (clean) list.

  Every download is content-vetted by `Cinder.Download.ContentPolicy`, which is on by default,
  both while `:downloading` and when first seen `:completed` — so without this, any test that
  advances a unit through either state hits an unstubbed mock.
  A `Mox.stub` is not verified and `expect` overrides it, so the fake-content tests still assert
  their own file lists; this only spares every *other* poller test from describing one.
  """
  def stub_clean_content do
    Mox.stub(Cinder.Download.ClientMock, :files, fn _id -> {:ok, []} end)
    Mox.stub(Cinder.Download.SabnzbdClientMock, :files, fn _id -> {:ok, []} end)
    Mox.stub(Cinder.Library.FilesystemMock, :chmod, fn _path, _mode -> :ok end)
    :ok
  end

  @doc """
  Runs one `Cinder.Library.MediaServer.Reconciler` poll under `name`, with empty movie and TV
  inventories and a season read that returns `result`, then stops it. Erases the poll's
  `last_run` on exit so `/activity` reads "not yet" in later tests.
  """
  def poll_media_server_seasons(name, result) do
    ExUnit.Callbacks.on_exit(fn -> :persistent_term.erase({Reconciler, :last_run}) end)
    Mox.expect(Cinder.Library.MediaServerMock, :list_items, 2, fn _kind -> {:ok, []} end)
    Mox.expect(Cinder.Library.MediaServerMock, :list_seasons, fn -> result end)

    pid = ExUnit.Callbacks.start_supervised!({Reconciler, name: name}, id: name)
    :ok = Reconciler.poll(pid)
    ExUnit.Callbacks.stop_supervised!(name)
  end

  @doc """
  Blocks until the named GenServer is back up under a pid different from
  `old_pid` (i.e. the supervisor has restarted it), returning the new pid.
  """
  def await_restart(name, old_pid) do
    case GenServer.whereis(name) do
      new_pid when is_pid(new_pid) and new_pid != old_pid ->
        new_pid

      _ ->
        Process.sleep(10)
        await_restart(name, old_pid)
    end
  end

  @doc """
  Blocks until `fun` returns a truthy value, polling every `interval` ms; raises after `timeout`
  ms. A condition poll for tests that must await an async effect without waiting a fixed span the
  happy path doesn't need — it returns as soon as the condition holds and only fails a genuinely
  stuck test.
  """
  def poll_until(fun, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 2_000)
    interval = Keyword.get(opts, :interval, 5)
    do_poll_until(fun, interval, System.monotonic_time(:millisecond) + timeout)
  end

  defp do_poll_until(fun, interval, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        raise "poll_until: condition not met within timeout"

      true ->
        Process.sleep(interval)
        do_poll_until(fun, interval, deadline)
    end
  end
end
