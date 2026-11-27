defmodule Cinder.Indexers.ParityRun.IndexerSet do
  @moduledoc """
  The configured indexers a parity run compares (`Cinder.Indexers.ParityRun`, #1624 point 9),
  their Prowlarr map, the corpus kinds each one's caps take, and whether its TV search takes a
  TVDB id (`caps/3`).

  ## The set

  By default, every configured indexer that is enabled, linked to a Prowlarr indexer
  (`configured_indexers.prowlarr_indexer_id`, written by the Prowlarr import of #1673) and whose
  state (`Cinder.Acquisition.IndexerSource.Native.IndexerState.list/1`) is not
  `{:not_supported, _}`. A Newznab or Torznab indexer with its FlareSolverr toggle on reads "not
  supported" there, so it stays out; a Cardigann one is in the set (#1682). `resolve/1`'s `select`
  (the run's `indexers:` option) names the set instead, by configured indexer id or name: every
  indexer it names is in it, whatever its state or link, so a missing map entry reaches the report.
  A name or id that matches no configured indexer refuses the run with `:unknown_indexer`. In either
  set, an indexer whose secrets do not decrypt refuses the run with `:undecryptable_indexer`.

  The map holds `prowlarr_indexer_id => id` for each indexer of the set that has a link.

  ## The kinds

  `caps/3` asks the indexer's own adapter how it plans one representative seam call per kind,
  and keeps a kind when the plan sends a request: `Cinder.Acquisition.Indexer.Newznab.plan/3`
  for a Newznab or Torznab indexer, `Cinder.Acquisition.Indexer.Cardigann.Query.plan/4` over
  the running copy (`Cinder.Acquisition.Indexer.Cardigann.copy/1`) for a Cardigann one.
  `:movie_imdb` is kept only when the IMDb id search plans a request (`{:search, imdb_id}`,
  which asks by the id alone). A kind whose seam calls do not all go one way (books, anime) is
  kept when one of them plans a request. A plan that cannot read the caps, or a running copy
  that does not run, keeps every kind, since the run cannot tell the indexer takes none: its
  cells then read uncovered or inconclusive rather than not asked.

  A Newznab plan reads the stored caps, and fetches them through the run's budget when they are
  missing or stale. A failed fetch keeps every kind and ends the indexer's plans, and a fetch
  that succeeds stores the row its later plans read, so it fetches once per indexer while that
  row stays usable. A later plan that finds no usable row fetches again: for an indexer deleted
  during the run, whose caps no row keeps, each plan fetches.
  """

  alias Cinder.Acquisition.Indexer.{Cardigann, Newznab}
  alias Cinder.Acquisition.Indexer.Cardigann.Query
  alias Cinder.Acquisition.Indexer.Newznab.Caps
  alias Cinder.Acquisition.IndexerSource.{Native, Prowlarr}
  alias Cinder.Acquisition.IndexerSource.Native.{IndexerCaps, IndexerState}
  alias Cinder.Indexers
  alias Cinder.Indexers.ConfiguredIndexer

  @imdb "tt0000001"

  # The seam calls each kind's caller sends, with a placeholder text.
  @probes %{
    movie_imdb: [{:search, @imdb}],
    movie_title: [{:search_movie_query, "x", []}],
    season: [{:search_tv, nil, "x", 1}],
    season_zero: [{:search_tv, nil, "x", 0}],
    anime_episodes: [{:search_tv, nil, "x", 1}, {:search_tv_query, "x", [categories: [5070]]}],
    ebook: [{:search_ebook, nil, "x", []}, {:search_ebook_query, "x", []}],
    audiobook: [{:search_audiobook, nil, "x", []}, {:search_audiobook_query, "x", []}]
  }

  # The seam calls a search of each kind may send, as its caller sends them: a movie with an id
  # sends `{:search_movie, imdb_id, query, opts}` (`Cinder.Acquisition.judge_movie/3`), which
  # Newznab sends as a text search to an indexer whose caps lack `imdbid`; one by title sends
  # `{:search_movie_query, query, opts}`; a season sends `{:search_tv, tvdb_id, title, season}`
  # with the series' TVDB id, or nil; a book search may name an author or none. `reaches?/3` reads
  # a kind as reaching an indexer when one of them may ask it.
  @reach_probes %{
    movie_imdb: [{:search_movie, @imdb, "x", []}],
    movie_title: [{:search_movie_query, "x", []}],
    season: [{:search_tv, 1, "x", 1}, {:search_tv, nil, "x", 1}],
    season_zero: [{:search_tv, 1, "x", 0}, {:search_tv, nil, "x", 0}],
    anime_episodes: [
      {:search_tv, 1, "x", 1},
      {:search_tv, nil, "x", 1},
      {:search_tv_query, "x", [categories: [5070]]}
    ],
    ebook: [
      {:search_ebook, "x", "x", []},
      {:search_ebook, nil, "x", []},
      {:search_ebook_query, "x", []}
    ],
    audiobook: [
      {:search_audiobook, "x", "x", []},
      {:search_audiobook, nil, "x", []},
      {:search_audiobook_query, "x", []}
    ]
  }

  @doc """
  The set as `[%ConfiguredIndexer{}]` with secrets, by priority then id, and its map; see the
  moduledoc. `select` is `nil` for the default set.
  """
  @spec resolve([pos_integer() | String.t()] | nil) ::
          {:ok, [ConfiguredIndexer.t()], %{integer() => pos_integer()}}
          | {:error, :unknown_indexer | :undecryptable_indexer}
  def resolve(select) do
    rows = Indexers.list()

    with {:ok, chosen} <- choose(rows, select),
         {:ok, indexers} <- with_secrets(chosen) do
      map = for i <- indexers, i.prowlarr_indexer_id, into: %{}, do: {i.prowlarr_indexer_id, i.id}
      {:ok, indexers, map}
    end
  end

  defp choose(rows, nil) do
    states = Map.new(IndexerState.list(), &{&1.id, &1.state})

    {:ok,
     Enum.filter(rows, fn row ->
       row.enabled and not is_nil(row.prowlarr_indexer_id) and
         not match?({:not_supported, _}, Map.get(states, row.id))
     end)}
  end

  defp choose(rows, select) when is_list(select) do
    Enum.reduce_while(select, {:ok, []}, fn wanted, {:ok, acc} ->
      case Enum.find(rows, &(&1.id == wanted or &1.name == wanted)) do
        nil -> {:halt, {:error, :unknown_indexer}}
        row -> {:cont, {:ok, [row | acc]}}
      end
    end)
    |> case do
      {:ok, chosen} -> {:ok, Enum.filter(rows, &(&1 in chosen))}
      error -> error
    end
  end

  defp with_secrets(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
      case Indexers.fetch_with_secrets(row.id) do
        {:ok, indexer} -> {:cont, {:ok, [indexer | acc]}}
        {:error, _reason} -> {:halt, {:error, :undecryptable_indexer}}
      end
    end)
    |> case do
      {:ok, indexers} -> {:ok, Enum.reverse(indexers)}
      error -> error
    end
  end

  @doc """
  What one read of `indexer`'s caps tells the run. `kinds` holds the corpus kinds among `kinds`
  that its caps take, in `kinds`' order (see the moduledoc). `tvdb_search` says whether its caps'
  TV search lists `tvdbid`, the test Prowlarr's `HttpIndexerBase.Fetch(TvSearchCriteria)` makes
  before it sends a TV search with a TVDB id (#1933). It is `nil` when the plan cannot read the
  caps, when the running copy does not run, or when a Newznab or Torznab indexer's stored caps
  row is no longer usable when read again after the plans: that read fetches nothing. `context`
  is the adapter context of `t:Cinder.Acquisition.Indexer.context/0`, the run's budget
  included.
  """
  @spec caps(ConfiguredIndexer.t(), [atom()], map()) :: %{
          kinds: [atom()],
          tvdb_search: boolean() | nil
        }
  def caps(%ConfiguredIndexer{type: :cardigann} = indexer, kinds, _context) do
    case Cardigann.copy(indexer) do
      {:ok, copy} ->
        planner = fn query -> Query.plan(copy.definition, copy.config, query, Native.now()) end

        %{
          kinds: Enum.filter(kinds, &takes?(&1, planner)),
          tvdb_search: Query.mode?(copy.definition, "tv-search", "tvdbid")
        }

      {:not_supported, _feature} ->
        unread(kinds)
    end
  end

  def caps(%ConfiguredIndexer{type: type} = indexer, kinds, context)
      when type in [:newznab, :torznab] do
    case Newznab.plan(indexer, {:search, @imdb}, context) do
      {:failed, _tag} ->
        unread(kinds)

      first ->
        planner = fn
          {:search, @imdb} -> first
          query -> Newznab.plan(indexer, query, context)
        end

        %{kinds: Enum.filter(kinds, &takes?(&1, planner)), tvdb_search: newznab_tvdbid?(indexer)}
    end
  end

  def caps(%ConfiguredIndexer{}, kinds, _context), do: unread(kinds)

  @doc """
  Whether `side` of a search of `kind` may send `indexer` a request, read before that side with
  no request and no write, over the seam calls a caller of that kind may send (`@reach_probes`:
  an id and none, an author and none). The parity run paces each side by it
  (`Cinder.Indexers.ParityRun` "Spacing").

  - `:native`: false only when Native's plan of every such call is `{:not_asked, :caps}`, the
    indexer's caps taking none of it: a Cardigann indexer plans over its running copy, a Newznab
    or Torznab one over its stored caps row (`Cinder.Acquisition.Indexer.Newznab.stored_plan/2`).
    A plan whose every query fails to build sends nothing too, but reads true.
  - `:prowlarr`: false only when every Prowlarr request of those calls
    (`Cinder.Acquisition.IndexerSource.Prowlarr.requests/2`) names categories and the indexer's
    caps list none of them (`Caps.covers?/2`, over a Cardigann copy's mapped categories), since
    Prowlarr leaves out of a search each indexer whose categories hold none of the request's
    (`ReleaseSearchService.Dispatch` at `b0b5774`). A request with no categories, such as a TV
    search or a movie by IMDb id, reaches every indexer it names.

  A copy that does not run, no usable caps row, or another type reads true on both sides, since
  the run cannot tell the search skips the indexer.
  """
  @spec reaches?(ConfiguredIndexer.t(), atom(), :native | :prowlarr) :: boolean()
  def reaches?(%ConfiguredIndexer{} = indexer, kind, :native) do
    case planner(indexer) do
      nil ->
        true

      planner ->
        Enum.any?(Map.fetch!(@reach_probes, kind), &(planner.(&1) != {:not_asked, :caps}))
    end
  end

  def reaches?(%ConfiguredIndexer{} = indexer, kind, :prowlarr) do
    for probe <- Map.fetch!(@reach_probes, kind),
        [callback | args] = Tuple.to_list(probe),
        request <- Prowlarr.requests(callback, args) do
      request.categories
    end
    |> Enum.any?(&(&1 == [] or covers?(indexer, &1)))
  end

  # The plan Native would make of a seam call for `indexer`, from what is stored; nil when the
  # run cannot read one.
  defp planner(%ConfiguredIndexer{type: :cardigann} = indexer) do
    case Cardigann.copy(indexer) do
      {:ok, copy} -> &Query.plan(copy.definition, copy.config, &1, Native.now())
      {:not_supported, _feature} -> nil
    end
  end

  # A plan with no usable row answers `{:failed, :not_stored}`, which reads as asking.
  defp planner(%ConfiguredIndexer{type: type} = indexer) when type in [:newznab, :torznab],
    do: &Newznab.stored_plan(indexer, &1)

  defp planner(%ConfiguredIndexer{}), do: nil

  defp covers?(%ConfiguredIndexer{type: :cardigann} = indexer, categories) do
    case Cardigann.copy(indexer) do
      {:ok, copy} -> Query.site_categories(copy.definition, categories) != []
      {:not_supported, _feature} -> true
    end
  end

  defp covers?(%ConfiguredIndexer{type: type} = indexer, categories)
       when type in [:newznab, :torznab] do
    case stored_caps(indexer) do
      {:ok, caps} -> Caps.covers?(caps, categories)
      {:error, _reason} -> true
    end
  end

  defp covers?(%ConfiguredIndexer{}, _categories), do: true

  defp stored_caps(indexer), do: IndexerCaps.read(indexer, fn -> {:error, :not_stored} end)

  @doc "The answer of `caps/3` for an indexer whose caps the run did not read."
  @spec unread([atom()]) :: %{kinds: [atom()], tvdb_search: nil}
  def unread(kinds), do: %{kinds: kinds, tvdb_search: nil}

  # The caps row the plans above read or stored; a fetch here would spend the budget again.
  defp newznab_tvdbid?(indexer) do
    case stored_caps(indexer) do
      {:ok, caps} -> Caps.param?(caps, "tv-search", "tvdbid")
      {:error, _reason} -> nil
    end
  end

  defp takes?(kind, planner) do
    Enum.any?(Map.fetch!(@probes, kind), fn query ->
      case planner.(query) do
        {:ok, _planned} -> true
        {:not_asked, :caps} -> false
        _failed -> true
      end
    end)
  end
end
