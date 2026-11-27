defmodule Cinder.HTTPPolicy.PinnedAdapter do
  @moduledoc """
  A `Req` adapter for requests pinned to a vetted IP address (`Cinder.HTTPPolicy.request_options/2`).

  A pinned request targets an address literal in its URL and carries the original hostname in
  `connect_options: [hostname: host]` so the TLS handshake still uses it for SNI and certificate
  verification. Req's default Finch adapter turns every distinct `connect_options` into a
  permanent `Finch` pool and a new atom under `Req.FinchSupervisor`, so a remote party that
  controls the hostname (redirects, download URLs) could grow the node without bound.

  This adapter instead opens one HTTP/1 `Mint` connection per request, streams the response
  into the request's `:into` function (or buffers it when none is set), and always closes the
  connection. Nothing outlives the call, and TLS verification is Mint's default
  (`:verify_peer` with hostname checking against `:hostname`).

  Supported `connect_options`: `:hostname` (required), `:timeout` (connect timeout),
  `:transport_opts` and `:certificate_pins`. Anything else (e.g. `:proxy`) raises rather than
  being silently ignored, because a pinned request must never be redirected through another
  route.

  ## Pinned certificates

  `certificate_pins: {host, thumbprints}` (#1678), each thumbprint the 20-byte SHA-1 of a
  certificate's DER bytes, is a Cardigann definition's `certificates` list, as Jackett reads it:
  a server certificate whose SHA-1 is listed is accepted even when normal verification fails
  (an unknown issuer, an expiry, another name). It applies only to an HTTPS request whose
  `:hostname`, in lower case and without a trailing dot, is `host`; on any other it does
  nothing, so a pin cannot follow a redirect to another host. The caller,
  `Cinder.Acquisition.Indexer.Cardigann.Fetch`, sets it only for the indexer's base URL host.

  Such a request first connects with `verify: :verify_none` and `reuse_sessions: false`, and
  reads the peer certificate (`:ssl.peercert/1`) before it sends a byte of the request. A
  listed thumbprint keeps the connection. Any other certificate, or a peer certificate that
  cannot be read, closes it, and the request connects again with Mint's normal verification,
  whose answer stands: an untrusted certificate fails there as it would with no pin. A first
  connection that fails is the answer, as no certificate check failed it. TLS still checks that
  the server holds the key of the certificate it sent, whatever `verify` says, and OTP caches a
  session only after `:verify_peer`, so a pinned session is never resumed by a later request.
  Verification never runs first: a failed handshake logs a TLS alert on every request.
  """

  @default_connect_timeout_ms 30_000
  @default_receive_timeout_ms 15_000
  @connect_option_keys [:hostname, :timeout, :transport_opts, :certificate_pins]

  @doc "Runs `request` over a one-shot Mint connection. See `Req.Request` for the adapter contract."
  @spec run(Req.Request.t()) :: {Req.Request.t(), Req.Response.t() | Exception.t()}
  def run(%Req.Request{} = request) do
    sink = sink!(request)
    body = body!(request)
    {address, hostname, connect_options, pins} = target!(request)
    scheme = scheme!(request.url)
    port = request.url.port || URI.default_port(request.url.scheme)

    case connect(scheme, {address, port, hostname}, connect_options, pins) do
      {:ok, conn} ->
        try do
          exchange(conn, request, body, sink)
        after
          Mint.HTTP.close(conn)
        end

      {:error, error} ->
        {request, normalize_error(error)}
    end
  end

  defp connect(:https, target, transport_opts, [_ | _] = pins) do
    pinned_opts = Keyword.merge(transport_opts, verify: :verify_none, reuse_sessions: false)

    with {:ok, conn} <- mint_connect(:https, target, pinned_opts) do
      if pinned?(conn, pins) do
        {:ok, conn}
      else
        Mint.HTTP.close(conn)
        mint_connect(:https, target, transport_opts)
      end
    end
  end

  defp connect(scheme, target, transport_opts, _pins),
    do: mint_connect(scheme, target, transport_opts)

  defp mint_connect(scheme, {address, port, hostname}, transport_opts) do
    Mint.HTTP.connect(scheme, address, port,
      hostname: hostname,
      protocols: [:http1],
      mode: :passive,
      transport_opts: transport_opts
    )
  end

  defp pinned?(conn, pins) do
    case :ssl.peercert(Mint.HTTP.get_socket(conn)) do
      {:ok, der} -> :crypto.hash(:sha, der) in pins
      {:error, _reason} -> false
    end
  end

  defp exchange(conn, request, body, sink) do
    receive_timeout = request.options[:receive_timeout] || @default_receive_timeout_ms

    case Mint.HTTP.request(
           conn,
           request.method |> Atom.to_string() |> String.upcase(),
           request_path(request.url),
           Req.get_headers_list(request),
           body
         ) do
      {:ok, conn, ref} ->
        state = %{
          ref: ref,
          sink: sink,
          timeout: receive_timeout,
          acc: {request, Req.Response.new()},
          headers?: false
        }

        receive_response(conn, state)

      {:error, _conn, error} ->
        {request, normalize_error(error)}
    end
  end

  defp receive_response(conn, state) do
    case Mint.HTTP.recv(conn, 0, state.timeout) do
      {:ok, conn, responses} ->
        case consume(responses, state) do
          {:cont, state} -> receive_response(conn, state)
          {:done, state} -> state.acc
          {:error, state, error} -> {elem(state.acc, 0), normalize_error(error)}
        end

      {:error, _conn, error, responses} ->
        case consume(responses, state) do
          {:done, state} -> state.acc
          {:cont, state} -> {elem(state.acc, 0), normalize_error(error)}
          {:error, state, error} -> {elem(state.acc, 0), normalize_error(error)}
        end
    end
  end

  # `:done` means the response is complete (or the `:into` function halted); `:cont` means more
  # bytes are needed from the socket.
  defp consume([], state), do: {:cont, state}

  # A 1xx interim response is followed by the final one on the same request, each with its own
  # status and headers events; the final pair replaces the interim one.
  defp consume([{:status, _ref, status} | rest], %{acc: {request, response}} = state) do
    response = %{response | status: status, headers: Req.Response.new().headers}
    consume(rest, %{state | acc: {request, response}, headers?: false})
  end

  defp consume([{:headers, _ref, headers} | rest], %{headers?: false} = state) do
    {request, response} = state.acc
    fields = Enum.map(headers, fn {name, value} -> {String.downcase(name, :ascii), value} end)
    response = %{response | headers: Req.Response.new(headers: fields).headers}
    consume(rest, %{state | acc: {request, response}, headers?: true})
  end

  defp consume([{:headers, _ref, trailers} | rest], %{headers?: true} = state) do
    {request, response} = state.acc
    fields = Enum.map(trailers, fn {name, value} -> {String.downcase(name, :ascii), value} end)
    trailers = Req.Response.new(trailers: fields).trailers
    consume(rest, %{state | acc: {request, %{response | trailers: trailers}}})
  end

  defp consume([{:data, _ref, chunk} | rest], state) do
    case state.sink.(chunk, state.acc) do
      {:cont, acc} -> consume(rest, %{state | acc: acc})
      {:halt, acc} -> {:done, %{state | acc: acc}}
    end
  end

  defp consume([{:done, _ref} | _rest], state), do: {:done, state}
  defp consume([{:error, _ref, error} | _rest], state), do: {:error, state, error}

  defp sink!(%Req.Request{into: nil}) do
    fn chunk, {request, response} ->
      {:cont, {request, %{response | body: response.body <> chunk}}}
    end
  end

  defp sink!(%Req.Request{into: fun}) when is_function(fun, 2) do
    fn chunk, acc -> fun.({:data, chunk}, acc) end
  end

  defp sink!(%Req.Request{into: into}) do
    raise ArgumentError,
          "pinned requests support `into: nil` or an `into:` function, got: #{inspect(into)}"
  end

  defp scheme!(%URI{scheme: "http"}), do: :http
  defp scheme!(%URI{scheme: "https"}), do: :https

  defp body!(%Req.Request{body: body}) when is_nil(body) or is_binary(body) or is_list(body),
    do: body

  defp body!(%Req.Request{body: body}) do
    raise ArgumentError, "pinned requests support binary or iodata bodies, got: #{inspect(body)}"
  end

  defp target!(%Req.Request{url: url, options: options}) do
    connect_options = Map.get(options, :connect_options, [])

    unknown = Keyword.keys(connect_options) -- @connect_option_keys

    if unknown != [] do
      raise ArgumentError,
            "pinned requests do not support connect option(s) #{inspect(unknown)}"
    end

    hostname =
      Keyword.get(connect_options, :hostname) ||
        raise ArgumentError, "pinned requests need `connect_options: [hostname: host]`"

    address =
      case :inet.parse_address(String.to_charlist(url.host || "")) do
        {:ok, address} -> address
        {:error, :einval} -> raise ArgumentError, "pinned request URL must use an IP address"
      end

    timeout = Keyword.get(connect_options, :timeout, @default_connect_timeout_ms)
    ipv6 = if tuple_size(address) == 8, do: [inet6: true], else: []

    transport_opts =
      Keyword.merge(
        [timeout: timeout] ++ ipv6,
        Keyword.get(connect_options, :transport_opts, [])
      )

    {address, hostname, transport_opts,
     pins(Keyword.get(connect_options, :certificate_pins), hostname)}
  end

  # The thumbprints that apply to `hostname`, or none.
  defp pins(nil, _hostname), do: []

  defp pins({host, thumbprints}, hostname) when is_binary(host) and is_list(thumbprints) do
    if normalized(host) == normalized(hostname),
      do: Enum.filter(thumbprints, &(is_binary(&1) and byte_size(&1) == 20)),
      else: []
  end

  defp pins(other, _hostname) do
    raise ArgumentError,
          "`certificate_pins` must be `{host, thumbprints}`, got: #{inspect(other)}"
  end

  defp normalized(host), do: host |> String.downcase() |> String.trim_trailing(".")

  defp request_path(%URI{path: path, query: nil}), do: path || "/"
  defp request_path(%URI{path: path, query: query}), do: (path || "/") <> "?" <> query

  defp normalize_error(%Mint.TransportError{reason: reason}),
    do: %Req.TransportError{reason: reason}

  defp normalize_error(%Mint.HTTPError{module: Mint.HTTP2, reason: reason}),
    do: %Req.HTTPError{protocol: :http2, reason: reason}

  defp normalize_error(%Mint.HTTPError{reason: reason}),
    do: %Req.HTTPError{protocol: :http1, reason: reason}
end
