defmodule Cinder.Indexers.Parity.ProwlarrReads do
  @moduledoc """
  The two Prowlarr reads the parity check (`Cinder.Indexers.Parity`) takes as evidence for
  Prowlarr's side of coverage (#1624 amendment change 2): the query history and the indexer
  status. Both go through `Cinder.Indexers.ProwlarrApi.get/3`, so they keep its redirect, retry,
  byte cap and closed error tags. The shapes below are read from Prowlarr `develop` at `b0b5774`.

  ## Query history

  `history/3` reads `GET /api/v1/history` with `eventType=2` (`IndexerQuery`), one `indexerIds`
  per Prowlarr indexer id, `page` and `pageSize`. `HistoryController.GetHistory` takes no date
  parameter: it answers a `PagingResource` (`page`, `pageSize`, `totalRecords`, `records`) sorted
  by date, newest first, when no `sortKey` is sent. So the window is applied here: the read keeps
  each entry dated from `from` to `to`, both included, and stops at the first page that is empty,
  that reaches `totalRecords`, or whose oldest entry is before `from`. A page whose entries are
  not newest first fails the read, since that stop rule rests on the order. Prowlarr inserts new
  queries at the top while the read pages, which shifts older entries onto the next page, so an
  entry seen twice is kept once, by its `id`.

  It reads at most 20 pages of 500 entries. A window that needs more is
  `{:error, :too_many_pages}`: at the prod rates of #1624 (about 120,000 queries in 30 days
  across five indexers), 10,000 entries span about two and a half days of history.

  Each entry keeps its `id`, `indexerId`, `date`, `successful` and the result count
  `data.queryResults`, nil when Prowlarr wrote it empty (a query with no release list), and
  `data.cached`, `"1"` when Prowlarr answered from its cache without asking the indexer and
  `"0"` otherwise (`HistoryService.cs`; prod's history held these keys on 2026-11-26). It also
  keeps what `Cinder.Indexers.Parity.HistoryMatch` matches against the run's own requests: the
  query term `data.query`, the search type `data.queryType`, the categories `data.categories`
  (comma-joined integers, `""` for none), each id field of `HistoryMatch.id_fields/0` that the
  entry holds, as text under its key (`ids`), the client `data.source`, and `data.limit` and
  `data.offset` when the entry holds them (`paging`). The `data` map's `url`, which holds the
  indexer's key (`HistoryService.cs`), and `host` are never read, so no value this module returns
  carries them. An entry whose `eventType` is not `indexerQuery`, or with a field missing or of
  another type, fails the whole read with `{:error, :unexpected_response}`: a dropped failed
  entry would let a cell read as covered.

  ## Indexer status

  `status/1` reads `GET /api/v1/indexerstatus`, which lists the indexers Prowlarr holds in
  backoff (`GetBlockedProviders`), and keeps each one's `indexerId`, `disabledTill`, the
  backoff's end, and `mostRecentFailure`, the failure that set it. Each record Prowlarr lists has
  a `disabledTill` (`IsDisabled()` in `ProviderStatusBase.cs`), so a record without one as a
  date fails the read with `{:error, :unexpected_response}`: read as no backoff, it would let a
  cell read as covered.

  Errors are `Cinder.Indexers.ProwlarrApi`'s closed tags, plus `:unexpected_response` and
  `:too_many_pages`. `history/3` with no indexer id answers `{:ok, []}` with no request, since a
  read with no `indexerIds` would return every indexer's history.
  """

  alias Cinder.Indexers.Parity.HistoryMatch
  alias Cinder.Indexers.ProwlarrApi
  alias Cinder.Indexers.ProwlarrApi.Connection

  @page_size 500
  @max_pages 20

  @type entry :: %{
          id: integer(),
          indexer_id: integer(),
          date: DateTime.t(),
          successful: boolean(),
          query_results: non_neg_integer() | nil,
          cached: boolean(),
          query: String.t(),
          query_type: String.t(),
          categories: [integer()],
          ids: %{String.t() => String.t()},
          source: String.t(),
          paging: %{String.t() => String.t()}
        }
  @type status :: %{
          indexer_id: integer(),
          disabled_till: DateTime.t(),
          most_recent_failure: DateTime.t() | nil
        }
  @type error :: ProwlarrApi.error() | :unexpected_response | :too_many_pages

  @doc """
  The indexer queries of the Prowlarr indexers `ids` dated inside `{from, to}`, newest first. See
  the moduledoc.
  """
  @spec history(Connection.t(), [integer()], {DateTime.t(), DateTime.t()}) ::
          {:ok, [entry()]} | {:error, error()}
  def history(_connection, [], _window), do: {:ok, []}

  def history(%Connection{} = connection, ids, {%DateTime{} = from, %DateTime{} = to}) do
    query = [eventType: 2] ++ Enum.map(ids, &{:indexerIds, &1})
    read_pages(connection, query, {from, to}, 1, [])
  end

  defp read_pages(_connection, _query, _window, page, _acc) when page > @max_pages,
    do: {:error, :too_many_pages}

  defp read_pages(connection, query, {from, _to} = window, page, acc) do
    with {:ok, body} <-
           ProwlarrApi.get(
             connection,
             "/api/v1/history",
             query ++ [page: page, pageSize: @page_size]
           ),
         {:ok, total, entries} <- parse_page(body),
         :ok <- newest_first(entries) do
      acc = Enum.reverse(entries, acc)

      if entries == [] or page * @page_size >= total or before?(List.last(entries), from),
        do: {:ok, finish(acc, window)},
        else: read_pages(connection, query, window, page + 1, acc)
    end
  end

  defp before?(%{date: date}, from), do: DateTime.before?(date, from)

  defp finish(acc, {from, to}) do
    acc
    |> Enum.reverse()
    |> Enum.uniq_by(& &1.id)
    |> Enum.filter(&(not DateTime.before?(&1.date, from) and not DateTime.after?(&1.date, to)))
  end

  defp newest_first(entries) do
    entries
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [a, b] -> not DateTime.before?(a.date, b.date) end)
    |> if(do: :ok, else: {:error, :unexpected_response})
  end

  defp parse_page(%{"totalRecords" => total, "records" => records})
       when is_integer(total) and total >= 0 and is_list(records) do
    Enum.reduce_while(records, {:ok, total, []}, fn record, {:ok, total, acc} ->
      case parse_entry(record) do
        {:ok, entry} -> {:cont, {:ok, total, [entry | acc]}}
        :error -> {:halt, {:error, :unexpected_response}}
      end
    end)
    |> case do
      {:ok, total, entries} -> {:ok, total, Enum.reverse(entries)}
      error -> error
    end
  end

  defp parse_page(_body), do: {:error, :unexpected_response}

  defp parse_entry(%{
         "id" => id,
         "indexerId" => indexer_id,
         "date" => date,
         "successful" => successful,
         "eventType" => "indexerQuery",
         "data" =>
           %{
             "queryResults" => results,
             "cached" => cached,
             "query" => query,
             "queryType" => query_type,
             "categories" => categories,
             "source" => source
           } = data
       })
       when is_integer(id) and is_integer(indexer_id) and is_boolean(successful) and
              cached in ["0", "1"] and is_binary(query) and is_binary(query_type) and
              is_binary(source) do
    with {:ok, date} <- parse_date(date),
         {:ok, results} <- parse_count(results),
         {:ok, categories} <- parse_categories(categories),
         {:ok, ids} <- parse_text(data, HistoryMatch.id_fields()),
         {:ok, paging} <- parse_text(data, ~w(limit offset)) do
      {:ok,
       %{
         id: id,
         indexer_id: indexer_id,
         date: date,
         successful: successful,
         query_results: results,
         cached: cached == "1",
         query: query,
         query_type: query_type,
         categories: categories,
         ids: ids,
         source: source,
         paging: paging
       }}
    end
  end

  defp parse_entry(_record), do: :error

  defp parse_categories(""), do: {:ok, []}

  defp parse_categories(text) when is_binary(text) do
    text
    |> String.split(",")
    |> Enum.reduce_while({:ok, []}, fn part, {:ok, acc} ->
      case Integer.parse(part) do
        {id, ""} -> {:cont, {:ok, [id | acc]}}
        _other -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.reverse(ids)}
      :error -> :error
    end
  end

  defp parse_categories(_value), do: :error

  defp parse_text(data, fields) do
    data
    |> Map.take(fields)
    |> Enum.reduce_while({:ok, %{}}, fn
      {field, value}, {:ok, acc} when is_binary(value) ->
        {:cont, {:ok, Map.put(acc, field, value)}}

      _pair, _acc ->
        {:halt, :error}
    end)
  end

  defp parse_count(""), do: {:ok, nil}

  defp parse_count(text) when is_binary(text) do
    case Integer.parse(text) do
      {count, ""} when count >= 0 -> {:ok, count}
      _other -> :error
    end
  end

  defp parse_count(_value), do: :error

  defp parse_date(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, date, _offset} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end

  defp parse_date(_value), do: :error

  @doc "The Prowlarr indexers in backoff, each with its backoff's end. See the moduledoc."
  @spec status(Connection.t()) :: {:ok, [status()]} | {:error, error()}
  def status(%Connection{} = connection) do
    with {:ok, body} <- ProwlarrApi.get(connection, "/api/v1/indexerstatus", []) do
      parse_statuses(body)
    end
  end

  defp parse_statuses(records) when is_list(records) do
    Enum.reduce_while(records, {:ok, []}, fn record, {:ok, acc} ->
      case parse_status(record) do
        {:ok, status} -> {:cont, {:ok, [status | acc]}}
        :error -> {:halt, {:error, :unexpected_response}}
      end
    end)
    |> case do
      {:ok, statuses} -> {:ok, Enum.reverse(statuses)}
      error -> error
    end
  end

  defp parse_statuses(_body), do: {:error, :unexpected_response}

  defp parse_status(%{"indexerId" => id} = record) when is_integer(id) do
    with {:ok, till} <- parse_date(Map.get(record, "disabledTill")),
         {:ok, failure} <- optional_date(record, "mostRecentFailure") do
      {:ok, %{indexer_id: id, disabled_till: till, most_recent_failure: failure}}
    end
  end

  defp parse_status(_record), do: :error

  defp optional_date(record, field) do
    case Map.get(record, field) do
      nil -> {:ok, nil}
      value -> parse_date(value)
    end
  end
end
