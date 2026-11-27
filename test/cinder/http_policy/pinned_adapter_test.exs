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
      # The pinned-certificate tests count the requests the server reads.
      if hits = :persistent_term.get({__MODULE__, :hits}, nil), do: :counters.add(hits, 1, 1)

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

  describe "pinned certificates (#1678)" do
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

      hits = :counters.new(1, [])
      :persistent_term.put({Echo, :hits}, hits)
      on_exit(fn -> :persistent_term.erase({Echo, :hits}) end)

      %{
        port: listener_port(server),
        cacerts: Keyword.fetch!(server_config, :cacerts),
        sha: :crypto.hash(:sha, Keyword.fetch!(server_config, :cert)),
        hits: hits
      }
    end

    defp pinned(host, shas, extra \\ []),
      do: [connect_options: [certificate_pins: {host, shas}] ++ extra]

    test "a listed thumbprint accepts a certificate no trusted root signed", %{
      port: port,
      sha: sha,
      hits: hits
    } do
      assert {:ok, %{status: 200, body: body}} =
               get(target("https", "pinned.example", port), pinned("pinned.example", [sha]))

      assert body == "host=pinned.example:#{port}"
      assert :counters.get(hits, 1) == 1
    end

    test "it also accepts the certificate on a name the certificate does not list", %{
      port: port,
      sha: sha
    } do
      assert {:ok, %{status: 200}} =
               get(target("https", "other.example", port), pinned("other.example", [sha]))
    end

    test "the pins' host matches the hostname in any case, with or without a trailing dot", %{
      port: port,
      sha: sha
    } do
      assert {:ok, %{status: 200}} =
               get(target("https", "pinned.example", port), pinned("Pinned.Example.", [sha]))
    end

    test "another thumbprint verifies as usual, and the first connection sends no request", %{
      port: port,
      sha: sha,
      cacerts: cacerts,
      hits: hits
    } do
      other = :crypto.hash(:sha, "another certificate")

      assert {:error, %Req.TransportError{reason: {:tls_alert, {:unknown_ca, _}}}} =
               get(target("https", "pinned.example", port), pinned("pinned.example", [other]))

      assert :counters.get(hits, 1) == 0

      # A trusted chain still passes after the pin missed, with one request read.
      trusted = pinned("pinned.example", [other], transport_opts: [cacerts: cacerts])
      assert {:ok, %{status: 200}} = get(target("https", "pinned.example", port), trusted)
      assert :counters.get(hits, 1) == 1

      # A thumbprint written as hex digits, not 20 bytes, is no pin.
      assert {:error, %Req.TransportError{reason: {:tls_alert, {:unknown_ca, _}}}} =
               get(
                 target("https", "pinned.example", port),
                 pinned("pinned.example", [Base.encode16(sha)])
               )
    end

    test "a Cardigann request carries its pins to its base URL host only", %{port: port, sha: sha} do
      alias Cinder.Acquisition.Indexer.Cardigann.Fetch

      request = fn host ->
        %{
          context: %{deadline_at: System.monotonic_time(:millisecond) + 10_000},
          certificate_pins: {host, [sha]},
          req_options: [retry: false]
        }
      end

      assert {:ok, %{status: 200}} =
               Fetch.send_get(target("https", "pinned.example", port), request.("pinned.example"))

      assert {:error, _tls} =
               Fetch.send_get(target("https", "pinned.example", port), request.("site.example"))
    end

    test "pins for another host do nothing", %{port: port, sha: sha} do
      assert {:error, %Req.TransportError{reason: {:tls_alert, {:unknown_ca, _}}}} =
               get(target("https", "pinned.example", port), pinned("site.example", [sha]))
    end

    test "a pinned session is not resumed by a later request", %{port: port, sha: sha} do
      assert {:ok, %{status: 200}} =
               get(target("https", "pinned.example", port), pinned("pinned.example", [sha]))

      assert {:error, %Req.TransportError{reason: {:tls_alert, {:unknown_ca, _}}}} =
               get(target("https", "pinned.example", port))
    end
  end
end
