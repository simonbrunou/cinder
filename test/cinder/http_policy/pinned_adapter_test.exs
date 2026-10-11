defmodule Cinder.HTTPPolicy.PinnedAdapterTest do
  use ExUnit.Case, async: false

  alias Cinder.HTTPPolicy

  defmodule Echo do
    @moduledoc false
    @behaviour Plug

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, _opts) do
      case conn.request_path do
        "/slow" ->
          conn = Plug.Conn.send_chunked(conn, 200)
          {:ok, conn} = Plug.Conn.chunk(conn, "first")
          Process.sleep(2_000)
          conn

        "/early" ->
          conn
          |> Plug.Conn.inform(103, [{"link", "</style.css>; rel=preload"}])
          |> Plug.Conn.put_resp_header("location", "/next")
          |> Plug.Conn.send_resp(302, "")

        "/big" ->
          Plug.Conn.send_resp(conn, 200, String.duplicate("x", 10_000))

        _ ->
          Plug.Conn.send_resp(conn, 200, "host=" <> conn.host <> ":" <> "#{conn.port}")
      end
    end
  end

  # The public constructors refuse loopback addresses, so the targets are built by hand with the
  # exact shape `HTTPPolicy.untrusted_request_target/2` produces for a vetted public address.
  defp target(scheme, hostname, port, path \\ "/path") do
    %{
      uri: URI.parse("#{scheme}://#{hostname}:#{port}#{path}"),
      url: URI.parse("#{scheme}://127.0.0.1:#{port}#{path}"),
      connect_options: [hostname: hostname]
    }
  end

  defp listener_port(server) do
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    port
  end

  defp get(target, options \\ [], max_bytes \\ 1_000, timeout_ms \\ 5_000) do
    target
    |> HTTPPolicy.request_options([retry: false, redirect: false] ++ options)
    |> Req.new()
    |> HTTPPolicy.bounded_request(max_bytes, timeout_ms)
  end

  defp finch_pool_count, do: DynamicSupervisor.count_children(Req.FinchSupervisor).active

  describe "pinned requests over plain HTTP" do
    setup do
      server =
        start_supervised!({Bandit, plug: Echo, scheme: :http, ip: {127, 0, 0, 1}, port: 0})

      %{port: listener_port(server)}
    end

    test "do not start a Finch pool per distinct hostname", %{port: port} do
      pools_before = finch_pool_count()

      for n <- 1..5 do
        hostname = "pool-leak-#{n}-#{System.unique_integer([:positive])}.example"

        assert {:ok, %{status: 200, body: body}} =
                 get(target("http", hostname, port), connect_options: [timeout: 1_000])

        assert body == "host=#{hostname}:#{port}"
      end

      assert finch_pool_count() == pools_before
    end

    test "still enforces the response byte cap", %{port: port} do
      assert {:error, :response_too_large} =
               get(target("http", "capped.example", port, "/big"), [], 100)
    end

    test "still enforces the total request deadline on a stalled response", %{port: port} do
      assert {:error, :request_timeout} =
               get(target("http", "slow.example", port, "/slow"), [], 1_000, 300)
    end

    test "returns the final response's headers after a 1xx interim response", %{port: port} do
      assert {:ok, %{status: 302} = response} =
               get(target("http", "early.example", port, "/early"))

      assert Req.Response.get_header(response, "location") == ["/next"]
      assert Req.Response.get_header(response, "link") == []
      assert response.trailers == %{}
    end

    test "reports a refused connection as a transport error" do
      {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
      {:ok, closed_port} = :inet.port(socket)
      :gen_tcp.close(socket)

      assert {:error, %Req.TransportError{reason: :econnrefused}} =
               get(target("http", "refused.example", closed_port))
    end
  end

  describe "pinned requests over HTTPS" do
    setup do
      %{server_config: server_config} =
        :public_key.pkix_test_data(%{
          server_chain: %{
            root: [key: {:rsa, 2048, 65_537}],
            intermediates: [],
            peer: [
              key: {:rsa, 2048, 65_537},
              extensions: [{:Extension, {2, 5, 29, 17}, false, [dNSName: ~c"pinned.example"]}]
            ]
          },
          client_chain: %{root: [key: {:rsa, 2048, 65_537}], intermediates: [], peer: []}
        })

      server =
        start_supervised!(
          {Bandit,
           plug: Echo,
           scheme: :https,
           ip: {127, 0, 0, 1},
           port: 0,
           thousand_island_options: [
             transport_options: Keyword.take(server_config, [:cert, :key])
           ]}
        )

      %{port: listener_port(server), cacerts: Keyword.fetch!(server_config, :cacerts)}
    end

    test "verifies the certificate against the original hostname, not the pinned address",
         %{port: port, cacerts: cacerts} do
      transport = [connect_options: [transport_opts: [cacerts: cacerts]]]

      assert {:ok, %{status: 200, body: body}} =
               get(target("https", "pinned.example", port), transport)

      assert body == "host=pinned.example:#{port}"

      assert {:error, %Req.TransportError{reason: {:tls_alert, {:bad_certificate, _}}}} =
               get(target("https", "other.example", port), transport)
    end

    test "rejects a certificate chain that is not trusted", %{port: port} do
      assert {:error, %Req.TransportError{reason: {:tls_alert, {:unknown_ca, _}}}} =
               get(target("https", "pinned.example", port))
    end
  end
end
