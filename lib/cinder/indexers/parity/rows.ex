defmodule Cinder.Indexers.Parity.Rows do
  @moduledoc """
  The row work of the parity check (`Cinder.Indexers.Parity`) on one try of one search: lining up
  the two sides' seam calls, the three known differences the check can apply, the timing cut,
  the rows it leaves out of every comparison, and the row count.

  A side is a list of recorded seam calls (`%{callback, args, started_at, outcome}`), each outcome
  one `Cinder.Acquisition.IndexerSource` answer. A Native row carries the configured indexer id
  as `indexer_id`; a Prowlarr row carries Prowlarr's, which `cid/3` reads through the map.

  ## The known differences

  Each runs on the rows as recorded, before the timing cut, and changes one side only:

  - `:order`, Prowlarr's indexer order (#1618 point 15): each Native call's rows sorted, stably,
    id-scoped rows first, then by the position of their indexer's first row among Prowlarr's rows
    of the same call and query origin. Prowlarr's `search_tv/3` answers its id query's rows, then
    its free-text query's, and a link both found is one row with both origins, which counts in
    each; on a call whose Prowlarr rows carry no origin, every row counts. Rows of one indexer and
    one origin keep their order, so this never hides an order bug among them; it does move an
    indexer's id-scoped rows ahead of its free-text ones, as Native's adapters already return
    them. An indexer with no Prowlarr row of that origin goes last.
  - `:category_filter`, Prowlarr's filter after the fetch (`ReleaseSearchService.cs` 218-222 at
    `b0b5774`): only on a call to which Prowlarr's adapter sent categories (`searched_categories/2`),
    each Native row is dropped unless it has no category id, or one equal to a searched id, or one
    under a searched parent (`x000` from 1000 to 8000 reaches `x001` to `x999`). Prowlarr expands
    a parent only to the children in that indexer's caps, so this keeps at least what Prowlarr
    keeps. It cannot tell a Native request that lost its category scope from Prowlarr's filter:
    only the request tests of the Newznab and Cardigann adapters catch that.
  - `:row_cap`, Native's 1,000 rows per indexer per query (#1618 point 4), which Prowlarr does
    not apply: a Prowlarr group of one call, one Prowlarr indexer and one query origin keeps its
    first 1,000 rows, only when Prowlarr recorded more than 1,000 there and Native recorded
    exactly 1,000 for the same call, mapped indexer and origin. Prowlarr's adapter tags origins
    on `search_tv/3` and the four book calls; on `search/1`, `search_movie/3` and the movie and
    TV query calls its rows carry none, so a group there has no origin and takes Native's count
    of the indexer, when every Native row of it has one and the same origin. A Prowlarr row with
    both origins (its `search_tv/3` merge) has no single query, so the cap leaves its call
    alone.
  """

  alias Cinder.Acquisition.IndexerSource.Prowlarr
  alias Cinder.Acquisition.IndexerSource.Report

  @max_rows 1000

  @doc "The known differences, in the order `subsets/0` tries them."
  @spec differences() :: [atom()]
  def differences, do: [:order, :category_filter, :row_cap]

  @doc "Every set of known differences, smallest first: the order the check tries them in."
  @spec subsets() :: [[atom()]]
  def subsets do
    [d1, d2, d3] = differences()
    [[d1], [d2], [d3], [d1, d2], [d1, d3], [d2, d3], [d1, d2, d3]]
  end

  # --- the calls ---

  @doc """
  Pairs the two sides' calls: the n-th call of a callback and arguments on one side with the
  n-th of the same on the other. Answers `{:ok, [{prowlarr_call, native_call}]}` in Native's call
  order, or `:calls_differ` when a call has no partner.
  """
  @spec align([map()], [map()]) :: {:ok, [{map(), map()}]} | :calls_differ
  def align(prowlarr, native) do
    {pairs, left} =
      Enum.map_reduce(native, prowlarr, fn call, left ->
        case Enum.find_index(left, &(&1.callback == call.callback and &1.args == call.args)) do
          nil -> {{nil, call}, left}
          index -> {{Enum.at(left, index), call}, List.delete_at(left, index)}
        end
      end)

    if left == [] and Enum.all?(pairs, &elem(&1, 0)), do: {:ok, pairs}, else: :calls_differ
  end

  @doc "The rows of an outcome, or nil for an error."
  @spec rows(term()) :: [map()] | nil
  def rows({:ok, rows}) when is_list(rows), do: rows
  def rows({:ok, rows, _report}) when is_list(rows), do: rows
  def rows(_error), do: nil

  @doc "The outcome with `fun` applied to its rows; an error stays as it is."
  @spec map_rows(term(), ([map()] -> [map()])) :: term()
  def map_rows({:ok, rows}, fun) when is_list(rows), do: {:ok, fun.(rows)}
  def map_rows({:ok, rows, report}, fun) when is_list(rows), do: {:ok, fun.(rows), report}
  def map_rows(error, _fun), do: error

  @doc "The Native report an outcome holds: its own, a `:no_indexer_answered` one, or an empty one."
  @spec report(term()) :: Report.t()
  def report({:ok, _rows, %Report{} = report}), do: report
  def report({:error, {:no_indexer_answered, %Report{} = report}}), do: report
  def report(_outcome), do: Report.new()

  @doc "The configured indexer id of a row of `side`, through `map` on Prowlarr's side."
  @spec cid(:prowlarr | :native, map(), map()) :: integer() | nil
  def cid(:native, row, _map), do: Map.get(row, :indexer_id)
  def cid(:prowlarr, row, map), do: Map.get(map, Map.get(row, :indexer_id))

  # --- the known differences ---

  @doc """
  Applies the known differences `subset` to the aligned calls' recorded outcomes. Answers the
  pairs with the changed outcomes.
  """
  @spec apply_differences([{map(), map()}], [atom()], map()) :: [{map(), map()}]
  def apply_differences(pairs, subset, map) do
    Enum.map(pairs, fn {p, n} ->
      Enum.reduce(subset, {p, n}, &apply_difference(&1, &2, map))
    end)
  end

  defp apply_difference(:order, {p, n}, map) do
    prowlarr_rows = rows(p.outcome) || []
    ranks = Map.new([:id_scoped, :free_text], &{&1, origin_ranks(prowlarr_rows, &1, map)})

    sort = fn rows -> Enum.sort_by(rows, &order_key(&1, ranks, map)) end
    {p, %{n | outcome: map_rows(n.outcome, sort)}}
  end

  defp apply_difference(:category_filter, {p, n}, _map) do
    case searched_categories(p.callback, p.args) do
      [] -> {p, n}
      categories -> {p, %{n | outcome: map_rows(n.outcome, &in_categories(&1, categories))}}
    end
  end

  defp apply_difference(:row_cap, {p, n}, map) do
    native_full =
      Enum.frequencies_by(rows(n.outcome) || [], &{cid(:native, &1, map), single_origin(&1)})

    prowlarr_rows = rows(p.outcome) || []
    merged? = Enum.any?(prowlarr_rows, &(single_origin(&1) == :merged))

    counts = Enum.frequencies_by(prowlarr_rows, &{Map.get(&1, :indexer_id), single_origin(&1)})

    capped =
      for {{pid, origin} = group, count} <- counts,
          count > @max_rows,
          native_count(native_full, Map.get(map, pid), origin) == @max_rows,
          into: MapSet.new(),
          do: group

    if merged?,
      do: {p, n},
      else: {%{p | outcome: map_rows(p.outcome, &cap(&1, capped))}, n}
  end

  # Prowlarr's adapter leaves the rows of search/1, search_movie/3 and the movie and TV query
  # calls untagged, so an untagged group stands for the call's one query: it takes Native's
  # count of that indexer, when all came from one query.
  defp native_count(native_full, cid, nil) do
    case for({{^cid, _origin}, count} <- native_full, do: count) do
      [count] -> count
      _none_or_two -> nil
    end
  end

  defp native_count(native_full, cid, origin), do: Map.get(native_full, {cid, origin})

  # Each capped group's first 1,000 rows, in order; every other row stays.
  defp cap(rows, capped) do
    rows
    |> Enum.map_reduce(%{}, fn row, seen ->
      group = {Map.get(row, :indexer_id), single_origin(row)}
      seen = Map.update(seen, group, 1, &(&1 + 1))
      {{row, MapSet.member?(capped, group) and seen[group] > @max_rows}, seen}
    end)
    |> elem(0)
    |> Enum.reject(&elem(&1, 1))
    |> Enum.map(&elem(&1, 0))
  end

  # A Native row's place: id-scoped rows first, then its indexer's rank in its origin.
  defp order_key(row, ranks, map) do
    origin =
      if :id_scoped in (Map.get(row, :query_origins) || []), do: :id_scoped, else: :free_text

    origin_ranks = ranks[origin]

    {if(origin == :id_scoped, do: 0, else: 1),
     Map.get(origin_ranks, cid(:native, row, map), map_size(origin_ranks))}
  end

  # Each configured indexer's place among Prowlarr's rows that carry `origin`; on a call whose
  # rows carry no origin, among all of them.
  defp origin_ranks(rows, origin, map) do
    rows
    |> Enum.filter(&(Map.get(&1, :query_origins) in [nil, []] or origin in &1.query_origins))
    |> Enum.map(&cid(:prowlarr, &1, map))
    |> Enum.uniq()
    |> Enum.with_index()
    |> Map.new()
  end

  defp single_origin(row) do
    case Map.get(row, :query_origins) do
      [origin] -> origin
      nil -> nil
      [] -> nil
      _both -> :merged
    end
  end

  @doc """
  The categories Prowlarr's adapter sends with a call (`Cinder.Acquisition.IndexerSource.Prowlarr`):
  none for `search/1` and `search_tv/3`, the call's own `categories` for the free-text and book
  calls, else that call's default.
  """
  @spec searched_categories(atom(), list()) :: [integer()]
  def searched_categories(:search_movie_query, [_query, opts]),
    do: Keyword.get(opts, :categories, [Prowlarr.movie_category()])

  def searched_categories(:search_tv_query, [_query, opts]),
    do: Keyword.get(opts, :categories, [])

  def searched_categories(callback, args) when callback in [:search_ebook, :search_ebook_query],
    do: Keyword.get(List.last(args), :categories, [Prowlarr.ebook_category()])

  def searched_categories(callback, args)
      when callback in [:search_audiobook, :search_audiobook_query],
      do: Keyword.get(List.last(args), :categories, [Prowlarr.audiobook_category()])

  def searched_categories(_callback, _args), do: []

  defp in_categories(rows, categories) do
    Enum.filter(rows, fn row ->
      case Map.get(row, :category_ids) || [] do
        [] -> true
        ids -> Enum.any?(ids, &in_scope?(&1, categories))
      end
    end)
  end

  defp in_scope?(id, categories) do
    Enum.any?(categories, fn category ->
      id == category or
        (category in 1000..8000//1000 and id > category and id < category + 1000)
    end)
  end

  # --- the cut and the rows left out ---

  @doc "Drops each row published after `cut`; a row with no publication time stays."
  @spec cut([map()], DateTime.t()) :: [map()]
  def cut(rows, cut) do
    Enum.reject(rows, fn row ->
      match?(%DateTime{}, Map.get(row, :published_at)) and
        DateTime.after?(row.published_at, cut)
    end)
  end

  @doc "Drops the rows whose configured indexer is in `cids`."
  @spec drop_cids([map()], :prowlarr | :native, MapSet.t(), map()) :: [map()]
  def drop_cids(rows, side, cids, map),
    do: Enum.reject(rows, &MapSet.member?(cids, cid(side, &1, map)))

  @doc "Keeps only the rows of the configured indexer `id`."
  @spec only_cid([map()], :prowlarr | :native, integer(), map()) :: [map()]
  def only_cid(rows, side, id, map), do: Enum.filter(rows, &(cid(side, &1, map) == id))

  # --- the row count ---

  @doc """
  The rows of one call of one indexer as the count compares them: one `{title, size}` per row,
  with a missing size read as 0. On Native's side the copies of one link, which its
  `search_tv/3` returns once per query, count once, as Prowlarr's adapter merges them.
  """
  @spec count_keys([map()], :prowlarr | :native) :: %{{term(), integer()} => pos_integer()}
  def count_keys(rows, :native) do
    rows
    |> Enum.uniq_by(&{Map.get(&1, :indexer_id), Map.get(&1, :download_url) || make_ref()})
    |> count_keys(:prowlarr)
  end

  def count_keys(rows, :prowlarr),
    do: Enum.frequencies_by(rows, &{Map.get(&1, :title), Map.get(&1, :size) || 0})
end
