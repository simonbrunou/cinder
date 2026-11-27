defmodule Cinder.Acquisition.Indexer.Cardigann do
  @moduledoc """
  The Cardigann adapter of `Cinder.Acquisition.Indexer` (#1671): Cardigann slice (a), the HTML
  search of a definition, as Nyaa.si and Torrent9 use it, under the definition's login when it
  has one (#1680). Its `fetch_download/3` is `Cinder.Acquisition.Indexer.Cardigann.Grab`'s
  (#1672).

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

  ## The login (#1680)

  For a definition with a `login` block, one `Cinder.Acquisition.Indexer.Cardigann.Session`
  runs through the call's queries and pages: its first request reads the stored cookie row or
  logs in first, and each page goes out with the session's cookies. A page answer that shows a
  login sign (`Cinder.Acquisition.Indexer.Cardigann.Login.sign/4`) is never read or recorded as
  a page: the session logs in once and sends the page once more, and a second sign is rejected
  credentials, `{:rejected_credentials, {:login_rejected, method}}`. Each login request holds
  the slot as a page does, the gate and the spacing included, and the login's answer is
  recorded inside its hold. A refused login, or a login failure, ends the call as a request
  failure does.

  ## The Test

  `test/3` sends the first request of a keywordless search with no category
  (`Query.test_plan/3`), as Prowlarr's `TestConnection` does, and records `:test_success` when
  its page gives at least one row that passes the row rules; when it gives none, the partial
  kind when a field hit a limit (`:regex_limit` or `:filter_output_cap`), else `:no_rows`; or
  the failure (a deadline cut reads `:timeout`). Under a login it runs the same session, with
  the gate off, so a Test runs while the indexer's credentials read rejected, and its one
  answer, a login's included, is recorded once at its end.
  """

  @behaviour Cinder.Acquisition.Indexer

  alias Cinder.Acquisition.Indexer
  alias Cinder.Acquisition.Indexer.Cardigann.{Charset, Fetch, Query, Rows, Session, Variables}
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

  @doc """
  The not-supported codes `copy/1` answers for a copy that does not run, besides a copy's own
  first code: as the moduledoc's "Which copy runs" lists them.
  """
  @spec copy_codes() :: [atom()]
  def copy_codes, do: [:definition_unchecked, :definition_fails, :definition_missing]

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
    start = {[], false, nil, nil, Session.start(copy)}

    {row_lists, answered?, query_error, stop, _session} =
      Enum.reduce_while(entries, start, fn entry, {lists, answered?, error, nil, session} ->
        case send_query(indexer, copy, entry, context, session) do
          {:ok, rows, partial, session} ->
            {:cont, {[rows | lists], true, error || partial, nil, session}}

          {:query_error, kind} ->
            {:cont, {lists, answered?, error || kind, nil, session}}

          {:stop, rows, stop, page_answered?} ->
            {:halt, {[rows | lists], answered? or page_answered?, error, stop, session}}
        end
      end)

    rows = row_lists |> Enum.reverse() |> Enum.concat()
    {rows, outcome(query_error, stop, answered?)}
  end

  # A query that fails before any request: a limit records its partial kind, a template failure
  # a failure.
  defp send_query(indexer, _copy, {:error, kind}, _context, _session) do
    IndexerStatus.record(indexer, kind, now())
    {:query_error, kind}
  end

  defp send_query(indexer, copy, {:ok, planned}, context, session) do
    case pages(indexer, copy, planned, context, {planned.pages, session}, nil, []) do
      {:ok, rows, partial, session} -> {:ok, tagged(rows, planned), partial, session}
      {:stop, rows, stop, answered?} -> {:stop, tagged(rows, planned), stop, answered?}
    end
  end

  defp tagged(rows, planned) do
    rows
    |> Enum.take(Items.max_rows())
    |> Enum.map(&Map.put(&1, :query_origins, [planned.origin]))
  end

  # The page loop: `first` is the first page's row count, nil before it; the session (nil for a
  # definition with no login) goes from page to page.
  defp pages(_indexer, _copy, _planned, _context, {[], session}, _first, acc),
    do: finished(acc, session)

  defp pages(indexer, copy, planned, context, {[page | rest], session}, first, acc) do
    case page(indexer, copy, planned, page, context, session) do
      {:ok, page, session} ->
        acc = [page | acc]
        first = first || page.count

        if first == 0 or page.count < first,
          do: finished(acc, session),
          else: pages(indexer, copy, planned, context, {rest, session}, first, acc)

      {:error, stop} ->
        {:stop, acc |> Enum.reverse() |> Enum.flat_map(& &1.rows), stop, acc != []}
    end
  end

  defp finished(acc, session) do
    pages = Enum.reverse(acc)
    {:ok, Enum.flat_map(pages, & &1.rows), Enum.find_value(pages, & &1.partial), session}
  end

  # One search request in the indexer's slot: the page, or the stop it gives. A definition with
  # a login sends it under its session (`Cinder.Acquisition.Indexer.Cardigann.Session`).
  defp page(indexer, copy, planned, page, context, nil) do
    fun = fn ->
      now = now()
      request = copy.request.(context, now)

      page
      |> Fetch.send_page(request)
      |> fetched()
      |> read_answer({indexer, copy, planned, page, context}, request, now)
    end

    case Indexer.leased(indexer, context, fun, delay_ms: copy.delay_ms) do
      {:ran, {:ok, page}} -> {:ok, page, nil}
      {:ran, {:error, _stop} = stop} -> stop
      not_run -> not_run_stop(not_run)
    end
  end

  defp page(indexer, copy, planned, page, context, session) do
    run = %{
      indexer: indexer,
      copy: copy,
      context: context,
      hold: &Indexer.leased(indexer, context, &1, delay_ms: copy.delay_ms),
      record?: true
    }

    finish = &read_answer(&1, {indexer, copy, planned, page, context}, &2, &3)

    case Session.exchange(run, page, session, finish) do
      {:ok, page, session} -> {:ok, page, session}
      {:error, stop} -> {:error, stop}
      {:not_run, outcome} -> not_run_stop({:not_run, outcome})
    end
  end

  defp not_run_stop({:not_run, {:skipped, :deadline}}), do: {:error, :deadline}
  defp not_run_stop(not_run), do: {:error, not_run}

  defp fetched({:ok, body, uri}), do: {:ok, %{body: body, uri: uri}}
  defp fetched({:error, _class} = error), do: error

  # A page's answer read and recorded: `:success`, then the page's partial kind; the failure
  # class otherwise.
  defp read_answer(answer, {indexer, copy, planned, page, context}, request, now) do
    with {:ok, fetched} <- answer,
         {:ok, page} <-
           Rows.read(
             fetched.body,
             copy.definition,
             page.variables,
             fetched.uri,
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
      test_page(indexer, copy, page, context, record, Session.start(copy))
    else
      {:not_supported, feature} -> {:not_run, {:not_asked, {:not_supported, feature}}}
      {:error, reason} -> {:ran, record.(reason)}
    end
  end

  defp test_page(indexer, copy, page, context, record, nil) do
    fun = fn ->
      request = copy.request.(context, now())

      page
      |> Fetch.send_page(request)
      |> fetched()
      |> test_answer(copy, page, context, request)
      |> test_class()
      |> record.()
    end

    Indexer.leased(indexer, context, fun, gate: false, delay_ms: copy.delay_ms)
  end

  # A definition with a login: its session in the Test's slots, which no rejected credentials
  # close, and the answer recorded once its last request answered.
  defp test_page(indexer, copy, page, context, record, session) do
    run = %{
      indexer: indexer,
      copy: copy,
      context: context,
      hold: &Indexer.leased(indexer, context, &1, gate: false, delay_ms: copy.delay_ms),
      record?: false
    }

    finish = fn answer, request, _now -> test_answer(answer, copy, page, context, request) end

    case Session.exchange(run, page, session, finish) do
      {:ok, answer, _session} -> {:ran, record.(answer)}
      {:error, class} -> {:ran, record.(test_class({:error, class}))}
      {:not_run, outcome} -> {:not_run, outcome}
    end
  end

  defp test_answer(answer, copy, test_page, context, request) do
    with {:ok, fetched} <- answer,
         {:ok, page} <-
           Rows.read(
             fetched.body,
             copy.definition,
             test_page.variables,
             fetched.uri,
             nil,
             context.deadline_at,
             request,
             test_page.response
           ) do
      cond do
        page.rows != [] -> {:ok, :test_success}
        page.partial != nil -> {:ok, page.partial}
        true -> {:ok, :no_rows}
      end
    end
  end

  defp test_class({:ok, answer}), do: answer
  defp test_class({:error, :deadline}), do: :timeout
  defp test_class({:error, class}), do: class

  defp now, do: Native.now()
end
