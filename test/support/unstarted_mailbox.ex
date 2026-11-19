defmodule Cinder.Test.UnstartedMailbox do
  @moduledoc """
  A `Swoosh.Adapters.Local` storage driver whose `push/1` makes the call
  `Swoosh.Adapters.Local.Storage.Memory.push/1` makes, to a global name no process holds.

  Prod sets `config :swoosh, local: false`, so Memory never starts there and an install with no
  SMTP host, which keeps the Local adapter, gets a `:noproc` exit on every delivery. The test env
  starts Memory, so a test reaches that exit through this driver
  (`storage_driver: Cinder.Test.UnstartedMailbox` in the `Cinder.Mailer` config).
  """

  def push(email), do: GenServer.call({:global, __MODULE__}, {:push, email})
end
