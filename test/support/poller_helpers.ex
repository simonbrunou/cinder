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
end
