defmodule Cinder.Acquisition.Indexer.Cardigann.Grab do
  @moduledoc """
  The grab fetch of `Cinder.Acquisition.Indexer.Cardigann` (#1672; #1621 points 2 to 6): fetches
  a grab's link from one configured Cardigann indexer, read by id at grab time
  (`Cinder.Acquisition.IndexerSource.Native.fetch_download/3`), running the definition's
  `download` block when it has one, and records in Native's backoff state what the answer says
  about that indexer, through `Cinder.Acquisition.Indexer.Newznab.Grab.checked_and_recorded/4`'s
  table.

  ## Which copy

  The indexer's running copy, as a search reads it
  (`Cinder.Acquisition.Indexer.Cardigann.copy/1`). A copy the boot re-check has not checked
  under this loader is `{:error, {:cardigann_grab, :definition_unchecked}}`, a capped retry while
  the re-check runs.
  Any other copy that does not load (it fails, reads not supported, or lost its pin) changed
  after the search that found the row, which needed a copy that loads: `{:error,
  :indexer_changed}`, which drops the grab. Neither sends a request.

  ## The fetch

  With no `download` block, or one with no `selectors`, the link itself is fetched and its
  answer goes to the check. With `selectors`:

  1. The link, the details page, is fetched. A redirect to a magnet reads as step 3's magnet
     rule says. A non-2xx answer and a login redirect go to the check as they are.
  2. A 2xx page's body is decoded (`Cinder.Acquisition.Indexer.Cardigann.Fetch.decoded/1`) and
     read once in a `Cinder.Indexers.ParserWorker`, one field per selector, each selector a
     template rendered first. A selector whose template does not render, renders blank, or that
     `Cinder.Indexers.Selector.compile/2` refuses is left out of the worker's plan, so one bad
     selector costs no other. Prowlarr fetches the page once per selector (`b0b5774`); Cinder
     fetches it once.
  3. In file order, each selector's value, trimmed, runs through its `filters`. The first that
     gives a value that is not blank wins:
     - a magnet holding a secret off the credential hosts
       (`Cinder.Acquisition.Indexer.Cardigann.Fetch.secret_link?/2`) is
       `{:cardigann_grab, :secret_host}`; any other magnet is `{:magnet, link}` under the
       client's `allow_magnet`, else `:unsupported_download_url`;
     - any other value is resolved against the URL that answered the details page, its fragment
       dropped. One that is not an http(s) URL is skipped. Otherwise it is fetched, and with the
       definition's `testlinktorrent` on (Prowlarr's default), a 2xx answer whose body, gzip
       inflated, starts with a byte other than `d` and is no login page of a credential host
       moves on to the next selector, as Prowlarr's test fetch does. A link whose chain ends on
       `:unsupported_download_url`, such as one the URL rules refuse for its userinfo, moves on
       too. Every other answer goes to the check, with no second fetch.
  4. With no selector left, the page itself, when it is a login page of a credential host
     (`Cinder.Download.Client.DownloadCheck`'s login sign) goes to the check, which reads
     `:indexer_auth_failed`. Otherwise the answer is the first limit a selector's template or
     filter hit (`{:cardigann_grab, :regex_limit}` or `{:cardigann_grab, :filter_output_cap}`),
     else `{:cardigann_grab, :no_link}`. A filter that fails otherwise skips its selector.

  The template variables are the search's `.Config.*` (`Query.config_variables/2`), `.True`,
  `.False` and `.Today.Year`, and the link's `.DownloadUri.*`
  (`Cinder.Acquisition.Indexer.Cardigann.Variables.download_uri/1`). Each
  `.DownloadUri.Query.<key>` a selector or filter names is nil when the link lacks it.

  ## Limits

  - One deadline, `deadline_ms/0` from the call's start, covers the whole grab: each request gets
    the time left before it (`Cinder.Acquisition.Indexer.request/3`, with no retry), the worker
    the smaller of `worker_ms/0` and the time left, and the worker is killed at its own deadline.
    A request or worker the deadline ends is `{:cardigann_grab, :deadline}`; a worker its own cap
    ends first is `{:cardigann_grab, :parser_failed}`.
  - Every request takes `Cinder.HTTPPolicy`'s untrusted path through
    `Cinder.Acquisition.Indexer.Cardigann.Fetch`: a validated public address, and before each
    request and each redirect, before its DNS lookup, the secret check: a hop that would carry a
    secret off the credential hosts is never sent, `{:cardigann_grab, :secret_host}`. Here a URL
    carries one when it holds a secret value, or when the definition's row fields or download
    block reference a secret setting.
  - Each request follows at most `Fetch.max_redirects/0` redirects, whatever the definition's
    `followredirect`; a sixth is `:too_many_redirects`. A redirect on a credential host, from a
    chain that stayed on them, to a credential host path ending in `/login` is not followed: its
    answer is the login sign.
  - The details page is read up to `Fetch.max_bytes/0`, past which it is
    `{:cardigann_grab, :page_too_large}`; a link up to the client's `max_bytes`, past which it is
    `:response_too_large`.
  - No request holds the indexer's slot or reads its backoff state, and none sends a `Referer`.
  - Cookies: a `Set-Cookie` from a credential host keeps its `name=value` pair for the rest of
    the grab when its name is not blank, the pair is under 4 KiB, and neither holds a control
    character, a `;` or a `,`. It is sent back only to the same scheme, host and port, which
    keep at most 32 names: a new name past them is dropped, a known one replaced. Any other
    host's `Set-Cookie` is dropped. Nothing is stored after the grab.

  ## The answer

  The client gets the check's answer (`DownloadCheck.check_classified/2` under its options). An
  answer is "trusted" only when every hop of its chain, the details page's and the link's, was
  on a credential host: only such an answer can read as the indexer's limit, rejected
  credentials or error, and only such a chain's `:https_downgrade` is recorded. A transport tag
  of `request/3` passes as it is, and every refusal is a closed atom or tag: no error holds a
  URL, a header, a cookie or a body, and nothing here logs.
  """

  alias Cinder.Acquisition.Indexer.Cardigann
  alias Cinder.Acquisition.Indexer.Cardigann.{Fetch, Filters, Query, Template, Variables}
  alias Cinder.Acquisition.Indexer.Newznab.Grab, as: NewznabGrab
  alias Cinder.Acquisition.IndexerSource.Native
  alias Cinder.Download.Client.DownloadCheck
  alias Cinder.Download.Torrent
  alias Cinder.HTTPPolicy
  alias Cinder.Indexers.ConfiguredIndexer
  alias Cinder.Indexers.ParserWorker
  alias Cinder.Indexers.Selector

  # The torrent clients' per-hop budget (`receive_timeout: 90_000` in `qbittorrent.ex`), here
  # for the whole chain.
  @deadline_ms 90_000
  @worker_ms 30_000
  @max_cookies 32
  @max_cookie_bytes 4_096
  @redirect_statuses [301, 302, 303, 307, 308]

  @doc "The whole grab's deadline in ms: 90 s unless config sets `grab_deadline_ms`."
  @spec deadline_ms() :: pos_integer()
  def deadline_ms, do: Keyword.get(config(), :grab_deadline_ms, @deadline_ms)

  @doc "The parser worker's own cap in ms: 30 s unless config sets `grab_worker_ms`."
  @spec worker_ms() :: pos_integer()
  def worker_ms, do: Keyword.get(config(), :grab_worker_ms, @worker_ms)

  @doc "Fetches `url` from `indexer` for a client with fetch options `opts`; see the moduledoc."
  @spec fetch_download(ConfiguredIndexer.t(), String.t(), keyword()) ::
          {:ok, binary()} | {:magnet, String.t()} | {:error, term()}
  def fetch_download(%ConfiguredIndexer{} = indexer, url, opts) when is_binary(url) do
    case Cardigann.copy(indexer) do
      {:ok, copy} ->
        grab(indexer, copy, url, opts)

      {:not_supported, :definition_unchecked} ->
        {:error, {:cardigann_grab, :definition_unchecked}}

      {:not_supported, _changed} ->
        {:error, :indexer_changed}
    end
  end

  defp grab(indexer, copy, url, opts) do
    deadline_at = System.monotonic_time(:millisecond) + deadline_ms()
    request = request(copy, deadline_at, opts)
    state = %{request: request, deadline_at: deadline_at, jar: %{}, opts: opts}
    download = copy.definition.download

    {fetched, from_source} =
      if download && download.selectors != [],
        do: download_block(copy, url, state),
        else: state |> fetch(url, Keyword.fetch!(opts, :max_bytes)) |> elem(0)

    NewznabGrab.checked_and_recorded(indexer, fetched, from_source, opts)
  end

  defp request(copy, deadline_at, opts) do
    request = copy.request.(%{deadline_at: deadline_at}, Native.now())
    referenced? = request.link_secret_referenced? or request.download_secret_referenced?

    # Every URL the grab sends, and every magnet it returns, holds a secret when the row's
    # fields or the download block reference one.
    Map.merge(request, %{
      follow_redirects?: true,
      secret_referenced?: referenced?,
      link_secret_referenced?: referenced?,
      resolver: Keyword.get(opts, :resolver),
      req_options: if(plug = Keyword.get(opts, :plug), do: [plug: plug])
    })
  end

  # --- the download block ---

  # Measured for #1672 on hand-fetched pages, never committed: fifteen Torrent9 details pages
  # of three searches, 27,705 to 30,663 bytes, none compressed. `Fetch.max_bytes/0`, 2 MiB, is
  # about 68 times the largest.
  defp download_block(copy, url, state) do
    case fetch(state, url, Fetch.max_bytes()) do
      {{{:ok, %{status: status, login_redirect: false} = page}, true_or_false}, state}
      when status in 200..299 ->
        read_page(copy, url, page, true_or_false, state)

      {{{:error, :response_too_large}, from_source}, _state} ->
        {{:error, {:cardigann_grab, :page_too_large}}, from_source}

      {answer, _state} ->
        answer
    end
  end

  defp read_page(copy, url, page, page_trusted, state) do
    with {:ok, html} <- decoded(page),
         {:ok, values, limit} <- selector_values(copy, url, html, state) do
      try_values(copy, values, page, page_trusted, limit, state)
    else
      {:error, reason} -> {{:error, {:cardigann_grab, reason}}, page_trusted}
    end
  end

  defp decoded(page) do
    response = %Req.Response{status: page.status, headers: page.headers, body: page.body}

    case Fetch.decoded(response) do
      {:ok, body} -> {:ok, body}
      {:error, :too_large} -> {:error, :page_too_large}
      {:error, :bad_response} -> {:error, :bad_page}
    end
  end

  # Each selector's worker value, in file order, beside its filters: `{:ok, [{value, filters}],
  # limit}`, `limit` the first limit a template hit, or `{:error, reason}`.
  defp selector_values(copy, url, html, state) do
    variables = variables(copy, url)
    now = state.request.now

    {planned, limit} =
      copy.definition.download.selectors
      |> Enum.with_index()
      |> Enum.reduce({[], nil}, fn {selector, index}, {planned, limit} ->
        case planned_field(selector, index, variables, now) do
          {:ok, field} -> {[{field, selector} | planned], limit}
          {:limit, kind} -> {planned, limit || kind}
          :skip -> {planned, limit}
        end
      end)

    planned = Enum.reverse(planned)

    with {:ok, values} <- run_worker(html, Enum.map(planned, &elem(&1, 0)), state) do
      found =
        for {field, selector} <- planned,
            do: {Map.get(values, field.name), selector.filters || [], variables}

      {:ok, found, limit}
    end
  end

  defp planned_field(%{selector: selector} = block, index, variables, now)
       when is_binary(selector) do
    case Template.render(selector, variables, now) do
      {:ok, rendered} ->
        rendered = String.trim(rendered)

        if rendered != "" and match?({:ok, _}, Selector.compile(rendered, "grab")),
          do:
            {:ok,
             %{
               name: "#{index}",
               selector: rendered,
               attribute: block.attribute,
               remove: [],
               case: []
             }},
          else: :skip

      {:error, kind} when kind in [:regex_limit, :filter_output_cap] ->
        {:limit, kind}

      {:error, _reason} ->
        :skip
    end
  end

  defp planned_field(_block, _index, _variables, _now), do: :skip

  defp run_worker(_html, [], _state), do: {:ok, %{}}

  defp run_worker(html, fields, state) do
    left_ms = state.deadline_at - System.monotonic_time(:millisecond)

    if left_ms <= 0 do
      {:error, :deadline}
    else
      cap = worker_ms()
      plan = %{rows: "html", fields: fields}

      case ParserWorker.run(String.replace_invalid(html), plan, deadline_ms: min(cap, left_ms)) do
        {:ok, [row | _]} -> {:ok, Map.new(row)}
        {:ok, []} -> {:ok, %{}}
        {:error, :timeout} when left_ms <= cap -> {:error, :deadline}
        {:error, _failure} -> {:error, :parser_failed}
      end
    end
  end

  # The grab variables of `url`: the search's settings, then the link's `.DownloadUri.*`, each
  # `.DownloadUri.Query.<key>` the block names nil unless the link holds it.
  defp variables(copy, url) do
    block_text = copy.definition.download |> Variables.download_texts() |> Enum.join("\n")
    named = Variables.download(copy.definition, block_text, nil)

    uri =
      case URI.new(url) do
        {:ok, uri} -> Variables.download_uri(uri)
        {:error, _part} -> %{}
      end

    named
    |> Map.merge(Query.config_variables(copy.definition, copy.config))
    |> Map.merge(uri)
  end

  defp try_values(_copy, [], page, page_trusted, limit, _state) do
    if login_page?(page),
      do: {{:ok, page}, page_trusted},
      else: {{:error, {:cardigann_grab, limit || :no_link}}, page_trusted}
  end

  defp try_values(copy, [{value, filters, variables} | rest], page, trusted, limit, state) do
    case selector_link(value, filters, variables, page.url, state) do
      {:magnet, magnet} ->
        magnet_answer(magnet, trusted, state)

      {:link, link} ->
        copy
        |> link_answer(link, trusted, state)
        |> next_or_answer(copy, rest, page, {trusted, limit})

      {:limit, kind} ->
        try_values(copy, rest, page, trusted, limit || kind, state)

      :next ->
        try_values(copy, rest, page, trusted, limit, state)
    end
  end

  defp next_or_answer({:next, state}, copy, rest, page, {trusted, limit}),
    do: try_values(copy, rest, page, trusted, limit, state)

  defp next_or_answer(answer, _copy, _rest, _page, _trusted_limit), do: answer

  defp selector_link(value, filters, variables, page_uri, state) when is_binary(value) do
    case Filters.apply(String.trim(value), filters, variables, state.request.now) do
      {:ok, filtered} -> link_of(String.trim(filtered), page_uri)
      {:error, kind} when kind in [:regex_limit, :filter_output_cap] -> {:limit, kind}
      {:error, _reason} -> :next
    end
  end

  defp selector_link(_value, _filters, _variables, _page_uri, _state), do: :next

  defp link_of("", _page_uri), do: :next

  defp link_of(value, page_uri) do
    if Torrent.magnet?(value), do: {:magnet, value}, else: resolved(page_uri, value)
  end

  defp resolved(page_uri, value) do
    with true <- String.valid?(value),
         {:ok, _ref} <- URI.new(value),
         %URI{scheme: scheme, host: host} = merged
         when scheme in ["http", "https"] and is_binary(host) and host != "" <-
           URI.merge(page_uri, value) do
      {:link, URI.to_string(%{merged | fragment: nil})}
    else
      _not_http -> :next
    end
  rescue
    ArgumentError -> :next
  end

  defp magnet_answer(magnet, trusted, state), do: {magnet_or_refusal(magnet, state), trusted}

  # The selector link's answer, or `{:next, state}`, `state` holding the cookies its chain kept,
  # when its chain ends on `:unsupported_download_url` (the URL rules refuse the link or a
  # redirect's scheme, or a redirect names a magnet the client cannot take): the value comes from
  # a page that can change, so it says nothing lasting about the release. Also `{:next, state}`
  # when `testlinktorrent` moves on from it.
  defp link_answer(copy, link, page_trusted, state) do
    max_bytes = Keyword.fetch!(state.opts, :max_bytes)

    {{fetched, from_source}, after_link} =
      fetch(%{state | trusted?: page_trusted}, link, max_bytes)

    cond do
      fetched == {:error, :unsupported_download_url} ->
        {:next, %{state | jar: after_link.jar}}

      copy.definition.testlinktorrent and not torrent_start?(fetched, max_bytes) ->
        {:next, %{state | jar: after_link.jar}}

      true ->
        {fetched, from_source}
    end
  end

  # True unless `fetched` is a 2xx answer, other than a credential host's login page, whose body
  # starts with a byte other than `d` once inflated. An empty body passes, as Prowlarr's test
  # fetch lets it pass, and so does every other answer: the check reads it.
  defp torrent_start?({:ok, %{status: status, body: body} = answer}, max_bytes)
       when status in 200..299 do
    case DownloadCheck.inflated(body, max_bytes) do
      {:ok, <<first, _rest::binary>>} -> first == ?d or login_page?(answer)
      _empty_or_too_large -> true
    end
  end

  defp torrent_start?(_fetched, _max_bytes), do: true

  defp login_page?(answer) do
    match?(
      {:error, :indexer_auth_failed},
      DownloadCheck.check({:ok, answer}, max_bytes: Fetch.max_bytes(), error_tag: :login_check)
    )
  end

  # --- one chain of requests ---

  # Fetches `url` and its redirects under the grab's deadline: `{{answer, from_source}, state}`,
  # `answer` shaped as `Cinder.Download.Client.Fetch.answer/3`'s.
  defp fetch(state, url, max_bytes) do
    state = Map.put_new(state, :trusted?, true)

    case Fetch.request_target(url, state.request) do
      {:ok, target} -> hop(target, Map.put(state, :max_bytes, max_bytes), 0)
      {:error, reason} -> {{{:error, link_refusal(reason)}, false}, state}
    end
  end

  defp hop(target, state, hops) do
    trusted = state.trusted? and credential?(target.uri, state)

    case send_get(target, state) do
      {:ok, response} ->
        state = keep_cookies(state, target.uri, response)
        answered(response, target, %{state | trusted?: trusted}, hops)

      {:error, reason} ->
        {{{:error, request_error(reason, state)}, trusted}, state}
    end
  end

  defp answered(%Req.Response{status: status} = response, target, state, hops)
       when status in @redirect_statuses do
    case Req.Response.get_header(response, "location") do
      [location | _] -> redirect(response, target, location, state, hops)
      [] -> {{{:ok, answer_of(response, target.uri, state.trusted?)}, state.trusted?}, state}
    end
  end

  defp answered(response, target, state, _hops),
    do: {{{:ok, answer_of(response, target.uri, state.trusted?)}, state.trusted?}, state}

  defp redirect(response, target, location, state, hops) do
    cond do
      Torrent.magnet?(location) ->
        {{magnet_or_refusal(location, state), state.trusted?}, state}

      hops >= Fetch.max_redirects() ->
        {{{:error, :too_many_redirects}, state.trusted?}, state}

      true ->
        follow(response, target, location, state, hops)
    end
  end

  # A magnet, from a selector or a redirect, under the secret check and the client's
  # `allow_magnet`.
  defp magnet_or_refusal(magnet, state) do
    cond do
      Fetch.secret_link?(magnet, state.request) -> {:error, {:cardigann_grab, :secret_host}}
      Keyword.get(state.opts, :allow_magnet, false) -> {:magnet, magnet}
      true -> {:error, :unsupported_download_url}
    end
  end

  defp follow(response, target, location, state, hops) do
    case Fetch.redirect_target(target, location, state.request) do
      {:ok, next} ->
        if state.trusted? and credential?(next.uri, state) and login_path?(next.uri) do
          answer = %{answer_of(response, next.uri, true) | login_redirect: true}
          {{{:ok, answer}, true}, state}
        else
          hop(next, state, hops + 1)
        end

      {:error, reason} ->
        {{{:error, redirect_refusal(reason)}, state.trusted?}, state}
    end
  end

  defp send_get(target, state) do
    left_ms = state.deadline_at - System.monotonic_time(:millisecond)

    if left_ms <= 0 do
      {:error, :deadline}
    else
      Fetch.send_get(target, Map.put(state.request, :context, %{deadline_at: state.deadline_at}),
        headers: cookie_header(state.jar, target.uri),
        max_bytes: state.max_bytes,
        timeout_ms: left_ms,
        retry: false
      )
    end
  end

  defp credential?(uri, state), do: Fetch.credential_host?(uri, state.request.credential_hosts)

  defp login_path?(%URI{path: path}) when is_binary(path),
    do: path |> String.downcase(:ascii) |> String.ends_with?("/login")

  defp login_path?(%URI{}), do: false

  defp answer_of(response, uri, trusted) do
    content_type = Req.Response.get_private(response, :cinder_content_type)

    %{
      status: response.status,
      headers:
        if(content_type,
          do: Map.put(response.headers, "content-type", content_type),
          else: response.headers
        ),
      body: response.body,
      url: uri,
      trusted: trusted,
      login_redirect: false
    }
  end

  # --- refusals as closed tags ---

  defp request_error(reason, state) when reason in [:deadline, :timeout] do
    if System.monotonic_time(:millisecond) >= state.deadline_at,
      do: {:cardigann_grab, :deadline},
      else: reason
  end

  defp request_error(:too_large, _state), do: :response_too_large
  defp request_error(reason, _state), do: reason

  # The grab's own link: a URL's text refusal can never pass on a retry, as
  # `Cinder.Download.Client.Fetch.download_url_target/3` reads it.
  defp link_refusal(:secret_host), do: {:cardigann_grab, :secret_host}
  defp link_refusal(:definition_error), do: :unsupported_download_url
  defp link_refusal(:dns_resolution_failed), do: :dns
  defp link_refusal(:forbidden_address), do: :forbidden_address

  defp link_refusal(reason) do
    if HTTPPolicy.text_refusal?(reason), do: :unsupported_download_url, else: closed(reason)
  end

  defp redirect_refusal(:secret_host), do: {:cardigann_grab, :secret_host}
  defp redirect_refusal(:unsupported_scheme), do: :unsupported_download_url
  defp redirect_refusal(:dns_resolution_failed), do: :dns
  defp redirect_refusal(reason), do: closed(reason)

  defp closed(reason) when is_atom(reason), do: reason
  defp closed(_text), do: :invalid_url

  # --- cookies ---

  defp keep_cookies(state, uri, response) do
    if credential?(uri, state) do
      origin = origin(uri)

      jar =
        response
        |> Req.Response.get_header("set-cookie")
        |> Enum.flat_map(&pair/1)
        |> Enum.reduce(state.jar, &keep_cookie(&1, &2, origin))

      %{state | jar: jar}
    else
      state
    end
  end

  # Past `@max_cookies` names per origin, a new name is dropped; a known one is replaced.
  defp keep_cookie({name, value}, jar, origin) do
    cookies = Map.get(jar, origin, %{})

    if map_size(cookies) < @max_cookies or Map.has_key?(cookies, name),
      do: Map.put(jar, origin, Map.put(cookies, name, value)),
      else: jar
  end

  # The `name=value` pair before the first `;`, kept when its name is not blank and neither
  # holds a control character, a `;` or a `,`, and it fits `@max_cookie_bytes`.
  defp pair(header) do
    with [pair | _attributes] <- String.split(header, ";", parts: 2),
         [name, value] <- String.split(pair, "=", parts: 2),
         name = String.trim(name),
         value = String.trim(value),
         true <- name != "" and byte_size(name) + byte_size(value) < @max_cookie_bytes,
         true <- cookie_text?(name) and cookie_text?(value) do
      [{name, value}]
    else
      _refused -> []
    end
  end

  defp cookie_text?(text),
    do: String.valid?(text) and not String.match?(text, ~r/[\x00-\x1f\x7f;,]/)

  defp cookie_header(jar, uri) do
    case Map.get(jar, origin(uri), %{}) do
      cookies when map_size(cookies) == 0 ->
        []

      cookies ->
        [{"cookie", Enum.map_join(cookies, "; ", fn {name, value} -> "#{name}=#{value}" end)}]
    end
  end

  defp origin(%URI{scheme: scheme, host: host, port: port}),
    do: {scheme, host |> String.downcase(:ascii) |> String.trim_trailing("."), port}

  defp config, do: Application.get_env(:cinder, Cardigann, [])
end
