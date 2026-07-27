defmodule Cinder.PollerHelpers do
  @moduledoc """
  Shared helpers for the poller crash-recovery tests.
  """

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
