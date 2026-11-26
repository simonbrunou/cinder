defmodule Cinder.Indexers.Parity.Replay do
  @moduledoc """
  The replay indexer source of the parity check (`Cinder.Indexers.Parity`): an
  `Cinder.Acquisition.IndexerSource` that answers each seam call with a recorded outcome and
  sends no request. The parity check passes it as `indexer_source:` to a caller
  (`Cinder.Acquisition.judge_movie/3` and the others), which sends every seam call of one search
  to it.

  `run/2` holds the recorded calls of one search in the calling process's dictionary while it
  runs a function. The callers run every seam call in the calling process (no `Task` or `async`
  in `Cinder.Acquisition`, `Cinder.Acquisition.Anime` or `Cinder.Acquisition.BookSearch`), so
  each callback the function reaches reads that state. Each callback answers the outcome of the
  first recorded call not yet answered whose callback and arguments equal its own, so a search
  that repeats a callback with other arguments, such as `search_tv/3` for each season, gets each
  call's own outcome, in call order. A callback with no such recorded call answers
  `{:error, :not_recorded}`, and `run/2` reports it: the replay then did not see the search the
  recording saw.

  A callback outside `run/2` raises. `health/0` and `fetch_download/3` answer
  `{:error, :not_supported}`: a replay checks no health and fetches no link.
  """

  @behaviour Cinder.Acquisition.IndexerSource

  @key {__MODULE__, :state}

  @type call :: %{callback: atom(), args: list(), outcome: term()}
  @type outcome :: %{unanswered: [call()], not_recorded: [{atom(), list()}]}

  @doc """
  Runs `fun` with `calls` as the recorded seam calls, and answers `{fun's value, outcome}`:
  `outcome.unanswered` are the recorded calls no callback asked for, in their order, and
  `outcome.not_recorded` each callback and its arguments that found no recorded call, in the
  order asked. The state is the calling process's own and is gone once `fun` returns or raises.
  """
  @spec run([call()], (-> value)) :: {value, outcome()} when value: term()
  def run(calls, fun) when is_list(calls) and is_function(fun, 0) do
    previous = Process.put(@key, %{calls: calls, not_recorded: []})

    try do
      value = fun.()
      %{calls: left, not_recorded: missing} = Process.get(@key)
      {value, %{unanswered: left, not_recorded: Enum.reverse(missing)}}
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
        raise ArgumentError, "#{inspect(__MODULE__)}.#{callback} called outside run/2"

    case pop_call(state.calls, callback, args) do
      {%{outcome: outcome}, left} ->
        Process.put(@key, %{state | calls: left})
        outcome

      nil ->
        Process.put(@key, %{state | not_recorded: [{callback, args} | state.not_recorded]})
        {:error, :not_recorded}
    end
  end

  defp pop_call(calls, callback, args) do
    case Enum.find_index(calls, &(&1.callback == callback and &1.args == args)) do
      nil -> nil
      index -> List.pop_at(calls, index)
    end
  end
end
