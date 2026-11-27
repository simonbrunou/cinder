defmodule Cinder.Acquisition.Indexer.Cardigann.Fetch do
  @moduledoc """
  Sends one Cardigann search request and its redirect hops on `Cinder.HTTPPolicy`'s untrusted
  path (#1671; #1615 threat model, "URLs" and "Run time and size"; #1619 point 1). The caller
  holds the indexer's slot; every hop runs inside it.

  Before each request and each hop:

  1. the secret check: when the URL or a POST's form body holds a secret value (raw,
     `application/x-www-form-urlencoded` or percent-encoded, spaces as `+` or `%20`, each encoded
     from UTF-8 and from the request's `charset`, the definition's, #1678; or encoded twice, as a
     `$raw` input's value is, #1679), or the definition's search templates reference a secret
     setting (`secret_referenced?: true`), the URL's host must be in the copy's
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

  Then `Cinder.Acquisition.Indexer.request/3` sends the page's request (`send_page/2`): a GET, or
  a POST with an `application/x-www-form-urlencoded` body (#1679) or a login's
  `multipart/form-data` one (#1680), with `accept-encoding: identity`, a 30 s timeout of its
  own, Req's redirects and retry off, and its one retry after a 502, 503, 504 or 408, which a
  login's request turns off (`retry: false`). The definition's headers (`site_headers`,
  `Cinder.Acquisition.Indexer.Cardigann.Headers`) go only on a hop to a credential host, a
  `cookie` among them joined with Cinder's own. A login session's request (`send_session/3`)
  carries the jar's cookies the same way and keeps each hop's `Set-Cookie` from a credential
  host. The body is read up to `max_bytes/0`; the request's path stays out of
  `Cinder.HTTPPolicy`'s request telemetry. A site can answer gzip anyway: Nyaa.si's keywordless
  page came gzip-encoded to a request for `identity` (#1671's test path).

  Answers, by the first rule that matches:

  - a 3xx with a `Location`: with the definition's `followredirect` on, or the path's own
    (#1679), the next hop through `HTTPPolicy.untrusted_redirect_target/3`, at most
    `max_redirects/0` hops, past which the answer is `:too_many_redirects`; with it off,
    `{:http_status, status}`, as Prowlarr's parser throws on a redirect. A 301, 302 or 303
    turns a POST into a GET with no body; a 307 or 308 keeps both, and the secret check reads
    the body again before that hop (`redirected/2`), and a login's body (`secret_body?`) goes
    on it only to a credential host;
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
  alias Cinder.Acquisition.Indexer.Cardigann.{Charset, Jar, Query}
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

  @typedoc """
  One request: its URL, its method (`:get` unless given), its body (nil for none), the body's
  `content_type` (`application/x-www-form-urlencoded` unless given), the definition's headers
  (`site_headers`, sent only to a credential host), whether its search path follows redirects on
  its own (`follow_redirects?`, beside the definition's), whether `request/3`'s one retry runs
  (`retry`, true unless given), and whether its body holds a credential whatever the secret
  check finds in it (`secret_body?`, a login's, #1680): such a body goes on a redirect hop only
  to a credential host.
  """
  @type outgoing :: %{
          required(:url) => String.t(),
          optional(:method) => :get | :post,
          optional(:body) => binary() | nil,
          optional(:content_type) => String.t() | nil,
          optional(:site_headers) => [{String.t(), String.t()}],
          optional(:follow_redirects?) => boolean(),
          optional(:retry) => boolean(),
          optional(:secret_body?) => boolean()
        }

  @typedoc """
  A 2xx answer of `send_session/3`: its body, decoded as `decoded/1` says, the URL that answered
  and its `content-type` header, nil for none.
  """
  @type page :: %{body: binary(), uri: URI.t(), content_type: String.t() | nil}

  @doc "Sends a GET to `url` under `request`; see the moduledoc."
  @spec get(String.t(), request()) :: {:ok, binary(), URI.t()} | {:error, term()}
  def get(url, request) when is_binary(url), do: send_page(%{url: url}, request)

  @doc """
  Sends `outgoing` under `request` and follows its redirects as the moduledoc says, with no
  cookie: `send_session/3` with no jar.
  """
  @spec send_page(outgoing(), request()) :: {:ok, binary(), URI.t()} | {:error, term()}
  def send_page(%{url: url} = outgoing, request) when is_binary(url) do
    case send_session(outgoing, request, nil) do
      {{:ok, page}, nil} -> {:ok, page.body, page.uri}
      {{:error, _class} = error, nil} -> error
    end
  end

  @doc """
  Sends `outgoing` under `request` with the cookies of `jar` (#1680), a
  `Cinder.Acquisition.Indexer.Cardigann.Jar` or nil for none, and follows its redirects as the
  moduledoc says. A 301, 302 or 303 turns a POST into a GET with no body; a 307 or 308 keeps the
  method and the body, and the secret check reads the body again before that hop.

  Each hop sends the jar's cookies for its own origin, only to a credential host
  (`Jar.header/3`), and each hop's answer, a redirect included, adds its `Set-Cookie` pairs from
  a credential host (`Jar.keep/4`). Answers `{answer, jar}`, the jar after the last hop: `answer`
  is `{:ok, page}` for a 2xx, else `{:error, class}` as the moduledoc lists.
  """
  @spec send_session(outgoing(), request(), Jar.t() | nil) ::
          {{:ok, page()} | {:error, term()}, Jar.t() | nil}
  def send_session(%{url: url} = outgoing, request, jar) when is_binary(url) do
    out = %{
      method: Map.get(outgoing, :method, :get),
      body: Map.get(outgoing, :body),
      content_type: Map.get(outgoing, :content_type),
      site_headers: Map.get(outgoing, :site_headers, []),
      retry: Map.get(outgoing, :retry, true),
      secret_body?: Map.get(outgoing, :secret_body?, false)
    }

    request = %{
      request
      | follow_redirects?:
          request.follow_redirects? or Map.get(outgoing, :follow_redirects?, false)
    }

    case target(url, request, :definition_error, out.body) do
      {:ok, target} -> hop(target, out, request, jar, 0)
      {:error, _reason} = refused -> {refused, jar}
    end
  end

  defp hop(target, out, request, jar, hops) do
    case send_request(target, request, out, jar) do
      {:ok, %Req.Response{status: status} = response} when status in 300..399 ->
        redirect(target, response, out, request, kept(jar, target, response, request), hops)

      {:ok, response} ->
        {answer(response, target, request), kept(jar, target, response, request)}

      {:error, tag} ->
        {{:error, tag}, jar}
    end
  end

  defp kept(nil, _target, _response, _request), do: nil

  defp kept(jar, target, response, request),
    do: Jar.keep(jar, target.uri, response, request.credential_hosts)

  defp redirect(target, response, out, request, jar, hops) do
    case Req.Response.get_header(response, "location") do
      [location | _] when request.follow_redirects? and hops < @max_redirects ->
        out = redirected(out, response.status)

        target
        |> redirect_target(location, hop_check(out, request), out.body)
        |> followed(out, request, jar, hops)

      [_location | _] when request.follow_redirects? ->
        {{:error, :too_many_redirects}, jar}

      _none_or_not_followed ->
        {{:error, {:http_status, response.status}}, jar}
    end
  end

  # A login's body holds a credential in a form the secret check may not read (a multipart part,
  # a filtered input): a hop that keeps it goes only to a credential host.
  defp hop_check(%{secret_body?: true, body: body}, request) when is_binary(body),
    do: %{request | secret_referenced?: true}

  defp hop_check(_out, request), do: request

  @doc """
  The method and body a redirect with `status` keeps of `out`: a 307 or 308 keeps both, any other
  status a GET with no body.
  """
  @spec redirected(map(), pos_integer()) :: map()
  def redirected(out, status) when status in [307, 308], do: out
  def redirected(out, _status), do: %{out | method: :get, body: nil}

  defp followed({:ok, next}, out, request, jar, hops), do: hop(next, out, request, jar, hops + 1)
  defp followed({:error, :secret_host} = refused, _out, _request, jar, _hops), do: {refused, jar}

  defp followed({:error, reason}, _out, _request, jar, _hops),
    do: {{:error, refusal(reason, :bad_response)}, jar}

  @doc """
  The pinned target of a redirect from `target` to `location` under `request`, or the refusal:
  `:secret_host` from the secret check, which runs on the merged URL before any DNS lookup, so
  a host built from a secret is never resolved; else `HTTPPolicy.untrusted_redirect_target/3`'s
  own reason, `:https_downgrade` and a URL's text refusal included. The resolver is the
  request's `resolver` when it holds one. `body`, the form body the hop keeps (nil for none),
  goes through the secret check beside the URL.
  """
  @spec redirect_target(HTTPPolicy.request_target(), String.t(), request(), binary() | nil) ::
          {:ok, HTTPPolicy.request_target()} | {:error, atom() | String.t()}
  def redirect_target(target, location, request, body \\ nil) do
    with :ok <- merged_secret_check(target.uri, location, request, body) do
      next_target(target.uri, location, request)
    end
  end

  # A `Location` that is not UTF-8 goes through the check too: `URI.merge/2` reads it,
  # `holds_secret?/2` reads each invalid sequence as U+FFFD, and a host holding such a byte is no
  # credential host. A merge that raises, which no `Location` tried for #1672 did, is refused
  # while the indexer holds a secret value; a secret reference needs one, so `secrets` alone
  # decides.
  defp merged_secret_check(uri, location, request, body) do
    case merged(uri, location) do
      {:ok, next} -> secret_check(URI.to_string(next), next, request, body)
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
  when it holds one. `body`, the request's form body (nil for none), goes through the secret
  check beside the URL.
  """
  @spec request_target(String.t(), request(), binary() | nil) ::
          {:ok, HTTPPolicy.request_target()} | {:error, atom() | String.t()}
  def request_target(url, request, body \\ nil) when is_binary(url) do
    with {:ok, uri} <- parse(url),
         :ok <- secret_check(url, uri, request, body) do
      pinned_target(url, request)
    end
  end

  defp target(url, request, text_refusal, body) do
    case request_target(url, request, body) do
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

  @doc """
  True when the parser worker's `input` (the text Cinder hands it and its plan, any term whose
  strings are read) holds a secret value, in a form the secret check reads, that `site_page`,
  the page as the site answered it, does not hold. Each secret is decided on its own, so a page
  that holds one secret lets no other in. No secret goes into the worker's input
  (`docs/agents/architecture.md` "The parser worker is not a security boundary"); a page the
  site wrote is the accepted risk, so a secret it already holds adds nothing. A string of
  `input` equal to `site_page` is that page and is not read; `site_page` itself is read only
  for a secret another string holds, and with case, so a page up to the fetch cap is never
  lowered in the search process.
  """
  @spec worker_secret?(String.t(), term(), request()) :: boolean()
  def worker_secret?(site_page, input, request) do
    charset = Map.get(request, :charset, :utf8)
    lowered = input |> strings([]) |> Enum.reject(&(&1 == site_page)) |> Enum.map(&lowered/1)

    Enum.any?(request.secrets, fn secret ->
      forms = forms(secret, charset)

      Enum.any?(lowered, &holds_form?(&1, forms)) and
        not Enum.any?(forms, &(:binary.match(site_page, &1) != :nomatch))
    end)
  end

  defp strings(text, acc) when is_binary(text), do: [text | acc]
  defp strings(map, acc) when is_map(map), do: map |> Map.values() |> strings(acc)
  defp strings(list, acc) when is_list(list), do: Enum.reduce(list, acc, &strings/2)
  defp strings(tuple, acc) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> strings(acc)
  defp strings(_other, acc), do: acc

  defp credential_url?(link, hosts) do
    case URI.new(link) do
      {:ok, %URI{scheme: scheme} = uri} when scheme in ["http", "https"] ->
        credential_host?(uri, hosts)

      _other ->
        false
    end
  end

  # --- the secret check ---

  defp secret_check(url, uri, request, body) do
    if (request.secret_referenced? or holds_secret?(url, request) or
          (is_binary(body) and holds_secret?(body, request))) and
         not credential_host?(uri, request.credential_hosts),
       do: {:error, :secret_host},
       else: :ok
  end

  # Each invalid sequence reads as U+FFFD first: `String.downcase/1` leaves the character after a
  # lone byte such as 0xC3 as it is, which hid a capitalised secret behind it (#1672).
  defp holds_secret?(url, request) do
    lowered = lowered(url)
    charset = Map.get(request, :charset, :utf8)
    Enum.any?(request.secrets, &holds_form?(lowered, forms(&1, charset)))
  end

  defp lowered(text), do: text |> String.replace_invalid() |> String.downcase()

  defp holds_form?(lowered, forms),
    do: Enum.any?(forms, &String.contains?(lowered, String.downcase(&1)))

  # The secret as written, then percent-encoded from its UTF-8 bytes and from its bytes in the
  # definition's charset, as `Query` writes a query string in it.
  #
  # A `$raw` input's value is encoded twice (#1679): by the template's `WebUtility.UrlEncode`
  # rule in UTF-8, then again by the query builder in the charset, so that form is one more.
  defp forms(secret, charset) do
    encoded =
      for bytes <- Enum.uniq([secret, Charset.encode(secret, charset)]) do
        www = URI.encode_www_form(bytes)
        [www, String.replace(www, "+", "%20"), URI.encode(bytes, &URI.char_unreserved?/1)]
      end

    raw = Query.dotnet_encode(secret)
    Enum.uniq([secret, raw, Query.dotnet_encode(raw, charset) | List.flatten(encoded)])
  end

  @doc "Whether `uri`'s host, in lower case and without a trailing dot, is one of `hosts`."
  @spec credential_host?(URI.t(), MapSet.t()) :: boolean()
  def credential_host?(%URI{host: host}, hosts) when is_binary(host),
    do: MapSet.member?(hosts, host |> String.downcase() |> String.trim_trailing("."))

  def credential_host?(_uri, _hosts), do: false

  # --- one request ---

  defp send_request(target, request, out, jar) do
    send_get(target, request,
      method: out.method,
      body: out.body,
      content_type: out.content_type,
      site_headers: out.site_headers,
      headers: if(jar, do: Jar.header(jar, target.uri, request.credential_hosts), else: []),
      retry: out.retry
    )
  end

  @doc """
  Sends one request to `target` under `request` through `Cinder.Acquisition.Indexer.request/3`,
  with `accept-encoding: identity`, Req's redirects and retry off and the path out of the request
  telemetry, and answers `request/3`'s answer. `opts` takes `method` (`:get` by default), `body`
  (sent as `content_type`, `application/x-www-form-urlencoded` unless given), `site_headers`
  (the definition's headers, sent only when `target`'s host is a credential host), `headers`
  (Cinder's own, such as a jar's cookies), `max_bytes` (`max_bytes/0` by default), `timeout_ms`
  (`request_timeout_ms/0` by default) and `retry` (`request/3`'s one retry, true by default).
  The plug is the request's `req_options` when it holds them, else the adapter config's.
  """
  @spec send_get(HTTPPolicy.request_target(), request(), keyword()) ::
          {:ok, Req.Response.t()} | {:error, atom()}
  def send_get(target, request, opts \\ []) do
    req_options = Map.get(request, :req_options) || req_options()
    pins = pin_options(target, request)
    body = Keyword.get(opts, :body)

    own =
      [{"accept-encoding", "identity"} | Keyword.get(opts, :headers, [])] ++
        if(is_binary(body),
          do: [
            {"content-type",
             Keyword.get(opts, :content_type) || "application/x-www-form-urlencoded"}
          ],
          else: []
        )

    site = site_headers(Keyword.get(opts, :site_headers, []), target, request)

    options =
      HTTPPolicy.request_options(
        target,
        Keyword.merge(req_options,
          method: Keyword.get(opts, :method, :get),
          headers: merge_headers(site, own),
          connect_options: Keyword.merge(Keyword.get(req_options, :connect_options, []), pins)
        )
      )
      |> then(fn options -> if is_binary(body), do: [{:body, body} | options], else: options end)

    Indexer.request(request.context, options,
      raw_body: true,
      max_bytes: Keyword.get(opts, :max_bytes, @max_bytes),
      timeout_ms: Keyword.get(opts, :timeout_ms, @request_timeout_ms),
      redact_path: true,
      retry: Keyword.get(opts, :retry, true)
    )
  end

  # The site's headers go only to a credential host; with none, `request` needs no
  # `credential_hosts`.
  defp site_headers([], _target, _request), do: []

  defp site_headers(headers, target, request) do
    if credential_host?(target.uri, request.credential_hosts), do: headers, else: []
  end

  # The definition's headers, then Cinder's own. A `cookie` in both joins into one header, the
  # definition's first; Cinder's other names replace the definition's.
  defp merge_headers(site, own) do
    own_names = MapSet.new(own, fn {name, _value} -> String.downcase(name) end)

    {site_cookie, site} =
      Enum.split_with(site, fn {name, _value} -> String.downcase(name) == "cookie" end)

    {own_cookie, own} = Enum.split_with(own, fn {name, _value} -> name == "cookie" end)

    cookie =
      case Enum.map(site_cookie ++ own_cookie, &elem(&1, 1)) do
        [] -> []
        values -> [{"cookie", Enum.join(values, "; ")}]
      end

    Enum.reject(site, fn {name, _value} -> MapSet.member?(own_names, String.downcase(name)) end) ++
      own ++ cookie
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
        with {:ok, body} <- decoded(response),
             do: {:ok, %{body: body, uri: target.uri, content_type: content_type(response)}}

      true ->
        NewznabAnswer.classify(status, response.headers, nil, request.now)
    end
  end

  # `Indexer.request/3` moves the `content-type` header into the private `:cinder_content_type`.
  defp content_type(response) do
    case Req.Response.get_private(response, :cinder_content_type) do
      [_ | _] = values -> Enum.join(values, ", ")
      _none -> nil
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
