defmodule Cinder.Acquisition.Indexer.Cardigann do
  @moduledoc """
  The Cardigann adapter of `Cinder.Acquisition.Indexer` (#1671): Cardigann slice (a), the HTML
  search of a definition with no login, as Nyaa.si and Torrent9 use it. Its `fetch_download/3`
  is `Cinder.Acquisition.Indexer.Cardigann.Grab`'s (#1672).

  ## Which copy runs

  Each search and Test reads the configured indexer's running copy
  (`Cinder.Indexers.Definitions.running_copy/1`) and runs it only when its stored load result
  under the current loader fingerprint is `:loads`. Otherwise the indexer is not asked, with
  `{:not_asked, {:not_supported, feature}}`, and no request:

  - the first code of a copy that reads not supported, as `report_feature/1` gives it;
  - `:definition_unchecked` for a copy the boot re-check has not checked under this loader;
  - `:definition_fails` for a copy that no longer loads;
  - `:definition_missing` for an indexer with no pin.

  ## A search

  `Cinder.Acquisition.Indexer.Cardigann.Query` plans the call's queries, in order. For each one:

  - a query whose keyword filters hit a regex limit or the filter-chain cap sends nothing, and
    one whose templates fail sends nothing either (`:definition_error`). The others still run;
  - a query whose every search path its categories skip sends nothing and reads as not asked
    for its caps (#1679);
  - otherwise its search paths go out in order, each request, a GET or a POST
    (`Cinder.Acquisition.Indexer.Cardigann.Query`'s "Paths"), holding the indexer's slot
    (`Cinder.Acquisition.Indexer.leased/4`) with the definition's `requestDelay` as the slot's
    spacing when it is above 2 s (at most 60 s), and its redirect hops inside the same slot
    (`Cinder.Acquisition.Indexer.Cardigann.Fetch`). The page is read inside the slot too
    (`Cinder.Acquisition.Indexer.Cardigann.Rows`), so its answer is recorded before the slot
    frees. The loop stops after a page with fewer rows than the first page, counted before the
    row filter, and after a first page with none, as Prowlarr's `IsFullPage` does;
  - its rows are tagged with its origin and capped at 1,000 across its pages.

  Each answer is recorded in `Cinder.Acquisition.IndexerSource.Native.IndexerStatus`: `:success`
  for a page that reads, then the page's partial kind when a field or a preprocessing filter
  hit a limit; the failure
  class or tag otherwise. A keyword-filter limit is recorded as its partial kind and a
  `:definition_error` as a failure.

  The outcome follows `Cinder.Acquisition.Indexer.Newznab`'s rules: `:asked` when every query
  answered; a request that fails stops the call, keeps the rows of the paths that answered and
  fails the indexer with its reason; a query that fails before a request (a limit or
  `:definition_error`) or a page that hit a limit fails the indexer with that reason and the
  call goes on; a deadline cut or a backoff skip after an answer keeps `:asked`.

  ## The Test

  `test/3` sends the first request of a keywordless search with no category
  (`Query.test_plan/3`), as Prowlarr's `TestConnection` does, and records `:test_success` when
  its page gives at least one row that passes the row rules; when it gives none, the partial
  kind when a field hit a limit (`:regex_limit` or `:filter_output_cap`), else `:no_rows`; or
  the failure (a deadline cut reads `:timeout`).
  """

  @behaviour Cinder.Acquisition.Indexer

  alias Cinder.Acquisition.Indexer
  alias Cinder.Acquisition.Indexer.Cardigann.{Charset, Fetch, Query, Rows, Variables}
  alias Cinder.Acquisition.Indexer.Newznab.Items
  alias Cinder.Acquisition.Indexer.NewznabAnswer
  alias Cinder.Acquisition.IndexerSource.Native
  alias Cinder.Acquisition.IndexerSource.Native.IndexerStatus
  alias Cinder.Acquisition.IndexerSource.Report
  alias Cinder.HTTPPolicy
  alias Cinder.Indexers.CardigannSettings
  alias Cinder.Indexers.ConfiguredIndexer
  alias Cinder.Indexers.Definitions
  alias Cinder.Indexers.Definitions.CredentialHosts

  # The longest slot spacing a `requestDelay` sets, so a large one cannot arm a lease timer
  # past what `Process.send_after/3` takes.
  @max_delay_ms 60_000

  @doc """
  A loader code as the report carries it: an atom as it is, a tuple of atoms as it is, and a
  tuple that holds a name (`{:filter, "tolower"}`) as its first atom (`:filter`), since the
  report's features are atoms and no name becomes one at run time.
  """
  @spec report_feature(term()) :: Report.feature()
  def report_feature(code) when is_atom(code), do: code

  def report_feature(code) when is_tuple(code) and tuple_size(code) > 0 do
    if code |> Tuple.to_list() |> Enum.all?(&is_atom/1), do: code, else: elem(code, 0)
  end

  @doc "Fetches a grab's link through `Cinder.Acquisition.Indexer.Cardigann.Grab`."
  @impl Indexer
  defdelegate fetch_download(indexer, url, opts), to: Cinder.Acquisition.Indexer.Cardigann.Grab

  # --- the copy ---

  @doc """
  The running copy of `indexer` as a search and a grab run it, or `{:not_supported, feature}`
  as the moduledoc's "Which copy runs" lists.
  """
  @spec copy(ConfiguredIndexer.t()) :: {:ok, map()} | {:not_supported, Report.feature()}
  def copy(%ConfiguredIndexer{} = indexer) do
    case Definitions.running_copy(indexer.id) do
      {:ok, %{result: :loads, definition: definition}} -> {:ok, running(indexer, definition)}
      {:ok, %{result: {:not_supported, [code | _]}}} -> {:not_supported, report_feature(code)}
      {:ok, %{result: :unchecked}} -> {:not_supported, :definition_unchecked}
      {:ok, %{result: _fails}} -> {:not_supported, :definition_fails}
      {:error, :fails} -> {:not_supported, :definition_fails}
      {:error, :no_pin} -> {:not_supported, :definition_missing}
    end
  end

  defp running(indexer, definition) do
    plain = indexer.settings || %{}
    secrets = indexer.secrets || %{}
    base_url = CredentialHosts.effective_base_url(definition, indexer.base_url)
    secret_values = secret_values(definition, secrets)

    %{
      definition: definition,
      config: %{
        base_url: HTTPPolicy.without_fragment(base_url),
        values: Map.merge(plain, secrets)
      },
      request: fn context, now ->
        %{
          context: context,
          follow_redirects?: definition.followredirect == true,
          secrets: Map.values(secret_values),
          secret_referenced?: referenced?(search_texts(definition.search), secret_values),
          link_secret_referenced?: referenced?(field_texts(definition.search), secret_values),
          download_secret_referenced?:
            referenced?(Variables.download_texts(definition.download), secret_values),
          credential_hosts:
            CredentialHosts.hosts(definition, %{
              stored_url: indexer.base_url,
              settings: Map.merge(plain, secrets)
            }),
          now: now,
          charset: Charset.of_definition(definition),
          certificate_pins: Fetch.certificate_pins(definition, base_url)
        }
      end,
      delay_ms: delay_ms(definition.request_delay)
    }
  end

  # The stored secrets of declared settings that are not blank and differ from the copy's
  # default (`Cinder.Indexers.Definitions.Hold`'s rule), by key.
  defp secret_values(definition, secrets) do
    declared = MapSet.new(definition.settings || [], & &1.name)

    for {key, value} <- secrets,
        is_binary(value),
        String.trim(value) != "",
        MapSet.member?(declared, key),
        value != CardigannSettings.default(definition, key),
        into: %{},
        do: {key, value}
  end

  # Whether any of `texts`, a definition's templates, reads one of the secret settings.
  defp referenced?(texts, secret_values) do
    Enum.any?(Map.keys(secret_values), fn key ->
      pattern = Regex.compile!("\\.Config\\." <> Regex.escape(key) <> "(?![A-Za-z0-9_-])")
      Enum.any?(texts, &Regex.match?(pattern, &1))
    end)
  end

  defp search_texts(search) do
    paths =
      for path <- search.paths || [], text <- [path.path | input_texts(path.inputs)], do: text

    filters =
      for filter <- search.keywordsfilters || [], arg <- List.wrap(filter.args), do: arg

    Enum.filter(paths ++ input_texts(search.inputs) ++ filters, &is_binary/1)
  end

  defp input_texts(inputs), do: for({_key, value} <- inputs || [], do: value)

  # The templates of the row fields and the preprocessing filters: a template that reads a
  # secret can put it in a row's link, and a preprocessing filter can write it into the page.
  defp field_texts(search) do
    preprocessing =
      for filter <- search.preprocessingfilters || [], arg <- List.wrap(filter.args), do: arg

    texts =
      for {_name, field} <- search.fields,
          text <-
            [field.text, field.default] ++
              for({_key, value} <- field.case || [], do: value) ++
              for(filter <- field.filters || [], arg <- List.wrap(filter.args), do: arg),
          do: text

    Enum.filter(preprocessing ++ texts, &is_binary/1)
  end

  defp delay_ms(delay) when is_number(delay) and delay > 2,
    do: min(round(delay * 1000), @max_delay_ms)

  defp delay_ms(_delay), do: 0

  # --- the search ---

  @doc "Searches `indexer` for `query`; see the moduledoc."
  @impl Indexer
  @spec search(ConfiguredIndexer.t(), Indexer.query(), Indexer.context()) ::
          {[map()], Report.outcome() | {:failed, :deadline}}
  def search(%ConfiguredIndexer{} = indexer, query, context) do
    with {:ok, copy} <- copy(indexer),
         {:ok, entries} <- Query.plan(copy.definition, copy.config, query, now()) do
      send_queries(indexer, copy, entries, context)
    else
      {:not_supported, feature} -> {[], {:not_asked, {:not_supported, feature}}}
      {:not_asked, :caps} -> {[], {:not_asked, :caps}}
    end
  end

  defp send_queries(indexer, copy, entries, context) do
    {row_lists, answered?, query_error, stop} =
      Enum.reduce_while(entries, {[], false, nil, nil}, fn entry,
                                                           {lists, answered?, error, nil} ->
        case send_query(indexer, copy, entry, context) do
          {:ok, rows, partial} ->
            {:cont, {[rows | lists], true, error || partial, nil}}

          {:query_error, kind} ->
            {:cont, {lists, answered?, error || kind, nil}}

          {:stop, rows, stop, page_answered?} ->
            {:halt, {[rows | lists], answered? or page_answered?, error, stop}}
        end
      end)

    rows = row_lists |> Enum.reverse() |> Enum.concat()
    {rows, outcome(query_error, stop, answered?)}
  end

  # A query that fails before any request: a limit records its partial kind, a template failure
  # a failure.
  defp send_query(indexer, _copy, {:error, kind}, _context) do
    IndexerStatus.record(indexer, kind, now())
    {:query_error, kind}
  end

  defp send_query(indexer, copy, {:ok, planned}, context) do
    case pages(indexer, copy, planned, context, planned.pages, nil, []) do
      {:ok, rows, partial} -> {:ok, tagged(rows, planned), partial}
      {:stop, rows, stop, answered?} -> {:stop, tagged(rows, planned), stop, answered?}
    end
  end

  defp tagged(rows, planned) do
    rows
    |> Enum.take(Items.max_rows())
    |> Enum.map(&Map.put(&1, :query_origins, [planned.origin]))
  end

  # The page loop: `first` is the first page's row count, nil before it.
  defp pages(_indexer, _copy, _planned, _context, [], _first, acc), do: finished(acc)

  defp pages(indexer, copy, planned, context, [page | rest], first, acc) do
    case page(indexer, copy, planned, page, context) do
      {:ok, page} ->
        acc = [page | acc]
        first = first || page.count

        if first == 0 or page.count < first,
          do: finished(acc),
          else: pages(indexer, copy, planned, context, rest, first, acc)

      {:error, stop} ->
        {:stop, acc |> Enum.reverse() |> Enum.flat_map(& &1.rows), stop, acc != []}
    end
  end

  defp finished(acc) do
    pages = Enum.reverse(acc)
    {:ok, Enum.flat_map(pages, & &1.rows), Enum.find_value(pages, & &1.partial)}
  end

  # One search request in the indexer's slot: the page, or the stop it gives.
  defp page(indexer, copy, planned, page, context) do
    fun = fn -> read_page(indexer, copy, planned, page, context) end

    case Indexer.leased(indexer, context, fun, delay_ms: copy.delay_ms) do
      {:ran, answer} -> answer
      {:not_run, {:skipped, :deadline}} -> {:error, :deadline}
      not_run -> {:error, not_run}
    end
  end

  defp read_page(indexer, copy, planned, page, context) do
    now = now()
    request = copy.request.(context, now)

    with {:ok, body, uri} <- Fetch.send_page(page, request),
         {:ok, page} <-
           Rows.read(
             body,
             copy.definition,
             page.variables,
             uri,
             planned.andmatch,
             context.deadline_at,
             request,
             page.response
           ) do
      IndexerStatus.record(indexer, :success, now)
      if page.partial, do: IndexerStatus.record(indexer, page.partial, now)
      {:ok, page}
    else
      {:error, class} -> {:error, recorded(indexer, class, now)}
    end
  end

  # Records `class` and answers it with a limit's wait ended as the status ends it.
  defp recorded(indexer, class, now) do
    IndexerStatus.record(indexer, class, now)

    case class do
      {:limit, wait} -> {:limit, NewznabAnswer.limit_until(wait, now)}
      class -> class
    end
  end

  # An indexer that answered was asked: a later query the deadline cut, or a backoff skip, keeps
  # the rows and `:asked`. Rejected credentials still win. As `Newznab`'s outcome.
  defp outcome(nil, stop, true = _answered) do
    if cut?(stop), do: :asked, else: outcome(nil, stop)
  end

  defp outcome(query_error, stop, _answered), do: outcome(query_error, stop)

  defp cut?(:deadline), do: true
  defp cut?({:not_run, {:skipped, _reason}}), do: true
  defp cut?(_stop), do: false

  defp outcome(nil, {:not_run, outcome}), do: outcome
  defp outcome(_query_error, {:not_run, {:failed, _reason} = outcome}), do: outcome
  defp outcome(query_error, {:not_run, {:skipped, _reason}}), do: failed(query_error)
  defp outcome(nil, nil), do: :asked
  defp outcome(query_error, :deadline) when query_error != nil, do: failed(query_error)
  defp outcome(query_error, nil), do: failed(query_error)
  defp outcome(_query_error, stop), do: failed(stop)

  defp failed(class), do: {:failed, NewznabAnswer.reason(class)}

  # --- the Test ---

  @doc "The per-indexer Test of `indexer` (#1657); see the moduledoc."
  @impl Indexer
  @spec test(ConfiguredIndexer.t(), Indexer.context(), (IndexerStatus.answer() -> value)) ::
          {:ran, value} | {:not_run, Report.outcome()}
        when value: term()
  def test(%ConfiguredIndexer{} = indexer, context, record) do
    with {:ok, copy} <- copy(indexer),
         {:ok, page, _variables} <- Query.test_plan(copy.definition, copy.config, now()) do
      fun = fn -> record.(test_answer(copy, page, context)) end
      Indexer.leased(indexer, context, fun, gate: false, delay_ms: copy.delay_ms)
    else
      {:not_supported, feature} -> {:not_run, {:not_asked, {:not_supported, feature}}}
      {:error, reason} -> {:ran, record.(reason)}
    end
  end

  defp test_answer(copy, test_page, context) do
    request = copy.request.(context, now())

    with {:ok, body, uri} <- Fetch.send_page(test_page, request),
         {:ok, page} <-
           Rows.read(
             body,
             copy.definition,
             test_page.variables,
             uri,
             nil,
             context.deadline_at,
             request,
             test_page.response
           ) do
      cond do
        page.rows != [] -> :test_success
        page.partial != nil -> page.partial
        true -> :no_rows
      end
    else
      {:error, :deadline} -> :timeout
      {:error, class} -> class
    end
  end

  defp now, do: Native.now()
end
