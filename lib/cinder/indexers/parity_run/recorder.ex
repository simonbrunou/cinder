defmodule Cinder.Indexers.ParityRun.Recorder do
  @moduledoc """
  The recording indexer source of a parity run (`Cinder.Indexers.ParityRun`, #1624 point 6): an
  `Cinder.Acquisition.IndexerSource` that passes each seam call on to one side's source and
  records it in the shape `Cinder.Indexers.Parity` reads, `%{callback, args, started_at,
  outcome}`. The run passes it as `indexer_source:` to the real caller through
  `Cinder.Indexers.Parity.Picks.run/4`.

  `record/2` holds one side's state in the calling process's dictionary while a function runs,
  as `Cinder.Indexers.Parity.Replay` does: the callers send every seam call of one search from
  the calling process. A side is one of:

  - `%{side: :native, only: cids, budget: budget}`: each call goes to
    `Cinder.Acquisition.IndexerSource.Native.search_run/2`, which searches only the configured
    indexers `cids` and spends `budget` (`Cinder.Indexers.ParityRun.Budget`) on each request.
  - `%{side: :prowlarr, pids: [{prowlarr_id, cid}], budget: budget}`: each call goes to
    `Cinder.Acquisition.IndexerSource.Prowlarr` inside `Prowlarr.restricted/2`. Before each HTTP
    search request, each Prowlarr id whose configured indexer still has a request left spends one
    and is asked; the others are dropped from the request's `indexerIds`.

  A callback outside `record/2` raises. `health/0` and `fetch_download/3` answer
  `{:error, :not_supported}`: the run checks no health, and its link check goes to Native
  directly.
  """

  @behaviour Cinder.Acquisition.IndexerSource

  alias Cinder.Acquisition.IndexerSource.{Native, Prowlarr}
  alias Cinder.Indexers.ParityRun.Budget

  @key {__MODULE__, :state}

  @doc """
  Runs `fun` with `side` as the source of every callback it reaches, and answers
  `{fun's value, calls}`, the recorded calls in the order they were made. The state is the
  calling process's own and is gone once `fun` returns or raises.
  """
  @spec record(map(), (-> value)) :: {value, [map()]} when value: term()
  def record(side, fun) when is_map(side) and is_function(fun, 0) do
    previous = Process.put(@key, %{side: side, calls: []})

    try do
      value = fun.()
      {value, Enum.reverse(Process.get(@key).calls)}
    after
      if previous, do: Process.put(@key, previous), else: Process.delete(@key)
    end
  end

  @impl true
  def search(imdb_id), do: answer(:search, [imdb_id])

  @impl true
  def search_movie(imdb_id, query, opts), do: answer(:search_movie, [imdb_id, query, opts])

  @impl true
  def search_movie_query(query, opts), do: answer(:search_movie_query, [query, opts])

  @impl true
  def search_tv_query(query, opts), do: answer(:search_tv_query, [query, opts])

  @impl true
  def search_tv(tvdb_id, title, season), do: answer(:search_tv, [tvdb_id, title, season])

  @impl true
  def search_ebook(author, title, opts), do: answer(:search_ebook, [author, title, opts])

  @impl true
  def search_ebook_query(query, opts), do: answer(:search_ebook_query, [query, opts])

  @impl true
  def search_audiobook(author, title, opts), do: answer(:search_audiobook, [author, title, opts])

  @impl true
  def search_audiobook_query(query, opts), do: answer(:search_audiobook_query, [query, opts])

  @impl true
  def health, do: {:error, :not_supported}

  @impl true
  def fetch_download(_url, _source_origin, _opts), do: {:error, :not_supported}

  defp answer(callback, args) do
    state =
      Process.get(@key) ||
        raise ArgumentError, "#{inspect(__MODULE__)}.#{callback} called outside record/2"

    # Floored to the second: Prowlarr writes its history dates in whole seconds
    # (`STJUtcConverter` at `b0b5774`), so a query's entry can read earlier than the call.
    started_at = DateTime.truncate(DateTime.utc_now(), :second)
    outcome = send_call(state.side, callback, args)
    call = %{callback: callback, args: args, started_at: started_at, outcome: outcome}
    Process.put(@key, %{state | calls: [call | Process.get(@key).calls]})
    outcome
  end

  defp send_call(%{side: :native, only: only, budget: budget}, callback, args),
    do:
      Native.search_run(List.to_tuple([callback | args]), %{
        only: only,
        budget: &Budget.take(budget, &1)
      })

  defp send_call(%{side: :prowlarr, pids: pids, budget: budget}, callback, args) do
    allowed = fn -> for {pid, cid} <- pids, Budget.take(budget, cid) == :ok, do: pid end
    Prowlarr.restricted(allowed, fn -> apply(Prowlarr, callback, args) end)
  end
end
