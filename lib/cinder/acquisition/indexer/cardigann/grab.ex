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

  The steps run in Prowlarr's order (`CardigannRequestGenerator.DownloadRequest`, `b0b5774`):
  `before`, then `infohash`, which wins over `selectors`, then `selectors`, else the link
  itself. With no `download` block, only the link is fetched.

  1. `before` (#1679): one request to its `path`, a template resolved against the base URL, with
     its `inputs` rendered, blank ones kept, and written in the definition's charset
     (`Cinder.Acquisition.Indexer.Cardigann.Query.encode_pairs/2`): as a query after `?`, or `&`
     when the path has one, for a GET, or as a form body for a `method: post`. The link is its
     `Referer` when the link is on a credential host and holds only printable ASCII; a
     `Referer` the definition sets never goes on it. Prowlarr reads no status of this answer.
     Here a trusted answer that is a login redirect, a 401, a 429 or a login page goes to the
     check as it is, which reads the indexer's rejected credentials or limit. A path or input
     whose template does not render, a path that does not resolve, a URL whose text the rules
     refuse and a redirect to a magnet are `{:cardigann_grab, :before_failed}`, its template
     limits aside, which keep their `{:cardigann_grab, kind}`. An answer past
     `Fetch.max_bytes/0` is `{:cardigann_grab, :page_too_large}`, and every other refusal or
     transport failure keeps its tag. Any other answer is passed over unless a block reads it.
  2. The page a block reads is the details page, the link fetched with a GET, or the `before`
     answer for a block with `usebeforeresponse` beside a `before`. The details page is fetched
     at most once. A redirect to a magnet reads as step 4's magnet rule says, and a details page
     past `Fetch.max_bytes/0` is `{:cardigann_grab, :page_too_large}`. Any other answer that is
     not a 2xx page, a login redirect included, goes to the check as it is. A 2xx page's body is
     decoded
     (`Cinder.Acquisition.Indexer.Cardigann.Fetch.decoded/1`), read as text in the definition's
     charset (`Cinder.Acquisition.Indexer.Cardigann.Charset`, #1678) whatever its
     `Content-Type` says, and read once in a `Cinder.Indexers.ParserWorker`, one field per
     selector, each selector a template rendered first and each `remove` taken out of a copy of
     the selected element first. A selector whose template does not render, renders blank, or
     that `Cinder.Indexers.Selector.compile/2` refuses, its `remove` included, is left out of
     the worker's plan, so one bad selector costs no other.
  3. `infohash` (#1679): on a login page of a credential host, the page goes to the check.
     Otherwise its `hash` and `title` selectors are read, each value trimmed, run through its
     `filters` in the definition's charset and trimmed again, and the magnet is
     `magnet:?xt=urn:btih:<hash>&dn=<title>` (`Cinder.Acquisition.Indexer.Cardigann.Magnet`),
     under the magnet rule of step 4. A template or filter limit is its
     `{:cardigann_grab, kind}`. A selector that matches nothing or a filter that fails
     otherwise, and a hash that is not 40 hex digits or 32 base32 characters, are
     `{:cardigann_grab, :infohash_not_found}`, where Prowlarr falls through to the link.
  4. `selectors`: a selector with `usebeforeresponse` reads the `before` answer, the others the
     details page, fetched first when one needs it. In file order, each selector's value,
     trimmed, runs through its `filters`, in the definition's charset. The first that gives a
     value that is not blank wins:
     - a magnet holding a secret off the credential hosts
       (`Cinder.Acquisition.Indexer.Cardigann.Fetch.secret_link?/2`) is
       `{:cardigann_grab, :secret_host}`; any other magnet is `{:magnet, link}` under the
       client's `allow_magnet`, else `:unsupported_download_url`;
     - any other value is resolved against the URL that answered the details page, or the link
       for a value from the `before` answer, as Prowlarr's `ResolvePath(href, link)`, its
       fragment dropped. One that is not an http(s) URL is skipped. Otherwise it is fetched, and
       with the definition's `testlinktorrent` on (Prowlarr's default), a 2xx answer whose body,
       gzip inflated, starts with a byte other than `d` and is no login page of a credential
       host moves on to the next selector, as Prowlarr's test fetch does. A link whose chain
       ends on `:unsupported_download_url`, such as one the URL rules refuse for its userinfo,
       moves on too. Every other answer goes to the check, with no second fetch. Prowlarr
       fetches the details page once per selector; Cinder fetches it once.
  5. With no selector left, the page itself, when it is a login page of a credential host
     (`Cinder.Download.Client.DownloadCheck`'s login sign) goes to the check, which reads
     `:indexer_auth_failed`. That page is the details page when one was fetched, else the
     `before` answer. Otherwise the answer is the first limit a selector's template or filter
     hit, in file order (`{:cardigann_grab, :regex_limit}` or
     `{:cardigann_grab, :filter_output_cap}`), else `{:cardigann_grab, :no_link}`. A filter that
     fails otherwise skips its selector.
  6. The final request, for the link a selector found or for the link itself, is a POST with an
     empty body under `download.method: post`, as Prowlarr compares it, else a GET.

  The template variables are the search's `.Config.*` (`Query.config_variables/2`), `.True`,
  `.False` and `.Today.Year`, and the link's `.DownloadUri.*`
  (`Cinder.Acquisition.Indexer.Cardigann.Variables.download_uri/1`). Each
  `.DownloadUri.Query.<key>` a selector, a filter, `before`, `infohash` or a header names is nil
  when the link lacks it (`Variables.grab_texts/1`).

  ## Headers

  Every request sends `download.headers` when the definition sets any, else `search.headers`
  (`Cinder.Acquisition.Indexer.Cardigann.Headers.download/3`, #1679), rendered once under the
  grab variables and sent only to a credential host. A template limit is its
  `{:cardigann_grab, kind}`, and any other header that does not render or that Cinder cannot
  send as written is `{:cardigann_grab, :bad_headers}`; neither sends a request.

  ## Limits

  - One deadline, `deadline_ms/0` from the call's start, covers the whole grab: each request gets
    the time left before it (`Cinder.Acquisition.Indexer.request/3`, with no retry), the worker
    the smaller of `worker_ms/0` and the time left, and the worker is killed at its own deadline.
    A request or worker the deadline ends is `{:cardigann_grab, :deadline}`; a worker its own cap
    ends first is `{:cardigann_grab, :parser_failed}`.
  - A worker plan whose rendered selectors hold a secret setting's value that the page does not
    hold already (`Fetch.worker_secret?/3`) reaches no worker: the grab is
    `{:cardigann_grab, :definition_error}`, as no secret goes into the worker's input
    (`docs/agents/architecture.md` "The parser worker is not a security boundary").
  - Every request takes `Cinder.HTTPPolicy`'s untrusted path through
    `Cinder.Acquisition.Indexer.Cardigann.Fetch`: a validated public address, and before each
    request and each redirect, before its DNS lookup, the secret check: a hop that would carry a
    secret off the credential hosts is never sent, `{:cardigann_grab, :secret_host}`. Here a URL
    or a POST body carries one when it holds a secret value, or when the definition's row fields
    or download block (`Variables.download_texts/1`: its selectors, `infohash` and `before`, the
    headers aside) reference a secret setting.
  - A 301, 302 or 303 turns a POST into a GET with no body; a 307 or 308 keeps the method and the
    body, which the secret check reads again before that hop (`Fetch.redirected/2`).
  - Each request follows at most `Fetch.max_redirects/0` redirects, whatever the definition's
    `followredirect`; a sixth is `:too_many_redirects`. A redirect on a credential host, from a
    chain that stayed on them, to a credential host path ending in `/login` is not followed: its
    answer is the login sign.
  - The details page is read up to `Fetch.max_bytes/0`, past which it is
    `{:cardigann_grab, :page_too_large}`; a link up to the client's `max_bytes`, past which it is
    `:response_too_large`.
  - No request holds the indexer's slot or reads its backoff state, but for the login rule
    below. Cinder adds a `Referer` of its own only on the `before` request, the link's, as step
    1 says; a `Referer` the definition sets goes on the other requests to the credential hosts,
    as its other headers do.
  - Cookies: a `Set-Cookie` from a credential host keeps its `name=value` pair for the rest of
    the grab, by `Cinder.Acquisition.Indexer.Cardigann.Jar`'s rules: sent back only to the same
    scheme, host and port while its host is a credential host; any other host's `Set-Cookie`
    is dropped. Under a login session, a pair the block's answers keep also updates the stored
    row, as the login section below says.

  ## The login (#1680)

  A definition with a `login` block grabs under its session
  (`Cinder.Acquisition.Indexer.Cardigann.Session`), outside the lease and inside the grab's
  deadline:

  - while the indexer's credentials are rejected, the grab sends no request and answers
    `:indexer_auth_failed`;
  - the requests start with the stored session's cookies, or after a login when no stored
    session reads, and a `Set-Cookie` that changes the jar updates the stored row
    (`IndexerCookies.update/3`);
  - a trusted answer that is a login redirect, an HTTP 401 or a login page logs in once and
    runs the block again once;
  - a refused login, or a login sign after this grab's login (any login sign of the `cookie`
    method), records `{:rejected_credentials, {:login_rejected, method}}` and answers
    `:indexer_auth_failed`, with nothing more recorded;
  - a login that fails otherwise records its class as a search's login does (#1654's ladder, a
    limit's backoff), and answers `{:indexer_limit, until}` for a limit, else
    `{:cardigann_grab, :login_failed}`, with nothing more recorded.

  ## The answer

  The client gets the check's answer (`DownloadCheck.check_classified/2` under its options). An
  answer is "trusted" only when every hop of its chain, the details page's and the link's, was
  on a credential host: only such an answer can read as the indexer's limit, rejected
  credentials or error, and only such a chain's `:https_downgrade` is recorded. A transport tag
  of `request/3` passes as it is, and every refusal is a closed atom or tag: no error holds a
  URL, a header, a cookie or a body, and nothing here logs.
  """

  alias Cinder.Acquisition.Indexer.Cardigann

  alias Cinder.Acquisition.Indexer.Cardigann.{
    Charset,
    Fetch,
    Filters,
    Headers,
    Jar,
    Login,
    Magnet,
    Query,
    Session,
    Template,
    Variables
  }

  alias Cinder.Acquisition.Indexer.Newznab.Grab, as: NewznabGrab
  alias Cinder.Acquisition.IndexerSource.Native
  alias Cinder.Acquisition.IndexerSource.Native.{IndexerCookies, IndexerStatus}
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
  @redirect_statuses [301, 302, 303, 307, 308]
  @get %{method: :get, body: nil, site_headers: nil}
  # A 40-digit hex or 32-character base32 info hash, as `xt=urn:btih:` takes.
  @info_hash ~r/\A(?:[0-9a-fA-F]{40}|[A-Za-z2-7]{32})\z/

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
    variables = variables(copy, url)

    state = %{
      request: request,
      deadline_at: deadline_at,
      jar: Jar.new(),
      store: nil,
      opts: opts,
      charset: Charset.of_definition(copy.definition),
      variables: variables,
      site_headers: [],
      final: final_request(copy.definition.download)
    }

    answer =
      case Headers.download(copy.definition, variables, request.now) do
        {:ok, headers} ->
          session_run(indexer, copy, url, %{state | site_headers: headers})

        {:error, kind} when kind in [:regex_limit, :filter_output_cap] ->
          {{:error, {:cardigann_grab, kind}}, false}

        {:error, _reason} ->
          {{:error, {:cardigann_grab, :bad_headers}}, false}
      end

    case answer do
      {:recorded, client_answer} ->
        client_answer

      {fetched, from_source} ->
        NewznabGrab.checked_and_recorded(indexer, fetched, from_source, opts)
    end
  end

  # --- the login session (#1680) ---

  # A definition with no login runs the block as it is. One with a login runs it under its
  # session: no request while its credentials are rejected; the stored row, or a login first;
  # one login and one rerun of the block when its answer is a login sign. A refused login, or a
  # login sign after this grab's login, is recorded as the login's rejection once, and the
  # client gets `:indexer_auth_failed`; a login that fails otherwise is recorded by the session
  # (`record?: true`). Both pass by the own record of
  # `Cinder.Acquisition.Indexer.Newznab.Grab.checked_and_recorded/4`.
  defp session_run(indexer, copy, url, state) do
    if copy.definition.login == nil do
      run(copy, url, state)
    else
      run = %{
        indexer: indexer,
        copy: copy,
        context: context(state.deadline_at, state.opts),
        hold: &{:ran, &1.()},
        record?: true,
        request: Map.take(state.request, [:resolver, :req_options])
      }

      if rejected?(indexer), do: refused_login(), else: loaded(run, copy, url, state)
    end
  end

  defp rejected?(indexer) do
    status = IndexerStatus.read([indexer])[indexer.id]
    IndexerStatus.gate(status, Native.now()) == {:failed, :rejected_credentials}
  end

  defp loaded(run, copy, url, state) do
    case Session.load(run, :unloaded) do
      {:ok, session} -> with_session(run, copy, url, state, session)
      refused -> login_refusal(refused)
    end
  end

  defp with_session(run, copy, url, state, session) do
    answer = run(copy, url, under(state, run, session))

    cond do
      not login_sign?(answer) ->
        answer

      session.logged_in? or Login.method(copy.definition) == :cookie ->
        rejected(run)

      true ->
        relogin(run, copy, url, state, session)
    end
  end

  defp relogin(run, copy, url, state, session) do
    case Session.login(run, session) do
      {:ok, session} -> rerun(run, copy, url, state, session)
      refused -> login_refusal(refused)
    end
  end

  defp rerun(run, copy, url, state, session) do
    answer = run(copy, url, under(state, run, session))
    if login_sign?(answer), do: rejected(run), else: answer
  end

  # The block runs on the session's jar, and a jar its answers change goes to the stored row.
  defp under(state, run, session),
    do: %{state | jar: session.jar, store: {run.indexer, session.logged_in_at}}

  # A trusted answer that says the session is not logged in: a redirect to a login path, or an
  # answer `DownloadCheck` reads as `:indexer_auth_failed` (`login_page?/1`), an HTTP 401 and a
  # login page among them.
  defp login_sign?({{:ok, %{trusted: true} = page}, _from_source}),
    do: page.login_redirect or login_page?(page)

  defp login_sign?(_answer), do: false

  # A login that did not log in, its class already recorded by the session.
  defp login_refusal({:error, {:rejected_credentials, _by}}), do: refused_login()

  defp login_refusal({:error, {:limit, until}}),
    do: {:recorded, {:error, {:indexer_limit, until}}}

  defp login_refusal(_failure), do: {:recorded, {:error, {:cardigann_grab, :login_failed}}}

  # A login sign after this grab's login, or any of the `cookie` method's.
  defp rejected(run) do
    method = Login.method(run.copy.definition)

    IndexerStatus.record(
      run.indexer,
      {:rejected_credentials, {:login_rejected, method}},
      Native.now()
    )

    refused_login()
  end

  defp refused_login, do: {:recorded, {:error, :indexer_auth_failed}}

  # The block's steps in Prowlarr's order (`DownloadRequest`, `b0b5774`): `before`, then
  # `infohash`, which wins over `selectors`, then `selectors`, else the link itself.
  defp run(copy, url, state) do
    download = copy.definition.download || %{before: nil, infohash: nil, selectors: []}

    case before(download.before, copy, url, state) do
      {:ok, before_page, state} ->
        cond do
          download.infohash ->
            infohash(download.infohash, url, before_page, state)

          download.selectors != [] ->
            download_block(copy, url, before_page, state)

          true ->
            state |> fetch(url, Keyword.fetch!(state.opts, :max_bytes), state.final) |> elem(0)
        end

      {:stop, answer} ->
        answer
    end
  end

  # The final request for the link, from `selectors` or the plain link: a POST with an empty
  # body under `download.method: post`, as Prowlarr compares it, else a GET.
  defp final_request(%{method: "post"}), do: %{@get | method: :post, body: ""}
  defp final_request(_download), do: @get

  # Each request's context: the grab's one deadline, and a parity run's link check budget
  # (`opts[:budget]`, `Cinder.Indexers.ParityRun`), which `Cinder.Acquisition.Indexer.request/3`
  # calls before each send. A client's grab passes none.
  defp context(deadline_at, opts) do
    case Keyword.get(opts, :budget) do
      budget when is_function(budget, 0) -> %{deadline_at: deadline_at, budget: budget}
      _none -> %{deadline_at: deadline_at}
    end
  end

  defp request(copy, deadline_at, opts) do
    request = copy.request.(context(deadline_at, opts), Native.now())
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

  # --- download.before ---

  # One request before the rest (#1679): `{:ok, before_page, state}`, `before_page` nil with no
  # block, else `{page, trusted}`, `state` holding the cookies its chain kept; or `{:stop,
  # answer}`. Prowlarr reads no status of it; here a trusted answer that says the indexer's
  # credentials or limit goes to the check as it is, and a request that cannot be sent fails the
  # grab. Every other answer is passed over unless a block reads it (`usebeforeresponse`).
  defp before(nil, _copy, _url, state), do: {:ok, nil, state}

  defp before(block, copy, url, state) do
    case before_request(block, copy, url, state) do
      {:ok, before_url, out} ->
        {{answer, trusted}, after_before} =
          fetch(Map.delete(state, :trusted?), before_url, Fetch.max_bytes(), out)

        before_answer(answer, trusted, %{state | jar: after_before.jar})

      {:error, kind} ->
        {:stop, {{:error, {:cardigann_grab, kind}}, false}}
    end
  end

  defp before_answer({:ok, page}, trusted, state) do
    if page.trusted and
         (page.login_redirect or page.status in [401, 429] or login_page?(page)),
       do: {:stop, {{:ok, page}, trusted}},
       else: {:ok, {page, trusted}, state}
  end

  defp before_answer({:magnet, _magnet}, trusted, _state),
    do: {:stop, {{:error, {:cardigann_grab, :before_failed}}, trusted}}

  defp before_answer({:error, reason}, trusted, _state),
    do: {:stop, {{:error, before_error(reason)}, trusted}}

  defp before_error(reason) when reason in [:unsupported_download_url, :invalid_url],
    do: {:cardigann_grab, :before_failed}

  defp before_error(:response_too_large), do: {:cardigann_grab, :page_too_large}
  defp before_error(reason), do: reason

  # Prowlarr's `HandleRequest`: `path` rendered and resolved against the site, its `inputs`
  # rendered, blank ones kept, and written in the definition's charset, as a query after `?`, or
  # `&` when the path has one, for a GET, or as a form body for a POST. The link is the
  # `Referer`, in place of any the definition sets, when it is on a credential host.
  defp before_request(block, copy, url, state) do
    with {:ok, path} <- before_text(block.path || "", state),
         {:ok, uri} <- Query.resolve(copy.config.base_url, path),
         {:ok, pairs} <- before_inputs(block.inputs || [], state) do
      query = Query.encode_pairs(pairs, state.charset)
      out = %{@get | site_headers: with_referer(state.site_headers, url, state)}

      if String.downcase(block.method || "", :ascii) == "post",
        do: {:ok, URI.to_string(uri), %{out | method: :post, body: query}},
        else: {:ok, URI.to_string(Query.with_query(uri, query)), out}
    else
      {:error, kind} when kind in [:regex_limit, :filter_output_cap] -> {:error, kind}
      {:error, _reason} -> {:error, :before_failed}
    end
  end

  defp before_text(text, state), do: Template.render(text, state.variables, state.request.now)

  defp before_inputs(inputs, state) do
    Enum.reduce_while(inputs, {:ok, []}, fn {key, value}, {:ok, acc} ->
      case before_text(value || "", state) do
        {:ok, rendered} -> {:cont, {:ok, [{key, rendered} | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, pairs} -> {:ok, Enum.reverse(pairs)}
      error -> error
    end
  end

  defp with_referer(site_headers, url, state) do
    headers =
      Enum.reject(site_headers, fn {name, _value} -> String.downcase(name) == "referer" end)

    with {:ok, uri} <- URI.new(url),
         true <- credential?(uri, state) and Headers.value?(url) do
      headers ++ [{"referer", url}]
    else
      _not_sent -> headers
    end
  end

  # --- the page a block reads ---

  # The page a block reads: the before answer when given, else the details page, fetched now.
  # `{:ok, page, trusted, state}` for a 2xx page that is no login redirect; any other answer
  # goes to the check as it is, `{:answer, answer}`.
  defp page(nil, url, state) do
    case fetch(Map.delete(state, :trusted?), url, Fetch.max_bytes()) do
      {{{:ok, %{status: status, login_redirect: false} = page}, trusted}, state}
      when status in 200..299 ->
        {:ok, page, trusted, state}

      {{{:error, :response_too_large}, from_source}, _state} ->
        {:answer, {{:error, {:cardigann_grab, :page_too_large}}, from_source}}

      {answer, _state} ->
        {:answer, answer}
    end
  end

  defp page({%{status: status, login_redirect: false} = page, trusted}, _url, state)
       when status in 200..299,
       do: {:ok, page, trusted, state}

  defp page({page, trusted}, _url, _state), do: {:answer, {{:ok, page}, trusted}}

  # --- download.infohash ---

  # The `hash` and `title` selectors on one page, the magnet built from them (#1679). A login
  # page goes to the check first. A hash or title that matches nothing, or a hash that is no
  # info hash, is `{:cardigann_grab, :infohash_not_found}`; Prowlarr falls through to the link.
  defp infohash(block, url, before_page, state) do
    source = if block.usebeforeresponse, do: before_page

    case page(source, url, state) do
      {:ok, page, trusted, state} ->
        if login_page?(page),
          do: {{:ok, page}, trusted},
          else: {infohash_magnet(block, page, state), trusted}

      {:answer, answer} ->
        answer
    end
  end

  defp infohash_magnet(block, page, state) do
    with {:ok, html} <- decoded(page),
         {:ok, values} <- page_values([{"hash", block.hash}, {"title", block.title}], html, state),
         {:ok, hash} <- infohash_value(values, "hash", state),
         true <- Regex.match?(@info_hash, hash) || :infohash_not_found,
         {:ok, title} <- infohash_value(values, "title", state) do
      magnet_or_refusal(Magnet.from_infohash(hash, title), state)
    else
      {:error, reason} -> {:error, {:cardigann_grab, reason}}
      {:limit, kind} -> {:error, {:cardigann_grab, kind}}
      :infohash_not_found -> {:error, {:cardigann_grab, :infohash_not_found}}
    end
  end

  defp infohash_value(values, name, state) do
    case Map.fetch(values, name) do
      {:ok, {value, filters}} when is_binary(value) -> filtered_hash(value, filters, state)
      {:ok, {{:limit, kind}, _filters}} -> {:limit, kind}
      _none -> :infohash_not_found
    end
  end

  defp filtered_hash(value, filters, state) do
    case Filters.apply(String.trim(value), filters, state.variables, state.request.now,
           encoding: state.charset
         ) do
      {:ok, filtered} -> {:ok, String.trim(filtered)}
      {:error, kind} when kind in [:regex_limit, :filter_output_cap] -> {:limit, kind}
      {:error, _reason} -> :infohash_not_found
    end
  end

  # --- download.selectors ---

  # Measured for #1672 on hand-fetched pages, never committed: fifteen Torrent9 details pages
  # of three searches, 27,705 to 30,663 bytes, none compressed. `Fetch.max_bytes/0`, 2 MiB, is
  # about 68 times the largest.
  #
  # A selector with `usebeforeresponse` reads the before answer, and its link resolves against
  # the link, as Prowlarr's `ResolvePath(href, link)`; the others read the details page, fetched
  # once and first when one needs it. No v11 definition sets `usebeforeresponse` on a selector
  # (Prowlarr/Indexers `56b20b19`), so the details page is fetched up front rather than at the
  # first selector that needs it.
  defp download_block(copy, url, before_page, state) do
    {from_before, from_details} =
      copy.definition.download.selectors
      |> Enum.with_index()
      |> Enum.split_with(fn {selector, _index} ->
        selector.usebeforeresponse and before_page != nil
      end)

    with {:ok, sources, state} <- sources(from_details, from_before, url, before_page, state),
         {:ok, entries, limit} <- entries(sources, state) do
      %{page: page, trusted: trusted} = hd(sources)
      try_values(copy, entries, {page, trusted}, limit, state)
    else
      {:answer, answer} -> answer
    end
  end

  defp sources(from_details, from_before, url, before_page, state) do
    with {:ok, details, state} <- details_source(from_details, url, state),
         {:ok, before, state} <- before_source(from_before, url, before_page, state) do
      {:ok, details ++ before, state}
    end
  end

  defp details_source([], _url, state), do: {:ok, [], state}

  defp details_source(selectors, url, state) do
    with {:ok, page, trusted, state} <- page(nil, url, state),
         do: {:ok, [%{page: page, trusted: trusted, base: page.url, selectors: selectors}], state}
  end

  defp before_source([], _url, _before_page, state), do: {:ok, [], state}

  defp before_source(selectors, url, before_page, state) do
    with {:ok, page, trusted, state} <- page(before_page, url, state),
         do:
           {:ok, [%{page: page, trusted: trusted, base: URI.parse(url), selectors: selectors}],
            state}
  end

  # Every selector's value in file order, `{value, filters, base, trusted}`, beside the first
  # limit a template hit, in file order; or `{:answer, answer}` for a page that does not read.
  defp entries(sources, state) do
    Enum.reduce_while(sources, {:ok, []}, fn source, {:ok, entries} ->
      case source_entries(source, state) do
        {:ok, found} ->
          {:cont, {:ok, entries ++ found}}

        {:error, reason} ->
          {:halt, {:answer, {{:error, {:cardigann_grab, reason}}, source.trusted}}}
      end
    end)
    |> case do
      {:ok, entries} ->
        sorted = Enum.sort_by(entries, &elem(&1, 0))

        limit =
          Enum.find_value(sorted, fn
            {_index, {:limit, kind}, _filters, _base, _trusted} -> kind
            _entry -> nil
          end)

        {:ok,
         for(
           {_index, value, filters, base, trusted} <- sorted,
           do: {value, filters, base, trusted}
         ), limit}

      answer ->
        answer
    end
  end

  defp source_entries(source, state) do
    blocks = for {selector, index} <- source.selectors, do: {index, selector}

    with {:ok, html} <- decoded(source.page),
         {:ok, values} <- page_values(blocks, html, state) do
      found =
        for {index, _selector} <- blocks,
            {value, filters} <- [Map.get(values, index, {nil, []})],
            do: {index, value, filters, source.base, source.trusted}

      {:ok, found}
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

  # Each block of `blocks`, `{name, block}`, read once in one worker on `html`: `{:ok, %{name =>
  # {value, filters}}}`, the value `{:limit, kind}` for a block whose template hit a limit and
  # nil for one left out or that matched nothing, or `{:error, reason}`.
  defp page_values(blocks, html, state) do
    planned =
      for {name, block} <- blocks do
        {name, block, planned_field(block, name, state.variables, state.request.now)}
      end

    fields = for {_name, _block, {:ok, field}} <- planned, do: field

    with {:ok, values} <- run_worker(html, fields, state) do
      found =
        Map.new(planned, fn
          {name, block, {:ok, field}} ->
            {name, {Map.get(values, field.name), block.filters || []}}

          {name, _block, {:limit, kind}} ->
            {name, {{:limit, kind}, []}}

          {name, block, :skip} ->
            {name, {nil, (block && block.filters) || []}}
        end)

      {:ok, found}
    end
  end

  defp planned_field(%{selector: selector} = block, name, variables, now)
       when is_binary(selector) do
    remove = Map.get(block, :remove)

    case Template.render(selector, variables, now) do
      {:ok, rendered} ->
        rendered = String.trim(rendered)

        if rendered != "" and compiles?(rendered) and (is_nil(remove) or compiles?(remove)),
          do:
            {:ok,
             %{
               name: "#{inspect(name)}",
               selector: rendered,
               attribute: block.attribute,
               remove: List.wrap(remove),
               case: []
             }},
          else: :skip

      {:error, kind} when kind in [:regex_limit, :filter_output_cap] ->
        {:limit, kind}

      {:error, _reason} ->
        :skip
    end
  end

  defp planned_field(_block, _name, _variables, _now), do: :skip

  defp compiles?(selector), do: match?({:ok, _}, Selector.compile(selector, "grab"))

  defp run_worker(_html, [], _state), do: {:ok, %{}}

  defp run_worker(html, fields, state) do
    left_ms = state.deadline_at - System.monotonic_time(:millisecond)

    if left_ms <= 0 do
      {:error, :deadline}
    else
      cap = worker_ms()
      plan = %{rows: "html", fields: fields}

      text = Charset.decode(html, state.charset)

      # A selector template that renders a secret setting's value never reaches the worker.
      if Fetch.worker_secret?(text, plan, state.request),
        do: {:error, :definition_error},
        else: worker_row(text, plan, min(cap, left_ms), left_ms <= cap)
    end
  end

  defp worker_row(text, plan, deadline_ms, deadline?) do
    case ParserWorker.run(text, plan, deadline_ms: deadline_ms) do
      {:ok, [row | _]} -> {:ok, Map.new(row)}
      {:ok, []} -> {:ok, %{}}
      {:error, :timeout} when deadline? -> {:error, :deadline}
      {:error, _failure} -> {:error, :parser_failed}
    end
  end

  # The grab variables of `url`: the search's settings, then the link's `.DownloadUri.*`, each
  # `.DownloadUri.Query.<key>` the block or the headers name nil unless the link holds it.
  defp variables(copy, url) do
    block_text = copy.definition |> Variables.grab_texts() |> Enum.join("\n")
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

  defp try_values(_copy, [], {page, page_trusted}, limit, _state) do
    if login_page?(page),
      do: {{:ok, page}, page_trusted},
      else: {{:error, {:cardigann_grab, limit || :no_link}}, page_trusted}
  end

  defp try_values(copy, [{value, filters, base, trusted} | rest], fallback, limit, state) do
    case selector_link(value, filters, state.variables, base, state) do
      {:magnet, magnet} ->
        magnet_answer(magnet, trusted, state)

      {:link, link} ->
        copy
        |> link_answer(link, trusted, state)
        |> next_or_answer(copy, rest, fallback, limit)

      {:limit, kind} ->
        try_values(copy, rest, fallback, limit || kind, state)

      :next ->
        try_values(copy, rest, fallback, limit, state)
    end
  end

  defp next_or_answer({:next, state}, copy, rest, fallback, limit),
    do: try_values(copy, rest, fallback, limit, state)

  defp next_or_answer(answer, _copy, _rest, _fallback, _limit), do: answer

  defp selector_link(value, filters, variables, page_uri, state) when is_binary(value) do
    case Filters.apply(String.trim(value), filters, variables, state.request.now,
           encoding: state.charset
         ) do
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
      fetch(Map.put(state, :trusted?, page_trusted), link, max_bytes, state.final)

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
  # `out` is the request's method, body and site headers (nil for the grab's own), which a
  # redirect keeps or drops as `Fetch.redirected/2` says.
  defp fetch(state, url, max_bytes, out \\ @get) do
    state = state |> Map.put_new(:trusted?, true) |> Map.merge(%{max_bytes: max_bytes, out: out})

    case Fetch.request_target(url, state.request, out.body) do
      {:ok, target} -> hop(target, state, 0)
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
    state = %{state | out: Fetch.redirected(state.out, response.status)}

    case Fetch.redirect_target(target, location, state.request, state.out.body) do
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
      Fetch.send_get(
        target,
        Map.put(state.request, :context, context(state.deadline_at, state.opts)),
        headers: Jar.header(state.jar, target.uri, state.request.credential_hosts),
        site_headers: state.out.site_headers || state.site_headers,
        method: state.out.method,
        body: state.out.body,
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

  # Under a login session (`store`), a jar an answer changed updates the stored row
  # (`IndexerCookies.update/3`), as a search answer does.
  defp keep_cookies(state, uri, response) do
    jar = Jar.keep(state.jar, uri, response, state.request.credential_hosts)
    if jar != state.jar, do: stored(state.store, jar)
    %{state | jar: jar}
  end

  defp stored(nil, _jar), do: :none
  defp stored({indexer, logged_in_at}, jar), do: IndexerCookies.update(indexer, logged_in_at, jar)

  defp config, do: Application.get_env(:cinder, Cardigann, [])
end
