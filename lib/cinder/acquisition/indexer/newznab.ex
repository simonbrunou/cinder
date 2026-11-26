defmodule Cinder.Acquisition.Indexer.Newznab do
  @moduledoc """
  The request half of the Newznab adapter (#1652), which `Cinder.Acquisition.Indexer.Torznab`
  shares, as Prowlarr's `Torznab.cs` reuses Newznab's request generator. `plan/3` turns one seam
  call into the requests to send one configured indexer, read from its caps. Parsing the answers,
  `search/3` and the registration in Native's adapter map are #1653's.

  ## Caps

  `plan/3` reads the indexer's caps once per seam call through
  `Cinder.Acquisition.IndexerSource.Native.IndexerCaps`, which fetches `t=caps` when its row is
  missing, 7 days old or more, or under another `config_version`. `refetch_caps/2` fetches them
  whatever the row holds. A failed fetch answers a closed tag:
  `Cinder.Acquisition.Indexer.request/3`'s own tag when it answers no response (a body labelled
  JSON that does not decode reads `:bad_response` there, whatever its status),
  `{:http_status, status}` for a response with a status outside 2xx, or `:bad_response` for a 2xx
  body `Cinder.Acquisition.Indexer.Newznab.Caps` refuses (an `<error>` answer included).

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

  alias Cinder.Acquisition.Indexer
  alias Cinder.Acquisition.Indexer.Newznab.Caps
  alias Cinder.Acquisition.IndexerSource.Native.IndexerCaps
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
  Fetches `indexer`'s caps whatever its stored row holds, and stores them on success: the Test's
  refetch (#1657).
  """
  @spec refetch_caps(ConfiguredIndexer.t(), Indexer.context()) ::
          {:ok, Caps.t()} | {:error, atom() | tuple()}
  def refetch_caps(%ConfiguredIndexer{} = indexer, context),
    do: IndexerCaps.refetch(indexer, fn -> fetch_caps(indexer, context) end)

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

  defp fetch_caps(indexer, context) do
    case Indexer.request(context, request_options(indexer, t: "caps")) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 -> Caps.parse(body)
      {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
      {:error, tag} -> {:error, tag}
    end
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
