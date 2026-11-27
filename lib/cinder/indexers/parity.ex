defmodule Cinder.Indexers.Parity do
  @moduledoc """
  The offline half of the parity check between Prowlarr and the built-in indexer source (#1683,
  from the #1624 resolution and its amendment): given what each source returned for the same
  searches, it decides which rows and picks match, which cells are covered, which gaps a known
  difference explains, and gives a verdict and a text report. `compare/1` sends no search of its
  own: its replays run the real callers over the recorded rows
  (`Cinder.Indexers.Parity.Replay`), which answer each search call from the record. #1684
  records the searches, reads Prowlarr's
  history and status (`Cinder.Indexers.Parity.ProwlarrReads`) and runs it on prod.

  ## Input

  A run is a map:

  - `seed`, printed; `window`, `{from, to}`, the run's time window.
  - `indexers`: one `%{id, name, kinds, link_check}` per configured indexer the run checks.
    `kinds` lists the corpus kinds (`Cinder.Indexers.Parity.Picks.kinds/0`) its caps can take,
    `:movie_imdb` only when its movie search lists `imdbid`; a kind outside that list gets no
    cell and keeps the verdict from pass. `link_check` is `:passed`, `{:failed, tag}`, either
    of those as `{:unpicked, check}` when `Cinder.Indexers.ParityRun.LinkCheck` fetched a row
    the caller did not pick (#1971), `:not_run`, or `{:not_run, reason}` with the reason
    `LinkCheck` or the run gives (#1954). `{:unpicked, :passed}` counts as a pass. An optional
    `tvdb_search` says whether its TV search caps list `tvdbid`: `true`, `false`, or `nil` when
    the run could not read them.
  - `prowlarr_map`: `%{prowlarr_id => configured_id}` (`configured_indexers.prowlarr_indexer_id`).
  - `history` and `statuses`: `ProwlarrReads.history/3` and `status/1` answers for the window;
    `statuses` may hold several reads (before and after the run).
  - `planned`, optional, `[]` by default: the corpus kinds the run planned a search of. A
    planned kind with no search in `searches` is undrawn: the library holds no candidate (#1915),
    as `Cinder.Indexers.ParityRun.Corpus` reads one, such as a standard series' season 0 with an
    episode a manual search may act on.
  - `searches`, in run order: `%{label, kind, first, target, opts, tries}`. `target` holds the
    caller's arguments (`Picks`), `opts` the household opts with `now:` set, the same for both
    sides. `first` names the side that ran first. `tries` is one try, or two when #1684 ran a
    search again after `compare/1` listed it in `retry`.
  - A try is `%{prowlarr: side, native: side}`; a side is `%{calls, finished_at, result, stops}`:
    each seam call in order as `%{callback, args, started_at, outcome}`, the time the side's
    caller returned, its pick's key (`Picks.run/4` through the recording source), and each
    `%{indexer_id, reason}` that stopped a configured indexer in this search, `reason` `:budget`
    or `:rate_limited`.

  ## Rules

  - **Mapping** (point 9). A Prowlarr row reaches a configured indexer only through
    `prowlarr_map`. A configured indexer with no Prowlarr id, or with two, has its cells
    uncovered; a Prowlarr id in a row with no entry, and an entry naming no checked indexer, are
    reported by id and keep the verdict from pass.
  - **Timing cut** (point 10). Per try, rows published after the first seam call of either side
    started are dropped on both sides; a row with no publication time stays.
  - **Rows left out.** A Native report that leaves an indexer `{:not_asked, _}` in a call (the
    structured book search) drops that indexer's rows from that call on both sides. In a
    `:movie_imdb` search, every indexer without `:movie_imdb` in `kinds` and with no id-scoped
    Native row in that search is dropped on both sides: Prowlarr's `search_movie/3` asks none of
    them, and Native's asks them by the "Title Year" text (#1632). An indexer with `:movie_imdb`
    that answers with free-text rows then shows as a difference, and so do the id-scoped rows of
    an indexer that `kinds` lists without it.
  - **The run's history entries** (#1859). Prowlarr's history does not tell the run's
    `/api/v1/search` requests from a live poller's, so every rule below reads only the entries
    of a try's Prowlarr window, from the Prowlarr side's first call to 5 s after it finished,
    that match a request one of that side's calls lists
    (`Cinder.Indexers.Parity.HistoryMatch`: the same term, ids and categories, and the same
    search type or `search`). The match does not check which indexers a call was restricted to.
    An entry another client wrote, such as a live poller's, opens no cell and counts toward none,
    unless it holds the same request as one of those calls, on an indexer of the run.
  - **Coverage** (point 13, amendment change 2), per search and indexer: covered when Native's
    report says `:asked` and the run's history entries hold a successful one for each request
    that search sent the indexer (those of each call Native asked it in,
    `Cinder.Acquisition.IndexerSource.Prowlarr.requests/2`, but not a TV request with a TVDB id
    when `tvdb_search` is `false`, since Prowlarr skips it for an indexer whose caps lack
    `tvdbid` (#1933)), no failed entry, no entry Prowlarr answered from its cache (a retry of the
    same search inside its cache time gets one), no Prowlarr call errored, and no status read
    shows a Prowlarr backoff that overlaps the window. A cell, one indexer and one kind, exists
    for each kind in `kinds`, and for a kind where the indexer left evidence it was asked (one of
    the run's history entries, or a Native outcome other than `{:not_asked, :caps}`; for
    `:movie_imdb` an id-scoped Native row). It is covered when at least one search of its kind
    ran and the indexer was covered in each. A cell whose kind has no search is uncovered, unless
    the kind is undrawn: it is then not asked, for no candidate in the library, and keeps no
    verdict from pass. Every other indexer and kind is listed apart, not asked.
  - **Stops** (point 7). A budget or 429 stop in any try of a search makes that indexer
    inconclusive in that search and every later one.
  - **Rows** (point 11). Per aligned seam call and covered indexer, the multisets of
    `{title, size}` match (`Rows.count_keys/1` and `Rows.native_count_keys/2`).
  - **Picks** (point 11). Each covered indexer's rows judged alone, and all rows judged
    together, give the same key on both sides (`Picks`). A pooled difference in a search where an
    indexer was not covered, or where Prowlarr returned rows of an indexer the map does not name,
    is judged again without those indexers' rows: a difference that stays counts, one that goes
    makes the try inconclusive once no other gap is left, or once a known difference explains the
    others.
  - **Known differences** (points 11 and 12). A try's gaps are explained only when one set of
    known differences (`Rows.subsets/0`, smallest first) applied to the recorded rows removes all
    of them at once. The report lists the other differences of point 12 as text.
  - **A search is inconclusive** when its two sides' seam calls do not pair up (one side stopped
    after an error, as `judge_season/3` does), when a replay asks a call that was not recorded or
    leaves one unasked, or when a side's replay over its own recorded rows does not give the key
    it recorded.
  - **Retry** (point 10). A try differs when it has a gap no known difference explains. A search
    whose first try differs and has no second is listed in `retry`; it differs only when both
    tries differ. The second try, when it ran, decides coverage and evidence.
  - **Evidence** (amendment change 1). Each indexer needs a covered search where both sides
    returned rows for it after the cut and its rows and picks matched as recorded, and a passed
    link check. A try whose gaps a known difference explains gives no evidence, with one
    exception (#1943): when `:category_filter` alone explains the try, the try has no
    inconclusive reason as recorded or under that filter, and every gap as recorded is a row gap
    of Native-only rows, the try gives
    evidence from the rows left once that filter drops Native's off-category rows. An indexer
    then needs rows on both sides among those kept rows.
  - **Blocks.** Per-indexer blocks pass through the map where #1684 builds the opts: a block
    scoped to one source with no twin for the mapped indexer of the other keeps the verdict from
    pass.
  - **Verdict** (point 17). `:fail` when a difference is confirmed; else `:pass` when nothing
    below is left; else `:inconclusive`, with each reason.

  ## Answer

  `%{verdict, reasons, retry, report}`: `retry` holds the indexes in `searches` to run again,
  and `report` the text `Cinder.Indexers.Parity.Text` writes; its moduledoc lists what it prints.
  """

  alias Cinder.Acquisition.IndexerSource.Report
  alias Cinder.Indexers.Parity.{HistoryMatch, Picks, Rows, Text}

  # How long past a Prowlarr side's end a history entry still counts: `HistoryService` writes it
  # from an async handler after the answer, on Prowlarr's clock.
  @history_slack_s 5

  @type verdict :: :pass | :fail | :inconclusive

  @doc "Compares a recorded run. See the moduledoc."
  @spec compare(map()) :: %{
          verdict: verdict(),
          reasons: [term()],
          retry: [non_neg_integer()],
          report: String.t()
        }
  def compare(run) do
    ctx = context(run)
    searches = run.searches |> Enum.with_index() |> Enum.map(&evaluate_search(&1, ctx))
    cells = cells(ctx, searches)
    evidence = evidence(ctx, searches)

    confirmed = for s <- searches, gap <- s.confirmed, do: {s.index, gap}
    reasons = reasons(ctx, searches, cells, evidence)

    verdict =
      cond do
        confirmed != [] -> :fail
        reasons == [] -> :pass
        true -> :inconclusive
      end

    retry = for %{retry?: true, index: index} <- searches, do: index

    result = %{
      verdict: verdict,
      reasons: reasons,
      retry: retry,
      searches: searches,
      cells: cells,
      evidence: evidence,
      confirmed: confirmed
    }

    %{verdict: verdict, reasons: reasons, retry: retry, report: Text.render(run, ctx, result)}
  end

  # --- the run's context ---

  defp context(run) do
    cids = MapSet.new(run.indexers, & &1.id)
    map = run.prowlarr_map

    pids_by_cid =
      Enum.reduce(map, %{}, fn {pid, cid}, acc -> Map.update(acc, cid, [pid], &[pid | &1]) end)

    searched = MapSet.new(run.searches, & &1.kind)

    %{
      run: run,
      map: map,
      cids: cids,
      undrawn: run |> Map.get(:planned, []) |> Enum.uniq() |> Enum.reject(&(&1 in searched)),
      indexers: Map.new(run.indexers, &{&1.id, &1}),
      pids_by_cid: Map.new(pids_by_cid, fn {cid, pids} -> {cid, Enum.sort(pids)} end),
      stops: first_stops(run.searches),
      history: run.history,
      statuses: run.statuses
    }
  end

  # The first search index, and its reason, at which each configured indexer was stopped.
  defp first_stops(searches) do
    for {search, index} <- Enum.with_index(searches),
        try <- search.tries,
        side <- [try.prowlarr, try.native],
        %{indexer_id: cid, reason: reason} <- Map.get(side, :stops, []),
        reduce: %{} do
      acc -> Map.put_new(acc, cid, {index, Picks.tag(reason)})
    end
  end

  # --- one search ---

  defp evaluate_search({search, index}, ctx) do
    base = %{index: index, search: search, confirmed: [], first_gaps: [], retry?: false}

    case search.tries do
      [] ->
        Map.merge(base, %{status: {:inconclusive, :no_try}, deciding: nil, tries: []})

      tries ->
        results = Enum.map(tries, &evaluate_try(search, index, &1, ctx))
        [first | rest] = results
        decide(Map.merge(base, %{tries: results, first_gaps: first.gaps}), first, rest)
    end
  end

  defp decide(s, %{gaps: []} = first, _rest),
    do: Map.merge(s, %{deciding: first, status: first.status})

  defp decide(s, first, []),
    do: Map.merge(s, %{deciding: first, status: first.status, retry?: true})

  defp decide(s, _first, [second | _rest]),
    do: Map.merge(s, %{deciding: second, status: second.status, confirmed: second.gaps})

  defp evaluate_try(search, index, try, ctx) do
    p_calls = try.prowlarr.calls
    n_calls = try.native.calls
    cut = cut_time(p_calls, n_calls)
    window = prowlarr_window(try.prowlarr)

    native_report =
      n_calls
      |> Enum.map(&Rows.report(&1.outcome))
      |> Enum.reduce(Report.new(), &Report.merge(&2, &1))

    statuses =
      Map.new(ctx.cids, fn cid ->
        {cid, cid_status(cid, search, index, try, native_report, window, ctx)}
      end)

    history_counts = history_counts(ctx, try)

    base = %{
      cut: cut,
      window: window,
      statuses: statuses,
      native_report: native_report,
      history_counts: history_counts,
      gaps: [],
      explained: nil,
      evidence: MapSet.new(),
      status: :ok
    }

    with {:ok, pairs} <- aligned(p_calls, n_calls),
         :ok <- faithful(search, try) do
      compare_try(base, search, pairs, cut, ctx)
    else
      {:inconclusive, reason} -> %{base | status: {:inconclusive, reason}}
    end
  end

  defp aligned(p_calls, n_calls) do
    case Rows.align(p_calls, n_calls) do
      {:ok, pairs} ->
        {:ok, pairs}

      :calls_differ ->
        errored? = Enum.any?(p_calls ++ n_calls, &(Rows.rows(&1.outcome) == nil))
        {:inconclusive, if(errored?, do: :halted_after_error, else: :calls_differ)}
    end
  end

  # Each side's replay over its own recorded rows gives the key it recorded and asks exactly the
  # recorded calls.
  defp faithful(search, try) do
    Enum.reduce_while([try.prowlarr, try.native], :ok, fn side, :ok ->
      {key, outcome} = Picks.replay(search, search.opts, side.calls)

      cond do
        key == {:error, :raised} -> {:halt, {:inconclusive, :caller_raised}}
        diverged?(outcome) -> {:halt, {:inconclusive, :replay_diverged}}
        key != side.result -> {:halt, {:inconclusive, :replay_differs_from_record}}
        true -> {:cont, :ok}
      end
    end)
  end

  defp diverged?(%{unanswered: unanswered, not_recorded: not_recorded}),
    do: unanswered != [] or not_recorded != []

  defp cut_time(p_calls, n_calls) do
    case for([call | _] <- [p_calls, n_calls], do: call.started_at) do
      [] -> nil
      starts -> Enum.min(starts, DateTime)
    end
  end

  defp prowlarr_window(%{calls: [first | _], finished_at: %DateTime{} = finished}),
    do: {first.started_at, DateTime.add(finished, @history_slack_s, :second)}

  defp prowlarr_window(_side), do: nil

  # --- coverage of one indexer in one try ---

  defp cid_status(cid, search, index, try, native_report, window, ctx) do
    cond do
      stopped?(ctx, cid, index) -> {:inconclusive, elem(ctx.stops[cid], 1)}
      not cell?(ctx, cid, search) -> :not_asked
      true -> asked_status(cid, try, native_report, window, ctx)
    end
  end

  defp stopped?(ctx, cid, index),
    do: match?({at, _reason} when at <= index, Map.get(ctx.stops, cid))

  defp asked_status(cid, try, native_report, window, ctx) do
    pids = Map.get(ctx.pids_by_cid, cid, [])

    with :ok <- mapped(pids),
         :ok <- native_asked(native_report, cid),
         :ok <- prowlarr_asked(cid, pids, try, window, ctx) do
      :covered
    else
      {:uncovered, _reason} = uncovered -> uncovered
    end
  end

  defp mapped([_pid]), do: :ok
  defp mapped([]), do: {:uncovered, :no_prowlarr_indexer}
  defp mapped(_pids), do: {:uncovered, :ambiguous_map}

  defp native_asked(report, cid) do
    case Map.get(report.indexers, {"native", cid}) do
      %{outcome: :asked} -> :ok
      nil -> {:uncovered, :native_no_answer}
      %{outcome: {class, reason}} -> {:uncovered, {:"native_#{class}", outcome_tag(reason)}}
    end
  end

  defp outcome_tag(reason) when is_atom(reason), do: reason
  defp outcome_tag(reason) when is_tuple(reason), do: elem(reason, 0)

  defp prowlarr_asked(cid, [pid], try, window, ctx) do
    entries = run_entries(ctx, [pid], try)

    cond do
      Enum.any?(try.prowlarr.calls, &(Rows.rows(&1.outcome) == nil)) ->
        {:uncovered, :prowlarr_call_failed}

      Enum.any?(entries, &(not &1.successful)) ->
        {:uncovered, :prowlarr_query_failed}

      Enum.any?(entries, &Map.get(&1, :cached, false)) ->
        {:uncovered, :prowlarr_cached}

      unanswered?(expected_requests(cid, ctx, try), entries) ->
        {:uncovered, :prowlarr_not_asked}

      backoff?(ctx.statuses, pid, window) ->
        {:uncovered, :prowlarr_backoff}

      true ->
        :ok
    end
  end

  # The history entries of the Prowlarr indexers `pids` in a try's Prowlarr window that match a
  # request the try's Prowlarr side sent (`HistoryMatch`, #1859): another client's query in the
  # window, a live poller's included, is left out.
  defp run_entries(ctx, pids, try) do
    sent = Enum.flat_map(try.prowlarr.calls, &HistoryMatch.expected_of_call/1)

    ctx.history
    |> entries_in(pids, prowlarr_window(try.prowlarr))
    |> Enum.filter(fn entry -> Enum.any?(sent, &HistoryMatch.matches?(entry, &1)) end)
  end

  defp entries_in(_history, _pids, nil), do: []

  defp entries_in(history, pids, {from, to}) do
    Enum.filter(history, fn entry ->
      entry.indexer_id in pids and not DateTime.before?(entry.date, from) and
        not DateTime.after?(entry.date, to)
    end)
  end

  # The requests Prowlarr sent the indexer in this search: those of each call Native asked it in
  # (`Cinder.Acquisition.IndexerSource.Prowlarr.requests/2`). `native_asked/2` passed, so there
  # is at least one. Prowlarr skips a TV request with a TVDB id, with no history entry, for an
  # indexer whose caps lack `tvdbid` (#1933): `tvdb_search: false` leaves it out.
  defp expected_requests(cid, ctx, try) do
    skips_tvdb? = ctx.indexers[cid][:tvdb_search] == false

    try.native.calls
    |> Enum.filter(
      &match?(%{outcome: :asked}, Map.get(Rows.report(&1.outcome).indexers, {"native", cid}))
    )
    |> Enum.flat_map(&HistoryMatch.expected_of_call/1)
    |> Enum.reject(&(skips_tvdb? and Map.has_key?(&1.ids, "tvdbId")))
  end

  # A request with no matching entry. One request can write several entries, one per page
  # Prowlarr fetches, so the entries are matched per request, never counted.
  defp unanswered?(requests, entries),
    do: not Enum.all?(requests, fn r -> Enum.any?(entries, &HistoryMatch.matches?(&1, r)) end)

  defp backoff?(_statuses, _pid, nil), do: false

  defp backoff?(statuses, pid, {from, to}) do
    Enum.any?(statuses, fn status ->
      status.indexer_id == pid and match?(%DateTime{}, status.disabled_till) and
        not DateTime.before?(status.disabled_till, from) and
        not after_window?(Map.get(status, :most_recent_failure), to)
    end)
  end

  defp after_window?(%DateTime{} = failure, to), do: DateTime.after?(failure, to)
  defp after_window?(_none, _to), do: false

  defp history_counts(ctx, try) do
    Map.new(ctx.cids, fn cid ->
      entries = run_entries(ctx, Map.get(ctx.pids_by_cid, cid, []), try)
      {cid, {length(entries), entries |> Enum.map(&(&1.query_results || 0)) |> Enum.sum()}}
    end)
  end

  # --- cells ---

  defp cell?(ctx, cid, search) do
    kind = search.kind
    indexer = Map.fetch!(ctx.indexers, cid)
    kind in indexer.kinds or asked_evidence?(ctx, cid, search)
  end

  defp asked_evidence?(_ctx, cid, %{kind: :movie_imdb} = search) do
    rows =
      for try <- search.tries,
          call <- try.native.calls,
          row <- Rows.rows(call.outcome) || [],
          do: row

    Enum.any?(rows, fn row ->
      Map.get(row, :indexer_id) == cid and :id_scoped in (Map.get(row, :query_origins) || [])
    end)
  end

  defp asked_evidence?(ctx, cid, search) do
    pids = Map.get(ctx.pids_by_cid, cid, [])

    outcomes =
      for try <- search.tries,
          call <- try.native.calls,
          %{outcome: outcome} <- [Map.get(Rows.report(call.outcome).indexers, {"native", cid})],
          do: outcome

    Enum.any?(outcomes, &(&1 != {:not_asked, :caps})) or
      Enum.any?(search.tries, &(run_entries(ctx, pids, &1) != []))
  end

  # Each indexer's cells: `{cid, kind} => status`, and the kinds it was not asked in.
  defp cells(ctx, searches) do
    corpus_kinds = searches |> Enum.map(& &1.search.kind) |> Enum.uniq()

    for {cid, indexer} <- ctx.indexers,
        kind <- Enum.uniq(indexer.kinds ++ corpus_kinds),
        kind in Picks.kinds(),
        into: %{} do
      of_kind = Enum.filter(searches, &(&1.search.kind == kind))

      status =
        if kind in ctx.undrawn,
          do: {:not_asked, :no_candidate},
          else: cell_status(cid, kind, indexer, of_kind)

      {{cid, kind}, status}
    end
  end

  defp cell_status(cid, kind, indexer, of_kind) do
    statuses =
      for %{deciding: %{statuses: statuses}} <- of_kind, do: Map.fetch!(statuses, cid)

    cond do
      of_kind == [] -> {:uncovered, :no_search}
      statuses == [] -> {:inconclusive, :no_try}
      Enum.all?(statuses, &(&1 == :not_asked)) and kind not in indexer.kinds -> :not_asked
      s = Enum.find(statuses, &match?({:inconclusive, _}, &1)) -> s
      s = Enum.find(statuses, &match?({:uncovered, _}, &1)) -> s
      true -> :covered
    end
  end

  # --- comparing one aligned try ---

  defp compare_try(base, search, pairs, cut, ctx) do
    {gaps, inconclusive} = gaps(search, pairs, [], cut, base.statuses, ctx)

    # A pooled pick that only the uncovered indexers change makes the try inconclusive, but only
    # once no other gap is left: a covered indexer's own gap still counts.
    cond do
      gaps == [] and inconclusive == nil ->
        %{base | evidence: evidence_cids(search, pairs, [], cut, base.statuses, ctx)}

      gaps == [] ->
        %{base | status: {:inconclusive, inconclusive}}

      explained = explaining(search, pairs, cut, base.statuses, ctx) ->
        {subset, still_inconclusive} = explained
        base = %{base | explained: {subset, gaps}}

        cond do
          still_inconclusive ->
            %{base | status: {:inconclusive, still_inconclusive}}

          off_category_rows_only?(subset, gaps, inconclusive) ->
            %{base | evidence: evidence_cids(search, pairs, subset, cut, base.statuses, ctx)}

          true ->
            base
        end

      true ->
        %{base | gaps: gaps}
    end
  end

  # The first set of known differences under which no gap is left, with the inconclusive reason
  # that remains under it.
  defp explaining(search, pairs, cut, statuses, ctx) do
    Enum.find_value(Rows.subsets(), fn subset ->
      case gaps(search, pairs, subset, cut, statuses, ctx) do
        {[], inconclusive} -> {subset, inconclusive}
        _gaps -> nil
      end
    end)
  end

  # The gaps of a try with `subset` applied: `{gaps, inconclusive_reason}`.
  defp gaps(search, pairs, subset, cut, statuses, ctx) do
    {p_calls, n_calls} = prepared(search, pairs, subset, cut, ctx)
    covered = for {cid, :covered} <- statuses, do: cid

    row_gaps =
      for {{p, n}, i} <- Enum.with_index(Enum.zip(p_calls, n_calls)),
          rows_p = Rows.rows(p.outcome),
          rows_n = Rows.rows(n.outcome),
          rows_p != nil and rows_n != nil,
          cid <- covered,
          cid_rows_p = Rows.only_cid(rows_p, :prowlarr, cid, ctx.map),
          count_p = Rows.count_keys(cid_rows_p),
          count_n =
            Rows.native_count_keys(Rows.only_cid(rows_n, :native, cid, ctx.map), cid_rows_p),
          count_p != count_n,
          do:
            {:rows, i, p.callback, cid, {total(count_p), total(count_n)},
             multiset_minus(count_p, count_n), multiset_minus(count_n, count_p)}

    pick_gaps =
      for cid <- covered,
          {key_p, key_n} =
            keys(search, only(p_calls, :prowlarr, cid, ctx), only(n_calls, :native, cid, ctx)),
          key_p != key_n,
          do: {:pick, cid, key_p, key_n}

    {pooled, inconclusive} = pooled_gap(search, p_calls, n_calls, statuses, ctx)
    {row_gaps ++ pick_gaps ++ pooled, inconclusive}
  end

  defp pooled_gap(search, p_calls, n_calls, statuses, ctx) do
    {key_p, key_n} = keys(search, p_calls, n_calls)

    # A row of a Prowlarr indexer the map does not name has no configured indexer (`nil`): no
    # Native row can match it, so it is left out like an uncovered indexer's.
    unmapped =
      for call <- p_calls,
          row <- Rows.rows(call.outcome) || [],
          Rows.cid(:prowlarr, row, ctx.map) == nil,
          into: MapSet.new(),
          do: nil

    open =
      for {cid, status} <- statuses,
          status not in [:covered, :not_asked],
          into: unmapped,
          do: cid

    cond do
      key_p == key_n ->
        {[], nil}

      MapSet.size(open) == 0 ->
        {[{:pooled, key_p, key_n}], nil}

      true ->
        {p_closed, n_closed} =
          {drop(p_calls, :prowlarr, open, ctx), drop(n_calls, :native, open, ctx)}

        {kp, kn} = keys(search, p_closed, n_closed)
        if kp == kn, do: {[], :pooled_differs_with_uncovered}, else: {[{:pooled, kp, kn}], nil}
    end
  end

  defp keys(search, p_calls, n_calls) do
    {elem(Picks.replay(search, search.opts, p_calls), 0),
     elem(Picks.replay(search, search.opts, n_calls), 0)}
  end

  defp only(calls, side, cid, ctx),
    do:
      Enum.map(
        calls,
        &%{
          &1
          | outcome:
              Rows.map_rows(&1.outcome, fn rows -> Rows.only_cid(rows, side, cid, ctx.map) end)
        }
      )

  defp drop(calls, side, cids, ctx),
    do:
      Enum.map(
        calls,
        &%{
          &1
          | outcome:
              Rows.map_rows(&1.outcome, fn rows -> Rows.drop_cids(rows, side, cids, ctx.map) end)
        }
      )

  # The two sides' calls as every comparison reads them: the known differences of `subset`, the
  # cut, then the rows left out.
  defp prepared(search, pairs, subset, cut, ctx) do
    imdb_drop =
      if search.kind == :movie_imdb,
        do:
          for(
            {cid, i} <- ctx.indexers,
            :movie_imdb not in i.kinds and not asked_evidence?(ctx, cid, search),
            into: MapSet.new(),
            do: cid
          ),
        else: MapSet.new()

    pairs
    |> Rows.apply_differences(subset, ctx.map)
    |> Enum.map(fn {p, n} ->
      not_asked =
        for {{"native", cid}, %{outcome: {:not_asked, _}}} <- Rows.report(n.outcome).indexers,
            into: imdb_drop,
            do: cid

      prep = fn call, side ->
        %{
          call
          | outcome:
              Rows.map_rows(call.outcome, fn rows ->
                rows |> cut_rows(cut) |> Rows.drop_cids(side, not_asked, ctx.map)
              end)
        }
      end

      {prep.(p, :prowlarr), prep.(n, :native)}
    end)
    |> Enum.unzip()
  end

  defp cut_rows(rows, nil), do: rows
  defp cut_rows(rows, cut), do: Rows.cut(rows, cut)

  defp total(counts), do: counts |> Map.values() |> Enum.sum()

  defp multiset_minus(a, b) do
    for {key, count} <- a, left = count - Map.get(b, key, 0), left > 0, do: {key, left}
  end

  # #1943: a try whose recorded gaps are all row gaps, that `:category_filter` alone explains,
  # and that has no inconclusive reason as recorded (`inconclusive`), differs only by the
  # off-category rows Prowlarr's filter drops after the fetch. That filter drops Native rows only,
  # so each such gap is one of rows only Native holds. Any other known difference, a pick gap, or
  # a pooled pick that differed as recorded keeps the rule that an explained try gives no
  # evidence.
  defp off_category_rows_only?(subset, gaps, inconclusive) do
    inconclusive == nil and subset == [:category_filter] and
      Enum.all?(gaps, &match?({:rows, _, _, _, _, _, _}, &1))
  end

  # The covered indexers with rows on both sides of a try once `subset` applies: `[]` for a try
  # that has no gap as recorded, `[:category_filter]` for one `off_category_rows_only?/3` admits.
  defp evidence_cids(search, pairs, subset, cut, statuses, ctx) do
    {p_calls, n_calls} = prepared(search, pairs, subset, cut, ctx)

    for {cid, :covered} <- statuses,
        rows?(p_calls, :prowlarr, cid, ctx) and rows?(n_calls, :native, cid, ctx),
        into: MapSet.new(),
        do: cid
  end

  defp rows?(calls, side, cid, ctx),
    do: Enum.any?(calls, &(Rows.only_cid(Rows.rows(&1.outcome) || [], side, cid, ctx.map) != []))

  # --- the verdict ---

  defp evidence(ctx, searches) do
    with_rows =
      for %{deciding: %{evidence: cids}} <- searches, cid <- cids, into: MapSet.new(), do: cid

    Map.new(ctx.indexers, fn {cid, indexer} ->
      {cid,
       %{
         rows: MapSet.member?(with_rows, cid),
         link_check: link_tag(Map.get(indexer, :link_check, :not_run))
       }}
    end)
  end

  defp reasons(ctx, searches, cells, evidence) do
    Enum.concat([
      if(ctx.run.searches == [], do: [:no_search], else: []),
      if(ctx.indexers == %{}, do: [:no_indexer], else: []),
      mapping_reasons(ctx),
      for(
        {cid, indexer} <- Enum.sort(ctx.indexers),
        Enum.any?(indexer.kinds, &(&1 not in Picks.kinds())),
        do: {:unknown_kind, cid}
      ),
      block_reasons(ctx),
      for(%{retry?: true, index: i} <- searches, do: {:retry_pending, i}),
      for(
        %{status: {:inconclusive, reason}, index: i} <- searches,
        do: {:search_inconclusive, i, reason}
      ),
      for(
        {{cid, kind}, {class, reason}} <- Enum.sort(cells),
        class in [:uncovered, :inconclusive],
        do: {:"cell_#{class}", cid, kind, reason}
      ),
      for({cid, e} <- Enum.sort(evidence), not e.rows, do: {:no_evidence, cid}),
      for(
        {cid, e} <- Enum.sort(evidence),
        e.link_check not in [:passed, {:unpicked, :passed}],
        do: {:link_check, cid, e.link_check}
      )
    ])
  end

  defp link_tag(:passed), do: :passed
  defp link_tag({:failed, tag}), do: {:failed, Picks.tag(tag)}
  defp link_tag({:unpicked, :passed}), do: {:unpicked, :passed}
  defp link_tag({:unpicked, {:failed, tag}}), do: {:unpicked, {:failed, Picks.tag(tag)}}
  defp link_tag(:not_run), do: :not_run

  defp link_tag({:not_run, {:picks, picks}}) when is_list(picks),
    do: {:not_run, {:picks, Enum.map(picks, &closed_tag/1)}}

  defp link_tag({:not_run, reason}), do: {:not_run, closed_tag(reason)}
  defp link_tag(_other), do: :other

  # A link check's reason as a closed tag (#1954): atoms and integers, in tuples; anything else
  # `:other`.
  defp closed_tag(term) when is_atom(term) or is_integer(term), do: term

  defp closed_tag(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.map(&closed_tag/1) |> List.to_tuple()

  defp closed_tag(_term), do: :other

  defp mapping_reasons(ctx) do
    seen_pids =
      for search <- ctx.run.searches,
          try <- search.tries,
          call <- try.prowlarr.calls,
          row <- Rows.rows(call.outcome) || [],
          into: MapSet.new(),
          do: Map.get(row, :indexer_id)

    unmapped =
      for pid <- Enum.sort(MapSet.to_list(seen_pids)),
          not Map.has_key?(ctx.map, pid),
          uniq: true,
          do: {:unmapped_prowlarr_indexer, if(is_integer(pid), do: pid, else: :other)}

    unknown =
      for {pid, cid} <- Enum.sort(ctx.map),
          not MapSet.member?(ctx.cids, cid),
          do: {:map_names_unknown_indexer, pid, cid}

    ambiguous =
      for {cid, [_, _ | _] = pids} <- Enum.sort(ctx.pids_by_cid),
          MapSet.member?(ctx.cids, cid),
          do: {:ambiguous_map, cid, pids}

    missing =
      for cid <- Enum.sort(MapSet.to_list(ctx.cids)),
          not Map.has_key?(ctx.pids_by_cid, cid),
          do: {:no_prowlarr_indexer, cid}

    unmapped ++ unknown ++ ambiguous ++ missing
  end

  # A block scoped to one source whose mapped twin for the other source is missing.
  defp block_reasons(ctx) do
    for {search, index} <- Enum.with_index(ctx.run.searches),
        blocks = Keyword.get(search.opts, :release_blocklist, []),
        scoped = for({title, {source, id}} <- blocks, do: {String.downcase(title), source, id}),
        {title, source, id} <- scoped,
        {twin_source, twin_id} <- twins(source, id, ctx),
        {title, twin_source, twin_id} not in scoped,
        uniq: true,
        do: {:block_without_twin, index}
  end

  defp twins("prowlarr", pid, ctx) do
    case Map.get(ctx.map, pid) do
      nil -> []
      cid -> [{"native", cid}]
    end
  end

  defp twins("native", cid, ctx),
    do: Enum.map(Map.get(ctx.pids_by_cid, cid, []), &{"prowlarr", &1})

  defp twins(_source, _id, _ctx), do: []
end
