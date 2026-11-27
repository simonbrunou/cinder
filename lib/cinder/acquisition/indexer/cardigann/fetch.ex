defmodule Cinder.Acquisition.Indexer.Cardigann.Fetch do
  @moduledoc """
  Sends one Cardigann search request and its redirect hops on `Cinder.HTTPPolicy`'s untrusted
  path (#1671; #1615 threat model, "URLs" and "Run time and size"; #1619 point 1). The caller
  holds the indexer's slot; every hop runs inside it.

  Before each request and each hop:

  1. the secret check: when the URL holds a secret value (raw, `application/x-www-form-urlencoded`
     or percent-encoded, spaces as `+` or `%20`, each encoded from UTF-8 and from the request's
     `charset`, the definition's, #1678), or the definition's search templates reference
     a secret setting (`secret_referenced?: true`), the URL's host must be in the copy's
     `credential_hosts`; otherwise nothing is sent and the answer is `:secret_host`. A secret is a
     declared setting's stored secret that is not blank and differs from the copy's default
     (`Cinder.Indexers.Definitions.Hold`'s rule);
  2. `HTTPPolicy.untrusted_request_target/2` pins a validated address: a forbidden address is
     `:forbidden_address`, a host that does not resolve `:dns`, any other refusal of a URL the
     definition built `:definition_error`, and of a `Location` the site sent `:bad_response`.

  A request whose `certificate_pins` holds the definition's `certificates` (#1678) passes them
  to `Cinder.HTTPPolicy.PinnedAdapter` on each HTTPS hop whose pinned target names the host it
  verifies (`connect_options` with `:hostname`) and whose host, in lower case and without a
  trailing dot, is the indexer's base URL host (`pin_options/2`), and on no other hop.

  Then `Cinder.Acquisition.Indexer.request/3` sends a GET with `accept-encoding: identity`, a 30 s
  timeout of its own, Req's redirects and retry off, and its one retry after a 502, 503, 504 or
  408. The body is read up to `max_bytes/0`; the request's path stays out of
  `Cinder.HTTPPolicy`'s request telemetry. A site can answer gzip anyway: Nyaa.si's keywordless
  page came gzip-encoded to a request for `identity` (#1671's test path).

  Answers, by the first rule that matches:

  - a 3xx with a `Location`: with the definition's `followredirect` on, the next hop through
    `HTTPPolicy.untrusted_redirect_target/3`, at most `max_redirects/0` hops, past which the
    answer is `:too_many_redirects`; with it off, `{:http_status, status}`, as Prowlarr's parser
    throws on a redirect;
  - a 403 or 503 whose `server` header names Cloudflare: `:challenge` (#1682 handles it);
  - a 2xx: `{:ok, body, uri}`, `uri` the URL that answered, which links resolve against. A body
    whose `content-encoding` is `gzip` or `x-gzip` is inflated first, up to `max_bytes/0` of
    output, past which the answer is `:too_large`; a gzip body that does not inflate whole, or
    any other encoding than `identity`, is `:bad_response`;
  - any other status as `Cinder.Acquisition.Indexer.NewznabAnswer.classify/4` reads a status:
    401 rejects credentials, 429 is a limit, any other status `{:http_status, status}`;
  - a transport tag of `request/3` as it is.

  No answer carries a URL, a header or a body.
  """

  alias Cinder.Acquisition.Indexer
  alias Cinder.Acquisition.Indexer.Cardigann.Charset
  alias Cinder.Acquisition.Indexer.NewznabAnswer
  alias Cinder.HTTPPolicy

  # Measured for #1671 on hand-fetched pages, never committed: a Nyaa.si search page 125,822
  # bytes, its keywordless page 122,898; a Torrent9 search page 23,791, its home page 127,345.
  # 2 MiB is about 16 times the largest.
  @max_bytes 2 * 1024 * 1024
  @max_redirects 5
  @request_timeout_ms 30_000

  @type request :: %{
          required(:context) => Indexer.context(),
          required(:follow_redirects?) => boolean(),
          required(:secrets) => [String.t()],
          required(:secret_referenced?) => boolean(),
          required(:link_secret_referenced?) => boolean(),
          optional(:download_secret_referenced?) => boolean(),
          required(:credential_hosts) => MapSet.t(),
          required(:now) => DateTime.t(),
          optional(:charset) => Cinder.Acquisition.Indexer.Cardigann.Charset.t(),
          optional(:certificate_pins) => {String.t(), [<<_::160>>]} | nil,
          optional(:resolver) => HTTPPolicy.resolver() | nil,
          optional(:req_options) => keyword() | nil
        }

  @doc "The largest body in bytes one request reads: 2 MiB."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc "The most redirect hops one request follows: 5."
  @spec max_redirects() :: pos_integer()
  def max_redirects, do: @max_redirects

  @doc "Each request's own timeout in milliseconds: 30 s."
  @spec request_timeout_ms() :: pos_integer()
  def request_timeout_ms, do: @request_timeout_ms

  @doc "Sends a GET to `url` under `request`; see the moduledoc."
  @spec get(String.t(), request()) :: {:ok, binary(), URI.t()} | {:error, term()}
  def get(url, request) when is_binary(url) do
    with {:ok, target} <- target(url, request, :definition_error) do
      hop(target, request, 0)
    end
  end

  defp hop(target, request, hops) do
    case send_request(target, request) do
      {:ok, %Req.Response{status: status} = response} when status in 300..399 ->
        redirect(target, response, request, hops)

      {:ok, response} ->
        answer(response, target, request)

      {:error, tag} ->
        {:error, tag}
    end
  end

  defp redirect(target, response, request, hops) do
    case Req.Response.get_header(response, "location") do
      [location | _] when request.follow_redirects? and hops < @max_redirects ->
        target |> redirect_target(location, request) |> followed(request, hops)

      [_location | _] when request.follow_redirects? ->
        {:error, :too_many_redirects}

      _none_or_not_followed ->
        {:error, {:http_status, response.status}}
    end
  end

  defp followed({:ok, next}, request, hops), do: hop(next, request, hops + 1)
  defp followed({:error, :secret_host} = refused, _request, _hops), do: refused
  defp followed({:error, reason}, _request, _hops), do: {:error, refusal(reason, :bad_response)}

  @doc """
  The pinned target of a redirect from `target` to `location` under `request`, or the refusal:
  `:secret_host` from the secret check, which runs on the merged URL before any DNS lookup, so
  a host built from a secret is never resolved; else `HTTPPolicy.untrusted_redirect_target/3`'s
  own reason, `:https_downgrade` and a URL's text refusal included. The resolver is the
  request's `resolver` when it holds one.
  """
  @spec redirect_target(HTTPPolicy.request_target(), String.t(), request()) ::
          {:ok, HTTPPolicy.request_target()} | {:error, atom() | String.t()}
  def redirect_target(target, location, request) do
    with :ok <- merged_secret_check(target.uri, location, request) do
      next_target(target.uri, location, request)
    end
  end

  # A `Location` that is not UTF-8 goes through the check too: `URI.merge/2` reads it,
  # `holds_secret?/2` reads each invalid sequence as U+FFFD, and a host holding such a byte is no
  # credential host. A merge that raises, which no `Location` tried for #1672 did, is refused
  # while the indexer holds a secret value; a secret reference needs one, so `secrets` alone
  # decides.
  defp merged_secret_check(uri, location, request) do
    case merged(uri, location) do
      {:ok, next} -> secret_check(URI.to_string(next), next, request)
      :error -> if request.secrets != [], do: {:error, :secret_host}, else: :ok
    end
  end

  # The URL a redirect names, before any check; `:error` for one `URI.merge/2` cannot read.
  defp merged(uri, location) do
    {:ok, URI.merge(uri, location)}
  rescue
    _invalid -> :error
  end

  @doc """
  The pinned target of a request to `url` under `request`, or the refusal: `:definition_error`
  for a URL with no host, `:secret_host` from the secret check, else
  `HTTPPolicy.untrusted_request_target/2`'s own reason. The resolver is the request's `resolver`
  when it holds one.
  """
  @spec request_target(String.t(), request()) ::
          {:ok, HTTPPolicy.request_target()} | {:error, atom() | String.t()}
  def request_target(url, request) when is_binary(url) do
    with {:ok, uri} <- parse(url),
         :ok <- secret_check(url, uri, request) do
      pinned_target(url, request)
    end
  end

  defp target(url, request, text_refusal) do
    case request_target(url, request) do
      {:ok, target} -> {:ok, target}
      {:error, reason} when reason in [:definition_error, :secret_host] -> {:error, reason}
      {:error, reason} -> {:error, refusal(reason, text_refusal)}
    end
  end

  defp parse(url) do
    case URI.new(url) do
      {:ok, %URI{host: host} = uri} when is_binary(host) and host != "" -> {:ok, uri}
      _invalid -> {:error, :definition_error}
    end
  end

  defp refusal(:forbidden_address, _text), do: :forbidden_address
  defp refusal(:dns_resolution_failed, _text), do: :dns
  defp refusal(_reason, text), do: text

  # HTTPPolicy's own resolver unless the request holds one (a grab's client options) or
  # `config :cinder, Cinder.Acquisition.Indexer.Cardigann` names one (a test's).
  defp pinned_target(url, request) do
    case resolver(request) do
      nil -> HTTPPolicy.untrusted_request_target(url)
      resolver -> HTTPPolicy.untrusted_request_target(url, resolver)
    end
  end

  defp next_target(uri, location, request) do
    case resolver(request) do
      nil -> HTTPPolicy.untrusted_redirect_target(uri, location)
      resolver -> HTTPPolicy.untrusted_redirect_target(uri, location, resolver)
    end
  end

  defp resolver(request), do: Map.get(request, :resolver) || Keyword.get(config(), :resolver)

  @doc """
  True when `link`, a row's link, holds a secret under `request` and is not an http(s) URL on a
  credential host. It holds one when it holds a secret value in a form the secret check reads,
  or when the definition's field templates reference a secret setting
  (`link_secret_referenced?: true`). A magnet has no host, so such a magnet always holds one.
  """
  @spec secret_link?(String.t(), request()) :: boolean()
  def secret_link?(link, request) when is_binary(link) do
    (request.link_secret_referenced? or holds_secret?(link, request)) and
      not credential_url?(link, request.credential_hosts)
  end

  defp credential_url?(link, hosts) do
    case URI.new(link) do
      {:ok, %URI{scheme: scheme} = uri} when scheme in ["http", "https"] ->
        credential_host?(uri, hosts)

      _other ->
        false
    end
  end

  # --- the secret check ---

  defp secret_check(url, uri, request) do
    if (request.secret_referenced? or holds_secret?(url, request)) and
         not credential_host?(uri, request.credential_hosts),
       do: {:error, :secret_host},
       else: :ok
  end

  # Each invalid sequence reads as U+FFFD first: `String.downcase/1` leaves the character after a
  # lone byte such as 0xC3 as it is, which hid a capitalised secret behind it (#1672).
  defp holds_secret?(url, request) do
    lowered = url |> String.replace_invalid() |> String.downcase()
    charset = Map.get(request, :charset, :utf8)

    Enum.any?(request.secrets, fn secret ->
      Enum.any?(forms(secret, charset), &String.contains?(lowered, String.downcase(&1)))
    end)
  end

  # The secret as written, then percent-encoded from its UTF-8 bytes and from its bytes in the
  # definition's charset, as `Query` writes a query string in it.
  defp forms(secret, charset) do
    encoded =
      for bytes <- Enum.uniq([secret, Charset.encode(secret, charset)]) do
        www = URI.encode_www_form(bytes)
        [www, String.replace(www, "+", "%20"), URI.encode(bytes, &URI.char_unreserved?/1)]
      end

    Enum.uniq([secret | List.flatten(encoded)])
  end

  @doc "Whether `uri`'s host, in lower case and without a trailing dot, is one of `hosts`."
  @spec credential_host?(URI.t(), MapSet.t()) :: boolean()
  def credential_host?(%URI{host: host}, hosts) when is_binary(host),
    do: MapSet.member?(hosts, host |> String.downcase() |> String.trim_trailing("."))

  def credential_host?(_uri, _hosts), do: false

  # --- one request ---

  defp send_request(target, request), do: send_get(target, request)

  @doc """
  Sends one GET to `target` under `request` through `Cinder.Acquisition.Indexer.request/3`, with
  `accept-encoding: identity`, Req's redirects and retry off and the path out of the request
  telemetry, and answers `request/3`'s answer. `opts` takes `headers` (more request headers),
  `max_bytes` (`max_bytes/0` by default), `timeout_ms` (`request_timeout_ms/0` by default) and
  `retry` (`request/3`'s one retry, true by default). The plug is the request's `req_options`
  when it holds them, else the adapter config's.
  """
  @spec send_get(HTTPPolicy.request_target(), request(), keyword()) ::
          {:ok, Req.Response.t()} | {:error, atom()}
  def send_get(target, request, opts \\ []) do
    req_options = Map.get(request, :req_options) || req_options()
    pins = pin_options(target, request)

    options =
      HTTPPolicy.request_options(
        target,
        Keyword.merge(req_options,
          method: :get,
          headers: [{"accept-encoding", "identity"} | Keyword.get(opts, :headers, [])],
          connect_options: Keyword.merge(Keyword.get(req_options, :connect_options, []), pins)
        )
      )

    Indexer.request(request.context, options,
      raw_body: true,
      max_bytes: Keyword.get(opts, :max_bytes, @max_bytes),
      timeout_ms: Keyword.get(opts, :timeout_ms, @request_timeout_ms),
      redact_path: true,
      retry: Keyword.get(opts, :retry, true)
    )
  end

  @doc """
  The `:certificate_pins` of a request for `definition` at `base_url`: its base URL host and the
  20-byte SHA-1 each `certificates` entry names in hex digits of either case, or nil for a
  definition with none or a base URL with no host. The load check refuses an entry that is not
  40 hex digits (#1678), so none is dropped here.
  """
  @spec certificate_pins(map(), String.t() | nil) :: {String.t(), [binary()]} | nil
  def certificate_pins(%{certificates: [_ | _] = certificates}, base_url) do
    case URI.new(base_url || "") do
      {:ok, %URI{host: host}} when is_binary(host) and host != "" ->
        {host,
         for(hex <- certificates, {:ok, sha} <- [Base.decode16(hex, case: :mixed)], do: sha)}

      _no_host ->
        nil
    end
  end

  def certificate_pins(_definition, _base_url), do: nil

  @doc """
  The `connect_options` that carry `request`'s pinned certificates to `target`:
  `[certificate_pins: {host, thumbprints}]` when `target` is a pinned HTTPS target whose host,
  in lower case and without a trailing dot, is the pins' base URL host, else none.
  """
  @spec pin_options(HTTPPolicy.request_target(), request()) :: keyword()
  def pin_options(target, request) do
    with {host, [_ | _] = thumbprints} <- Map.get(request, :certificate_pins),
         %URI{scheme: "https", host: target_host} when is_binary(target_host) <- target.uri,
         true <- Keyword.has_key?(target.connect_options, :hostname),
         true <- normalized(target_host) == normalized(host) do
      [certificate_pins: {normalized(host), thumbprints}]
    else
      _no_pin -> []
    end
  end

  defp normalized(host), do: host |> String.downcase() |> String.trim_trailing(".")

  defp answer(%Req.Response{status: status} = response, target, request) do
    cond do
      status in [403, 503] and cloudflare?(response) ->
        {:error, :challenge}

      status in 200..299 ->
        with {:ok, body} <- decoded(response), do: {:ok, body, target.uri}

      true ->
        NewznabAnswer.classify(status, response.headers, nil, request.now)
    end
  end

  defp body(%Req.Response{body: body}) when is_binary(body), do: body
  defp body(_response), do: ""

  defp cloudflare?(response) do
    response
    |> Req.Response.get_header("server")
    |> Enum.any?(&String.contains?(String.downcase(&1), "cloudflare"))
  end

  @doc """
  The body of a 2xx `response` as the moduledoc says: inflated when its `content-encoding` is
  `gzip` or `x-gzip`, up to `max_bytes/0` of output (`:too_large` past it), `:bad_response` for
  a gzip body that does not inflate whole or any other encoding.
  """
  @spec decoded(Req.Response.t()) :: {:ok, binary()} | {:error, :too_large | :bad_response}
  def decoded(response) do
    case encodings(response) do
      [] -> {:ok, body(response)}
      [gzip] when gzip in ["gzip", "x-gzip"] -> gunzip(body(response))
      _other -> {:error, :bad_response}
    end
  end

  # The `content-encoding` codings in order, `identity` left out.
  defp encodings(response) do
    for value <- Req.Response.get_header(response, "content-encoding"),
        coding <- String.split(value, ","),
        coding = coding |> String.trim() |> String.downcase(),
        coding not in ["", "identity"],
        do: coding
  end

  # Inflates in the chunks `:zlib.safeInflate/2` gives, so a body that inflates past the cap
  # stops at the first chunk over it. `:zlib.inflateEnd/1` raises on a stream that did not end.
  defp gunzip(body) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z, 31)
      inflated = inflate(z, :zlib.safeInflate(z, body), [], 0)
      if match?({:ok, _body}, inflated), do: :zlib.inflateEnd(z)
      inflated
    catch
      :error, _reason -> {:error, :bad_response}
    after
      :zlib.close(z)
    end
  end

  defp inflate(z, {status, out}, acc, size) do
    size = size + IO.iodata_length(out)

    cond do
      size > @max_bytes -> {:error, :too_large}
      status == :continue -> inflate(z, :zlib.safeInflate(z, []), [acc | out], size)
      true -> {:ok, IO.iodata_to_binary([acc | out])}
    end
  end

  defp req_options, do: Keyword.get(config(), :req_options, [])

  defp config, do: Application.get_env(:cinder, Cinder.Acquisition.Indexer.Cardigann, [])
end
