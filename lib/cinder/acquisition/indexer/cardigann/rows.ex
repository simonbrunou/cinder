defmodule Cinder.Acquisition.Indexer.Cardigann.Rows do
  @moduledoc """
  The rows of one Cardigann search page (#1671; #1618 points 6, 7 and 15), read as Prowlarr's
  `CardigannParser` reads a page (`b0b5774`), with the exceptions the issue sets.

  ## Extraction

  The page is read in the definition's charset (`Cinder.Acquisition.Indexer.Cardigann.Charset`,
  #1678), whatever its `Content-Type` says, as Prowlarr's `HttpResponse.Content` reads the
  request's encoding first. A byte the charset cannot read becomes U+FFFD, so one such byte costs
  no row. The search path's `response.type` picks the reader:

  - none: an HTML page. Every selector runs in a `Cinder.Indexers.ParserWorker`: the rows
    selector and each field's selector, rendered first with the search variables, go in as one
    plan, and per-row values come out. A field written as `text` has no selector in the plan.
    Each field's `remove` is taken out of a copy of its element before the value is read. With
    `rows.after` above 0 (#1679), each group of a row and the `after` rows below it reads as one
    row, the group's rows emptied into the first, and a last group short of rows merges what it
    has. With `rows.dateheaders`, the worker also reads, for each row, the header the walk of
    Prowlarr's parser finds: the first element the header selector reads a value from, trying
    each element's previous element sibling, else its parent's previous element sibling, from
    the row up. All the workers of one page
    share the smaller of 30 s and the time left before the search deadline;
  - `json`: `Cinder.Acquisition.Indexer.Cardigann.JsonRows`, in the search process;
  - `xml`: `Cinder.Acquisition.Indexer.Cardigann.XmlRows`, in the search process.

  On an HTML or XML page, `search.preprocessingfilters` run first over the decoded text, in the
  definition's charset, as Prowlarr's `ParseResponse` runs them (#1679). A regex limit or the
  filter-chain cap there reads as a page with no rows, partial with that kind; any other failure
  is `:definition_error`. A text longer than that cap, 64 KiB, gets no filter and reads as
  partial `:filter_output_cap`: a regex filter runs in the search process, and over a whole
  page its time grows with the square of the page's size.

  ## Selectors that read `.Result`

  A field selector whose template reads `.Result.<name>`, as keepfriends' and pterclub's do,
  is left out of the first worker's plan (#1679). After it, each round renders such selectors
  per row with that row's values of the fields before the first one pending, checks each
  distinct rendering with `Cinder.Indexers.Selector.compile/2`, and asks one more worker for
  them on the same page, rows and merge. A row whose rendering fails, or that the check or the
  worker refuses, reads nil for that field. A page takes at most `max_result_rounds/0` rounds
  after the first and `max_result_selectors/0` distinct renderings per field and round; past
  either the page is `:definition_error`, and a round whose row count differs from the first's
  makes it `:parser_failed`. `Cinder.Indexers.Definitions.LoadCheck` refuses a chain past the
  rounds at load time. Prowlarr renders the selector per row in one pass.

  ## The worker's input

  No secret goes into the parser worker's input (`docs/agents/architecture.md` "The parser
  worker is not a security boundary"). A plan whose rendered selectors, or a preprocessed page
  whose text, hold a secret setting's value that the page as the site answered does not hold
  (`Cinder.Acquisition.Indexer.Cardigann.Fetch.worker_secret?/3`) reaches no worker, first
  plan and `.Result` rounds alike: the page is `:definition_error`.

  ## Fields

  Each row starts with `.Result.<name>` nil for every field, then runs the fields in file order,
  each one reading the earlier ones:

  1. the value: a `text` field's template rendered; else the worker's value, trimmed, or for a
     `case` field the first matching key's value rendered as a template;
  2. an `optional` field with a blank value takes its `default` rendered; a blank default leaves
     `.Result.<name>` nil and skips the filters;
  3. the field's filters (`Cinder.Acquisition.Indexer.Cardigann.Filters`, in the definition's
     charset). The issue orders the
     default before the filters; Prowlarr filters the selector's value and leaves the default
     unfiltered.

  A field with no value (a selector that matched nothing, a `case` that matched no key) or whose
  template or filter fails leaves `.Result.<name>` nil and the row goes on, as Prowlarr's parser
  does. A regex limit or the filter-chain cap in a field drops the row and marks the page
  partial with that kind. `.Result.<name>` holds the field's text after its filters.

  ## Row filter and row

  With the `andmatch` row filter listed and the call's query text not blank, a row stays only
  when `Filters.andmatch?/3` keeps it for its title and description. Then:

  - `title`: the shared title rule (`Cinder.Acquisition.Indexer.Newznab.Items.row_title/1`);
  - `download_url`: the `download` value (a `magnet:` value as it is, any other resolved against
    the page's URL and kept when it is an http(s) URL), else the `magnet` value when it starts
    with `magnet:`, else, unless the definition's `type` is `private`, a magnet built from
    `infohash`: `magnet:?xt=urn:btih:<hash>&dn=<title>`, with no tracker. A row with no link
    or no title is dropped, and so is one whose link holds a secret off the credential hosts
    (`Cinder.Acquisition.Indexer.Cardigann.Fetch.secret_link?/2`), counted as missing its link;
  - `size`: `Cinder.Acquisition.Indexer.Cardigann.Size.bytes/1`;
  - `category_ids`: the value split on `,`, each part trimmed and mapped through
    `categorymappings` (the site id in any case) to every standard category it names, each once;
    nil when none maps;
  - `published_at`: `Cinder.Acquisition.Indexer.Cardigann.DotnetDate.from_unknown/2`. When
    it is nil on an HTML page and the definition sets `rows.dateheaders`, the row's date
    header runs as a field run with `optional` off, its filters included, and its value through
    `from_unknown/2`. A header with no value, or one whose filter fails, drops the row unless
    the header is `optional`, and a value `from_unknown/2` cannot read drops it either way,
    as Prowlarr's parser does. Prowlarr walks on to an earlier header when a filter fails;
    Cinder reads that header as none;
  - `protocol` `:torrent`, `download_url_origin` and `tvdb_id` nil.

  Seeders, leechers, grabs and volume factors are read only as `.Result` values. The page's
  rows then pass `Cinder.Acquisition.Indexer.Newznab.Items.kept/1`.
  """

  alias Cinder.Acquisition.Indexer.Cardigann.{
    Charset,
    DotnetDate,
    Fetch,
    Filters,
    JsonRows,
    Magnet,
    Query,
    Size,
    Template,
    XmlRows
  }

  alias Cinder.Acquisition.Indexer.Newznab.Items
  alias Cinder.Indexers.{ParserWorker, Selector}

  @preprocess_cap Template.output_cap()

  @worker_ms 30_000
  @max_result_rounds 3
  @max_result_selectors 64
  @result_name ~r/\.Result\.([A-Za-z0-9_-]+)/

  @type page :: %{
          rows: [map()],
          count: non_neg_integer(),
          partial: atom() | nil,
          missing: [:title | :download_url]
        }

  @doc """
  Reads `body`, the page `uri` answered to the Fetch `request` (its secrets, credential hosts
  and clock), for `definition` under the search `variables`, with the call's query text
  `query_text` (nil for none), `deadline_at` in `System.monotonic_time(:millisecond)` and the
  search path's `response` record (nil for an HTML page). Answers
  `{:ok, page}`: `rows`, `count` (how many rows the rows selector matched, before the row filter
  and the row rules, which Prowlarr's page loop counts), `partial` (nil, `:regex_limit` or `:filter_output_cap`) and `missing`, the required
  field each row dropped for lack of one lacked first (`:title`, then `:download_url`), in page
  order, for the canary. Or `{:error, reason}`:
  `:parser_failed` for a worker that crashed, ran out of memory or time, or refused a selector;
  `:deadline` for a worker the search deadline cut; `:definition_error` for a selector template
  that does not render; and the JSON and XML readers' own failures, `:invalid_json`,
  `:invalid_xml`, `:xml_dtd` and `:no_results_list`.

  The worker gets 30 s or what is left before `deadline_at`, whichever is less, and
  `[:cinder, :cardigann, :parse]` reports that budget as `deadline_ms` before it starts.
  """
  @spec read(
          binary(),
          map(),
          Template.variables(),
          URI.t(),
          String.t() | nil,
          integer(),
          Fetch.request(),
          map() | nil
        ) ::
          {:ok, page()} | {:error, atom()}
  def read(body, definition, variables, uri, query_text, deadline_at, request, response \\ nil) do
    charset = Charset.of_definition(definition)
    text = Charset.decode(body, charset)

    case values(text, definition, variables, deadline_at, request, response) do
      {:ok, values} ->
        header = if html?(response), do: definition.search.rows.dateheaders
        read_rows(values, definition, variables, uri, query_text, request, charset, header)

      {:error, {:preprocessing, kind}} ->
        {:ok, %{rows: [], count: 0, partial: kind, missing: []}}

      {:error, _reason} = error ->
        error
    end
  end

  # Only the HTML worker walks to a date header; a JSON or XML page reads none.
  defp html?(%{type: type}) when type in ["json", "xml"], do: false
  defp html?(_response), do: true

  defp values(text, definition, variables, _deadline_at, request, %{type: "json"} = response),
    do: JsonRows.values(text, definition, variables, request.now, response)

  defp values(text, definition, variables, _deadline_at, request, %{type: "xml"}) do
    with {:ok, xml} <- preprocess(text, definition, variables, request),
         do: XmlRows.values(xml, definition, variables, request.now)
  end

  defp values(text, definition, variables, deadline_at, request, _html_response) do
    # One parse budget for every worker the page takes, `.Result` rounds included.
    deadlines = {deadline_at, min(System.monotonic_time(:millisecond) + @worker_ms, deadline_at)}

    with {:ok, html} <- preprocess(text, definition, variables, request),
         {:ok, plan} <- plan(definition, variables, request.now),
         :ok <- worker_input(text, [html, plan], request),
         {:ok, rows} <- run(html, plan, deadlines) do
      page = %{html: html, plan: plan, deadlines: deadlines, site: text, request: request}

      result_rounds(
        rows,
        page,
        definition,
        variables,
        request,
        MapSet.new(plan.fields, & &1.name)
      )
    end
  end

  # `search.preprocessingfilters` over the decoded HTML or XML text, under the filter chain's
  # output cap, as Prowlarr's `ParseResponse` runs them before it parses (#1679). A limit reads
  # as a page with no rows and that partial kind, as a field's limit does, so the call goes on;
  # any other failure is `:definition_error`. A text past that cap gets no filter: `BoundedRegex`
  # re-checks the UTF-8 from each match to the text's end, so a regex that matches often takes
  # time that grows with the square of the text's size.
  defp preprocess(text, %{search: %{preprocessingfilters: [_ | _]}}, _variables, _request)
       when byte_size(text) > @preprocess_cap,
       do: {:error, {:preprocessing, :filter_output_cap}}

  defp preprocess(
         text,
         %{search: %{preprocessingfilters: [_ | _] = filters}} = definition,
         variables,
         request
       ) do
    charset = Charset.of_definition(definition)

    case Filters.apply(text, filters, variables, request.now, encoding: charset) do
      {:ok, text} -> {:ok, text}
      {:error, reason} -> preprocessing_failure(Query.failure(reason))
    end
  end

  defp preprocess(text, _definition, _variables, _request), do: {:ok, text}

  defp preprocessing_failure(:definition_error), do: {:error, :definition_error}
  defp preprocessing_failure(kind), do: {:error, {:preprocessing, kind}}

  # --- the worker ---

  defp plan(definition, variables, now) do
    rows = definition.search.rows

    with {:ok, rows_selector} <- render(rows.selector, variables, now),
         {:ok, fields} <- plan_fields(definition.search.fields, variables, now),
         {:ok, dateheader} <- plan_dateheader(rows.dateheaders, variables, now) do
      {:ok,
       %{rows: rows_selector, fields: fields, after: rows.after || 0, dateheader: dateheader}}
    end
  end

  defp plan_dateheader(nil, _variables, _now), do: {:ok, nil}

  defp plan_dateheader(%{selector: nil} = header, _variables, _now),
    do: {:ok, worker_field(:dateheader, nil, header)}

  defp plan_dateheader(header, variables, now) do
    with {:ok, selector} <- render(header.selector, variables, now),
         do: {:ok, worker_field(:dateheader, selector, header)}
  end

  defp worker_field(name, selector, field) do
    %{
      name: name,
      selector: selector,
      attribute: field.attribute,
      remove: List.wrap(field.remove),
      case: Enum.map(field.case || [], &elem(&1, 0))
    }
  end

  defp plan_fields(fields, variables, now) do
    fields
    |> Enum.reject(fn {_name, field} ->
      field.text != nil or field.selector == nil or result_selector?(field)
    end)
    |> Enum.reduce_while({:ok, []}, fn {name, field}, {:ok, acc} ->
      case render(field.selector, variables, now) do
        {:ok, selector} ->
          {:cont, {:ok, [worker_field(name, selector, field) | acc]}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  defp render(nil, _variables, _now), do: {:error, :definition_error}

  defp render(template, variables, now) do
    case Template.render(template, variables, now) do
      {:ok, text} -> {:ok, text}
      {:error, _reason} -> {:error, :definition_error}
    end
  end

  # A preprocessing filter or a selector template can write a secret setting's value into the
  # worker's input; that fails the page as a definition error.
  defp worker_input(site, input, request) do
    if Fetch.worker_secret?(site, input, request), do: {:error, :definition_error}, else: :ok
  end

  # `deadline_at` is the search's, `page_at` the page's parse budget, never later than it. A
  # worker the search deadline cuts is `:deadline`; one the page budget cuts `:parser_failed`.
  defp run(html, plan, {deadline_at, page_at}) do
    left_ms = page_at - System.monotonic_time(:millisecond)

    if left_ms <= 0 do
      {:error, if(page_at == deadline_at, do: :deadline, else: :parser_failed)}
    else
      worker_ms = min(@worker_ms, left_ms)
      :telemetry.execute([:cinder, :cardigann, :parse], %{deadline_ms: worker_ms}, %{})

      case ParserWorker.run(html, plan, deadline_ms: worker_ms) do
        {:ok, rows} -> {:ok, rows}
        {:error, :timeout} when page_at == deadline_at -> {:error, :deadline}
        {:error, _failure} -> {:error, :parser_failed}
      end
    end
  end

  # --- selectors that read `.Result` ---

  @doc """
  Whether `field`'s selector template reads an earlier field's value (`.Result.<name>`), as
  keepfriends' and pterclub's do (#1679): such a field is planned per row after the fields
  before it, in a later worker round on the same page (`result_rounds/6`).
  """
  @spec result_selector?(map()) :: boolean()
  def result_selector?(%{text: nil, selector: selector}) when is_binary(selector),
    do: Regex.match?(@result_name, selector)

  def result_selector?(_field), do: false

  @doc """
  How many worker rounds after the first `fields` take, by `result_rounds/6`'s rule, or
  `:too_many` past `max_result_rounds/0`. `Cinder.Indexers.Definitions.LoadCheck` reads it.
  """
  @spec result_rounds([{String.t(), map()}]) :: non_neg_integer() | :too_many
  def result_rounds(fields), do: count_rounds(fields, done_names(fields), 0)

  defp count_rounds(fields, done, rounds) do
    case pending(fields, done) do
      [] -> rounds
      _pending when rounds >= @max_result_rounds -> :too_many
      pending -> count_rounds(fields, MapSet.union(done, plannable(fields, pending)), rounds + 1)
    end
  end

  @doc "The most worker rounds a page takes after its first for `.Result` selectors."
  @spec max_result_rounds() :: pos_integer()
  def max_result_rounds, do: @max_result_rounds

  @doc "The most distinct renderings one `.Result` selector may take on one page."
  @spec max_result_selectors() :: pos_integer()
  def max_result_selectors, do: @max_result_selectors

  defp done_names(fields),
    do: for({name, field} <- fields, not result_selector?(field), into: MapSet.new(), do: name)

  defp pending(fields, done),
    do: for({name, field} <- fields, result_selector?(field), name not in done, do: name)

  # The pending fields this round plans: the first, and each later one whose selector reads
  # only fields before the first, or fields after itself, which read nil there as a later
  # field's value reads nil when Cinder renders a template of the row.
  defp plannable(fields, [first | _] = pending) do
    at = fields |> Enum.with_index() |> Map.new(fn {{name, _field}, i} -> {name, i} end)
    by_name = Map.new(fields)

    for name <- pending,
        Enum.all?(read_names(by_name[name].selector), fn read ->
          read_at = Map.get(at, read)
          read_at == nil or read_at < at[first] or read_at >= at[name]
        end),
        into: MapSet.new(),
        do: name
  end

  defp read_names(selector),
    do: for([_whole, name] <- Regex.scan(@result_name, selector), uniq: true, do: name)

  # Each round renders the planned fields' selectors per row, with that row's values of the
  # fields before the first pending one, gates each distinct rendering with
  # `Cinder.Indexers.Selector.compile/2`, and asks one more worker for those selectors on the
  # same page, with the same rows and merge. A row whose rendering fails, or that the gate or
  # lexbor refuses, reads nil for that field. A field with more than `max_result_selectors/0`
  # renderings, a chain past `max_result_rounds/0` rounds, or a round whose row count differs from
  # the first's, is an error.
  defp result_rounds(rows, page, definition, variables, request, done, round \\ 1) do
    fields = definition.search.fields

    case pending(fields, done) do
      [] ->
        {:ok, rows}

      _pending when round > @max_result_rounds ->
        {:error, :definition_error}

      [first | _] = pending ->
        planned = plannable(fields, pending)
        by_name = Map.new(fields)
        names = Enum.filter(pending, &MapSet.member?(planned, &1))
        prefix = Enum.take_while(fields, fn {name, _field} -> name != first end)
        charset = Charset.of_definition(definition)
        seeded = seeded(variables, fields)

        rendered =
          Enum.map(rows, fn row ->
            vars = row_vars(prefix, row, seeded, request.now, charset)
            Map.new(names, &{&1, rendered_selector(by_name[&1].selector, vars, request.now)})
          end)

        with {:ok, distinct} <- distinct_selectors(rendered, names),
             {:ok, answers} <- round_answers(distinct, by_name, page, length(rows)) do
          result_rounds(
            merge_round(rows, rendered, answers, names, distinct),
            page,
            definition,
            variables,
            request,
            MapSet.union(done, planned),
            round + 1
          )
        end
    end
  end

  defp row_vars(prefix, row, seeded, now, charset) do
    case fields(prefix, Map.new(row), seeded, now, charset) do
      {:ok, vars} -> vars
      {:dropped, _kind} -> nil
    end
  end

  defp merge_round(rows, rendered, answers, names, distinct) do
    [rows, rendered, answers]
    |> Enum.zip()
    |> Enum.map(fn {row, selectors, answer} ->
      row ++ Enum.map(names, &{&1, round_value(&1, selectors[&1], distinct, answer)})
    end)
  end

  defp seeded(variables, fields),
    do: Map.merge(variables, Map.new(fields, fn {name, _field} -> {".Result." <> name, nil} end))

  defp rendered_selector(_template, nil, _now), do: nil

  defp rendered_selector(template, vars, now) do
    with {:ok, selector} <- Template.render(template, vars, now),
         {:ok, _compiled} <- Selector.compile(selector, "gate"),
         do: selector,
         else: (_failed -> nil)
  end

  defp distinct_selectors(rendered, names) do
    distinct =
      Map.new(names, fn name ->
        selectors = rendered |> Enum.map(& &1[name]) |> Enum.reject(&is_nil/1) |> Enum.uniq()
        {name, selectors |> Enum.with_index() |> Map.new()}
      end)

    if Enum.any?(distinct, fn {_name, selectors} ->
         map_size(selectors) > @max_result_selectors
       end),
       do: {:error, :definition_error},
       else: {:ok, distinct}
  end

  defp round_answers(distinct, by_name, page, count) do
    round_fields =
      for {name, selectors} <- distinct,
          {selector, j} <- selectors,
          do: worker_field({name, j}, selector, by_name[name])

    if round_fields == [] do
      {:ok, List.duplicate(%{}, count)}
    else
      plan = %{rows: page.plan.rows, fields: round_fields, after: page.plan.after, lenient: true}

      with :ok <- worker_input(page.site, plan, page.request),
           {:ok, answers} <- run(page.html, plan, page.deadlines) do
        round_rows(answers, count)
      end
    end
  end

  defp round_rows(answers, count) when length(answers) == count,
    do: {:ok, Enum.map(answers, &Map.new/1)}

  defp round_rows(_answers, _count), do: {:error, :parser_failed}

  defp round_value(_name, nil, _distinct, _answer), do: nil
  defp round_value(name, selector, distinct, answer), do: answer[{name, distinct[name][selector]}]

  # --- the fields ---

  defp read_rows(values, definition, variables, uri, query_text, request, charset, header) do
    now = request.now
    fields = definition.search.fields

    seeded = seeded(variables, fields)
    andmatch? = andmatch?(definition, query_text)
    mappings = Query.mappings(definition)
    private? = definition.type == "private"

    one_row = fn results, worker_values ->
      with true <- keep?(results, andmatch?, query_text),
           %{} = release <- row(results, uri, mappings, private?, request) do
        dated(release, header, worker_values[:dateheader], results, now, charset)
      end
    end

    {rows, missing, partial} =
      Enum.reduce(values, {[], [], nil}, fn row_values, {rows, missing, partial} ->
        worker_values = Map.new(row_values)

        case fields(fields, worker_values, seeded, now, charset) do
          {:ok, results} -> {rows, missing, partial} |> add_row(one_row.(results, worker_values))
          {:dropped, kind} -> {rows, missing, partial || kind}
        end
      end)

    {:ok,
     %{
       rows: rows |> Enum.reverse() |> Items.kept(),
       count: length(values),
       partial: partial,
       missing: Enum.reverse(missing)
     }}
  end

  # `dateheaders` (#1679): a release whose date reads nil takes the date of the header the
  # worker found before its row, through the block's own text, `case`, filters and
  # `DotnetDate.from_unknown/2`, as Prowlarr's `ParseResponse` does after the row filters. No
  # header drops the row unless the block is `optional`; a header whose date does not parse
  # drops it either way, as Prowlarr's exception does. A filter that fails reads as no header,
  # where Prowlarr walks on to the next candidate. A limit drops the row with its kind.
  defp dated(release, nil, _worker_value, _results, _now, _charset), do: release

  defp dated(%{published_at: %DateTime{}} = release, _header, _value, _results, _now, _charset),
    do: release

  defp dated(release, header, worker_value, results, now, charset) do
    case field_value(%{header | optional: false}, worker_value, results, now, charset) do
      {:ok, nil} ->
        if header.optional, do: release, else: false

      {:ok, value} ->
        header_dated(release, value, now)

      {:dropped, kind} ->
        {:dropped, kind}
    end
  end

  defp header_dated(release, value, now) do
    case DotnetDate.from_unknown(value, now) do
      {:ok, time} -> %{release | published_at: time}
      :error -> false
    end
  end

  # A row andmatch or its date header drops, one missing a required field, or a release row.
  defp add_row(acc, false), do: acc

  defp add_row({rows, missing, partial}, {:dropped, kind}), do: {rows, missing, partial || kind}

  defp add_row({rows, missing, partial}, {:missing, field}),
    do: {rows, [field | missing], partial}

  defp add_row({rows, missing, partial}, row), do: {[row | rows], missing, partial}

  defp fields(fields, worker_values, variables, now, charset) do
    Enum.reduce_while(fields, {:ok, variables}, fn {name, field}, {:ok, vars} ->
      case field_value(field, Map.get(worker_values, name), vars, now, charset) do
        {:ok, value} -> {:cont, {:ok, Map.put(vars, ".Result." <> name, value)}}
        {:dropped, kind} -> {:halt, {:dropped, kind}}
      end
    end)
  end

  # `{:ok, value}`, value nil for a field that failed or stayed blank, or `{:dropped, kind}`.
  defp field_value(field, worker_value, vars, now, charset) do
    with {:ok, raw} <- found(field, raw(field, worker_value, vars, now)),
         {:ok, value} <- defaulted(field, raw, vars, now) do
      filtered(field, value, vars, now, charset)
    else
      :none -> {:ok, nil}
      {:dropped, kind} -> {:dropped, kind}
    end
  end

  defp raw(%{text: text}, _worker_value, vars, now) when is_binary(text),
    do: template(text, vars, now)

  defp raw(%{case: [_ | _] = cases}, {:case, selector}, vars, now) do
    case List.keyfind(cases, selector, 0) do
      {^selector, value} -> template(value || "", vars, now)
      nil -> :missing
    end
  end

  defp raw(_field, value, _vars, _now) when is_binary(value), do: {:ok, String.trim(value)}
  defp raw(_field, _value, _vars, _now), do: :missing

  # A selector that matched nothing, or a `case` with no key that matched: an optional field
  # goes on blank to its default, any other fails, as Prowlarr's `HandleSelector` throws.
  defp found(%{optional: true}, :missing), do: {:ok, ""}
  defp found(_field, :missing), do: :none
  defp found(_field, raw), do: raw

  # A template's text, `:none` when it fails, or `{:dropped, kind}` for a limit.
  defp template(text, vars, now) do
    case Template.render(text, vars, now) do
      {:ok, value} -> {:ok, value}
      {:error, kind} when kind in [:regex_limit, :filter_output_cap] -> {:dropped, kind}
      {:error, _reason} -> :none
    end
  end

  defp defaulted(%{optional: true} = field, raw, vars, now) do
    cond do
      not blank?(raw) ->
        {:ok, raw}

      field.default == nil ->
        :none

      true ->
        field.default |> template(vars, now) |> rendered_default()
    end
  end

  defp defaulted(_field, raw, _vars, _now), do: {:ok, raw}

  defp rendered_default({:ok, default}), do: if(blank?(default), do: :none, else: {:ok, default})
  defp rendered_default(other), do: other

  defp filtered(field, value, vars, now, charset) do
    case Filters.apply(value, field.filters || [], vars, now, encoding: charset) do
      {:ok, filtered} -> {:ok, filtered}
      {:error, kind} when kind in [:regex_limit, :filter_output_cap] -> {:dropped, kind}
      {:error, _reason} -> {:ok, nil}
    end
  end

  defp blank?(value), do: value == nil or String.trim(value) == ""

  # --- the row ---

  defp andmatch?(definition, query_text) do
    filters = definition.search.rows.filters || []

    Enum.any?(filters, &(&1.name == "andmatch")) and is_binary(query_text) and
      String.trim(query_text) != ""
  end

  defp keep?(_results, false, _query_text), do: true

  defp keep?(results, true, query_text),
    do: Filters.andmatch?(query_text, results[".Result.title"], results[".Result.description"])

  defp row(results, uri, mappings, private?, request) do
    title = Items.row_title(results[".Result.title"])
    link = link(results, uri, title, private?)

    cond do
      title == nil -> {:missing, :title}
      link == nil or Fetch.secret_link?(link, request) -> {:missing, :download_url}
      true -> release(title, link, results, mappings, request.now)
    end
  end

  defp release(title, link, results, mappings, now) do
    %{
      title: title,
      download_url: link,
      download_url_origin: nil,
      protocol: :torrent,
      size: size(results[".Result.size"]),
      category_ids: category_ids(results[".Result.category"], mappings),
      published_at: published_at(results[".Result.date"], now),
      tvdb_id: nil
    }
  end

  defp link(results, uri, title, private?) do
    download_link(results[".Result.download"], uri) || magnet(results[".Result.magnet"]) ||
      infohash_magnet(results[".Result.infohash"], title, private?)
  end

  defp download_link(value, uri) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" -> nil
      String.starts_with?(value, "magnet:") -> value
      true -> resolved(uri, value)
    end
  end

  defp download_link(_value, _uri), do: nil

  defp resolved(uri, value) do
    with {:ok, _ref} <- URI.new(value),
         %URI{scheme: scheme, host: host} = merged
         when scheme in ["http", "https"] and is_binary(host) and host != "" <-
           URI.merge(uri, value) do
      URI.to_string(merged)
    else
      _invalid -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp magnet(value) when is_binary(value) do
    value = String.trim(value)
    if String.starts_with?(value, "magnet:"), do: value
  end

  defp magnet(_value), do: nil

  defp infohash_magnet(_hash, _title, true = _private?), do: nil
  defp infohash_magnet(_hash, nil, _private?), do: nil

  defp infohash_magnet(hash, title, false) when is_binary(hash),
    do: Magnet.from_infohash(hash, title)

  defp infohash_magnet(_hash, _title, _private?), do: nil

  defp size(value) when is_binary(value), do: Size.bytes(value)
  defp size(_value), do: nil

  defp category_ids(value, mappings) when is_binary(value) do
    parts = value |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    ids =
      for part <- parts,
          {site_id, standard} <- mappings,
          String.downcase(site_id) == String.downcase(part),
          uniq: true,
          do: standard

    if ids == [], do: nil, else: ids
  end

  defp category_ids(_value, _mappings), do: nil

  defp published_at(value, now) when is_binary(value) do
    case DotnetDate.from_unknown(value, now) do
      {:ok, time} -> time
      :error -> nil
    end
  end

  defp published_at(_value, _now), do: nil
end
