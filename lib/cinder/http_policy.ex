defmodule Cinder.HTTPPolicy do
  @moduledoc """
  Shared validation and response-size limits for outbound HTTP clients.

  Configured service origins use `same_origin?/2` and the `:same_origin` redirect policy.
  Remote-supplied URLs use `validate_untrusted_url/2` and a resolver-backed redirect policy.
  DNS validation rejects unsafe answer sets, but does not pin the transport to the checked answer.
  """

  @max_log_bytes 500
  @default_request_timeout_ms 60_000

  @type address :: :inet.ip_address()
  @type resolver :: (String.t() -> {:ok, [address()]} | {:error, term()})

  @doc "Returns whether two HTTP(S) URLs have the same normalized origin."
  @spec same_origin?(String.t() | URI.t(), String.t() | URI.t()) :: boolean()
  def same_origin?(left, right) do
    with {:ok, left_origin} <- origin(left),
         {:ok, right_origin} <- origin(right) do
      left_origin == right_origin
    else
      _ -> false
    end
  end

  @doc "Validates a remote-supplied HTTP(S) URL against all resolved addresses."
  @spec validate_untrusted_url(String.t() | URI.t(), resolver()) ::
          {:ok, URI.t()} | {:error, atom()}
  def validate_untrusted_url(url, resolver \\ &resolve_host/1) when is_function(resolver, 1) do
    with {:ok, uri} <- validated_uri(url),
         {:ok, addresses} <- addresses(uri.host, resolver),
         :ok <- validate_addresses(addresses) do
      {:ok, uri}
    end
  end

  @doc """
  Resolves and validates a redirect.

  Pass `:same_origin` for configured services. Pass `:untrusted` or a resolver function for a
  remote-supplied destination. HTTPS-to-HTTP redirects are always rejected.
  """
  @spec resolve_redirect(
          String.t() | URI.t(),
          String.t(),
          :same_origin | :untrusted | resolver()
        ) ::
          {:ok, URI.t()} | {:error, atom()}
  def resolve_redirect(current, location, policy)

  def resolve_redirect(current, location, :same_origin) do
    with {:ok, current_uri} <- validated_uri(current),
         {:ok, next_uri} <- merge_uri(current_uri, location),
         {:ok, next_uri} <- validated_uri(next_uri),
         :ok <- prevent_downgrade(current_uri, next_uri) do
      if same_origin?(current_uri, next_uri),
        do: {:ok, next_uri},
        else: {:error, :cross_origin_redirect}
    end
  end

  def resolve_redirect(current, location, :untrusted),
    do: resolve_redirect(current, location, &resolve_host/1)

  def resolve_redirect(current, location, resolver) when is_function(resolver, 1) do
    with {:ok, current_uri} <- validated_uri(current),
         {:ok, next_uri} <- merge_uri(current_uri, location),
         {:ok, next_uri} <- validated_uri(next_uri),
         :ok <- prevent_downgrade(current_uri, next_uri) do
      validate_untrusted_url(next_uri, resolver)
    end
  end

  @doc "Runs a Req request with total-time and retained-response-body limits."
  @spec bounded_request(Req.Request.t() | String.t() | keyword(), pos_integer()) ::
          {:ok, Req.Response.t()} | {:error, term()}
  def bounded_request(request, max_bytes),
    do: bounded_request(request, max_bytes, @default_request_timeout_ms)

  @doc "Like `bounded_request/2`, with an explicit total request deadline in milliseconds."
  @spec bounded_request(
          Req.Request.t() | String.t() | keyword(),
          pos_integer(),
          pos_integer()
        ) :: {:ok, Req.Response.t()} | {:error, term()}
  def bounded_request(request, max_bytes, timeout_ms)
      when is_integer(max_bytes) and max_bytes > 0 and is_integer(timeout_ms) and timeout_ms > 0 do
    request = request_struct(request)
    gate = make_ref()
    owner = self()

    task =
      Task.Supervisor.async_nolink(Cinder.HTTPPolicy.TaskSupervisor, fn ->
        receive do
          {^gate, :run} -> run_bounded_request(request, max_bytes, timeout_ms)
        end
      end)

    case allow_req_test(request, owner, task.pid) do
      :ok ->
        send(task.pid, {gate, :run})
        await_request(task, timeout_ms)

      {:error, reason} ->
        Task.shutdown(task, :brutal_kill)
        {:error, reason}
    end
  end

  defp run_bounded_request(request, max_bytes, timeout_ms) do
    started_at = System.monotonic_time(:millisecond)

    into = fn {:data, chunk}, {req, resp} ->
      collect_chunk(chunk, {req, resp}, max_bytes, started_at, timeout_ms)
    end

    request
    |> Req.request(decode_body: false, into: into)
    |> finish_bounded_request(started_at, timeout_ms)
  end

  @doc "Removes line breaks and limits a remote value before logging it."
  @spec sanitize_log(term()) :: binary()
  def sanitize_log(value) do
    value
    |> log_string()
    |> :binary.replace(["\r", "\n"], "", [:global])
    |> truncate(@max_log_bytes)
  end

  defp validated_uri(url) do
    with {:ok, uri} <- new_uri(url),
         {:ok, uri} <- normalize_http_uri(uri),
         :ok <- reject_userinfo(uri),
         :ok <- reject_fragment(uri) do
      {:ok, uri}
    end
  end

  defp new_uri(%URI{} = uri), do: {:ok, uri}
  defp new_uri(url) when is_binary(url), do: URI.new(url)
  defp new_uri(_url), do: {:error, :invalid_url}

  defp normalize_http_uri(%URI{} = uri) do
    scheme = uri.scheme && String.downcase(uri.scheme, :ascii)
    host = uri.host && normalize_host(uri.host)
    uri = %{uri | scheme: scheme, host: host}

    cond do
      scheme not in ["http", "https"] -> {:error, :unsupported_scheme}
      host in [nil, ""] -> {:error, :missing_host}
      not valid_port?(uri) -> {:error, :invalid_port}
      true -> {:ok, uri}
    end
  end

  defp normalize_host(host) do
    host = String.downcase(host, :ascii)

    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} -> address |> :inet.ntoa() |> List.to_string()
      {:error, :einval} -> host
    end
  end

  defp reject_userinfo(%URI{userinfo: nil}), do: :ok
  defp reject_userinfo(_uri), do: {:error, :userinfo_not_allowed}

  defp reject_fragment(%URI{fragment: nil}), do: :ok
  defp reject_fragment(_uri), do: {:error, :fragment_not_allowed}

  defp origin(url) do
    with {:ok, uri} <- new_uri(url),
         {:ok, uri} <- normalize_http_uri(uri) do
      {:ok, {uri.scheme, uri.host, effective_port(uri)}}
    end
  end

  defp effective_port(%URI{port: nil, scheme: "http"}), do: 80
  defp effective_port(%URI{port: nil, scheme: "https"}), do: 443
  defp effective_port(%URI{port: port}), do: port

  defp valid_port?(uri) do
    port = effective_port(uri)
    is_integer(port) and port in 1..65_535
  end

  defp merge_uri(current, location) when is_binary(location) do
    {:ok, URI.merge(current, location)}
  rescue
    _error -> {:error, :invalid_url}
  end

  defp merge_uri(_current, _location), do: {:error, :invalid_url}

  defp prevent_downgrade(%URI{scheme: "https"}, %URI{scheme: "http"}),
    do: {:error, :https_downgrade}

  defp prevent_downgrade(_current, _next), do: :ok

  defp addresses(host, resolver) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} -> {:ok, [address]}
      {:error, :einval} -> normalize_resolution(resolver.(host))
    end
  end

  defp normalize_resolution({:ok, addresses}) when is_list(addresses) and addresses != [],
    do: {:ok, addresses}

  defp normalize_resolution(_result), do: {:error, :dns_resolution_failed}

  defp resolve_host(host) do
    char_host = String.to_charlist(host)

    addresses =
      [:inet, :inet6]
      |> Enum.flat_map(fn family ->
        case :inet.getaddrs(char_host, family) do
          {:ok, found} -> found
          {:error, _reason} -> []
        end
      end)
      |> Enum.uniq()

    normalize_resolution({:ok, addresses})
  end

  defp validate_addresses(addresses) do
    if Enum.any?(addresses, &forbidden_address?/1),
      do: {:error, :forbidden_address},
      else: :ok
  end

  # IPv4 special-use networks that must never be reached through a remote-supplied URL.
  defp forbidden_address?({0, _, _, _}), do: true
  defp forbidden_address?({10, _, _, _}), do: true
  defp forbidden_address?({100, b, _, _}) when b in 64..127, do: true
  defp forbidden_address?({127, _, _, _}), do: true
  defp forbidden_address?({169, 254, _, _}), do: true
  defp forbidden_address?({172, b, _, _}) when b in 16..31, do: true
  defp forbidden_address?({192, 0, 0, _}), do: true
  defp forbidden_address?({192, 0, 2, _}), do: true
  defp forbidden_address?({192, 31, 196, _}), do: true
  defp forbidden_address?({192, 52, 193, _}), do: true
  defp forbidden_address?({192, 88, 99, _}), do: true
  defp forbidden_address?({192, 168, _, _}), do: true
  defp forbidden_address?({192, 175, 48, _}), do: true
  defp forbidden_address?({198, b, _, _}) when b in 18..19, do: true
  defp forbidden_address?({198, 51, 100, _}), do: true
  defp forbidden_address?({203, 0, 113, _}), do: true
  defp forbidden_address?({a, _, _, _}) when a >= 224, do: true

  defp forbidden_address?({a, b, c, d})
       when a in 1..223 and b in 0..255 and c in 0..255 and d in 0..255,
       do: false

  # IPv4-mapped IPv6 must inherit the embedded IPv4 classification.
  defp forbidden_address?({0, 0, 0, 0, 0, 0xFFFF, high, low}),
    do: forbidden_address?(embedded_ipv4(high, low))

  # Deprecated IPv4-compatible IPv6, unspecified, and loopback all live in ::/96.
  defp forbidden_address?({0, 0, 0, 0, 0, 0, _, _}), do: true

  # The well-known NAT64 prefix embeds IPv4 in its final 32 bits.
  defp forbidden_address?({0x64, 0xFF9B, 0, 0, 0, 0, high, low}),
    do: forbidden_address?(embedded_ipv4(high, low))

  defp forbidden_address?({0x64, 0xFF9B, 1, _, _, _, _, _}), do: true
  defp forbidden_address?({0x100, 0, 0, 0, _, _, _, _}), do: true

  defp forbidden_address?({0x2001, second, _, _, _, _, _, _}) when second in 0x0000..0x01FF,
    do: true

  defp forbidden_address?({0x2001, 0x0DB8, _, _, _, _, _, _}), do: true

  defp forbidden_address?({0x2002, high, low, _, _, _, _, _}),
    do: forbidden_address?(embedded_ipv4(high, low))

  defp forbidden_address?({0x3FFF, second, _, _, _, _, _, _}) when second in 0x0000..0x0FFF,
    do: true

  defp forbidden_address?({first, _, _, _, _, _, _, _}) when first in 0xFC00..0xFDFF, do: true
  defp forbidden_address?({first, _, _, _, _, _, _, _}) when first in 0xFE80..0xFEFF, do: true
  defp forbidden_address?({first, _, _, _, _, _, _, _}) when first in 0xFF00..0xFFFF, do: true

  defp forbidden_address?({a, b, c, d, e, f, g, h})
       when a in 0x2000..0x3FFF and b in 0..0xFFFF and c in 0..0xFFFF and d in 0..0xFFFF and
              e in 0..0xFFFF and f in 0..0xFFFF and g in 0..0xFFFF and h in 0..0xFFFF,
       do: false

  defp forbidden_address?(_address), do: true

  defp embedded_ipv4(high, low) do
    {div(high, 256), rem(high, 256), div(low, 256), rem(low, 256)}
  end

  defp decode_json(%Req.Response{body: body} = response) when is_binary(body) and body != "" do
    if json_content_type?(response) do
      case Jason.decode(body) do
        {:ok, decoded} -> {:ok, %{response | body: decoded}}
        {:error, _exception} -> {:error, :invalid_json}
      end
    else
      {:ok, response}
    end
  end

  defp decode_json(response), do: {:ok, response}

  defp json_content_type?(response) do
    response
    |> Req.Response.get_header("content-type")
    |> Enum.any?(fn value ->
      media_type =
        value
        |> String.split(";", parts: 2)
        |> hd()
        |> String.trim()
        |> String.downcase(:ascii)

      media_type == "application/json" or String.ends_with?(media_type, "+json")
    end)
  end

  defp log_string(value) when is_binary(value), do: value
  defp log_string(value), do: inspect(value)

  defp truncate(value, max_bytes) when byte_size(value) <= max_bytes, do: value

  defp truncate(value, max_bytes) do
    prefix = binary_part(value, 0, max_bytes)

    case :unicode.characters_to_binary(prefix) do
      valid when is_binary(valid) -> valid
      {_status, valid, _rest} -> valid
    end
  end

  defp request_expired?(started_at, timeout_ms),
    do: System.monotonic_time(:millisecond) - started_at >= timeout_ms

  defp collect_chunk(chunk, {req, resp}, max_bytes, started_at, timeout_ms) do
    cond do
      request_expired?(started_at, timeout_ms) ->
        {:halt, {req, %{resp | body: {:error, :request_timeout}}}}

      byte_size(resp.body) + byte_size(chunk) > max_bytes ->
        {:halt, {req, %{resp | body: {:error, :response_too_large}}}}

      true ->
        {:cont, {req, %{resp | body: resp.body <> chunk}}}
    end
  end

  defp finish_bounded_request({:ok, %{body: {:error, reason}}}, _started_at, _timeout_ms)
       when reason in [:request_timeout, :response_too_large],
       do: {:error, reason}

  defp finish_bounded_request({:ok, response}, started_at, timeout_ms) do
    if request_expired?(started_at, timeout_ms),
      do: {:error, :request_timeout},
      else: decode_json(response)
  end

  defp finish_bounded_request(result, _started_at, _timeout_ms), do: result

  defp request_struct(%Req.Request{} = request), do: request
  defp request_struct(%URI{} = url), do: Req.new(url: url)
  defp request_struct(url) when is_binary(url), do: Req.new(url: url)
  defp request_struct(options) when is_list(options), do: Req.new(options)

  defp allow_req_test(%Req.Request{options: %{plug: {Req.Test, name}}}, owner, request_pid),
    do: allow_req_test_result(Req.Test.allow(name, owner, request_pid))

  defp allow_req_test(_request, _owner, _request_pid), do: :ok

  defp allow_req_test_result(:ok), do: :ok
  defp allow_req_test_result({:error, %{reason: :cant_allow_in_shared_mode}}), do: :ok
  defp allow_req_test_result({:error, reason}), do: {:error, reason}

  defp await_request(task, timeout_ms) do
    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        {:error, reason}

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, :request_timeout}
    end
  end
end
