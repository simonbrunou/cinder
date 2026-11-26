defmodule Cinder.Download.Client.FetchErrorTest do
  @moduledoc """
  A download fetch's failure reason holds no URL (#1658): Mint's error for a request target it
  refuses quotes that target, query and key included, so `Fetch` keeps only the error's class.
  A `Req.Test` plug never reaches Mint, so this test serves the link over real HTTP.
  """
  use ExUnit.Case, async: true

  alias Cinder.Download.Client.Fetch

  defmodule Indexer do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    # Mint refuses a request target with a space in it, and quotes the target in its error.
    def call(%{request_path: "/1/download"} = conn, _opts) do
      conn
      |> put_resp_header("location", "/files/a b?apikey=fixture-key")
      |> send_resp(302, "")
    end
  end

  setup do
    server =
      start_supervised!({Bandit, plug: Indexer, scheme: :http, ip: {127, 0, 0, 1}, port: 0})

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    %{origin: "http://127.0.0.1:#{port}"}
  end

  test "a request target Mint refuses fails with its class, not the target", %{origin: origin} do
    result =
      Fetch.bytes(origin <> "/1/download", origin, max_bytes: 1024, error_tag: :nzb_fetch_status)

    assert result == {:error, %Req.HTTPError{protocol: :http1, reason: :invalid_request_target}}
  end
end
