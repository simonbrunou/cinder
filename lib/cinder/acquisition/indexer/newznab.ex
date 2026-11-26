defmodule Cinder.Acquisition.Indexer.Newznab do
  @moduledoc """
  The Newznab adapter of `Cinder.Acquisition.Indexer` (#1652, #1653), which
  `Cinder.Acquisition.Indexer.Torznab` shares, as Prowlarr's `Torznab.cs` reuses Newznab's request
  generator. `plan/3` turns one seam call into the requests to send one configured indexer, read
  from its caps, and `search/3` sends them and reads the answers. Native's adapter map
  (`config :cinder, :indexer_adapters`) names this module for the `newznab` type.

  ## Caps

  `plan/3` reads the indexer's caps once per seam call through
  `Cinder.Acquisition.IndexerSource.Native.IndexerCaps`, which fetches `t=caps` when its row is
  missing, 7 days old or more, or under another `config_version`. The Test (`test/3`) fetches
  them whatever the row holds. A failed fetch answers a closed tag:
  `Cinder.Acquisition.Indexer.request/3`'s own tag when it answers no response, else the class
  `Cinder.Acquisition.Indexer.NewznabAnswer.classify_caps/4` gives the answer (a 2xx `<error
  code="100">` reads `:rejected_credentials`, a 503 `{:http_status, 503}`), or `:bad_response`
  for a 2xx `caps` body `Cinder.Acquisition.Indexer.Newznab.Caps` refuses.

  ## The search

  `search/3` answers Native's `{rows, outcome}`:

  - `{[], {:not_asked, :caps}}` when the caps take none of the call's requests.
  - `{[], {:failed, reason}}` when the caps could not be read, `reason` the fetch's class read
    through `Cinder.Acquisition.Indexer.NewznabAnswer.reason/1`.
  - Otherwise it sends the planned requests one after another, id-scoped first, each once (plus
    the one retry `Cinder.Acquisition.Indexer.request/3` gives an HTTP 502, 503, 504 or 408),
    with no `limit` or `offset`. Each answer is read by
    `Cinder.Acquisition.Indexer.NewznabAnswer.read/2` and its items by
    `Cinder.Acquisition.Indexer.Newznab.Items.rows/2`, every row tagged with its request's query
    origin. A `{:query_error, code}` answer fails that query only: the next one is
    still sent. Any other failure stops the search, the rows of the answers before it kept. The
    outcome is `:asked` when no request failed, else `{:failed, reason}` of the stopping failure,
    or of the first query error when there is none. A request the search deadline cut
    (`{:failed, :deadline}`, which Native reads as skipped) loses to an earlier query error, so
    the search still reads incomplete, and to an earlier answer, so the indexer reads `:asked`
    with that answer's rows.

  A limit's reason carries the end `Cinder.Acquisition.Indexer.NewznabAnswer.limit_until/2` gives
  its wait, never nil.

  ## The slot

  Each search request and each caps fetch is sent inside `Cinder.Acquisition.Indexer.leased/4`,
  which holds the indexer's slot of `Cinder.Acquisition.IndexerSource.Native.Lease` until the
  answer is recorded, the one retry included. A request that never left the slot queue before the
  deadline reads as `request/3`'s `:deadline` tag. A request whose re-read backoff state says no
  is never sent, and stops the search with that state's outcome: `{:skipped, {:backoff, until}}`,
  which loses to an earlier query error or answer as a deadline cut does, or `{:failed,
  :rejected_credentials}`, which wins. A caps fetch the state holds back answers that outcome as
  the search's. The Test's two requests wait for the slot but ask the indexer whatever its
  state.

  ## The backoff state

  Each answer to a search request, and each caps fetch that fails, goes to
  `Cinder.Acquisition.IndexerSource.Native.IndexerStatus.record/3` from the process that sent
  it, as soon as it is read: `:success` for a search answer that reads, else its class or
  transport tag. A caps fetch that succeeds records nothing, so the Test (`test/3`), which
  refetches the caps before its search, records one answer. A request the deadline cut never
  answers, so a search records nothing for it.

  The class's `wait` and the times the answer records count from the `clock` of `config :cinder,
  Cinder.Acquisition.IndexerSource.Native`, `DateTime.utc_now/0` by default, read once the answer
  has come in. No error, outcome or log line carries a URL, a header or a body.

  ## The requests

  Each request is a GET (`request_options/2` sets the method over the configured Req options) to
  the indexer's base URL, its own path kept, plus its API path, with
  `apikey` when the indexer has a key (`request_options/2`). Each planned request carries one
  query origin. A request with a category scope goes only to an indexer whose caps list a
  category the scope takes in, and sends those listed ids as `cat`, as Prowlarr does
  (`Cinder.Acquisition.Indexer.Newznab.Caps.categories/2`): a 2000 scope sends `2000,2040` to an
  indexer that lists both.

  | Seam call | Request | Origin |
  |---|---|---|
  | `search(imdb)` | `t=movie&imdbid=<digits>`, when movie-search lists `imdbid` | id-scoped |
  | `search_tv` with a TVDB id | `t=tvsearch&tvdbid=..`, plus `season` when tv-search lists it, when tv-search lists `tvdbid` | id-scoped |
  | `search_tv` | `t=tvsearch&q=..&season=..` when tv-search lists `q` and `season`, else `t=search&q=..` (scope 5000) when search lists `q` | free text |
  | the four `*_query` calls | `t=search&q=..` when search lists `q` | free text |
  | `search_ebook`, `search_audiobook` | `t=book&title=..`, plus `author` when not nil, when book-search lists `title`, and `author` when one is sent | id-scoped |

  - The IMDb id goes out as its digits, a leading `tt` cut, zero-padded to at least 7 digits. An
    id that is not digits, with or without a leading `tt`, plans nothing.
  - Season 0 goes out as `00`, as Prowlarr's `NewznabifySeasonNumber` sends it.
  - The scope of a `t=search` is the caller's non-empty `categories`, else (an empty list
    included) 2000 for
    `search_movie_query`, 5000 for `search_tv_query` and the `search_tv` fallback, 7020 for
    `search_ebook_query` and 3030 for `search_audiobook_query`. A book request takes the caller's
    non-empty `categories`, else 7020 for `search_ebook` and 3030 for `search_audiobook`. The
    `t=movie` and `t=tvsearch` requests carry no scope.
  - No request ever carries `ep`, and none is `t=moviesearch`. No text request stands in for an
    id-scoped or book request the caps cannot take.

  The Req options a request is built from come from `config :cinder, #{inspect(__MODULE__)},
  req_options: [...]` at runtime, which the tests point at a `Req.Test` stub.
  """

  @behaviour Cinder.Acquisition.Indexer

  alias Cinder.Acquisition.Indexer
  alias Cinder.Acquisition.Indexer.Newznab.{Caps, Grab, Items}
  alias Cinder.Acquisition.Indexer.NewznabAnswer
  alias Cinder.Acquisition.IndexerSource.{Native, Report}
  alias Cinder.Acquisition.IndexerSource.Native.{IndexerCaps, IndexerStatus}
  alias Cinder.HTTPPolicy
  alias Cinder.Indexers.ConfiguredIndexer

  @typedoc "One request to send: its query parameters, the key left out, and its query origin."
  @type planned :: %{params: keyword(String.t()), origin: :id_scoped | :free_text}

  @movie_category 2000
  @tv_category 5000
  @ebook_category 7020
  @audiobook_category 3030

  @doc """
  The requests one seam call sends `indexer`: `{:ok, planned}` with at least one request,
  `{:not_asked, :caps}` when the caps take none of them, or `{:failed, tag}` when its caps could
  not be read (see the moduledoc).
  """
  @spec plan(ConfiguredIndexer.t(), Indexer.query(), Indexer.context()) ::
          {:ok, [planned()]} | {:not_asked, :caps} | {:failed, atom() | tuple()}
  def plan(%ConfiguredIndexer{} = indexer, query, context) do
    case IndexerCaps.read(indexer, fn -> fetch_caps(indexer, context) end) do
      {:ok, caps} -> query |> requests(caps) |> planned()
      {:error, tag} -> {:failed, tag}
    end
  end

  defp planned([]), do: {:not_asked, :caps}
  defp planned(requests), do: {:ok, requests}

  @doc """
  The Req options of one request to `indexer` with the query `params`: a GET to the base URL with
  its own path kept, the API path, and `apikey` when the indexer has a key.
  """
  @spec request_options(ConfiguredIndexer.t(), keyword()) :: keyword()
  def request_options(%ConfiguredIndexer{} = indexer, params) do
    Keyword.merge(req_options(),
      method: :get,
      base_url: HTTPPolicy.without_fragment(indexer.base_url),
      url: indexer.api_path,
      params: params ++ api_key(indexer)
    )
  end

  defp req_options,
    do: :cinder |> Application.get_env(__MODULE__, []) |> Keyword.get(:req_options, [])

  defp api_key(%ConfiguredIndexer{secrets: %{"api_key" => key}})
       when is_binary(key) and key != "",
       do: [apikey: key]

  defp api_key(_indexer), do: []

  # A search's caps fetch: an answer that fails is recorded in the indexer's backoff state, one
  # that succeeds is not. The fetch holds the indexer's slot (`Indexer.leased/4`) behind the
  # backoff gate. The Test fetches its caps in `test_caps/3` instead, which records through the
  # Test's own `record`.
  defp fetch_caps(indexer, context),
    do: leased(indexer, context, fn -> send_caps(indexer, context) end)

  # `Indexer.leased/4`'s answer as the fetch or request answer: the function's own, or the
  # not-run class.
  defp leased(indexer, context, fun, opts \\ []) do
    case Indexer.leased(indexer, context, fun, opts) do
      {:ran, answer} -> answer
      not_run -> {:error, not_run_class(not_run)}
    end
  end

  # A request that never left the slot queue reads as `Indexer.request/3`'s deadline tag, as one
  # with no time left to send it does; one the gate held back carries the gate's outcome.
  defp not_run_class({:not_run, {:skipped, :deadline}}), do: :deadline
  defp not_run_class(not_run), do: not_run

  defp send_caps(indexer, context) do
    case caps_answer(indexer, context) do
      {:ok, caps, _now} -> {:ok, caps}
      {:error, class, now} -> {:error, recorded(indexer, class, now)}
    end
  end

  # One `t=caps` request and its answer read, recording nothing: `{:ok, caps, now}` or
  # `{:error, class, now}`, `now` read once the answer came in.
  defp caps_answer(indexer, context) do
    response = Indexer.request(context, request_options(indexer, t: "caps"), raw_body: true)
    now = now()

    response
    |> NewznabAnswer.read_caps(now)
    |> case do
      {:ok, element} -> Caps.read(element)
      {:error, class} -> {:error, class}
    end
    |> case do
      {:ok, caps} -> {:ok, caps, now}
      {:error, class} -> {:error, class, now}
    end
  end

  # --- the Test ---

  @test_categories %{newznab: @movie_category, torznab: @tv_category}

  @doc """
  The per-indexer Test of `indexer` (#1657), which asks it whatever its backoff state holds:

  1. it refetches the caps and stores them on success (`IndexerCaps.refetch/2`);
  2. then it sends one `t=search` with no query terms, with `apikey` when the indexer has a key
     (`request_options/2`), scoped to the type's default category, Movies (2000) for Newznab
     and TV (5000) for Torznab: `cat` lists the caps' ids under it (`Caps.categories/2`), and
     is left out when the caps list none. An RSS answer, an empty one included, is a pass.

  Each request holds the indexer's slot in `context`'s class (`Indexer.leased/4`, with no gate),
  and `Indexer.request/3` gives each one its one retry after an HTTP 502, 503, 504 or 408. The
  request that settles the Test calls `record` once, before its slot frees: a failed caps fetch
  with its class or tag, else the search with `:test_success` for a pass or its class or tag.
  A deadline cut reads as `:timeout`. A caps fetch that succeeds frees its slot without calling
  `record`. Answers `{:ran, value}` with `record`'s value, or `{:not_run, {:skipped, :deadline}}`
  when a request never left the slot queue, with nothing recorded.
  """
  @impl Indexer
  @spec test(ConfiguredIndexer.t(), Indexer.context(), (IndexerStatus.answer() -> value)) ::
          {:ran, value} | {:not_run, Report.outcome()}
        when value: term()
  def test(%ConfiguredIndexer{} = indexer, context, record) do
    caps_step = fn -> test_caps(indexer, context, record) end

    case Indexer.leased(indexer, context, caps_step, gate: false) do
      {:ran, {:caps, caps}} ->
        Indexer.leased(indexer, context, fn -> test_search(indexer, caps, context, record) end,
          gate: false
        )

      {:ran, {:recorded, value}} ->
        {:ran, value}

      not_run ->
        not_run
    end
  end

  # The Test's caps refetch: the caps it stored, or the failure it recorded.
  defp test_caps(indexer, context, record) do
    case IndexerCaps.refetch(indexer, fn -> caps_only(indexer, context) end) do
      {:ok, caps} -> {:caps, caps}
      {:error, class} -> {:recorded, record.(test_answer(class))}
    end
  end

  defp caps_only(indexer, context) do
    case caps_answer(indexer, context) do
      {:ok, caps, _now} -> {:ok, caps}
      {:error, class, _now} -> {:error, class}
    end
  end

  defp test_search(indexer, caps, context, record) do
    params = [t: "search"] ++ test_category(indexer.type, caps)
    response = Indexer.request(context, request_options(indexer, params), raw_body: true)

    case NewznabAnswer.read(response, now()) do
      {:ok, _items} -> record.(:test_success)
      {:error, class} -> record.(test_answer(class))
    end
  end

  defp test_category(type, caps) do
    case Caps.categories(caps, [Map.fetch!(@test_categories, type)]) do
      [] -> []
      ids -> [cat: cat(ids)]
    end
  end

  # A Test the budget cut ran out of time: a timeout failure, not a skipped search.
  defp test_answer(:deadline), do: :timeout
  defp test_answer(class), do: class

  # --- the search ---

  @typedoc "A row of `Cinder.Acquisition.Indexer.Newznab.Items.rows/2` tagged with its query origin."
  @type row :: %{
          required(:query_origins) => [:id_scoped | :free_text],
          optional(atom()) => term()
        }

  @doc """
  Fetches a grab's link `url` from `indexer` for a download client
  (`Cinder.Acquisition.Indexer.Newznab.Grab`, whose moduledoc gives the rules, #1659).
  """
  @impl Indexer
  defdelegate fetch_download(indexer, url, opts), to: Grab

  @doc "Searches `indexer` for `query`; see the moduledoc."
  @impl Indexer
  @spec search(ConfiguredIndexer.t(), Indexer.query(), Indexer.context()) ::
          {[row()], Report.outcome() | {:failed, :deadline}}
  def search(%ConfiguredIndexer{} = indexer, query, context) do
    case plan(indexer, query, context) do
      {:ok, planned} -> send_planned(indexer, planned, context)
      {:not_asked, :caps} -> {[], {:not_asked, :caps}}
      {:failed, {:not_run, outcome}} -> {[], outcome}
      {:failed, class} -> {[], {:failed, NewznabAnswer.reason(class)}}
    end
  end

  defp send_planned(indexer, planned, context) do
    {row_lists, query_error, stop} =
      Enum.reduce_while(planned, {[], nil, nil}, fn request, {row_lists, query_error, nil} ->
        case answer(indexer, request, context) do
          {:ok, rows} ->
            {:cont, {[rows | row_lists], query_error, nil}}

          {:error, {:query_error, _code} = class} ->
            {:cont, {row_lists, query_error || class, nil}}

          {:error, class} ->
            {:halt, {row_lists, query_error, class}}
        end
      end)

    {row_lists |> Enum.reverse() |> Enum.concat(), outcome(query_error, stop, row_lists != [])}
  end

  # An indexer that answered a query was asked: a later query the deadline cut, or one a backoff
  # skip held back, keeps the rows and the `:asked` outcome. Rejected credentials still win.
  defp outcome(nil, stop, true = _answered) do
    if cut?(stop), do: :asked, else: outcome(nil, stop)
  end

  defp outcome(query_error, stop, _answered), do: outcome(query_error, stop)

  defp cut?(:deadline), do: true
  defp cut?({:not_run, {:skipped, _reason}}), do: true
  defp cut?(_stop), do: false

  # One search request, holding the indexer's slot (`Indexer.leased/4`) while it is sent and its
  # answer recorded.
  defp answer(indexer, request, context),
    do: leased(indexer, context, fn -> send_request(indexer, request, context) end)

  defp send_request(indexer, %{params: params, origin: origin}, context) do
    response = Indexer.request(context, request_options(indexer, params), raw_body: true)
    now = now()

    response
    |> NewznabAnswer.read(now)
    |> case do
      {:ok, items} ->
        IndexerStatus.record(indexer, :success, now)
        {:ok, for(row <- Items.rows(items, indexer), do: Map.put(row, :query_origins, [origin]))}

      {:error, class} ->
        {:error, recorded(indexer, class, now)}
    end
  end

  # Records `class` in the indexer's backoff state and answers it with a limit's wait ended as
  # the state ends it, so the report and the state hold one until-time.
  defp recorded(indexer, class, now) do
    IndexerStatus.record(indexer, class, now)

    case class do
      {:limit, wait} -> {:limit, NewznabAnswer.limit_until(wait, now)}
      class -> class
    end
  end

  # A request the gate held back stops the search with the gate's outcome. A backoff skip loses
  # to an earlier query error, as a deadline cut does, so the search still reads incomplete;
  # rejected credentials win.
  defp outcome(nil, {:not_run, outcome}), do: outcome
  defp outcome(_query_error, {:not_run, {:failed, _reason} = outcome}), do: outcome
  defp outcome(query_error, {:not_run, {:skipped, _reason}}), do: failed(query_error)
  defp outcome(nil, nil), do: :asked
  defp outcome(query_error, :deadline) when query_error != nil, do: failed(query_error)
  defp outcome(query_error, nil), do: failed(query_error)
  defp outcome(_query_error, stop), do: failed(stop)

  defp failed(class), do: {:failed, NewznabAnswer.reason(class)}

  defp now do
    clock = :cinder |> Application.get_env(Native, []) |> Keyword.get(:clock, &DateTime.utc_now/0)
    clock.()
  end

  # --- the request table ---

  defp requests({:search, imdb_id}, caps) do
    with {:ok, digits} <- imdb_digits(imdb_id),
         true <- Caps.param?(caps, "movie-search", "imdbid") do
      [id_scoped(t: "movie", imdbid: digits)]
    else
      _not_asked -> []
    end
  end

  defp requests({:search_tv, tvdb_id, title, season}, caps),
    do: tv_id_request(tvdb_id, season, caps) ++ tv_text_request(title, season, caps)

  defp requests({:search_movie_query, query, opts}, caps),
    do: search_request(query, scope(opts, @movie_category), caps)

  defp requests({:search_tv_query, query, opts}, caps),
    do: search_request(query, scope(opts, @tv_category), caps)

  defp requests({:search_ebook_query, query, opts}, caps),
    do: search_request(query, scope(opts, @ebook_category), caps)

  defp requests({:search_audiobook_query, query, opts}, caps),
    do: search_request(query, scope(opts, @audiobook_category), caps)

  defp requests({:search_ebook, author, title, opts}, caps),
    do: book_request(author, title, scope(opts, @ebook_category), caps)

  defp requests({:search_audiobook, author, title, opts}, caps),
    do: book_request(author, title, scope(opts, @audiobook_category), caps)

  defp tv_id_request(nil, _season, _caps), do: []

  defp tv_id_request(tvdb_id, season, caps) do
    if Caps.param?(caps, "tv-search", "tvdbid") do
      season = if Caps.param?(caps, "tv-search", "season"), do: [season: season(season)], else: []
      [id_scoped([t: "tvsearch", tvdbid: to_string(tvdb_id)] ++ season)]
    else
      []
    end
  end

  defp tv_text_request(title, season, caps) do
    if Caps.param?(caps, "tv-search", "q") and Caps.param?(caps, "tv-search", "season"),
      do: [free_text(t: "tvsearch", q: title, season: season(season))],
      else: search_request(title, [@tv_category], caps)
  end

  defp search_request(query, scope, caps) do
    case {Caps.param?(caps, "search", "q"), Caps.categories(caps, scope)} do
      {true, [_ | _] = ids} -> [free_text(t: "search", q: query, cat: cat(ids))]
      _not_asked -> []
    end
  end

  defp book_request(author, title, scope, caps) do
    author_param = if author == nil, do: [], else: [author: author]

    takes_params? =
      Caps.param?(caps, "book-search", "title") and
        (author == nil or Caps.param?(caps, "book-search", "author"))

    case {takes_params?, Caps.categories(caps, scope)} do
      {true, [_ | _] = ids} ->
        [id_scoped([t: "book", title: title] ++ author_param ++ [cat: cat(ids)])]

      _not_asked ->
        []
    end
  end

  defp id_scoped(params), do: %{params: params, origin: :id_scoped}
  defp free_text(params), do: %{params: params, origin: :free_text}

  defp scope(opts, default) do
    case Keyword.get(opts, :categories) do
      [_ | _] = categories -> categories
      _none -> [default]
    end
  end

  defp cat(ids), do: Enum.map_join(ids, ",", &to_string/1)

  defp season(0), do: "00"
  defp season(season), do: to_string(season)

  defp imdb_digits(imdb_id) when is_binary(imdb_id) do
    case Regex.run(~r/\A(?:tt)?(\d+)\z/, imdb_id) do
      [_match, digits] -> {:ok, String.pad_leading(digits, 7, "0")}
      nil -> :error
    end
  end

  defp imdb_digits(_imdb_id), do: :error
end
