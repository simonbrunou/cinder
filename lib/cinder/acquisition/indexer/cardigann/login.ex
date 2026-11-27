defmodule Cinder.Acquisition.Indexer.Cardigann.Login do
  @moduledoc """
  A Cardigann definition's login (#1680): the `post`, `get`, `form` and `cookie` methods, as
  Prowlarr's `CardigannRequestGenerator.DoLogin` and `CheckForError` run them (`b0b5774`), and
  the login sign a page answer shows (`sign/4`). No code is copied.

  ## The methods

  Each login starts from a jar holding `login.cookies` as fixed cookies, which go to every
  credential host (`Cinder.Acquisition.Indexer.Cardigann.Jar.put_fixed/2`). Its inputs
  are templates rendered with the stored settings (`Query.config_variables/2`) and written in
  the definition's charset (`Query.encode_pairs/2`); a template limit is its own tag, any other
  template failure `:definition_error`.

  - `post`: `login.inputs` as an `application/x-www-form-urlencoded` body to `login.path`.
  - `get`: `login.inputs` as a query on `login.path`.
  - `form`: a GET of `login.path`, the landing page, read in one parser worker: the first form
    `login.form` names (`form` by default), its named inputs that are not `disabled`, a
    checkbox or radio only when `checked`, each value `""` when it has none. Then
    `login.inputs` over them (with `login.selectors` on, each key is a selector whose element's
    `name` is the input's), then `login.selectorinputs`, read from the landing page. When the
    page loads a `simpleCaptcha` script, a GET of `simpleCaptcha.php?numImages=1` and its first
    image's `hash` as `captchaSelection`, with `submitme=X`. The form goes to `login.submitpath`,
    else its `action`, else the landing page, each resolved against the landing page's URL,
    with `login.getselectorinputs` as its query, as `multipart/form-data` when the form's
    `enctype` says so and urlencoded otherwise, with the landing page as its `Referer`. A
    selector input marked `optional` that matches nothing is left out. A landing page with no
    such form, any other selector input or `login.selectors` key that matches nothing, and a
    `simpleCaptcha` answer that is no JSON with an image hash are `:bad_response`.
  - `cookie`: no request. `login.inputs`' `cookie` (`{{ .Config.cookie }}` in each v11 file that
    sets it), else the `cookie` setting, goes in the jar as fixed cookies (`seed/2`), sent on
    every request to a credential host.

  ## Requests

  Every request takes `Cinder.Acquisition.Indexer.Cardigann.Fetch.send_session/3`: the untrusted
  path, the secret check on each hop, the jar's cookies only to a credential host (an origin's
  own cookies only to that origin), Req's redirects off with every hop followed here, and no
  retry. A request that carries inputs (the `post` and `get` requests and the form's submit)
  goes only to a credential host, else `:secret_host` and nothing is sent, and a redirect hop
  that keeps its body goes only to one too, since a filtered or multipart value can hide a
  secret from the check. Each request sends `login.headers`, else `search.headers`
  (`Cinder.Acquisition.Indexer.Cardigann.Headers`), only to a credential host. Each request is
  one call of the caller's `hold`, so a search spaces them as its own (`run/2`).

  ## The answer

  The login's last answer, as the search reads a page answer first: HTTP 401 is
  `{:rejected, method}`, 429 a limit, any other status, a transport failure or a timeout that
  failure. A 2xx answer is `{:rejected, method}` when one of the `login.error` selectors matches
  it, else `{:ok, jar}`. Each `login.error`'s `path` and `message` are not read, and no text of
  the page is kept. A parse that fails is `:parser_failed` (`:deadline` at the caller's
  deadline: the search's, the Test's or the grab's), never a rejection, and a parse whose input
  would hold a secret the page does not hold reaches no worker: `:definition_error`
  (`Fetch.worker_secret?/3`).
  """

  alias Cinder.Acquisition.Indexer.Cardigann.{
    Charset,
    Fetch,
    Filters,
    Headers,
    Jar,
    Query,
    Template
  }

  alias Cinder.Acquisition.IndexerSource.Native
  alias Cinder.Indexers.{ParserWorker, Selector}

  @worker_ms 30_000
  @methods %{"post" => :post, "get" => :get, "form" => :form, "cookie" => :cookie}
  @captcha_path "simpleCaptcha.php?numImages=1"
  @max_image_bytes 1_048_576

  @type method :: :post | :get | :form | :cookie
  @type answer :: {:ok, Jar.t()} | {:rejected, method()} | {:error, term()}

  @typedoc """
  One step of a login inside one call of the caller's hold: the next step's state, or the
  login's answer.
  """
  @type step :: {:next, map()} | {:done, answer() | {:fresh, term()}}

  @typedoc """
  Runs one step's function, which sends at most one request, and answers `{:ran, step}`, or
  `{:not_run, outcome}` when the step could not run.
  """
  @type hold :: ((-> step()) -> {:ran, step()} | {:not_run, term()})

  @doc "The login method of `definition` as an atom, or nil for a definition with no login."
  @spec method(map()) :: method() | nil
  def method(%{login: %{method: method}}), do: Map.get(@methods, method)
  def method(_definition), do: nil

  @doc """
  The jar of the `cookie` method: the moduledoc's cookie string as fixed cookies, beside
  `login.cookies`.
  """
  @spec seed(map(), DateTime.t()) :: {:ok, Jar.t()} | {:error, atom()}
  def seed(copy, now) do
    login = copy.definition.login
    variables = Query.config_variables(copy.definition, copy.config)

    template =
      case List.keyfind(login.inputs || [], "cookie", 0) do
        {"cookie", template} -> template || ""
        nil -> "{{ .Config.cookie }}"
      end

    with {:ok, _uri} <- base_uri(copy),
         {:ok, text} <- render(template, variables, now) do
      {:ok, Jar.put_fixed(start_jar(copy), text)}
    end
  end

  @doc """
  Logs in as `copy`'s definition says, each request in one call of `opts.hold`.

  `opts` holds `context` (the request context, its deadline among them), `hold`, `fresh`, a
  function the first step calls inside its hold before any request: `{:use, session}` ends the
  login with `{:fresh, session}` and no request, as when another search logged in while this
  one waited; `:none` goes on; and optionally `request`, keys that replace the copy's request
  map's (a grab's resolver and plug). Answers `t:answer/0`, `{:fresh, session}`, `{:not_run,
  outcome}` when a hold did not run its step, `{:unsent, class}` when the login fails before
  its first hold (a base URL or a header that does not render), or what the hold made of the
  last step's answer.
  """
  @spec run(map(), map()) ::
          answer() | {:fresh, term()} | {:not_run, term()} | {:unsent, term()} | term()
  def run(copy, opts) do
    case start(copy, opts) do
      {:ok, state} -> steps(state, plan(method(copy.definition), copy, opts), opts)
      {:error, class} -> {:unsent, class}
    end
  end

  # A `form` login that carries the admin's captcha answer (#1681) sends no landing page and
  # reads no fresh row: the load's session gives the page, taken inside the hold of the first
  # request, the `simpleCaptcha` GET or the submit.
  defp plan(:form, copy, %{captcha: captcha}),
    do: [&resumed(&1, copy, captcha), &submit_form(&1, copy)]

  defp plan(method, copy, opts) do
    first = fn state ->
      case opts.fresh.() do
        {:use, session} -> {:done, {:fresh, session}}
        :none -> first_step(method, copy, state)
      end
    end

    [first | later_steps(method, copy)]
  end

  defp steps(state, [step | rest], opts) do
    case opts.hold.(fn -> step.(state) end) do
      {:ran, {:next, state}} -> steps(state, rest, opts)
      {:ran, {:done, answer}} -> answer
      {:not_run, outcome} -> {:not_run, outcome}
    end
  end

  defp later_steps(:form, copy), do: [&captcha(&1, copy), &submit_form(&1, copy)]
  defp later_steps(_method, _copy), do: []

  defp first_step(:post, copy, state), do: {:done, send_inputs(:post, copy, state)}
  defp first_step(:get, copy, state), do: {:done, send_inputs(:get, copy, state)}
  defp first_step(:form, copy, state), do: landing(copy, state)

  # The state every step reads: the request map, the variables, the headers and the jar.
  defp start(copy, opts) do
    now = Native.now()
    variables = Query.config_variables(copy.definition, copy.config)

    request =
      copy.request.(opts.context, now)
      |> Map.merge(Map.get(opts, :request, %{}))
      |> Map.merge(%{secret_referenced?: false, follow_redirects?: true})

    with {:ok, _uri} <- base_uri(copy),
         {:ok, headers} <- headers(copy.definition, variables, now) do
      {:ok,
       %{
         request: request,
         variables: variables,
         headers: headers,
         jar: start_jar(copy),
         now: now,
         deadline_at: opts.context.deadline_at
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp base_uri(copy) do
    case URI.new(copy.config.base_url || "") do
      {:ok, %URI{scheme: scheme, host: host} = uri}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, uri}

      _invalid ->
        {:error, :definition_error}
    end
  end

  defp start_jar(copy) do
    Enum.reduce(copy.definition.login.cookies || [], Jar.new(), &Jar.put_fixed(&2, &1))
  end

  # `login.headers` when the definition sets any, else `search.headers` (#1679's handover).
  defp headers(definition, variables, now) do
    result =
      case definition.login.headers do
        [_ | _] = headers -> Headers.render(headers, variables, now)
        _none -> Headers.render(definition.search.headers || [], variables, now)
      end

    case result do
      {:ok, headers} -> {:ok, headers}
      {:error, kind} when kind in [:regex_limit, :filter_output_cap] -> {:error, kind}
      {:error, _reason} -> {:error, :definition_error}
    end
  end

  # --- post and get ---

  defp send_inputs(method, copy, state) do
    login = copy.definition.login

    with {:ok, pairs} <- inputs(login.inputs || [], state),
         {:ok, uri} <- Query.resolve(copy.config.base_url, login.path || "") do
      query = Query.encode_pairs(pairs, charset(state))

      outgoing =
        case method do
          :post -> %{url: URI.to_string(uri), method: :post, body: query}
          :get -> %{url: URI.to_string(Query.with_query(uri, query)), method: :get}
        end

      sent(outgoing, copy, state)
    end
  end

  # Each input rendered, in file order; a key repeated later replaces the earlier value.
  defp inputs(inputs, state) do
    Enum.reduce_while(inputs, {:ok, []}, fn {key, template}, {:ok, acc} ->
      case render(template || "", state.variables, state.now) do
        {:ok, value} -> {:cont, {:ok, put_pair(acc, key, value)}}
        error -> {:halt, error}
      end
    end)
  end

  # A key already in `pairs` keeps its place with the new value; a new key goes last.
  defp put_pair(pairs, key, value), do: List.keystore(pairs, key, 0, {key, value})

  # A request that carries the login's inputs, sent only to a credential host, its body only on
  # hops to one; then the answer as the moduledoc's "The answer" says.
  defp sent(outgoing, copy, state, extra_headers \\ []) do
    if credential_url?(outgoing.url, state) do
      outgoing =
        Map.merge(outgoing, %{
          site_headers: with_headers(state.headers, extra_headers),
          retry: false,
          secret_body?: true
        })

      outgoing |> Fetch.send_session(state.request, state.jar) |> login_answer(copy, state)
    else
      {:error, :secret_host}
    end
  end

  defp credential_url?(url, state) do
    case URI.new(url) do
      {:ok, uri} -> Fetch.credential_host?(uri, state.request.credential_hosts)
      {:error, _part} -> false
    end
  end

  defp with_headers(headers, []), do: headers

  defp with_headers(headers, extra) do
    names = MapSet.new(extra, fn {name, _value} -> String.downcase(name) end)
    Enum.reject(headers, &MapSet.member?(names, String.downcase(elem(&1, 0)))) ++ extra
  end

  defp login_answer({{:ok, page}, jar}, copy, state) do
    case error_match(page, copy, state) do
      :none -> {:ok, jar}
      :matched -> {:rejected, method(copy.definition)}
      {:error, class} -> {:error, class}
    end
  end

  defp login_answer({{:error, {:rejected_credentials, _by}}, _jar}, copy, _state),
    do: {:rejected, method(copy.definition)}

  defp login_answer({{:error, class}, _jar}, _copy, _state), do: {:error, class}

  # Prowlarr's `CheckForError`: a `login.error` selector that matches the login answer.
  defp error_match(page, copy, state) do
    fields =
      for {%{selector: selector}, index} <- Enum.with_index(copy.definition.login.error || []),
          is_binary(selector),
          do: field("error#{index}", selector, nil)

    if fields == [] do
      :none
    else
      page.body |> first_row(%{rows: "html", fields: fields}, state) |> error_row(fields)
    end
  end

  defp error_row({:ok, row}, fields),
    do: if(Enum.any?(fields, &row[&1.name]), do: :matched, else: :none)

  defp error_row({:error, class}, _fields), do: {:error, class}

  # --- form ---

  defp landing(copy, state) do
    with {:ok, page, form, state} <- landed(copy, state),
         :no_captcha <- form.image_captcha,
         {:ok, pairs} <- form_pairs(form, copy.definition.login, state) do
      {:next, Map.merge(state, %{landing: page.uri, form: Map.put(form, :pairs, pairs)})}
    else
      {:error, class} -> {:done, {:error, class}}
      # Prowlarr's "Found captcha during automatic login, aborting" (#1681).
      %{} -> {:done, :captcha_required}
    end
  end

  # The landing page fetched and its form read, its `Set-Cookie` in the state's jar.
  defp landed(copy, state) do
    login = copy.definition.login

    with {:ok, uri} <- Query.resolve(copy.config.base_url, login.path || ""),
         {{:ok, page}, jar} <-
           Fetch.send_session(
             %{url: URI.to_string(uri), site_headers: state.headers, retry: false},
             state.request,
             state.jar
           ),
         state = %{state | jar: jar},
         {:ok, form} <- read_form(page, copy, state) do
      {:ok, page, form, state}
    else
      {{:error, class}, _jar} -> {:error, class}
      {:error, class} -> {:error, class}
    end
  end

  # The landing page read once: the html row first, then each form row and its inputs, in
  # document order. The answer holds only what the page gives (`page_form`); the settings join
  # it in `form_pairs/3`.
  defp read_form(page, copy, state) do
    login = copy.definition.login
    form = String.trim(login.form || "") |> then(&if(&1 == "", do: "form", else: &1))

    with {:ok, keyed} <- keyed_fields(login, state),
         {:ok, rows} <- rows(page.body, form_plan(form, keyed), state),
         [html | rest] <- rows,
         html = Map.new(html),
         {:ok, form_row, inputs} <- first_form(rest) do
      {:ok, page_form(form_row, inputs, keyed, html, state)}
    else
      [] -> {:error, :parser_failed}
      {:error, class} -> {:error, class}
    end
  end

  # What the landing page gives the form: its action and enctype, its inputs the browser would
  # send, the names the `login.selectors` keys select, the `selectorinputs` values and the
  # `getselectorinputs` query, each value read now and each failure kept for the step that
  # needs it. `page` holds the page's parts these are read from, as strings, which a captcha
  # session stores so the answered login reads the same form again (`resumed_form/3`).
  defp page_form(form_row, inputs, keyed, html, state) do
    %{
      action: Map.get(form_row, "action"),
      multipart?:
        String.downcase(String.trim(Map.get(form_row, "enctype") || "")) ==
          "multipart/form-data",
      captcha?: Map.get(html, "captcha") != nil,
      kept:
        Enum.reduce(inputs, [], fn input, acc ->
          if sent_input?(input), do: put_pair(acc, input["name"], input["value"] || ""), else: acc
        end),
      names: for({field, _selector} <- keyed.keys, do: html[field]),
      set: values_of(keyed.set_values, html, state),
      query: values_of(keyed.get_values, html, state),
      image_captcha: image_captcha(keyed.captcha, html),
      page: %{
        "form_row" => Map.take(form_row, ["action", "enctype"]),
        "inputs" => Enum.map(inputs, &Map.take(&1, ~w(name type value checked disabled))),
        "html" => Map.take(html, ["captcha" | Enum.map(keyed.fields, & &1.name)])
      }
    }
  end

  # The element `login.captcha.selector` matches (#1681): `:no_captcha` when the definition has
  # no captcha or the page shows none, else its `src` and the name its answer goes under, nil
  # when the page gives none.
  defp image_captcha(nil, _html), do: :no_captcha

  defp image_captcha(captcha, html) do
    if html["captcha_seen"] == nil,
      do: :no_captcha,
      else: %{src: html["captcha_src"], input: captcha_input(captcha, html)}
  end

  defp captcha_input(%{selectors?: true}, html), do: html["captcha_input"]
  defp captcha_input(%{input: input}, _html), do: input

  defp form_plan(form, keyed) do
    fields =
      [
        field("form", form, nil),
        field("action", nil, "action"),
        field("enctype", nil, "enctype"),
        field("name", nil, "name"),
        field("type", nil, "type"),
        field("value", nil, "value"),
        field("checked", nil, "checked"),
        field("disabled", nil, "disabled"),
        field("captcha", ~s|script[src*="simpleCaptcha"]|, "src")
      ] ++ keyed.fields

    %{rows: "html, #{form}, #{form} input", fields: fields}
  end

  # The worker fields of `login.selectors` keys, `selectorinputs` and `getselectorinputs`, each
  # read on the html row.
  defp keyed_fields(login, state) do
    selector_keys =
      if login.selectors,
        do: for({{key, _value}, i} <- Enum.with_index(login.inputs || []), do: {"key#{i}", key}),
        else: []

    with {:ok, set} <- selector_fields(login.selectorinputs || [], "set", state),
         {:ok, get} <- selector_fields(login.getselectorinputs || [], "get", state),
         {:ok, captcha, captcha_fields} <- captcha_fields(login) do
      {:ok,
       %{
         keys: selector_keys,
         set_values: set,
         get_values: get,
         captcha: captcha,
         fields:
           for({name, key} <- selector_keys, do: field(name, key, "name")) ++
             Enum.map(set ++ get, & &1.field) ++ captcha_fields
       }}
    end
  end

  # The image captcha's element, read for its presence and its `src`, and with
  # `login.selectors` on the element `captcha.input` selects, read for its `name`, as Prowlarr's
  # `DoLogin` reads it (#1681).
  defp captcha_fields(%{captcha: %{type: "image", selector: selector} = captcha} = login)
       when is_binary(selector) do
    selectors? = login.selectors == true
    input = captcha.input

    cond do
      not compiles?(selector) or not is_binary(input) or String.trim(input) == "" ->
        {:error, :definition_error}

      selectors? and not compiles?(input) ->
        {:error, :definition_error}

      true ->
        fields =
          [field("captcha_seen", selector, nil), field("captcha_src", selector, "src")] ++
            if(selectors?, do: [field("captcha_input", input, "name")], else: [])

        {:ok, %{input: input, selectors?: selectors?}, fields}
    end
  end

  defp captcha_fields(%{captcha: nil}), do: {:ok, nil, []}
  defp captcha_fields(_login), do: {:error, :definition_error}

  defp selector_fields(blocks, prefix, state) do
    blocks
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {{name, block}, i}, {:ok, acc} ->
      case selector_field(block, "#{prefix}#{i}", state) do
        {:ok, field} -> {:cont, {:ok, [%{name: name, block: block, field: field} | acc]}}
        error -> {:halt, error}
      end
    end)
    |> in_order()
  end

  defp selector_field(%{selector: selector} = block, name, state) when is_binary(selector) do
    with {:ok, rendered} <- render(selector, state.variables, state.now),
         rendered = String.trim(rendered),
         true <- rendered != "" and compiles?(rendered) and removes?(block) do
      {:ok,
       %{
         name: name,
         selector: rendered,
         attribute: block.attribute,
         remove: List.wrap(Map.get(block, :remove)),
         case: []
       }}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :definition_error}
    end
  end

  defp selector_field(_block, _name, _state), do: {:error, :definition_error}

  defp removes?(block), do: is_nil(Map.get(block, :remove)) or compiles?(block.remove)

  defp compiles?(selector), do: match?({:ok, _}, Selector.compile(selector, "login"))

  # The first form row and the input rows after it, up to the next form row.
  defp first_form(rows) do
    case Enum.drop_while(rows, &(not form_row?(&1))) do
      [form | rest] ->
        {:ok, Map.new(form),
         rest |> Enum.take_while(&(not form_row?(&1))) |> Enum.map(&Map.new/1)}

      [] ->
        {:error, :bad_response}
    end
  end

  defp form_row?(row), do: List.keyfind(row, "form", 0) not in [nil, {"form", nil}]

  # The pairs the form posts: the page's kept inputs, then `login.inputs` rendered with the
  # stored settings now, under the names the page gave their keys, then the `selectorinputs`.
  defp form_pairs(form, login, state) do
    with {:ok, rendered} <- inputs(login.inputs || [], state),
         {:ok, named} <- input_names(rendered, form.names, login.selectors),
         {:ok, set} <- form.set do
      {:ok,
       Enum.reduce(named ++ set, form.kept, fn {key, value}, acc -> put_pair(acc, key, value) end)}
    end
  end

  defp sent_input?(input) do
    name = input["name"]
    type = String.downcase(input["type"] || "")

    is_binary(name) and name != "" and is_nil(input["disabled"]) and
      (type not in ["checkbox", "radio"] or input["checked"] != nil)
  end

  # With `login.selectors` on, each input key is a selector whose element's `name` the value
  # goes under.
  defp input_names(rendered, _names, false), do: {:ok, rendered}

  defp input_names(rendered, names, true) do
    Enum.zip(rendered, names)
    |> Enum.reduce_while({:ok, []}, fn {{_key, value}, name}, {:ok, acc} ->
      case name do
        name when is_binary(name) and name != "" -> {:cont, {:ok, [{name, value} | acc]}}
        _none -> {:halt, {:error, :bad_response}}
      end
    end)
    |> in_order()
  end

  # Each selector input's value on the html row, run through its filters; a value that is
  # missing reads `:bad_response` unless the selector is optional.
  defp values_of(entries, html, state) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case selector_value(entry, html[entry.field.name], state) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, value} -> {:cont, {:ok, [{entry.name, value} | acc]}}
        error -> {:halt, error}
      end
    end)
    |> in_order()
  end

  # A reduction's list, built by prepending, back in file order.
  defp in_order({:ok, reversed}), do: {:ok, Enum.reverse(reversed)}
  defp in_order(error), do: error

  defp selector_value(entry, nil, _state) do
    if entry.block.optional, do: {:ok, nil}, else: {:error, :bad_response}
  end

  defp selector_value(entry, value, state) do
    case Filters.apply(String.trim(value), entry.block.filters || [], state.variables, state.now,
           encoding: charset(state)
         ) do
      {:ok, filtered} -> {:ok, String.trim(filtered)}
      {:error, kind} when kind in [:regex_limit, :filter_output_cap] -> {:error, kind}
      {:error, _reason} -> {:error, :bad_response}
    end
  end

  defp captcha(%{form: %{captcha?: false}} = state, _copy), do: {:next, state}

  defp captcha(state, copy) do
    with {:ok, uri} <- Query.resolve(copy.config.base_url, @captcha_path),
         {{:ok, page}, jar} <-
           Fetch.send_session(
             %{url: URI.to_string(uri), site_headers: state.headers, retry: false},
             state.request,
             state.jar
           ),
         {:ok, hash} <- captcha_hash(page.body) do
      pairs = state.form.pairs |> put_pair("captchaSelection", hash) |> put_pair("submitme", "X")
      {:next, %{state | jar: jar, form: %{state.form | pairs: pairs}}}
    else
      {{:error, class}, _jar} -> {:done, {:error, class}}
      {:error, class} -> {:done, {:error, class}}
    end
  end

  defp captcha_hash(body) do
    case Jason.decode(body) do
      {:ok, %{"images" => [%{"hash" => hash} | _]}} when is_binary(hash) and hash != "" ->
        {:ok, hash}

      _other ->
        {:error, :bad_response}
    end
  end

  defp submit_form(state, copy) do
    form = state.form
    path = copy.definition.login.submitpath || form.action || ""

    with {:ok, uri} <- merged(state.landing, path),
         {:ok, query} <- form.query do
      uri = Query.with_query(uri, Query.encode_pairs(query, charset(state)))
      {body, content_type} = form_body(form, state)

      outgoing = %{
        url: URI.to_string(uri),
        method: :post,
        body: body,
        content_type: content_type
      }

      {:done, sent(outgoing, copy, state, referer(state.landing))}
    else
      {:error, class} -> {:done, {:error, class}}
    end
  end

  defp merged(base, path) do
    case URI.merge(base, path) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, %{uri | fragment: nil}}

      _other ->
        {:error, :bad_response}
    end
  rescue
    ArgumentError -> {:error, :bad_response}
  end

  defp referer(uri) do
    text = URI.to_string(uri)
    if Headers.value?(text), do: [{"referer", text}], else: []
  end

  defp form_body(%{multipart?: false, pairs: pairs}, state),
    do: {Query.encode_pairs(pairs, charset(state)), nil}

  defp form_body(%{multipart?: true, pairs: pairs}, state) do
    boundary = "cinder" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    charset = charset(state)

    parts =
      for {name, value} <- pairs do
        [
          "--",
          boundary,
          "\r\ncontent-disposition: form-data; name=\"",
          part_name(name, charset),
          "\"\r\n\r\n",
          Charset.encode(value, charset),
          "\r\n"
        ]
      end

    {IO.iodata_to_binary([parts, "--", boundary, "--\r\n"]),
     "multipart/form-data; boundary=" <> boundary}
  end

  # A part's name as HTML's form encoding writes it: a quote, CR and LF percent-encoded.
  defp part_name(name, charset) do
    name
    |> Charset.encode(charset)
    |> String.replace(["\"", "\r", "\n"], fn
      "\"" -> "%22"
      "\r" -> "%0D"
      "\n" -> "%0A"
    end)
  end

  # --- the image captcha (#1681) ---

  @doc """
  Loads the image captcha of `copy`'s `form` login, each request in one call of `opts.hold`
  (`opts` as `run/2` takes it, with no `fresh`): the landing page, then the image its
  `login.captcha.selector` element's `src` names, resolved against the landing page's URL. The
  image goes out with the landing page's cookies and the definition's headers, and the landing
  page as its `Referer`, each only to a credential host.

  Answers `{:ok, loaded}`, where `loaded` holds the jar after the image's answer, the landing
  page's URL, the page parts its form was read from (`form`), the image's bytes and its type;
  `{:error, :captcha_not_found}` when the landing page shows no such element or the element
  gives no `src` that resolves to an `http` or `https` URL; `{:error, {:captcha_image, :type}}`
  for an answer whose first bytes are no PNG, JPEG, GIF or WebP, whatever its `content-type`
  says; `{:error, {:captcha_image, :too_large}}` past `max_image_bytes/0`; otherwise a failure
  class, `{:not_run, outcome}` or `{:unsent, class}` as `run/2` answers them.
  """
  @spec load_captcha(map(), map()) ::
          {:ok, map()} | {:error, term()} | {:not_run, term()} | {:unsent, term()}
  def load_captcha(copy, opts) do
    case start(copy, opts) do
      {:ok, state} -> steps(state, [&captcha_page(&1, copy), &captcha_image/1], opts)
      {:error, class} -> {:unsent, class}
    end
  end

  @doc "The largest captcha image a load takes, in bytes: 1 MiB."
  @spec max_image_bytes() :: pos_integer()
  def max_image_bytes, do: @max_image_bytes

  defp captcha_page(state, copy) do
    with {:ok, page, form, state} <- landed(copy, state),
         {:ok, url} <- image_url(form.image_captcha, page.uri) do
      {:next, Map.merge(state, %{landing: page.uri, form: form, image: url})}
    else
      :none -> {:done, {:error, :captcha_not_found}}
      {:error, class} -> {:done, {:error, class}}
    end
  end

  defp image_url(%{src: src}, base) when is_binary(src) do
    case String.trim(src) do
      "" -> :none
      src -> with({:error, _class} <- merged(base, src), do: :none)
    end
  end

  defp image_url(_no_captcha, _base), do: :none

  defp captcha_image(state) do
    outgoing = %{
      url: URI.to_string(state.image),
      site_headers: with_headers(state.headers, referer(state.landing)),
      retry: false
    }

    case Fetch.send_session(outgoing, state.request, state.jar) do
      {{:ok, %{body: body}}, jar} when byte_size(body) <= @max_image_bytes ->
        {:done, image(state, jar, body)}

      {{:ok, _page}, _jar} ->
        {:done, {:error, {:captcha_image, :too_large}}}

      {{:error, :too_large}, _jar} ->
        {:done, {:error, {:captcha_image, :too_large}}}

      {{:error, class}, _jar} ->
        {:done, {:error, class}}
    end
  end

  # The load's answer for an image `body` within the cap: the session and the image, when its
  # first bytes name a type the dialog shows.
  defp image(state, jar, body) do
    case image_type(body) do
      {:ok, mime} ->
        {:ok,
         %{
           jar: jar,
           landing: URI.to_string(state.landing),
           form: state.form.page,
           image: body,
           mime: mime
         }}

      :error ->
        {:error, {:captcha_image, :type}}
    end
  end

  # The answered login's first step: the session taken, its form read again with the settings
  # rendered now and the answer under the captcha's input, then the step's one request.
  defp resumed(state, copy, captcha) do
    login = copy.definition.login

    with {:ok, session} <- taken(captcha.take.()),
         state = %{state | jar: session.jar},
         {:ok, form} <- resumed_form(session.form, copy, state),
         {:ok, pairs} <- form_pairs(form, login, state),
         {:ok, pairs} <- with_answer(pairs, form.image_captcha, captcha.answer) do
      state =
        Map.merge(state, %{
          landing: URI.parse(session.landing),
          form: Map.put(form, :pairs, pairs)
        })

      if form.captcha?, do: captcha(state, copy), else: submit_form(state, copy)
    else
      :miss -> {:done, :captcha_expired}
      {:error, class} -> {:done, {:error, class}}
    end
  end

  defp taken({:ok, session}), do: {:ok, session}
  defp taken(:miss), do: :miss

  defp resumed_form(%{"form_row" => row, "inputs" => inputs, "html" => html}, copy, state)
       when is_map(row) and is_list(inputs) and is_map(html) do
    with {:ok, keyed} <- keyed_fields(copy.definition.login, state),
         do: {:ok, page_form(row, inputs, keyed, html, state)}
  end

  defp resumed_form(_page, _copy, _state), do: {:error, :bad_response}

  defp with_answer(pairs, %{input: input}, answer) when is_binary(input) and input != "",
    do: {:ok, put_pair(pairs, input, String.trim(answer.()))}

  defp with_answer(_pairs, _captcha, _answer), do: {:error, :bad_response}

  defp image_type(<<0x89, "PNG\r\n", 0x1A, "\n", _rest::binary>>), do: {:ok, "image/png"}
  defp image_type(<<0xFF, 0xD8, 0xFF, _rest::binary>>), do: {:ok, "image/jpeg"}
  defp image_type(<<"GIF8", v, "a", _rest::binary>>) when v in [?7, ?9], do: {:ok, "image/gif"}

  defp image_type(<<"RIFF", _size::binary-size(4), "WEBP", _rest::binary>>),
    do: {:ok, "image/webp"}

  defp image_type(_bytes), do: :error

  # --- the login sign ---

  @doc """
  The login sign of a page answer (#1680), as the search reads it before it records anything:
  `:sign` for a redirect it did not follow (`{:http_status, 3xx}`), an HTTP 401, or a 2xx page
  whose `content-type` is `text/html` or absent, of a definition with a `login.test.selector`,
  on which that selector matches nothing; `{:error, class}` for a parse that fails, as the
  moduledoc's "The answer" says; else `:none`.
  """
  @spec sign({:ok, Fetch.page()} | {:error, term()}, map(), map(), integer()) ::
          :sign | :none | {:error, term()}
  def sign({:error, {:http_status, status}}, _definition, _request, _deadline_at)
      when status in 300..399,
      do: :sign

  def sign({:error, {:rejected_credentials, {:http_status, 401}}}, _definition, _request, _at),
    do: :sign

  def sign({:ok, page}, %{login: %{test: %{selector: selector}}}, request, deadline_at)
      when is_binary(selector) do
    if html?(page.content_type) do
      plan = %{rows: "html", fields: [field("test", selector, nil)]}
      page.body |> first_row(plan, %{request: request, deadline_at: deadline_at}) |> test_row()
    else
      :none
    end
  end

  def sign(_answer, _definition, _request, _deadline_at), do: :none

  defp test_row({:ok, row}), do: if(row["test"] == nil, do: :sign, else: :none)
  defp test_row({:error, class}), do: {:error, class}

  defp html?(nil), do: true
  defp html?(type), do: type |> String.downcase() |> String.contains?("text/html")

  # --- the parser worker ---

  defp field(name, selector, attribute),
    do: %{name: name, selector: selector, attribute: attribute, remove: [], case: []}

  defp first_row(body, plan, state) do
    case rows(body, plan, state) do
      {:ok, [row | _]} -> {:ok, Map.new(row)}
      {:ok, []} -> {:error, :parser_failed}
      {:error, class} -> {:error, class}
    end
  end

  # One worker run on `body`, decoded in the definition's charset: 30 s or the time left before
  # the deadline, whichever is less.
  defp rows(body, plan, state) do
    text =
      Charset.decode(body, Map.get(state.request, :charset))

    left_ms = state.deadline_at - System.monotonic_time(:millisecond)

    cond do
      left_ms <= 0 ->
        {:error, :deadline}

      Fetch.worker_secret?(text, plan, state.request) ->
        {:error, :definition_error}

      true ->
        case ParserWorker.run(text, plan, deadline_ms: min(@worker_ms, left_ms)) do
          {:ok, rows} -> {:ok, rows}
          {:error, :timeout} when left_ms <= @worker_ms -> {:error, :deadline}
          {:error, _failure} -> {:error, :parser_failed}
        end
    end
  end

  defp charset(state), do: Map.get(state.request, :charset, :utf8)

  defp render(template, variables, now) do
    case Template.render(template, variables, now) do
      {:ok, text} -> {:ok, text}
      {:error, kind} when kind in [:regex_limit, :filter_output_cap] -> {:error, kind}
      {:error, _reason} -> {:error, :definition_error}
    end
  end
end
