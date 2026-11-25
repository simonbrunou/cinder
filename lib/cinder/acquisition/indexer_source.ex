defmodule Cinder.Acquisition.IndexerSource do
  @moduledoc """
  The indexer source seam: the behaviour a search across indexers runs through, as `GLOSSARY.md`
  "Indexer source" defines it. Prowlarr (`Cinder.Acquisition.IndexerSource.Prowlarr`) is the one
  source today. The app env key `:indexer_source` names the configured source: `configured/0`
  returns it, each search reads it once ("One source per search" below), and the `"indexer"`
  target of `Cinder.Health` calls it.

  Prefer searching by IMDb id over free-text title.

  ## What a search callback returns

  Each search callback returns one of three shapes (`t:result/0`):

  - `{:ok, rows}`: the rows, with no report. Prowlarr answers this way.
  - `{:ok, rows, report}`: the rows and a `Cinder.Acquisition.IndexerSource.Report` of what the
    search did with each indexer. A caller counts the call as answered and keeps its rows; an
    indexer the report lists as failed makes the search incomplete.
  - `{:error, reason}`: no rows. Besides Prowlarr's own reasons, a source may return three more:
    - `:no_indexers`: no indexer is enabled.
    - `{:indexers_backing_off, retry_at}`: every indexer that could take the query was skipped.
      `retry_at` must be a `DateTime`: the earliest end of a backoff among them, or 60 s after
      the search when none of them was in backoff (each was cut by the deadline or never left
      the queue).
    - `{:no_indexer_answered, report}`: every indexer asked failed, or some failed and the rest
      were skipped. It has the `{code, detail}` shape `Cinder.Download.Watch.reason_code/1`
      reads, so a park records the code and no detail.

  Every caller reads an answer through `Report.from_result/1`, and a search of several seam calls
  combines them through `Report.combine/1`.

  ## One source per search

  Each search entry (`Cinder.Acquisition`'s judge and pick functions,
  `Cinder.Acquisition.BookSearch`) takes the source module as `indexer_source:` in its opts and,
  when that is absent, reads `configured/0` once. It sends every seam call of that search to the
  one module, so a source switch during a search reaches only the searches after it.
  """

  alias Cinder.Acquisition.IndexerSource.Report

  @typedoc "One search callback's answer; see the moduledoc."
  @type result :: {:ok, [map()]} | {:ok, [map()], Report.t()} | {:error, term()}

  @callback search(imdb_id :: String.t()) :: result()

  @doc "Searches movie releases by a bounded free-text query."
  @callback search_movie_query(query :: String.t(), opts :: keyword()) ::
              result()

  @doc "Searches TV releases by a bounded free-text query."
  @callback search_tv_query(query :: String.t(), opts :: keyword()) ::
              result()

  @doc """
  Searches for releases of one TV season. Prefer the `tvdb_id` when present; fall
  back to `title` + season otherwise. `season` may be `0` (a Standard series'
  explicitly monitored specials). Returns the same normalized release maps as
  `search/1` (packs and individual episodes mixed — the parser/scorer sort them out).

  Implementations that union identity-scoped and free-text searches should set each result's
  `:query_origins` to `[:id_scoped]`, `[:free_text]`, or both so callers can apply title guards per
  result without rejecting AKA-titled identity matches.
  """
  @callback search_tv(
              tvdb_id :: integer() | nil,
              title :: String.t(),
              season :: non_neg_integer()
            ) :: result()

  @doc """
  Searches e-book releases by the Newznab **book** search type, which carries `author` and
  `title` as separate fields rather than one free-text blob.

  `author` may be `nil` when the caller has a title but no contributor evidence; the adapter then
  sends the title alone. Returns the same normalized release maps as `search/1`.

  Implementations should set each result's `:query_origins` the same way `search_tv/3` does, so a
  caller can tell an identity-scoped hit from a free-text one.
  """
  @callback search_ebook(author :: String.t() | nil, title :: String.t(), opts :: keyword()) ::
              result()

  @doc """
  Searches e-book releases by a bounded free-text query — the ISBN probe and the last-resort
  `"Title Author"` fallback, neither of which maps onto the structured book fields.
  """
  @callback search_ebook_query(query :: String.t(), opts :: keyword()) ::
              result()

  @doc """
  Searches audiobook releases by the Newznab **book** search type, which carries `author` and
  `title` as separate fields rather than one free-text blob — the audiobook sibling of
  `search_ebook/3`. `author` may be `nil` when the caller has a title but no contributor evidence.
  Returns the same normalized release maps as `search/1`.

  Implementations should set each result's `:query_origins` the same way `search_ebook/3` does.
  """
  @callback search_audiobook(author :: String.t() | nil, title :: String.t(), opts :: keyword()) ::
              result()

  @doc """
  Searches audiobook releases by a bounded free-text query — the ASIN/ISBN probe and the
  last-resort `"Title Author"` fallback, the audiobook sibling of `search_ebook_query/2`.
  """
  @callback search_audiobook_query(query :: String.t(), opts :: keyword()) ::
              result()

  @doc "Lightweight reachability check — `:ok` if the indexer answers, else `{:error, reason}`."
  @callback health() :: :ok | {:error, term()}

  @doc """
  The source module the app env key `:indexer_source` names: what a search uses when its caller
  passes no `indexer_source:` opt.
  """
  @spec configured() :: module()
  def configured, do: Application.fetch_env!(:cinder, :indexer_source)

  @doc """
  Takes the source of one search out of `opts`: `{module, opts}`, the module the
  `indexer_source:` opt names, else `configured/0`, and `opts` without that key. Each search entry
  calls it once and passes the module to every seam call of the search.
  """
  @spec pop_opt(keyword()) :: {module(), keyword()}
  def pop_opt(opts), do: Keyword.pop_lazy(opts, :indexer_source, &configured/0)
end
