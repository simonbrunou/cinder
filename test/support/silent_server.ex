defmodule Cinder.Test.SilentServer do
  @moduledoc """
  A TCP server on 127.0.0.1 that accepts every connection and never answers, for a test that a
  real Req request ends at its `receive_timeout`. The `Req.Test` plug never applies Req's
  `receive_timeout`, so only a socket shows it.
  """

  import ExUnit.Callbacks

  @doc """
  Starts the server under the test supervisor and returns its URL, such as
  `http://127.0.0.1:41234`. With `notify: pid`, it sends `pid` `:silent_server_accepted` each
  time it accepts a connection.
  """
  def start!(opts \\ []) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    notify = Keyword.get(opts, :notify)
    acceptor = start_supervised!({Task, fn -> accept(listen, notify) end}, id: make_ref())
    :ok = :gen_tcp.controlling_process(listen, acceptor)
    "http://127.0.0.1:#{port}"
  end

  # The acceptor owns every accepted socket, so each stays open until the test ends.
  defp accept(listen, notify) do
    {:ok, _socket} = :gen_tcp.accept(listen)
    if notify, do: send(notify, :silent_server_accepted)
    accept(listen, notify)
  end
end
