defmodule Cinder.Indexers.ParityRun.IndexerSet do
  @moduledoc """
  The configured indexers a parity run compares (`Cinder.Indexers.ParityRun`, #1624 point 9),
  their Prowlarr map, and the corpus kinds each one's caps take.

  ## The set

  By default, every configured indexer that is enabled, linked to a Prowlarr indexer
  (`configured_indexers.prowlarr_indexer_id`, written by the Prowlarr import of #1673) and whose
  state (`Cinder.Acquisition.IndexerSource.Native.IndexerState.list/1`) is not
  `{:not_supported, _}`. An indexer behind FlareSolverr reads "not supported" there, so it stays
  out. `resolve/1`'s `select` (the run's `indexers:` option) names the set instead, by configured
  indexer id or name: every indexer it names is in it, whatever its state or link, so a missing
  map entry reaches the report. A name or id that matches no configured indexer refuses the run
  with `:unknown_indexer`. In either set, an indexer whose secrets do not decrypt refuses the run
  with `:undecryptable_indexer`.

  The map holds `prowlarr_indexer_id => id` for each indexer of the set that has a link.

  ## The kinds

  `kinds/3` asks the indexer's own adapter how it plans one representative seam call per kind,
  and keeps a kind when the plan sends a request: `Cinder.Acquisition.Indexer.Newznab.plan/3`
  for a Newznab or Torznab indexer, `Cinder.Acquisition.Indexer.Cardigann.Query.plan/4` over
  the running copy (`Cinder.Acquisition.Indexer.Cardigann.copy/1`) for a Cardigann one.
  `:movie_imdb` is kept only when the IMDb id search plans a request (`{:search, imdb_id}`,
  which asks by the id alone). A kind whose seam calls do not all go one way (books, anime) is
  kept when one of them plans a request. A plan that cannot read the caps, or a running copy
  that does not run, keeps every kind, since the run cannot tell the indexer takes none: its
  cells then read uncovered or inconclusive rather than not asked.

  A Newznab plan reads the stored caps, and fetches them through the run's budget when they are
  missing or stale; it fetches at most once per indexer, since a failed fetch keeps every kind.
  """

  alias Cinder.Acquisition.Indexer.{Cardigann, Newznab}
  alias Cinder.Acquisition.Indexer.Cardigann.Query
  alias Cinder.Acquisition.IndexerSource.Native
  alias Cinder.Acquisition.IndexerSource.Native.IndexerState
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
  The corpus kinds among `kinds` that `indexer`'s caps take, in `kinds`' order; see the
  moduledoc. `context` is the adapter context of `t:Cinder.Acquisition.Indexer.context/0`, the
  run's budget included.
  """
  @spec kinds(ConfiguredIndexer.t(), [atom()], map()) :: [atom()]
  def kinds(%ConfiguredIndexer{type: :cardigann} = indexer, kinds, _context) do
    case Cardigann.copy(indexer) do
      {:ok, copy} ->
        planner = fn query -> Query.plan(copy.definition, copy.config, query, Native.now()) end
        Enum.filter(kinds, &takes?(&1, planner))

      {:not_supported, _feature} ->
        kinds
    end
  end

  def kinds(%ConfiguredIndexer{type: type} = indexer, kinds, context)
      when type in [:newznab, :torznab] do
    case Newznab.plan(indexer, {:search, @imdb}, context) do
      {:failed, _tag} ->
        kinds

      first ->
        planner = fn
          {:search, @imdb} -> first
          query -> Newznab.plan(indexer, query, context)
        end

        Enum.filter(kinds, &takes?(&1, planner))
    end
  end

  def kinds(%ConfiguredIndexer{}, kinds, _context), do: kinds

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
