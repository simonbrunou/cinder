defmodule Cinder.Indexers.ParityRun do
  @moduledoc """
  The parity run (#1684, from the #1624 resolution and its amendment): it searches a seeded
  corpus from the library through both indexer sources, Prowlarr and the built-in one, records
  every seam call, hands the records to `Cinder.Indexers.Parity.compare/1` and prints its report.
  An operator starts it over `bin/cinder rpc`:

      bin/cinder rpc 'Cinder.Indexers.ParityRun.run(seed: 42)'

  `bin/cinder rpc` waits for the run to return with no timeout of its own: Elixir's
  `--rpc-eval`, which it runs, calls `:erpc.call/4` with the default timeout, `:infinity`.

  ## Options

  - `seed:`, an integer; a random one by default. It is printed, and the same seed draws the same
    corpus and side order from the same library (`Cinder.Indexers.ParityRun.Corpus`).
  - `indexers:`, configured indexer ids or names: the set to compare
    (`Cinder.Indexers.ParityRun.IndexerSet`). By default every linked, enabled indexer whose state
    is not "not supported".
  - `budget:`, the requests per indexer over the run, both sources, retries and link checks
    counted: 200 by default (#1624 point 7).
  - `counts:`, a map of kind to searches, in place of `Corpus.planned_counts/1`'s plan for the
    budget. A kind it leaves out has no search.
  - `deadline_s:`, the run's total deadline: 2,700 s by default. A search or retry not started by
    then has no try, and the engine reads it inconclusive.
  - `retry_spacing_s:`, how long after a search's first try ended its retry may start: 660 s by
    default. At Prowlarr `b0b5774` only two indexer definitions answer a query from a cache,
    AnimeBytes for 3 minutes and Rarbg for 10 (`_queryResultCache.Set` in their `FetchPage`),
    and a cached answer leaves the engine's cell uncovered (`:prowlarr_cached`).
  - `history_wait_ms:`, how long after the last Prowlarr call the run reads Prowlarr's history:
    5,000 ms by default, the engine's slack for Prowlarr writing an entry after its answer.
  - `fetch_opts:`, extra fetch options for the link check (a test's `plug:` and `resolver:`).
  - `picks:`, the function each side's search runs through, `Cinder.Indexers.Parity.Picks.run/4`
    by default (a test's wrapper that sees each side's opts).

  ## What it does

  1. Refuses to start, printing one closed tag, when `inspect` of a `Release`, an
     `EbookRelease` or an `AudiobookRelease` holding a synthetic `download_url` shows it
     (`:inspect_shows_download_url`, #1624 point 16), when another run is in progress on the node
     (`:already_running`), when Prowlarr's URL or key is unset (`:prowlarr_not_configured`),
     when the set names an unknown indexer (`:unknown_indexer`), when an indexer of the set has
     secrets that do not decrypt (`:undecryptable_indexer`), or when Prowlarr's indexer status
     cannot be read (`:prowlarr_status`).
  2. Reads Prowlarr's indexer status, draws the corpus and prints the seed, the set, the run's
     limits and the planned counts. The kinds with a planned count above 0 go to the engine as
     `planned` (#1915): one whose draw gave no search, since the library holds no candidate,
     has its cells read not asked. A kind planned at 0 keeps its cells uncovered.
  3. Runs each search once through both sides (`Cinder.Indexers.ParityRun.Recorder`), the side
     that goes first alternating per search from a first side the seed picks. Both sides get the
     same opts: the household policy (`HouseholdPolicy.for_target/2`, or the book panel's opts),
     each one-source block's twin under the other source, and one `now:`. Native asks only the
     set's indexers; Prowlarr's requests carry one `indexerIds` per mapped indexer.
  4. After each search it reads Prowlarr's status again. An indexer whose allowance refused a
     request, whose Native answer was a limit or an HTTP 429, or whose Prowlarr indexer shows a
     backoff set by a failure after the search started, is stopped for the rest of the run, and
     the search records the stop. A search with no indexer of the set left has no try.
  5. Reads each indexer's kinds and whether its TV search takes a TVDB id
     (`Cinder.Indexers.ParityRun.IndexerSet.caps/3`), runs its link check
     (`Cinder.Indexers.ParityRun.LinkCheck`), then reads Prowlarr's history over the run and
     compares.
  6. Runs each search the engine lists in `retry` once more, through both sides, once
     `retry_spacing_s` has passed since its first try ended, reads the history again and
     compares the two tries. A stop in a retry makes the indexer inconclusive from that search
     on, as the engine reads a stop.
  7. Prints the engine's report, then the requests each indexer spent.

  It never calls `Application.put_env/3` and writes no setting, so the live pollers keep
  reading the app env. It stores nothing beyond what Native's own searches write: each
  indexer's status and caps rows, as any search does (#1624 point 15).

  It rescues every raise, exit and throw and prints one line, `Parity run failed: <tag>`, with
  the exception's module name after a raise (`raised KeyError`), never a message or a term that
  can hold a link or a key. It answers `:ok` once the report is printed, else `{:error, tag}`.

  ## Live pollers and Prowlarr's history

  The engine counts each indexer's Prowlarr history entries inside each search's window and
  cannot tell the run's queries apart from another client's (#1859). Cinder has no switch that
  pauses its pollers, and this run sets none, so an operator cannot keep them out of a window
  while Prowlarr is the configured indexer source: a poller's search that reaches Prowlarr
  meanwhile adds entries to that window, as does any other application searching through the
  same Prowlarr. The only way is the configured source: every Cinder search reads it
  (`Cinder.Acquisition.IndexerSource.configured/0`), so while the built-in source is configured,
  no poller's search reaches Prowlarr. The run itself passes each side's source explicitly and
  does not read that setting.
  """

  alias Cinder.Acquisition.{AudiobookRelease, EbookRelease, HouseholdPolicy, Release}
  alias Cinder.Acquisition.IndexerSource
  alias Cinder.Books
  alias Cinder.Download
  alias Cinder.Indexers.{Parity, ProwlarrApi}
  alias Cinder.Indexers.Parity.{Picks, ProwlarrReads, Rows, Text}
  alias Cinder.Indexers.ParityRun.{Budget, Corpus, IndexerSet, LinkCheck, Recorder}

  @budget 200
  @deadline_s 2_700
  @retry_spacing_s 660
  @history_wait_ms 5_000

  @probe_url "https://parity.invalid/get?apikey=PARITYPROBEKEY"
  @release_structs [Release, EbookRelease, AudiobookRelease]

  @doc "Runs a parity run and prints its report. See the moduledoc."
  @spec run(keyword()) :: :ok | {:error, atom()}
  def run(opts \\ []) do
    print = Keyword.get(opts, :print, &IO.puts/1)

    answer =
      try do
        guarded(opts, print)
      rescue
        exception -> {:error, :raised, inspect(exception.__struct__)}
      catch
        :exit, _reason -> {:error, :exited}
        :throw, {__MODULE__, tag} -> {:error, tag}
        :throw, _value -> {:error, :thrown}
      end

    case answer do
      :ok ->
        :ok

      # The exception's module name alone: its message can hold a link or a key.
      {:error, :raised, module} ->
        print.("Parity run failed: raised #{module}")
        {:error, :raised}

      {:error, tag} when is_atom(tag) ->
        print.("Parity run failed: #{tag}")
        {:error, tag}
    end
  end

  defp guarded(opts, print) do
    with :ok <- inspect_hides_links(Keyword.get(opts, :release_structs, @release_structs)) do
      locked(fn -> start(opts, print) end)
    end
  end

  defp inspect_hides_links(structs) do
    if Enum.any?(structs, &(inspect(struct(&1, download_url: @probe_url)) =~ "PARITYPROBEKEY")),
      do: {:error, :inspect_shows_download_url},
      else: :ok
  end

  # One run per node: the run's process holds the module's name while it runs.
  defp locked(fun) do
    if register() do
      try do
        fun.()
      after
        Process.unregister(__MODULE__)
      end
    else
      {:error, :already_running}
    end
  end

  defp register do
    Process.register(self(), __MODULE__)
  rescue
    ArgumentError -> false
  end

  defp start(opts, print) do
    with {:ok, connection} <- connection(),
         {:ok, indexers, map} <- IndexerSet.resolve(Keyword.get(opts, :indexers)),
         {:ok, before} <- read(ProwlarrReads.status(connection), :prowlarr_status) do
      seed = Keyword.get_lazy(opts, :seed, fn -> :rand.uniform(1_000_000_000) end)
      limits = limits(opts)
      counts = Keyword.get_lazy(opts, :counts, fn -> Corpus.planned_counts(limits.budget) end)

      ctx = %{
        opts: opts,
        limits: limits,
        connection: connection,
        indexers: indexers,
        map: map,
        budget: Budget.new(Enum.map(indexers, & &1.id), limits.budget),
        deadline_at: mono() + limits.deadline_s * 1000,
        stopped: %{},
        statuses: before,
        before: before,
        print: print
      }

      searches = Corpus.draw(seed, counts)
      print_header(ctx, seed, counts, searches)
      planned = for kind <- Corpus.kinds(), Map.get(counts, kind, 0) > 0, do: kind
      compare_and_print(Map.put(ctx, :planned, planned), seed, searches)
    end
  end

  defp connection do
    case ProwlarrApi.connection() do
      {:ok, connection} -> {:ok, connection}
      {:error, :not_configured} -> {:error, :prowlarr_not_configured}
    end
  end

  # The run's limits, read once: the header prints them and the run uses these values.
  defp limits(opts),
    do: %{
      budget: Keyword.get(opts, :budget, @budget),
      deadline_s: Keyword.get(opts, :deadline_s, @deadline_s),
      retry_spacing_s: Keyword.get(opts, :retry_spacing_s, @retry_spacing_s),
      history_wait_ms: Keyword.get(opts, :history_wait_ms, @history_wait_ms)
    }

  defp read({:ok, value}, _tag), do: {:ok, value}
  defp read({:error, _reason}, tag), do: {:error, tag}

  defp mono, do: System.monotonic_time(:millisecond)

  defp print_header(ctx, seed, counts, searches) do
    names = Enum.map_join(ctx.indexers, ", ", &"#{Text.safe(&1.name)} (##{&1.id})")
    planned = Enum.map_join(Corpus.kinds(), ", ", &"#{&1} #{Map.get(counts, &1, 0)}")

    ctx.print.("Parity run, seed #{seed}")
    ctx.print.("Indexers: #{if names == "", do: "none", else: names}")

    ctx.print.(
      "Limits: #{ctx.limits.budget} requests per indexer, deadline #{ctx.limits.deadline_s} s, " <>
        "retry spacing #{ctx.limits.retry_spacing_s} s, " <>
        "history wait #{ctx.limits.history_wait_ms} ms"
    )

    ctx.print.("Planned searches: #{planned}; drawn: #{length(searches)}")
  end

  # --- the searches ---

  defp compare_and_print(ctx, seed, drawn) do
    first_side = if rem(abs(seed), 2) == 0, do: :prowlarr, else: :native

    {searches, ctx} =
      drawn
      |> Enum.with_index()
      |> Enum.map_reduce(ctx, fn {search, index}, ctx ->
        side = if rem(index, 2) == 0, do: first_side, else: other(first_side)
        search = Map.merge(search, %{first: side, opts: search_opts(search, ctx), tries: []})
        {try, ctx} = run_try(search, ctx)
        {%{search | tries: List.wrap(try)}, ctx}
      end)

    engine_indexers = engine_indexers(searches, ctx)

    with {:ok, run} <- engine_run(ctx, seed, searches, engine_indexers),
         {:ok, result} <- retried(Parity.compare(run), searches, ctx, seed, engine_indexers) do
      ctx.print.(result.report)
      print_spent(result.ctx)
      :ok
    end
  end

  defp retried(%{retry: []} = result, _searches, ctx, _seed, _engine_indexers),
    do: {:ok, Map.put(result, :ctx, ctx)}

  defp retried(%{retry: retry}, searches, ctx, seed, engine_indexers) do
    {searches, ctx} = retries(searches, retry, ctx)

    with {:ok, run} <- engine_run(ctx, seed, searches, engine_indexers) do
      {:ok, run |> Parity.compare() |> Map.put(:ctx, ctx)}
    end
  end

  defp other(:prowlarr), do: :native
  defp other(:native), do: :prowlarr

  defp retries(searches, retry, ctx) do
    spacing_ms = ctx.limits.retry_spacing_s * 1000

    searches
    |> Enum.with_index()
    |> Enum.map_reduce(ctx, fn
      {%{tries: [first]} = search, index}, ctx ->
        if index in retry do
          wait_until(first_ended_ms(first) + spacing_ms, ctx)
          {try, ctx} = run_try(search, ctx)
          {%{search | tries: [first | List.wrap(try)]}, ctx}
        else
          {search, ctx}
        end

      {search, _index}, ctx ->
        {search, ctx}
    end)
  end

  defp first_ended_ms(%{ended_ms: ended_ms}), do: ended_ms

  # Waits for `at` (monotonic ms), never past the run's deadline.
  defp wait_until(at, ctx) do
    left = min(at, ctx.deadline_at) - mono()
    if left > 0, do: Process.sleep(left)
  end

  # One try of a search through both sides, in the search's order, or nil when the deadline has
  # passed or no indexer of the set is left.
  defp run_try(search, ctx) do
    left = for i <- ctx.indexers, not Map.has_key?(ctx.stopped, i.id), do: i.id

    if mono() >= ctx.deadline_at or left == [] do
      {nil, ctx}
    else
      started_at = DateTime.utc_now()

      {sides, ctx} =
        Enum.map_reduce([search.first, other(search.first)], ctx, fn side, ctx ->
          {record, ctx} = run_side(side, search, left, ctx)
          {{side, record}, ctx}
        end)

      sides = Map.new(sides)
      {statuses, ctx} = after_status(started_at, ctx)
      sides = put_in(sides, [:prowlarr, :stops], sides.prowlarr.stops ++ statuses)

      {%{prowlarr: sides.prowlarr, native: sides.native, ended_ms: mono()}, ctx}
    end
  end

  defp run_side(side, search, left, ctx) do
    source = side_source(side, left, ctx)
    picks = Keyword.get(ctx.opts, :picks, &Picks.run/4)

    {result, calls} =
      Recorder.record(source, fn ->
        picks.(search.kind, search.target, search.opts, Recorder)
      end)

    finished_at = DateTime.utc_now()

    # Every refused indexer not stopped yet, whether its allowance refused a request of this side
    # or one sent between tries (a caps read, a link check): a spent allowance sends nothing on
    # either side, so the try records the stop and the indexer's later searches read
    # inconclusive.
    budget_stops =
      for cid <- Budget.refused(ctx.budget),
          not Map.has_key?(ctx.stopped, cid),
          do: %{indexer_id: cid, reason: :budget}

    limit_stops =
      if side == :native,
        do:
          for(
            cid <- limited(calls),
            cid in left,
            not Map.has_key?(ctx.stopped, cid),
            do: %{indexer_id: cid, reason: :rate_limited}
          ),
        else: []

    stops = Enum.uniq_by(budget_stops ++ limit_stops, & &1.indexer_id)
    ctx = stop(ctx, stops)
    {%{calls: calls, finished_at: finished_at, result: result, stops: stops}, ctx}
  end

  defp side_source(:native, left, ctx), do: %{side: :native, only: left, budget: ctx.budget}

  defp side_source(:prowlarr, left, ctx) do
    pids = for {pid, cid} <- Enum.sort(ctx.map), cid in left, do: {pid, cid}
    %{side: :prowlarr, pids: pids, budget: ctx.budget}
  end

  # The configured indexers a Native call reported limited: a limit, or an HTTP 429.
  defp limited(calls) do
    for call <- calls,
        {{"native", cid}, %{outcome: outcome}} <- Rows.report(call.outcome).indexers,
        match?({:failed, {:limit, _until}}, outcome) or outcome == {:failed, {:http_status, 429}},
        uniq: true,
        do: cid
  end

  defp stop(ctx, stops),
    do: %{
      ctx
      | stopped: Enum.reduce(stops, ctx.stopped, &Map.put_new(&2, &1.indexer_id, &1.reason))
    }

  # Prowlarr's status after a search: each mapped indexer of the set newly held in a backoff
  # whose failure came after the search started is stopped.
  defp after_status(started_at, ctx) do
    case ProwlarrReads.status(ctx.connection) do
      {:ok, statuses} ->
        stops =
          for status <- statuses,
              cid = Map.get(ctx.map, status.indexer_id),
              cid != nil,
              not Map.has_key?(ctx.stopped, cid),
              new_backoff?(status, started_at, ctx.before),
              uniq: true,
              do: %{indexer_id: cid, reason: :rate_limited}

        {stops, %{stop(ctx, stops) | statuses: ctx.statuses ++ statuses}}

      {:error, _reason} ->
        throw_tag(:prowlarr_status)
    end
  end

  # Prowlarr lists only the indexers its backoff holds (`GetBlockedProviders` keeps a status whose
  # `DisabledTill` is ahead, at `b0b5774`). A backoff is new when a failure no earlier than the
  # search's start second set it (Prowlarr writes whole seconds), or, with no failure date, when
  # the snapshot before the run did not hold it.
  defp new_backoff?(status, started_at, before) do
    case status.most_recent_failure do
      %DateTime{} = failure ->
        not DateTime.before?(failure, DateTime.truncate(started_at, :second))

      nil ->
        status not in before
    end
  end

  defp throw_tag(tag), do: throw({__MODULE__, tag})

  # --- the opts both sides get ---

  defp search_opts(search, ctx) do
    base =
      case search.policy do
        {:title, target} -> HouseholdPolicy.for_target(target)
        {:anime, series, policy} -> HouseholdPolicy.for_target(series) ++ [anime_policy: policy]
        {:book, target} -> book_opts(target)
      end

    base
    |> Keyword.update(:release_blocklist, [], &with_twins(&1, ctx.map))
    |> Keyword.put(:now, DateTime.utc_now())
  end

  # The manual book panel's opts (`CinderWeb.BookManualSearchComponent`).
  defp book_opts(target),
    do: [
      protocols: Download.available_protocols(),
      language: target.preferred_language,
      release_blocklist: Books.blocked_release_titles(target.id)
    ]

  # Each block scoped to one source, with its twin under the other source's mapped indexer
  # added once, so both sides skip the same releases.
  defp with_twins(blocklist, map) do
    native_pids = Enum.group_by(map, &elem(&1, 1), &elem(&1, 0))

    twins =
      for {title, {source, id}} <- blocklist,
          twin <- twins(source, id, map, native_pids),
          {title, twin} not in blocklist,
          uniq: true,
          do: {title, twin}

    blocklist ++ twins
  end

  defp twins("prowlarr", pid, map, _native_pids) do
    case Map.get(map, pid) do
      nil -> []
      cid -> [{"native", cid}]
    end
  end

  defp twins("native", cid, _map, native_pids),
    do: for(pid <- Map.get(native_pids, cid, []), do: {"prowlarr", pid})

  defp twins(_source, _id, _map, _native_pids), do: []

  # --- the engine's input ---

  # Each indexer's kinds, `tvdb_search` and link check, read once after the first tries. A
  # stopped indexer, or any once the deadline has passed, is sent nothing more: it keeps every
  # kind, its `tvdb_search` is nil and its link check is not run.
  defp engine_indexers(searches, ctx) do
    fetch_opts = Keyword.get(ctx.opts, :fetch_opts, [])

    Enum.map(ctx.indexers, fn indexer ->
      {caps, link_check} =
        if Map.has_key?(ctx.stopped, indexer.id) or mono() >= ctx.deadline_at do
          {IndexerSet.unread(Corpus.kinds()), :not_run}
        else
          {IndexerSet.caps(indexer, Corpus.kinds(), adapter_context(indexer, ctx)),
           LinkCheck.check(indexer, searches, ctx.budget, fetch_opts)}
        end

      %{
        id: indexer.id,
        name: indexer.name,
        kinds: caps.kinds,
        tvdb_search: caps.tvdb_search,
        link_check: link_check
      }
    end)
  end

  # The adapter context Native's searches hand an indexer (`Native.search_run/2`).
  defp adapter_context(indexer, ctx),
    do: %{
      deadline_at: ctx.deadline_at,
      priority: IndexerSource.priority(),
      budget: fn -> Budget.take(ctx.budget, indexer.id) end
    }

  defp engine_run(ctx, seed, searches, engine_indexers) do
    wait_for_history(searches, ctx)
    window = window(searches)

    with {:ok, history} <- history(ctx, window) do
      {:ok,
       %{
         seed: seed,
         window: window,
         indexers: engine_indexers,
         prowlarr_map: ctx.map,
         planned: ctx.planned,
         history: history,
         statuses: ctx.statuses,
         searches: Enum.map(searches, &engine_search/1)
       }}
    end
  end

  defp engine_search(search) do
    tries = for try <- search.tries, do: %{prowlarr: try.prowlarr, native: try.native}
    Map.take(%{search | tries: tries}, [:label, :kind, :first, :target, :opts, :tries])
  end

  defp wait_for_history(searches, ctx) do
    ends = for s <- searches, try <- s.tries, try.prowlarr.calls != [], do: try.ended_ms

    with [_ | _] <- ends do
      left = Enum.max(ends) + ctx.limits.history_wait_ms - mono()
      if left > 0, do: Process.sleep(left)
    end

    :ok
  end

  # From the first call of any try to 5 s past the last side's end.
  defp window(searches) do
    sides = for s <- searches, try <- s.tries, side <- [try.prowlarr, try.native], do: side
    starts = for %{calls: [call | _]} <- sides, do: call.started_at
    ends = for side <- sides, do: side.finished_at

    case {starts, ends} do
      {[], _ends} ->
        now = DateTime.utc_now()
        {now, now}

      {starts, ends} ->
        {Enum.min(starts, DateTime), DateTime.add(Enum.max(ends, DateTime), 5, :second)}
    end
  end

  defp history(ctx, window) do
    pids = ctx.map |> Map.keys() |> Enum.sort()
    read(ProwlarrReads.history(ctx.connection, pids, window), :prowlarr_history)
  end

  defp print_spent(ctx) do
    spent =
      Enum.map_join(ctx.indexers, ", ", fn i ->
        "#{Text.safe(i.name)} (##{i.id}) #{Budget.spent(ctx.budget, i.id)}"
      end)

    ctx.print.("Requests spent: #{if spent == "", do: "none", else: spent}")
  end
end
