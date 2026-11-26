defmodule Cinder.Acquisition.IndexerSource.Native do
  @moduledoc """
  The built-in `Cinder.Acquisition.IndexerSource`: searches every configured indexer that
  `Cinder.Indexers.searchable/0` returns (enabled, secrets decrypted, by priority then id),
  whatever the `indexer_source` setting holds, each through the `Cinder.Acquisition.Indexer`
  adapter of its type, and returns a `Cinder.Acquisition.IndexerSource.Report` keyed
  `{"native", id}` beside the rows.

  ## Which indexers are asked

  - A type with no adapter in the `:indexer_adapters` map is `{:not_asked, {:not_supported,
    type}}` and gets no request.
  - Otherwise an indexer whose FlareSolverr toggle is on is `{:not_asked, {:not_supported,
    :flaresolverr}}`, and its adapter is never called.
  - Otherwise Native reads the indexer's backoff state
    (`Cinder.Acquisition.IndexerSource.Native.IndexerStatus.read/1`) before any request. An
    indexer whose credentials are rejected is `{:failed, :rejected_credentials}`, and one in a
    failure or limit backoff whose until-time is after the clock is `{:skipped, {:backoff,
    until}}`. Neither gets a request, a caps fetch included.
  - Every other indexer is searched in its own process under
    `Cinder.Acquisition.IndexerSource.Native.TaskSupervisor`, all at once. Each such process runs
    under a `max_heap_size` that kills it; a killed, crashed or raising search, or an answer
    outside the adapter contract, reads as `{:failed, :crashed}`, which Native records in the
    indexer's backoff state as a failure. The adapter records each other answer from the search
    process (`Cinder.Acquisition.Indexer.Newznab`).

  ## The deadline

  A seam call has 90 s from the moment it enters Native. Each adapter request gets the smaller of
  its own timeout and the time left (`Cinder.Acquisition.Indexer.request/3`), so a search cut by
  the deadline can still answer with its rows and `{:skipped, :deadline}`. One second past the
  deadline Native kills every search process still running, reports each such indexer
  `{:skipped, :deadline}`, and returns the rows it has. A request task a killed search process
  started ends with it (`Cinder.HTTPPolicy.bounded_request/3`).

  The calling process gets a `Cinder.Download.PollerProgress.beat/0` each time one indexer's
  search answers or crashes. A search the deadline kills writes no stamp.

  ## Rows and order

  Native stamps every row with the configured indexer's `indexer_id`, `indexer_name`,
  `indexer_source` (`"native"`) and `credentials_version`, over any value the adapter set. A row
  whose `query_origins` is not exactly `[:id_scoped]` or `[:free_text]` is dropped. Rows come
  back id-scoped first, then free text; inside each, by indexer (priority, then id), and inside
  one indexer in the adapter's order.

  ## What a search callback returns

  - `{:error, :no_indexers}` with no searchable configured indexer.
  - `{:ok, [], report}` when no indexer could be asked.
  - `{:error, {:indexers_backing_off, retry_at}}` when none was asked or failed and some were
    skipped. `retry_at` is the earliest of each skipped indexer's backoff end and, when the
    deadline cut one, 60 s after the search ends.
  - `{:error, {:no_indexer_answered, report}}` when none was asked and one or more failed.
  - `{:ok, rows, report}` otherwise, a failed indexer's rows included.

  `fetch_download/3` answers `{:error, :not_supported}` and `health/0` `{:error,
  :not_supported}`, neither with a request.

  `config :cinder, #{inspect(__MODULE__)}` may set `deadline_ms` (a shorter deadline for a test)
  and `clock`, a 0-arity function returning the `DateTime` that `retry_at`, the backoff check
  and the backoff state count from.
  """
  @behaviour Cinder.Acquisition.IndexerSource

  alias Cinder.Acquisition.IndexerSource.Native.IndexerStatus
  alias Cinder.Acquisition.IndexerSource.Report
  alias Cinder.Download.PollerProgress
  alias Cinder.Indexers
  alias Cinder.Indexers.ConfiguredIndexer

  require Logger

  @source "native"
  @deadline_ms 90_000
  @retry_after_s 60

  # How long past the deadline a search process may take to answer before it is killed. Its
  # requests already end at the deadline (`Cinder.Acquisition.Indexer.request/3`), so a search
  # cut there still returns the rows of the paths that answered before it.
  @kill_grace_ms 1_000

  # 16 Mi words, 128 MiB on a 64-bit VM. A response body is at most 4 MiB
  # (`Cinder.Acquisition.Indexer.request/3`) and arrives as an off-heap binary, which
  # `max_heap_size` does not count. Parsing it into terms costs the heap: a body read as a
  # charlist at its worst takes 2 words per byte, 8 Mi words, and a garbage collection can hold
  # the old and the new copy at once, so twice that.
  @max_heap_words 16_777_216

  @origins [[:id_scoped], [:free_text]]

  @impl true
  def search(imdb_id), do: run({:search, imdb_id})

  @impl true
  def search_movie_query(query, opts), do: run({:search_movie_query, query, opts})

  @impl true
  def search_tv_query(query, opts), do: run({:search_tv_query, query, opts})

  @impl true
  def search_tv(tvdb_id, title, season), do: run({:search_tv, tvdb_id, title, season})

  @impl true
  def search_ebook(author, title, opts), do: run({:search_ebook, author, title, opts})

  @impl true
  def search_ebook_query(query, opts), do: run({:search_ebook_query, query, opts})

  @impl true
  def search_audiobook(author, title, opts), do: run({:search_audiobook, author, title, opts})

  @impl true
  def search_audiobook_query(query, opts), do: run({:search_audiobook_query, query, opts})

  @impl true
  def health, do: {:error, :not_supported}

  @impl true
  def fetch_download(_url, _source_origin, _opts), do: {:error, :not_supported}

  defp run(query) do
    deadline_at = System.monotonic_time(:millisecond) + deadline_ms()

    case Indexers.searchable() do
      [] -> {:error, :no_indexers}
      indexers -> indexers |> search_all(query, deadline_at) |> answer(indexers)
    end
  end

  defp deadline_ms, do: Keyword.get(config(), :deadline_ms, @deadline_ms)
  defp now, do: Keyword.get(config(), :clock, &DateTime.utc_now/0).()
  defp config, do: Application.get_env(:cinder, __MODULE__, [])

  # --- the searches ---

  # Each indexer's `{rows, outcome}`, by id.
  defp search_all(indexers, query, deadline_at) do
    adapters = Application.fetch_env!(:cinder, :indexer_adapters)
    {supported, left_out} = Enum.split_with(indexers, &asked?(&1, adapters))
    left_out = Map.new(left_out, &{&1.id, {[], not_asked(&1, adapters)}})
    {asked, held} = gate(supported)

    asked
    |> Enum.map(&{&1, Map.fetch!(adapters, &1.type)})
    |> collect(query, deadline_at)
    |> Map.merge(left_out)
    |> Map.merge(held)
  end

  # The indexers whose backoff state lets the search ask them, and the outcome of each other one:
  # skipped while a backoff runs, failed while its credentials are rejected.
  defp gate(indexers) do
    states = IndexerStatus.read(indexers)
    now = now()

    Enum.reduce(indexers, {[], %{}}, fn indexer, {asked, held} ->
      case IndexerStatus.gate(Map.fetch!(states, indexer.id), now) do
        :ask -> {[indexer | asked], held}
        outcome -> {asked, Map.put(held, indexer.id, {[], outcome})}
      end
    end)
    |> then(fn {asked, held} -> {Enum.reverse(asked), held} end)
  end

  defp asked?(%ConfiguredIndexer{type: type, flaresolverr: flaresolverr}, adapters),
    do: Map.has_key?(adapters, type) and not flaresolverr

  # The type check runs first: both read "not supported".
  defp not_asked(%ConfiguredIndexer{type: type}, adapters) when not is_map_key(adapters, type),
    do: {:not_asked, {:not_supported, type}}

  defp not_asked(%ConfiguredIndexer{flaresolverr: true}, _adapters),
    do: {:not_asked, {:not_supported, :flaresolverr}}

  defp collect([], _query, _deadline_at), do: %{}

  defp collect(searches, query, deadline_at) do
    context = %{deadline_at: deadline_at}

    searches
    |> Map.new(fn {indexer, adapter} ->
      task = start(indexer, adapter, query, context)
      {task.ref, {indexer, task}}
    end)
    |> await(%{}, deadline_at + @kill_grace_ms)
  end

  defp start(indexer, adapter, query, context) do
    Task.Supervisor.async_nolink(__MODULE__.TaskSupervisor, fn ->
      Process.flag(:max_heap_size, %{size: @max_heap_words, kill: true, error_logger: true})
      search_one(adapter, indexer, query, context)
    end)
  end

  # An adapter that raises, exits or throws reads as crashed. The log names the indexer and the
  # kind of failure only: an exception's message can hold a URL with its key.
  defp search_one(adapter, indexer, query, context) do
    adapter.search(indexer, query, context)
  catch
    kind, _reason ->
      Logger.warning("native search of indexer #{indexer.id} ended on #{kind}")
      :crashed
  end

  defp await(tasks, answers, _kill_at) when map_size(tasks) == 0, do: answers

  defp await(tasks, answers, kill_at) do
    left_ms = max(kill_at - System.monotonic_time(:millisecond), 0)

    receive do
      {task_ref, answer} when is_map_key(tasks, task_ref) ->
        Process.demonitor(task_ref, [:flush])
        {{indexer, _task}, tasks} = Map.pop!(tasks, task_ref)
        PollerProgress.beat()
        await(tasks, Map.put(answers, indexer.id, recorded(indexer, checked(answer))), kill_at)

      {:DOWN, task_ref, :process, _pid, _reason} when is_map_key(tasks, task_ref) ->
        {{indexer, _task}, tasks} = Map.pop!(tasks, task_ref)
        PollerProgress.beat()

        await(
          tasks,
          Map.put(answers, indexer.id, recorded(indexer, {[], {:failed, :crashed}})),
          kill_at
        )
    after
      left_ms -> expire(tasks, answers)
    end
  end

  # The search processes still running past the deadline. Each request task one started ends
  # with it (`Cinder.HTTPPolicy.bounded_request/3`).
  defp expire(tasks, answers) do
    Enum.reduce(tasks, answers, fn {_task_ref, {indexer, task}}, answers ->
      Task.shutdown(task, :brutal_kill)
      Map.put(answers, indexer.id, {[], {:skipped, :deadline}})
    end)
  end

  # A crashed search is a failure in the indexer's backoff state. The process that ran it may be
  # dead, so the calling process records it; the adapter records every other answer itself.
  defp recorded(indexer, {_rows, {:failed, :crashed}} = answer) do
    IndexerStatus.record(indexer, :crashed, now())
    answer
  end

  defp recorded(_indexer, answer), do: answer

  # The adapter's answer as Native reads it: a row list and an outcome of the closed set, the
  # deadline tag read as a skip. Anything else reads as crashed.
  defp checked({rows, {:failed, :deadline}}), do: checked({rows, {:skipped, :deadline}})

  defp checked({rows, outcome}) when is_list(rows) do
    if Report.outcome?(outcome) and Enum.all?(rows, &is_map/1),
      do: {rows, outcome},
      else: {[], {:failed, :crashed}}
  end

  defp checked(_answer), do: {[], {:failed, :crashed}}

  # --- the answer ---

  defp answer(answers, indexers) do
    report =
      Enum.reduce(indexers, Report.new(), fn indexer, report ->
        {_rows, outcome} = Map.fetch!(answers, indexer.id)
        Report.put(report, {@source, indexer.id}, indexer.name, outcome)
      end)

    outcomes = Enum.map(indexers, &elem(Map.fetch!(answers, &1.id), 1))

    cond do
      Enum.all?(outcomes, &match?({:not_asked, _reason}, &1)) ->
        {:ok, [], report}

      :asked in outcomes ->
        {:ok, rows(indexers, answers), report}

      Enum.any?(outcomes, &match?({:failed, _reason}, &1)) ->
        {:error, {:no_indexer_answered, report}}

      true ->
        {:error, {:indexers_backing_off, retry_at(outcomes)}}
    end
  end

  # The earliest time a skipped indexer can be asked again: its backoff's end, or 60 s after the
  # search for one the deadline cut.
  defp retry_at(outcomes) do
    deadline_retry = DateTime.add(now(), @retry_after_s, :second)

    outcomes
    |> Enum.flat_map(fn
      {:skipped, {:backoff, until}} -> [until]
      {:skipped, :deadline} -> [deadline_retry]
      _outcome -> []
    end)
    |> Enum.min(DateTime)
  end

  # Id-scoped rows of every indexer, then free-text rows; inside each, indexers in the searchable
  # order (priority, then id); inside one indexer, the adapter's order.
  defp rows(indexers, answers) do
    for origins <- @origins,
        indexer <- indexers,
        {rows, _outcome} = Map.fetch!(answers, indexer.id),
        %{query_origins: ^origins} = row <- rows,
        do: stamp(row, indexer)
  end

  defp stamp(row, indexer) do
    Map.merge(row, %{
      indexer_id: indexer.id,
      indexer_name: indexer.name,
      indexer_source: @source,
      credentials_version: indexer.credentials_version
    })
  end
end
