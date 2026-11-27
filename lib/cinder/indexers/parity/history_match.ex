defmodule Cinder.Indexers.Parity.HistoryMatch do
  @moduledoc """
  Which Prowlarr history entries a parity run's own requests wrote (#1859). Prowlarr's
  `SearchController` writes `source` "Prowlarr" for every `/api/v1/search` request, the run's
  and a live poller's alike (every entry on prod read so on 2026-11-26), so
  `Cinder.Indexers.Parity` reads an entry as the run's only when it matches a request of the
  run's calls (`Cinder.Acquisition.IndexerSource.Prowlarr.requests/2`): the same query term, the
  same ids, the same categories, and the same search type or `search`. The entry must also read
  `source` "Prowlarr" and hold no `limit` or `offset`, as each entry of a Cinder search does:
  `NewznabController` writes the client's name from its request headers instead, so a Sonarr or
  Radarr linked to Prowlarr matches none, and Cinder sends no `limit` or `offset`. A live poller's
  query or another application's through `/api/v1/search` matches none of the run's requests
  unless it holds the same request.

  ## What Prowlarr writes for a request

  Read from Prowlarr `v3.1.0.5799` (`b0b5774`), the version prod ran on 2026-11-27:

  - `NewznabRequest.QueryToParams` takes the brace tokens of the request's type out of `q`:
    `tvsearch` reads `imdbid`, `rid`, `tvdbid`, `tmdbid`, `tvmazeid`, `doubanid`, `season`,
    `episode`, `year` and `genre`; `movie` reads `imdbid`, `doubanid`, `tmdbid`, `traktid`, `year`
    and `genre`; `book` reads `author`, `publisher`, `title`, `year` and `genre`; `music`, which
    Cinder never sends, reads its own. `search`, the one other type Cinder sends, keeps its
    tokens in the term. Each token is `{name:value}`, the name in any case, the value
    up to the last `}` before the next `{`. An id that does not parse as an integer is dropped.
  - `ReleaseSearchService.Get` trims what is left into the criteria's `SearchTerm`, and the
    criteria's `Categories` are the request's `cat` list.
  - `HistoryService.HandleAsync(IndexerQueryEvent)` writes `Query` (the term), `QueryType`,
    `Categories` (comma-joined, `""` for none) and each id field the criteria hold, `ImdbId` as
    `tt` and at least seven digits.

  `QueryType` is the one field Prowlarr rewrites: `NewznabRequestGenerator.GetSearchRequests` sets
  the criteria's `SearchType` to `search` when no id parameter of the request applies to the
  indexer, and `ReleaseSearchService.Dispatch` hands every indexer of one request the same
  criteria. So any entry of a request can read `search`, whichever indexer wrote it: on prod a
  `tvsearch` with categories 5070 and no token read `search` on Nyaa.si, a Cardigann indexer.
  An entry whose type reads `search` matches a request of any type; the term, the ids and the
  categories still tell another client's query apart.

  An id compares as an integer, an IMDb id by its digits as `ParseUtil.GetImdbId` reads them,
  and every other value as text.
  """

  alias Cinder.Acquisition.IndexerSource.Prowlarr

  @tokens %{
    "tvsearch" => ~w(imdbid rid tvdbid tmdbid tvmazeid doubanid season episode year genre),
    "movie" => ~w(imdbid doubanid tmdbid traktid year genre),
    "book" => ~w(author publisher title year genre)
  }

  # Prowlarr's token name, as `HistoryService` names its field; `doubanid` has no field.
  @fields %{
    "imdbid" => "imdbId",
    "rid" => "rId",
    "tvdbid" => "tvdbId",
    "tmdbid" => "tmdbId",
    "tvmazeid" => "tvMazeId",
    "traktid" => "traktId",
    "season" => "season",
    "episode" => "episode",
    "year" => "year",
    "genre" => "genre",
    "author" => "author",
    "publisher" => "publisher",
    "title" => "title"
  }

  @integer_fields ~w(rId tvdbId tmdbId tvMazeId traktId season year)

  @doc """
  The history fields Prowlarr writes for a request's criteria, beside `Query`, `QueryType` and
  `Categories`: the keys `Cinder.Indexers.Parity.ProwlarrReads` keeps in an entry's `ids`.
  """
  @spec id_fields() :: [String.t()]
  def id_fields,
    do: ~w(imdbId tmdbId traktId tvdbId rId tvMazeId season episode year genre artist album
           track label author title publisher)

  @typedoc "What Prowlarr writes for a request: its term, type, categories and ids."
  @type expected :: %{
          term: String.t(),
          type: String.t(),
          categories: [integer()],
          ids: %{String.t() => term()}
        }

  @doc "The fields Prowlarr writes for `request`. See the moduledoc."
  @spec expected(Prowlarr.request()) :: expected()
  def expected(%{query: query, type: type, categories: categories}) do
    names = Map.get(@tokens, type, [])

    {term, ids} =
      if names == [] do
        {query, %{}}
      else
        matches = Regex.scan(token_regex(names), query)
        term = Enum.reduce(matches, query, fn [whole | _], q -> String.replace(q, whole, "") end)
        {term, Enum.reduce(matches, %{}, &put_token/2)}
      end

    %{
      term: String.trim(term),
      type: type,
      categories: Enum.sort(Enum.uniq(categories)),
      ids: ids
    }
  end

  @doc "The fields Prowlarr writes for each request of a recorded call (`%{callback, args}`)."
  @spec expected_of_call(map()) :: [expected()]
  def expected_of_call(%{callback: callback, args: args}),
    do: callback |> Prowlarr.requests(args) |> Enum.map(&expected/1)

  @doc """
  Whether a history entry (`Cinder.Indexers.Parity.ProwlarrReads.history/3`) is one `expected`
  describes. See the moduledoc.
  """
  @spec matches?(map(), expected()) :: boolean()
  def matches?(entry, expected) do
    entry.source == "Prowlarr" and entry.paging == %{} and
      entry.query_type in [expected.type, "search"] and entry.query == expected.term and
      Enum.sort(Enum.uniq(entry.categories)) == expected.categories and
      normalized(entry.ids) == expected.ids
  end

  defp token_regex(names),
    do: Regex.compile!("\\{(#{Enum.join(names, "|")}):([^{]+)\\}", "iu")

  # A later token of one name replaces an earlier one, as `QueryToParams` assigns it.
  defp put_token([_whole, name, value], ids) do
    case Map.fetch(@fields, String.downcase(name)) do
      {:ok, field} -> put_value(ids, field, value)
      :error -> ids
    end
  end

  defp put_value(ids, field, value) do
    case normal(field, value) do
      nil -> Map.delete(ids, field)
      normal -> Map.put(ids, field, normal)
    end
  end

  defp normalized(ids) do
    Enum.reduce(ids, %{}, fn {field, value}, acc ->
      case normal(field, value) do
        nil -> Map.put(acc, field, {:unreadable, value})
        normal -> Map.put(acc, field, normal)
      end
    end)
  end

  defp normal(field, value) when field in @integer_fields, do: integer(value)
  defp normal("imdbId", value), do: imdb(value)
  defp normal(_field, value), do: value

  # `ParseUtil.GetImdbId` and `GetFullImdbId`: `tt` and up to eight digits, or the digits alone; a
  # zero id is none.
  defp imdb(value) do
    case Regex.run(~r/\A(?:tt)?(\d{1,8})\z/, value) do
      [_whole, digits] -> if String.to_integer(digits) > 0, do: String.to_integer(digits)
      nil -> nil
    end
  end

  defp integer(text) do
    case Integer.parse(String.trim(text)) do
      {n, ""} -> n
      _other -> nil
    end
  end
end
