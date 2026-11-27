defmodule Cinder.Acquisition.Indexer.Cardigann.FlareSolverr do
  @moduledoc """
  A Cardigann request behind a Cloudflare or DDoS-Guard challenge (#1682).

  ## Detection

  `challenge?/1` is Prowlarr's rule (`CloudFlareDetectionService.cs`, `b0b5774`): the answer's
  `Server` header is `cloudflare`, `cloudflare-nginx` or `ddos-guard` in any case, and either

  - its status is 403 or 503 and its body holds `<title>Just a moment...</title>`,
    `<title>Access denied</title>` or `<title>Attention Required! | Cloudflare</title>`, holds
    `<title>DDOS-GUARD</title>` in any case, or reads `error code: 1020` once trimmed; or
  - its `Vary` header is `Accept-Encoding,User-Agent`, it has no `Content-Encoding`, and its body
    holds `ddos` in any case.

  A gzip body is read inflated, as `Cinder.Acquisition.Indexer.Cardigann.Fetch.decoded/1` reads
  it; a body that does not inflate is read as it came.

  ## Deadlines

  A request that meets a challenge, its solve and its replay share one budget: the smaller of
  `budget_ms/0` and the time left before the request's deadline when the request started.
  `max_timeout_ms/1` gives FlareSolverr's `maxTimeout` from the time left of that budget at the
  solve: that time less `margin_ms/0`, in whole seconds rounded up, as Prowlarr gives its HTTP
  call `RequestTimeout + 5` s.
  """

  alias Cinder.Acquisition.Indexer.Cardigann.{Fetch, Jar}
  alias Cinder.HTTPPolicy

  @budget_ms 60_000
  @margin_ms 5_000
  # FlareSolverr's answer holds the solved page's HTML (`solution.response`), which Cinder never
  # reads, JSON-escaped: 4 times `Fetch.max_bytes/0`, the largest page a search reads.
  @max_bytes 8 * 1024 * 1024
  @max_user_agent_bytes 512
  @servers ["cloudflare", "cloudflare-nginx", "ddos-guard"]
  @titles [
    "<title>Just a moment...</title>",
    "<title>Access denied</title>",
    "<title>Attention Required! | Cloudflare</title>"
  ]

  @doc "The most one challenged request, its solve and its replay take together: 60 s."
  @spec budget_ms() :: pos_integer()
  def budget_ms, do: @budget_ms

  @doc "What FlareSolverr's own HTTP call keeps past its `maxTimeout`: 5 s."
  @spec margin_ms() :: pos_integer()
  def margin_ms, do: @margin_ms

  @doc """
  FlareSolverr's `maxTimeout` in ms when `left_ms` of the budget is left at the solve: `left_ms`
  less `margin_ms/0`, rounded up to whole seconds, or nil when that leaves no time.
  """
  @spec max_timeout_ms(integer()) :: pos_integer() | nil
  def max_timeout_ms(left_ms) when is_integer(left_ms) do
    case left_ms - @margin_ms do
      ms when ms > 0 -> div(ms + 999, 1000) * 1000
      _none -> nil
    end
  end

  @doc "The largest FlareSolverr answer in bytes Cinder reads: 8 MiB."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @typedoc """
  A clearance: FlareSolverr's user agent and the solution cookies Cinder kept, each with its
  domain, in lower case without a leading or trailing dot.
  """
  @type clearance :: %{user_agent: String.t(), cookies: [{String.t(), String.t(), String.t()}]}

  @typedoc """
  What a Cardigann request map carries for this step (`Fetch.request/0`'s `flaresolverr`): the
  mode (`:off` for an indexer with the toggle off, `:no_url` for the toggle on and no URL saved,
  `{:url, url}` otherwise), the indexer's base URL, the function that reads the stored
  clearance (called before each request, so a clearance one request of a chain stored reaches the
  next), the function that stores a new clearance, and, on a replay, the clearance it won and the
  `solved?` mark: the request already solved once.
  """
  @type config :: %{
          required(:mode) => :off | :no_url | {:url, String.t()},
          required(:base_url) => String.t(),
          optional(:read) => (-> clearance() | nil),
          optional(:store) => (clearance() -> term()),
          optional(:clearance) => clearance(),
          optional(:solved?) => boolean()
        }

  @doc """
  The clearance a request under `request` sends: the one its replay won, else the stored one
  the config's `read` gives, else nil. None with the toggle off.
  """
  @spec clearance(map()) :: clearance() | nil
  def clearance(request) do
    case config(request) do
      %{mode: :off} -> nil
      %{clearance: %{} = clearance} -> clearance
      %{read: read} when is_function(read, 0) -> read.()
      _none -> nil
    end
  end

  @doc """
  What a request does with `response`, which `target` answered for `out` under `request`, sent
  at `started_ms` (`System.monotonic_time(:millisecond)`):

  - `:pass` when it is no challenge;
  - `{:error, :cloudflare_challenge}` with the toggle off, or for a request that already solved
    once (no second solve);
  - `{:error, :flaresolverr_url_not_set}` with the toggle on and no URL saved;
  - else the solve (`solve/4`): `{:replay, request}`, `request` carrying the new clearance, its
    `solved?` mark and a context whose deadline is the budget's end, after the clearance is
    handed to the config's `store`; or the solve's error.
  """
  @spec step(Req.Response.t(), HTTPPolicy.request_target(), map(), map(), integer()) ::
          :pass | {:replay, map()} | {:error, atom()}
  def step(%Req.Response{} = response, target, out, request, started_ms) do
    if challenge?(response),
      do: challenged(config(request), target, out, request, started_ms),
      else: :pass
  end

  defp config(request), do: Map.get(request, :flaresolverr) || %{mode: :off}

  defp challenged(%{mode: :off}, _target, _out, _request, _started_ms),
    do: {:error, :cloudflare_challenge}

  defp challenged(%{mode: :no_url}, _target, _out, _request, _started_ms),
    do: {:error, :flaresolverr_url_not_set}

  defp challenged(%{solved?: true}, _target, _out, _request, _started_ms),
    do: {:error, :cloudflare_challenge}

  defp challenged(%{mode: {:url, url}} = config, target, out, request, started_ms) do
    budget_end = min(started_ms + @budget_ms, request.context.deadline_at)

    case solve(url, handed(target, out, request, config), request, budget_end) do
      {:ok, clearance} ->
        if store = Map.get(config, :store), do: store.(clearance)

        {:replay,
         %{
           request
           | context: %{request.context | deadline_at: budget_end},
             flaresolverr: Map.merge(config, %{clearance: clearance, solved?: true})
         }}

      {:error, _kind} = error ->
        error
    end
  end

  @doc """
  What Cinder hands FlareSolverr for a challenged request to `target` with `out` (its method,
  body and content type) under `request`: `{:get, url}` or `{:post, url, body}`. A request that
  carries a secret (`Fetch.carries_secret?/3`, a login's body or any request of a login, #1680
  and #1681), a POST whose body is not `application/x-www-form-urlencoded`, or a POST with no
  body is handed over as a GET of the indexer's base URL, which carries none (#1620 point 2;
  #1616 rule 5). A urlencoded POST goes as `request.post` with its body.
  """
  @spec handed(HTTPPolicy.request_target(), map(), map(), config()) ::
          {:get, String.t()} | {:post, String.t(), binary()}
  def handed(target, out, request, config) do
    url = URI.to_string(target.uri)
    body = Map.get(out, :body)

    cond do
      secret?(url, out, request) -> {:get, config.base_url}
      Map.get(out, :method, :get) == :get -> {:get, url}
      urlencoded?(out) and is_binary(body) -> {:post, url, body}
      true -> {:get, config.base_url}
    end
  end

  defp secret?(url, out, request) do
    Map.get(request, :login?, false) or Map.get(out, :secret_body?, false) or
      Fetch.carries_secret?(url, Map.get(out, :body), request)
  end

  defp urlencoded?(out) do
    case Map.get(out, :content_type) do
      nil ->
        true

      type ->
        type |> String.downcase() |> String.starts_with?("application/x-www-form-urlencoded")
    end
  end

  @doc """
  Asks FlareSolverr at `url` (the saved setting) for a clearance of `handed` under `request`,
  before `budget_end`. Answers `{:ok, clearance}` or `{:error, kind}`, a closed atom that holds
  no URL, header or body.
  """
  @spec solve(String.t(), {:get, String.t()} | {:post, String.t(), binary()}, map(), integer()) ::
          {:ok, clearance()} | {:error, atom()}
  def solve(url, handed, request, budget_end) do
    with :ok <- own_target(handed, request),
         left_ms = budget_end - System.monotonic_time(:millisecond),
         max_timeout when is_integer(max_timeout) <- max_timeout_ms(left_ms) || :deadline do
      url
      |> call(payload(handed, max_timeout), left_ms)
      |> solution(request)
    else
      :deadline -> {:error, :deadline}
      {:error, _kind} = error -> error
    end
  end

  # The URL handed over sits on a credential host, the definition's own hosts (#1615 point 7,
  # #1621 point 4), and passes the untrusted path's address check: FlareSolverr's browser
  # resolves it itself. A URL off those hosts is the challenge Cinder did not get past,
  # `:cloudflare_challenge`: FlareSolverr was not asked, so `:flaresolverr_off_host` does not fit.
  defp own_target(handed, request) do
    url = elem(handed, 1)

    with {:ok, %URI{host: host} = uri} when is_binary(host) <- URI.new(url),
         true <- Fetch.credential_host?(uri, request.credential_hosts) || :off_host,
         {:ok, _target} <- untrusted(url, request) do
      :ok
    else
      {:error, :forbidden_address} -> {:error, :forbidden_address}
      {:error, :dns_resolution_failed} -> {:error, :dns}
      _off_host_or_refused -> {:error, :cloudflare_challenge}
    end
  end

  defp untrusted(url, request) do
    case Map.get(request, :resolver) || Keyword.get(cardigann_config(), :resolver) do
      nil -> HTTPPolicy.untrusted_request_target(url)
      resolver -> HTTPPolicy.untrusted_request_target(url, resolver)
    end
  end

  defp payload({:get, url}, max_timeout),
    do: %{"cmd" => "request.get", "url" => url, "maxTimeout" => max_timeout}

  defp payload({:post, url, body}, max_timeout),
    do: %{"cmd" => "request.post", "url" => url, "postData" => body, "maxTimeout" => max_timeout}

  # FlareSolverr is a configured origin, usually on the LAN: the trusted path, with redirects
  # and retry off and the answer read under `@max_bytes`.
  defp call(url, payload, left_ms) do
    [
      url: url |> HTTPPolicy.without_fragment() |> URI.new!() |> URI.append_path("/v1"),
      method: :post,
      json: payload,
      receive_timeout: left_ms,
      retry: false,
      redirect: false
    ]
    |> Keyword.merge(Keyword.get(config(), :req_options, []))
    |> Req.new()
    |> HTTPPolicy.bounded_request(@max_bytes, left_ms)
  rescue
    # A saved URL `URI.new!/1` cannot read: `Cinder.Indexers.FlareSolverrUrl.put/1` never saves
    # one, so only a row written around it gets here.
    _invalid -> {:error, :invalid_url}
  end

  # FlareSolverr answers an error as HTTP 500 with `status: "error"`, so 200 and 500 are read.
  defp solution({:ok, %Req.Response{status: status, body: body}}, request)
       when status in [200, 500] do
    with {:ok, %{"status" => "ok", "solution" => %{} = solution}} <- decoded(body),
         %{"cookies" => [_ | _] = cookies, "userAgent" => user_agent} <- solution,
         true <- user_agent?(user_agent),
         :ok <- answered_on_host(solution, request) do
      {:ok, %{user_agent: user_agent, cookies: kept(cookies, request.credential_hosts)}}
    else
      {:error, :flaresolverr_off_host} = off_host -> off_host
      _failed -> {:error, :flaresolverr_failed}
    end
  end

  defp solution(_answer, _request), do: {:error, :flaresolverr_failed}

  defp decoded(%{} = body), do: {:ok, body}

  defp decoded(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      _not_an_object -> :error
    end
  end

  defp decoded(_body), do: :error

  # A user agent goes into a header on every request to the definition's hosts: printable ASCII,
  # not blank, at most `@max_user_agent_bytes`.
  defp user_agent?(user_agent) when is_binary(user_agent) do
    String.trim(user_agent) != "" and byte_size(user_agent) <= @max_user_agent_bytes and
      String.match?(user_agent, ~r/\A[\x20-\x7e]+\z/)
  end

  defp user_agent?(_user_agent), do: false

  # `solution.url`, the page FlareSolverr's browser ended on, sits on the definition's own hosts.
  defp answered_on_host(%{"url" => url}, request) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme} = uri} when scheme in ["http", "https"] ->
        if Fetch.credential_host?(uri, request.credential_hosts),
          do: :ok,
          else: {:error, :flaresolverr_off_host}

      _unreadable ->
        {:error, :flaresolverr_off_host}
    end
  end

  defp answered_on_host(_solution, _request), do: {:error, :flaresolverr_off_host}

  # The solution cookies whose domain, without a leading or trailing dot and in lower case,
  # domain-matches one of the definition's own hosts (#1621 point 6; RFC 6265 section 5.1.3: the
  # host is the domain or ends in `.` and the domain), by the jar's pair rules, at most 32. A
  # cookie of `example.org` kept for `www.example.org` goes only to the own hosts it matches.
  defp kept(cookies, hosts) do
    cookies
    |> Enum.flat_map(fn
      %{"name" => name, "value" => value, "domain" => domain} when is_binary(domain) ->
        domain = domain |> String.trim(".") |> String.downcase(:ascii)

        if domain != "" and Enum.any?(hosts, &domain_match?(&1, domain)) and
             Jar.cookie?(name, value),
           do: [{domain, name, value}],
           else: []

      _other ->
        []
    end)
    |> Enum.uniq_by(fn {domain, name, _value} -> {domain, name} end)
    |> Enum.take(32)
  end

  defp domain_match?(host, domain) when is_binary(host),
    do: host == domain or String.ends_with?(host, "." <> domain)

  defp domain_match?(_unknown, _domain), do: false

  @doc """
  The headers a clearance adds to a request to `uri` under `hosts`: `user-agent` for any of
  `hosts`, and a `cookie` header with the clearance cookies whose domain `uri`'s host
  domain-matches and whose names `taken`, the names the request's own cookies already use,
  leave free: a login's cookie wins over a clearance cookie of the same name. None for another
  host.
  """
  @spec headers(clearance() | nil, URI.t(), MapSet.t(), MapSet.t()) :: [{String.t(), String.t()}]
  def headers(nil, _uri, _hosts, _taken), do: []

  def headers(%{user_agent: user_agent, cookies: cookies}, %URI{host: host} = uri, hosts, taken) do
    if Fetch.credential_host?(uri, hosts) do
      host = host |> String.downcase(:ascii) |> String.trim_trailing(".")

      pairs =
        for {domain, name, value} <- cookies,
            domain_match?(host, domain),
            not MapSet.member?(taken, name),
            do: name <> "=" <> value

      [{"user-agent", user_agent}] ++
        if(pairs == [], do: [], else: [{"cookie", Enum.join(pairs, "; ")}])
    else
      []
    end
  end

  defp config, do: Application.get_env(:cinder, __MODULE__, [])

  defp cardigann_config,
    do: Application.get_env(:cinder, Cinder.Acquisition.Indexer.Cardigann, [])

  @doc "Whether `response` is a Cloudflare or DDoS-Guard challenge; see the moduledoc."
  @spec challenge?(Req.Response.t()) :: boolean()
  def challenge?(%Req.Response{} = response) do
    server?(response) and (titled?(response) or vary?(response))
  end

  defp server?(response) do
    response
    |> Req.Response.get_header("server")
    |> Enum.any?(&(String.downcase(&1) in @servers))
  end

  defp titled?(%Req.Response{status: status} = response) when status in [403, 503] do
    body = text(response)

    Enum.any?(@titles, &String.contains?(body, &1)) or String.trim(body) == "error code: 1020" or
      String.contains?(lowered(body), "<title>ddos-guard</title>")
  end

  defp titled?(_response), do: false

  defp vary?(response) do
    Req.Response.get_header(response, "vary") == ["Accept-Encoding,User-Agent"] and
      Req.Response.get_header(response, "content-encoding") in [[], [""]] and
      String.contains?(lowered(text(response)), "ddos")
  end

  defp text(%Req.Response{body: body} = response) when is_binary(body) do
    case Fetch.decoded(response) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> body
    end
  end

  defp text(_response), do: ""

  # Each invalid sequence reads as U+FFFD first, as `Fetch` lowers a page.
  defp lowered(text), do: text |> String.replace_invalid() |> String.downcase()
end
