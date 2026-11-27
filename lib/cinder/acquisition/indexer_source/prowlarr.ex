defmodule Cinder.Acquisition.IndexerSource.Prowlarr do
  @moduledoc """
  Real `Cinder.Acquisition.IndexerSource` impl, backed by `Req`, against Prowlarr's
  unified JSON search (`GET /api/v1/search`).

  Reads `base_url`, `api_key` and optional `req_options` from
  `config :cinder, #{inspect(__MODULE__)}` at runtime. Searches by IMDb id with
  Prowlarr's `{ImdbId:...}` query token (`type=movie`) and returns normalized
  release maps (`%{title, size, download_url, download_url_origin, protocol, category_ids,
  indexer_id, indexer_source, indexer_name, published_at}`, plus `tvdb_id` when the result
  reports a positive integer one). `download_url` is the result's non-blank `downloadUrl`, else
  its non-blank `magnetUrl`; `protocol` is `:usenet` for Usenet results, `:torrent` otherwise.
  `indexer_source` is always `"prowlarr"`, and `indexer_name` is the result's `indexer` field,
  nil when blank or not a string. No result carries a `credentials_version`.

  `search_tv/3` is the TV sibling: `type=tvsearch`, unioning a `{TvdbId:...}{Season:...}`
  token query with a free-text title + `{Season:...}` query (see `search_tv/3` for why
  the id query alone is not enough), reusing the same normalization.

  `search_movie/3`, the standard movie search, sends `search/1`.

  `search_movie_query/2` is the free-text movie search (`type=search`), scoped to the movie
  category by default.

  `search_ebook/3` and `search_ebook_query/2` are the e-book siblings (`type=book` /
  `type=search`), scoped to the e-book category by default. `search_audiobook/3` and
  `search_audiobook_query/2` are their audiobook siblings, scoped to the audiobook category
  instead.
  """
  @behaviour Cinder.Acquisition.IndexerSource

  alias Cinder.Acquisition.Release
  alias Cinder.Download.Client.Fetch
  alias Cinder.HTTPPolicy
  alias Cinder.Util

  @default_base_url "http://localhost:9696"

  # Real release names run well under 300 bytes; this leaves generous headroom while keeping a
  # poisoned multi-KB title out of the parsers (#656).
  @max_title_bytes 1024
  @max_response_bytes 4 * 1024 * 1024

  # A search fanning out to a scraper indexer behind FlareSolverr takes 20-60s (a Cloudflare solve
  # alone budgets 60s), and 15s silently starved the title-query half of search_tv/3's union down
  # to usenet-only results. The figure is each search's receive_timeout, and
  # `HTTPPolicy.bounded_request/2` makes it the search's total deadline too (#1348, #1414).
  @search_timeout_ms 90_000

  # Newznab/Torznab standard category for Movies, the parent: Prowlarr expands a parent to its
  # children in each indexer's category tree before it maps them to that indexer's own, so one id
  # covers each movie subcategory an indexer carries (#1627).
  @movie_category 2000

  # Newznab/Torznab standard category for Books/EBook. Deliberately NOT the 7000 Books parent,
  # which also carries magazines (7010), comics (7030) and technical manuals (7040) — the roadmap
  # requires starting from e-book category evidence rather than an unrestricted parent. A module
  # attribute for the same reason `Cinder.Acquisition.Anime` hardcodes 5070: no operator has asked
  # for a per-install override, and an unused settings key is a support burden.
  @ebook_category 7020

  # Newznab/Torznab standard category for Audio/Audiobook. Audio's parent is 3000, the sibling of
  # the Books parent (7000) the e-book category sits under — B7a's own module-attribute choice,
  # the same "no per-install override" reasoning `@ebook_category` above already gives.
  @audiobook_category 3030

  @doc "The Newznab category the free-text movie search is scoped to when its caller names none."
  def movie_category, do: @movie_category

  @doc "The Newznab category the book searches are scoped to."
  def ebook_category, do: @ebook_category

  @doc "The Newznab category the audiobook searches are scoped to."
  def audiobook_category, do: @audiobook_category

  @impl true
  def search(imdb_id), do: send_one(:search, [imdb_id])

  @doc """
  A standard movie search: `search/1` of `imdb_id`, the one request Prowlarr has always sent.
  `query` and `opts` are not read, since Prowlarr asks no indexer whose caps lack `imdbid`
  (cinder#1613) and the maintainer kept Prowlarr as it is (#1632).
  """
  @impl true
  def search_movie(imdb_id, _query, _opts), do: search(imdb_id)

  @impl true
  def search_tv(nil, title, season) do
    case send_one(:search_tv, [nil, title, season]) do
      {:ok, releases} -> {:ok, tag_query_origin(releases, :free_text)}
      {:error, _reason} = error -> error
    end
  end

  # Text-scraper indexers (1337x & co.) return nothing for a {TvdbId:...} token —
  # Prowlarr does no id→title resolution for them — so the id query alone hides every
  # release they carry. Union both shapes (id results first, deduped by download_url and indexer);
  # one side failing degrades to the other so a flaky scraper can't sink the search.
  # Keep per-result provenance so callers can title-guard the free-text half without
  # rejecting AKA-titled releases that genuinely came from the TVDB-scoped query.
  def search_tv(tvdb_id, title, season) do
    [by_id, by_title] = requests(:search_tv, [tvdb_id, title, season])

    case {search_query(by_id), search_query(by_title)} do
      {{:ok, by_id}, {:ok, by_title}} ->
        releases =
          tag_query_origin(by_id, :id_scoped) ++ tag_query_origin(by_title, :free_text)

        {:ok, merge_query_origins(releases)}

      {{:ok, by_id}, _error} ->
        {:ok, tag_query_origin(by_id, :id_scoped)}

      {_error, {:ok, by_title}} ->
        {:ok, tag_query_origin(by_title, :free_text)}

      {error, _error} ->
        error
    end
  end

  defp tag_query_origin(releases, origin),
    do: Enum.map(releases, &Map.put(&1, :query_origins, [origin]))

  # One result per link and indexer (`Release.per_indexer_rows/3`). A link is a `download_url`.
  # The merge is the link's first copy with the query origins of every copy of the link.
  defp merge_query_origins(releases) do
    by_url =
      Enum.reduce(releases, %{}, fn release, by_url ->
        Map.update(by_url, release.download_url, release, fn kept ->
          %{kept | query_origins: Enum.uniq(kept.query_origins ++ release.query_origins)}
        end)
      end)

    Release.per_indexer_rows(releases, & &1.download_url, by_url)
  end

  @doc """
  Free-text movie search (`type=search`), scoped to the movie category unless `opts` names
  its own `categories` (anime passes 5070).

  Not `type=moviesearch`: that is no Newznab search function. Prowlarr runs any type other than
  `movie`, `music`, `tvsearch` and `book` as its basic search, which sends each Newznab or Torznab
  indexer it asks the type as its `t`. On prod, altHUB and NinjaCentral answered each of 245
  `moviesearch` queries over a month with no results (#1627).
  """
  @impl true
  def search_movie_query(query, opts), do: send_one(:search_movie_query, [query, opts])

  @impl true
  def search_tv_query(query, opts), do: send_one(:search_tv_query, [query, opts])

  @doc """
  Structured book search (`type=book`).

  Prowlarr re-parses `{Author:...}`/`{Title:...}` brace tokens out of `query` into the Newznab
  `author`/`title` request fields, exactly as it does for `{ImdbId:...}` on the movie path — see
  `NewznabRequest.QueryToParams`'s `BookRegex`, which routes them to `BookSearchCriteria`. So the
  structured search is still one `query` string, and an indexer that ignores the fields falls back
  to matching the same text.

  Results are tagged `:id_scoped`: the author/title pair is the strongest identity a book search
  has (there is no book equivalent of a TVDB id in the Newznab book criteria), and it is scoped
  rather than free text.
  """
  @impl true
  def search_ebook(author, title, opts),
    do: tagged(send_one(:search_ebook, [author, title, opts]), :id_scoped)

  @doc """
  Free-text book search (`type=search`).

  Used for the ISBN probe and the `"Title Author"` fallback, neither of which maps onto the
  structured book fields — an ISBN is not a title, and sending it as one asks the indexer to
  match it against release names as a title string. Results are tagged `:free_text`.
  """
  @impl true
  def search_ebook_query(query, opts),
    do: tagged(send_one(:search_ebook_query, [query, opts]), :free_text)

  @doc """
  Structured audiobook search (`type=book`) — the audiobook sibling of `search_ebook/3`. Reuses
  `book_query/2`'s brace-token construction unchanged: Newznab's structured book-search type
  still carries `author`/`title` fields regardless of the category filtering the results to
  audio. Results are tagged `:id_scoped`.
  """
  @impl true
  def search_audiobook(author, title, opts),
    do: tagged(send_one(:search_audiobook, [author, title, opts]), :id_scoped)

  @doc """
  Free-text audiobook search (`type=search`) — the audiobook sibling of `search_ebook_query/2`.
  Used for the ASIN/ISBN probe and the `"Title Author"` fallback. Results are tagged `:free_text`.
  """
  @impl true
  def search_audiobook_query(query, opts),
    do: tagged(send_one(:search_audiobook_query, [query, opts]), :free_text)

  defp tagged({:ok, releases}, origin), do: {:ok, tag_query_origin(releases, origin)}
  defp tagged({:error, _reason} = error, _origin), do: error

  @typedoc "One `/api/v1/search` request: its `query`, its `type` and the `categories` it sends."
  @type request :: %{query: String.t(), type: String.t(), categories: [integer()]}

  @doc """
  The `/api/v1/search` requests a search callback sends, in order, for `args` as the callback
  takes them: one each, but two for `search_tv/3` with a TVDB id, the id-scoped one first. Each
  search function of this module builds its requests from this function and sends no other,
  none at all inside `restricted/2` when its ids are `[]`, so the parity check
  (`Cinder.Indexers.Parity`) reads from it which queries a recorded call could have sent.
  `categories` is `[]` when the request sends none.
  """
  @spec requests(atom(), list()) :: [request()]
  def requests(:search, [imdb_id]), do: [request("{ImdbId:#{imdb_id}}", "movie", [])]
  def requests(:search_movie, [imdb_id, _query, _opts]), do: requests(:search, [imdb_id])

  def requests(:search_tv, [nil, title, season]),
    do: [request(tv_query(nil, title, season), "tvsearch", [])]

  def requests(:search_tv, [tvdb_id, title, season]),
    do: [
      request(tv_query(tvdb_id, title, season), "tvsearch", []),
      request(tv_query(nil, title, season), "tvsearch", [])
    ]

  def requests(:search_movie_query, [query, opts]),
    do: [request(query, "search", movie_categories(opts))]

  def requests(:search_tv_query, [query, opts]), do: [request(query, "tvsearch", opts)]

  def requests(:search_ebook, [author, title, opts]),
    do: [request(book_query(author, title), "book", categories(opts))]

  def requests(:search_ebook_query, [query, opts]),
    do: [request(query, "search", categories(opts))]

  def requests(:search_audiobook, [author, title, opts]),
    do: [request(book_query(author, title), "book", audiobook_categories(opts))]

  def requests(:search_audiobook_query, [query, opts]),
    do: [request(query, "search", audiobook_categories(opts))]

  defp request(query, type, opts),
    do: %{query: query, type: type, categories: Keyword.get(opts, :categories, [])}

  defp send_one(callback, args) do
    [request] = requests(callback, args)
    search_query(request)
  end

  defp movie_categories(opts), do: Keyword.put_new(opts, :categories, [@movie_category])
  defp categories(opts), do: Keyword.put_new(opts, :categories, [@ebook_category])
  defp audiobook_categories(opts), do: Keyword.put_new(opts, :categories, [@audiobook_category])

  # Both braces are removed before interpolation. Prowlarr's `BookRegex` captures with `[^{]+`,
  # which stops at a `{` — so an embedded `{` would open a second token and let a crafted value
  # choose its own field (`author`/`title`/`publisher`/`year`), while an embedded `}` ends the
  # token early and leaves the rest as bare query text. Either way the search stops meaning what
  # the caller asked. Dropping both is lossy but honest: no book title or author name carries a
  # meaningful brace.
  defp book_query(nil, title), do: "{Title:#{brace_safe(title)}}"

  defp book_query(author, title),
    do: "{Author:#{brace_safe(author)}} {Title:#{brace_safe(title)}}"

  defp brace_safe(value), do: String.replace(value, ["{", "}"], "")

  # Prowlarr parses brace tokens out of the query (same syntax as the movie
  # `{ImdbId:...}` path). Prefer the TVDB id; fall back to a free-text title scoped
  # by season. (See the Servarr "Prowlarr Search" wiki.)
  defp tv_query(nil, title, season), do: "#{title} {Season:#{season}}"
  defp tv_query(tvdb_id, _title, season), do: "{TvdbId:#{tvdb_id}}{Season:#{season}}"

  @impl true
  def health do
    # Short receive AND connect bounds — a blackholed host would otherwise sit on
    # Mint's default 30s connect timeout despite the 3s receive_timeout.
    case request(
           url: "/api/v1/health",
           receive_timeout: 3_000,
           connect_options: [timeout: 3_000]
         ) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      other -> error(other)
    end
  end

  # A Prowlarr link is fetched as every client fetched it before #1650: through `Fetch.bytes/3`
  # with the client's options as they come. `Fetch` reads none of the provenance keys.
  @impl true
  def fetch_download(url, source_origin, opts), do: Fetch.bytes(url, source_origin, opts)

  # `HTTPPolicy.bounded_request/2` takes the receive_timeout left after the caller's opts and the
  # configured `req_options` merge as the total deadline when it is past 60s: 90s for every search
  # unless `req_options` sets its own (#1348). `health/0`'s 3s keeps the 60s default.
  defp request(opts) do
    config = config()

    # retry: false — the pollers carry their own bounded-retry budget; Req's default
    # 3-retry backoff on top of it only stretches a tick against a failing indexer.
    [
      base_url: HTTPPolicy.without_fragment(Keyword.get(config, :base_url, @default_base_url)),
      receive_timeout: @search_timeout_ms,
      pool_timeout: 5_000,
      connect_options: [timeout: 5_000],
      retry: false
    ]
    |> auth(Keyword.get(config, :api_key))
    |> Keyword.merge(opts)
    |> Keyword.merge(Keyword.get(config, :req_options, []))
    |> Keyword.put(:redirect, false)
    |> Req.new()
    |> HTTPPolicy.bounded_request(@max_response_bytes)
  end

  defp auth(opts, nil), do: opts
  defp auth(opts, api_key), do: Keyword.put(opts, :headers, [{"x-api-key", api_key}])

  defp config, do: Application.get_env(:cinder, __MODULE__, [])

  @doc """
  The Prowlarr URL the admin set, in `/settings` or through the environment: the `base_url`
  this module runs with, or nil when none is set or it is blank. Unlike a search, it never
  falls back to `#{@default_base_url}`.
  """
  @spec saved_base_url() :: String.t() | nil
  def saved_base_url do
    case Keyword.get(config(), :base_url) do
      url when is_binary(url) -> if String.trim(url) == "", do: nil, else: url
      _none -> nil
    end
  end

  defp error({:ok, %{status: status}}), do: {:error, {:prowlarr_status, status}}
  defp error({:error, reason}), do: {:error, reason}

  @restriction_key {__MODULE__, :indexer_ids}

  @doc """
  Runs `fun` with every search request it sends from the calling process restricted to the
  Prowlarr indexers `ids.()` names, and answers `fun`'s value: a parity run's Prowlarr side
  (`Cinder.Indexers.ParityRun`, #1684). Before each `/api/v1/search` request, `search_tv/3`'s two
  included, the request calls `ids.()` and sends one `indexerIds` parameter per id, so Prowlarr
  asks only those indexers (`SearchController.cs` at `b0b5774`). When `ids.()` answers `[]` the
  request is never sent and answers no rows, since a search with no `indexerIds` asks every
  enabled indexer. The scope is the calling process's own and ends when `fun` returns or raises;
  a search outside it sends no `indexerIds`.
  """
  @spec restricted((-> [integer()]), (-> value)) :: value when value: term()
  def restricted(ids, fun) when is_function(ids, 0) and is_function(fun, 0) do
    previous = Process.put(@restriction_key, ids)

    try do
      fun.()
    after
      if previous,
        do: Process.put(@restriction_key, previous),
        else: Process.delete(@restriction_key)
    end
  end

  defp search_query(%{query: query, type: type, categories: categories}) do
    params = add_categories([query: query, type: type], categories)

    case Process.get(@restriction_key) do
      nil -> send_search(params)
      ids -> restricted_search(params, ids.())
    end
  end

  defp restricted_search(_params, []), do: {:ok, []}

  defp restricted_search(params, ids),
    do: send_search(params ++ Enum.map(ids, &{:indexerIds, &1}))

  defp send_search(params) do
    case request(url: "/api/v1/search", params: params) do
      {:ok, %{status: 200, body: results}} when is_list(results) ->
        {:ok, Enum.flat_map(results, &normalize/1)}

      {:ok, %{status: 200}} ->
        {:error, :unexpected_response}

      other ->
        error(other)
    end
  end

  defp add_categories(params, []), do: params

  defp add_categories(params, categories),
    do: Keyword.put(params, :categories, Enum.join(categories, ","))

  defp normalize(result) when is_map(result) do
    with title when is_binary(title) <- Util.blank_to_nil(result["title"]),
         true <- byte_size(title) <= @max_title_bytes,
         download_url when is_binary(download_url) <-
           Util.blank_to_nil(result["downloadUrl"]) || Util.blank_to_nil(result["magnetUrl"]) do
      [
        %{
          title: title,
          size: integer_or_nil(result["size"]),
          download_url: download_url,
          download_url_origin: download_url_origin(download_url),
          protocol: protocol(result["protocol"]),
          category_ids: category_ids(result["categories"]),
          indexer_id: integer_or_nil(result["indexerId"]),
          indexer_source: "prowlarr",
          indexer_name: indexer_name(result["indexer"]),
          published_at: published_at(result["publishDate"])
        }
        |> put_if_present(:tvdb_id, positive_integer_or_nil(result["tvdbId"]))
      ]
    else
      _ -> []
    end
  end

  defp normalize(_result), do: []

  defp integer_or_nil(value) when is_integer(value), do: value
  defp integer_or_nil(_value), do: nil

  # Prowlarr's `indexer` field, the indexer's display name: a blank or non-string one is no name.
  defp indexer_name(name) when is_binary(name), do: Util.blank_to_nil(name)
  defp indexer_name(_name), do: nil

  defp positive_integer_or_nil(value) when is_integer(value) and value > 0, do: value
  defp positive_integer_or_nil(_value), do: nil

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp category_ids(categories) when is_list(categories) do
    categories
    |> Enum.flat_map(fn
      %{"id" => id} when is_integer(id) -> [id]
      _ -> []
    end)
    |> Enum.uniq()
  end

  defp category_ids(_categories), do: []

  defp published_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp published_at(_value), do: nil

  # The download clients refuse an origin with user info or a fragment, which
  # `Cinder.HTTPPolicy.same_origin?/2` ignores, so the recorded origin drops both (#1286). The
  # searches keep the base URL as set.
  defp download_url_origin(download_url) when is_binary(download_url) do
    base_url = Keyword.get(config(), :base_url, @default_base_url)
    if HTTPPolicy.same_origin?(download_url, base_url), do: HTTPPolicy.source_origin(base_url)
  end

  # Prowlarr's unified search tags each result "torrent" or "usenet"; anything
  # absent/unexpected defaults to :torrent (the conservative routing choice).
  defp protocol("usenet"), do: :usenet
  defp protocol(_), do: :torrent
end
