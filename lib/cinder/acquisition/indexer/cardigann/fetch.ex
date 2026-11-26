defmodule Cinder.Acquisition.Indexer.Cardigann.Fetch do
  @moduledoc """
  Sends one Cardigann search request and its redirect hops on `Cinder.HTTPPolicy`'s untrusted
  path (#1671; #1615 threat model, "URLs" and "Run time and size"; #1619 point 1). The caller
  holds the indexer's slot; every hop runs inside it.

  Before each request and each hop:

  1. the secret check: when the URL holds a secret value (raw, `application/x-www-form-urlencoded`
     or percent-encoded, spaces as `+` or `%20`), or the definition's search templates reference
     a secret setting (`secret_referenced?: true`), the URL's host must be in the copy's
     `credential_hosts`; otherwise nothing is sent and the answer is `:secret_host`. A secret is a
     declared setting's stored secret that is not blank and differs from the copy's default
     (`Cinder.Indexers.Definitions.Hold`'s rule);
  2. `HTTPPolicy.untrusted_request_target/2` pins a validated address: a forbidden address is
     `:forbidden_address`, a host that does not resolve `:dns`, any other refusal of a URL the
     definition built `:definition_error`, and of a `Location` the site sent `:bad_response`.

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
          required(:credential_hosts) => MapSet.t(),
          required(:now) => DateTime.t()
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
        with {:ok, next} <- redirect_target(target, location, request) do
          hop(next, request, hops + 1)
        end

      [_location | _] when request.follow_redirects? ->
        {:error, :too_many_redirects}

      _none_or_not_followed ->
        {:error, {:http_status, response.status}}
    end
  end

  defp redirect_target(target, location, request) do
    case next_target(target.uri, location) do
      {:ok, next} ->
        with :ok <- secret_check(URI.to_string(next.uri), next.uri, request), do: {:ok, next}

      {:error, reason} ->
        {:error, refusal(reason, :bad_response)}
    end
  end

  defp target(url, request, text_refusal) do
    with {:ok, uri} <- parse(url),
         :ok <- secret_check(url, uri, request) do
      case request_target(url) do
        {:ok, target} -> {:ok, target}
        {:error, reason} -> {:error, refusal(reason, text_refusal)}
      end
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

  # HTTPPolicy's own resolver unless `config :cinder, Cinder.Acquisition.Indexer.Cardigann`
  # names one (a test's).
  defp request_target(url) do
    case Keyword.get(config(), :resolver) do
      nil -> HTTPPolicy.untrusted_request_target(url)
      resolver -> HTTPPolicy.untrusted_request_target(url, resolver)
    end
  end

  defp next_target(uri, location) do
    case Keyword.get(config(), :resolver) do
      nil -> HTTPPolicy.untrusted_redirect_target(uri, location)
      resolver -> HTTPPolicy.untrusted_redirect_target(uri, location, resolver)
    end
  end

  @doc """
  True when `link`, a row's link, holds a secret under `request` and is not an http(s) URL on a
  credential host. It holds one when it holds a secret value in a form the secret check reads,
  or when the definition's field templates reference a secret setting
  (`link_secret_referenced?: true`). A magnet has no host, so such a magnet always holds one.
  """
  @spec secret_link?(String.t(), request()) :: boolean()
  def secret_link?(link, request) when is_binary(link) do
    (request.link_secret_referenced? or holds_secret?(link, request.secrets)) and
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
    if (request.secret_referenced? or holds_secret?(url, request.secrets)) and
         not credential_host?(uri, request.credential_hosts),
       do: {:error, :secret_host},
       else: :ok
  end

  defp holds_secret?(url, secrets) do
    lowered = String.downcase(url)

    Enum.any?(secrets, fn secret ->
      Enum.any?(forms(secret), &String.contains?(lowered, String.downcase(&1)))
    end)
  end

  defp forms(secret) do
    www = URI.encode_www_form(secret)

    Enum.uniq([
      secret,
      www,
      String.replace(www, "+", "%20"),
      URI.encode(secret, &URI.char_unreserved?/1)
    ])
  end

  defp credential_host?(%URI{host: host}, hosts) when is_binary(host),
    do: MapSet.member?(hosts, host |> String.downcase() |> String.trim_trailing("."))

  defp credential_host?(_uri, _hosts), do: false

  # --- one request ---

  defp send_request(target, request) do
    options =
      HTTPPolicy.request_options(
        target,
        Keyword.merge(req_options(),
          method: :get,
          headers: [{"accept-encoding", "identity"}]
        )
      )

    Indexer.request(request.context, options,
      raw_body: true,
      max_bytes: @max_bytes,
      timeout_ms: @request_timeout_ms,
      redact_path: true
    )
  end

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

  defp decoded(response) do
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
