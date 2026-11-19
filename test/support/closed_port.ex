defmodule Cinder.Test.ClosedPort do
  @moduledoc """
  A loopback TCP port nothing listens on: it opens a listener on port 0, reads the port the OS
  picked, and closes the listener. Another process can take the port before the caller uses it,
  so a test reads a refused connection as the likely outcome, not a certain one.
  """

  @spec number() :: :inet.port_number()
  def number do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
