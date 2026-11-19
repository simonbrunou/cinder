defmodule Cinder.Test.StoppedMailbox do
  @moduledoc """
  Puts the test node in prod's no-SMTP mail state: Swoosh's local mailbox
  (`Swoosh.Adapters.Local.Storage.Memory`) is not running, so a `Swoosh.Adapters.Local`
  delivery exits with `:noproc`.

  Prod sets `config :swoosh, local: false`, which Swoosh reads only when its application
  starts, so setting it in a test leaves the mailbox running. `stop!/0` stops the mailbox
  instead: it terminates `Swoosh.Adapters.Local.Storage.Manager`, which would restart it, then
  stops the mailbox, and restarts the Manager (and with it the mailbox) when the test exits.
  The mailbox is node-global, so a caller runs `async: false`.
  """

  alias Swoosh.Adapters.Local.Storage.Manager
  alias Swoosh.Adapters.Local.Storage.Memory

  def stop! do
    ExUnit.Callbacks.on_exit(fn ->
      {:ok, _pid} = Supervisor.restart_child(Swoosh.Supervisor, Manager)
    end)

    :ok = Supervisor.terminate_child(Swoosh.Supervisor, Manager)
    :ok = Memory.stop()
    :undefined = :global.whereis_name(Memory)
    :ok
  end
end
