defmodule Cinder.Indexers.Parity.Text do
  # #1916: a row difference line held over 8,800 characters on #1690's run 2.
  @max_entries 10

  @moduledoc """
  The parity check's report (`Cinder.Indexers.Parity`), plain text for `bin/cinder rpc` (#1624
  point 16): the seed, the window, a line per kind the run could not draw
  (`not drawn: <kind> (no candidate in the library)`), the verdict and its reasons, a line per
  cell, the evidence per indexer, each search's tries with their history counts, differences,
  explained gaps and inconclusive reasons, the searches to run again, and the known differences
  the check cannot apply.

  A row difference (#1916) prints each side's row count of that indexer in that call: the rows
  left after the timing cut, as `Rows.count_keys/1` and `Rows.native_count_keys/2` count them.
  So a side with no row left to compare reads apart from a short one. Then each side's rows the
  other lacks, one entry per title and size with its row count: at most #{@max_entries} entries,
  sorted by title and size, then how many more entries and how many such rows in all.

  A link check that did not run and carries a reason (#1954) prints it after `not_run`, in fixed
  words and closed tags: no Native row of the indexer in any search's first try, the pick over
  its own first-try rows in each search that held one, by the search's index (`#0 no_match`),
  the stop and its reason, or the deadline. A bare `:not_run`, which the run no longer gives,
  prints `not_run` alone.

  From the input it prints the seed, search labels, indexer names, titles, sizes, counts, ids,
  times (the window, a wait's end) and closed tags only, beside its own fixed text such as the
  listed differences; never a link, a request URL, a history entry's URL, a key or an error
  term. Every string from the input passes through `safe/1`.
  """

  @max_text 200
  @no_candidate "(no candidate in the library)"

  # #1624 point 12: known differences the check lists but cannot apply.
  @listed_differences [
    "Native rejects an anime link whose free-text copy reports another series' TVDB id; Prowlarr accepts it (#1617).",
    "Native scopes every t=search to a category (#1618).",
    "Native's query-level errors do not back off; its limit waits follow the indexer (#1619).",
    "Native stops asking an indexer whose credentials are rejected (#1619).",
    "Native has no admin caps, spaces requests per indexer, and retries once, not twice (#1619).",
    "A grab-time limit backs a Native indexer off (#1619).",
    "Prowlarr drops a second copy of a release across indexers by its guid; Native rows carry none."
  ]

  @doc """
  A string from the input as the report prints it: each control character as `\\uXXXX`, its code
  point in hex; each word between two spaces that holds `=` or `://` as `[redacted]` (a link, or
  a query parameter that can carry a key); and at most #{@max_text} characters.
  """
  @spec safe(term()) :: String.t()
  def safe(text) when is_binary(text) do
    text
    |> String.replace(~r/[[:cntrl:]]/u, fn <<code_point::utf8>> ->
      "\\u" <> String.pad_leading(Integer.to_string(code_point, 16), 4, "0")
    end)
    |> String.split(" ")
    |> Enum.map_join(" ", fn word ->
      if String.contains?(word, ["=", "://"]), do: "[redacted]", else: word
    end)
    |> String.slice(0, @max_text)
  end

  def safe(nil), do: "-"
  def safe(other) when is_integer(other), do: Integer.to_string(other)
  def safe(other) when is_atom(other), do: Atom.to_string(other)
  def safe(_other), do: "?"

  @doc "The report of `result` (`Cinder.Indexers.Parity.compare/1`'s working record)."
  @spec render(map(), map(), map()) :: String.t()
  def render(run, ctx, result) do
    {from, to} = run.window

    [
      "Parity check, seed #{safe(run.seed)}",
      "Window: #{DateTime.to_iso8601(from)} to #{DateTime.to_iso8601(to)}",
      Enum.map(ctx.undrawn, &"not drawn: #{safe(&1)} #{@no_candidate}"),
      "Verdict: #{result.verdict}",
      "",
      section("Reasons", Enum.map(result.reasons, &reason(&1, ctx, run))),
      section("Cells", cells(result.cells, ctx)),
      section("Evidence", evidence(result.evidence, ctx)),
      section("Searches", Enum.flat_map(result.searches, &search(&1, ctx))),
      section("Retry", Enum.map(result.retry, &"##{&1}")),
      section("Known differences not applied", @listed_differences)
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  defp section(_title, []), do: []
  defp section(title, lines), do: ["#{title}:" | Enum.map(lines, &"  #{&1}")] ++ [""]

  defp name(ctx, cid) do
    case Map.get(ctx.indexers, cid) do
      nil -> "indexer ##{safe(cid)}"
      indexer -> "#{safe(indexer.name)} (##{cid})"
    end
  end

  defp label(run, index), do: "##{index} #{safe(Enum.at(run.searches, index).label)}"

  defp reason(:no_search, _ctx, _run), do: "the run holds no search"
  defp reason(:no_indexer, _ctx, _run), do: "the run holds no indexer"

  defp reason({:unknown_kind, cid}, ctx, _run),
    do: "#{name(ctx, cid)} lists a kind the check does not know"

  defp reason({:unmapped_prowlarr_indexer, pid}, _ctx, _run),
    do: "Prowlarr indexer #{safe(pid)} has no configured indexer in the map"

  defp reason({:map_names_unknown_indexer, pid, cid}, _ctx, _run),
    do:
      "the map sends Prowlarr indexer #{safe(pid)} to configured indexer #{safe(cid)}, which the run does not check"

  defp reason({:ambiguous_map, cid, pids}, ctx, _run),
    do: "Prowlarr indexers #{Enum.map_join(pids, ", ", &safe/1)} all map to #{name(ctx, cid)}"

  defp reason({:no_prowlarr_indexer, cid}, ctx, _run),
    do: "no Prowlarr indexer maps to #{name(ctx, cid)}"

  defp reason({:block_without_twin, index}, _ctx, run),
    do: "#{label(run, index)}: a block scoped to one source has no twin for the other"

  defp reason({:retry_pending, index}, _ctx, run),
    do: "#{label(run, index)} differs on its first try and has no second"

  defp reason({:search_inconclusive, index, why}, _ctx, run),
    do: "#{label(run, index)} is inconclusive: #{tag(why)}"

  defp reason({cell, cid, kind, why}, ctx, _run)
       when cell in [:cell_uncovered, :cell_inconclusive],
       do:
         "#{name(ctx, cid)} #{safe(kind)}: #{if cell == :cell_uncovered, do: "uncovered", else: "inconclusive"} (#{tag(why)})"

  defp reason({:no_evidence, cid}, ctx, _run),
    do: "#{name(ctx, cid)} has no search where both sides returned matching rows"

  defp reason({:link_check, cid, check}, ctx, _run),
    do: "#{name(ctx, cid)} link check: #{link_check(check)}"

  defp cells(cells, ctx) do
    for {{cid, kind}, status} <- Enum.sort(cells),
        do: "#{name(ctx, cid)} #{safe(kind)}: #{cell_text(status)}"
  end

  defp cell_text({:not_asked, :no_candidate}), do: "not asked #{@no_candidate}"
  defp cell_text(status), do: tag(status)

  defp evidence(evidence, ctx) do
    for {cid, e} <- Enum.sort(evidence),
        do:
          "#{name(ctx, cid)}: matching rows #{if e.rows, do: "found", else: "none"}, link check #{link_check(e.link_check)}"
  end

  # #1954: a link check that did not run names the reason it carries.
  defp link_check({:not_run, reason}), do: "not_run (#{not_run(reason)})"
  defp link_check(check), do: tag(check)

  defp not_run(:no_rows), do: "no Native row in any first try"
  defp not_run(:deadline), do: "deadline passed"
  defp not_run({:stopped, reason}), do: "stopped #{tag(reason)}"

  defp not_run({:picks, picks}) when is_list(picks),
    do: "pick over its own first-try rows: " <> Enum.map_join(picks, ", ", &pick_entry/1)

  defp not_run(reason), do: tag(reason)

  defp pick_entry({index, pick}) when is_integer(index), do: "##{index} #{tag(pick)}"
  defp pick_entry(entry), do: tag(entry)

  defp search(s, ctx) do
    head =
      "##{s.index} #{safe(s.search.label)} (#{safe(s.search.kind)}, first: #{safe(Map.get(s.search, :first))}): #{tag(s.status)}"

    tries =
      s.tries
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {try, n} -> try_lines(try, n, ctx) end)

    confirmed = for gap <- s.confirmed, do: "    confirmed difference: #{gap(gap, ctx)}"
    [head | tries ++ confirmed]
  end

  defp try_lines(try, n, ctx) do
    status = "    try #{n}: #{tag(try.status)}"

    history =
      for {cid, {count, results}} <- Enum.sort(try.history_counts),
          count > 0,
          do: "      history: #{name(ctx, cid)} #{count} queries, #{results} results"

    statuses =
      for {cid, st} <- Enum.sort(try.statuses),
          st != :not_asked,
          do: "      #{name(ctx, cid)}: #{tag(st)}"

    gaps = for gap <- try.gaps, do: "      difference: #{gap(gap, ctx)}"

    explained =
      case try.explained do
        nil ->
          []

        {subset, gaps} ->
          for gap <- gaps,
              do: "      explained by #{Enum.join(subset, " and ")}: #{gap(gap, ctx)}"
      end

    [status | history ++ statuses ++ gaps ++ explained]
  end

  defp gap({:rows, i, callback, cid, {rows_p, rows_n}, p_only, n_only}, ctx),
    do:
      "rows of #{name(ctx, cid)} in call #{i + 1} (#{safe(callback)}): Prowlarr #{count(rows_p, "row")}, Native #{count(rows_n, "row")}; Prowlarr only #{rows(p_only)}; Native only #{rows(n_only)}"

  defp gap({:pick, cid, p, n}, ctx),
    do: "pick of #{name(ctx, cid)} alone: Prowlarr #{pick(p)}; Native #{pick(n)}"

  defp gap({:pooled, p, n}, _ctx), do: "pooled pick: Prowlarr #{pick(p)}; Native #{pick(n)}"

  defp rows([]), do: "none"

  defp rows(rows) do
    {listed, rest} = rows |> Enum.sort() |> Enum.split(@max_entries)

    Enum.map_join(listed, ", ", fn {{title, size}, count} ->
      "#{count} x \"#{safe(title)}\" (#{safe(size)})"
    end) <> more(rest, rows)
  end

  defp more([], _rows), do: ""

  defp more(rest, rows),
    do:
      ", and #{length(rest)} more #{if length(rest) == 1, do: "entry", else: "entries"} (#{count(Enum.sum_by(rows, &elem(&1, 1)), "row")} in all)"

  defp count(1, noun), do: "1 #{noun}"
  defp count(n, noun), do: "#{n} #{noun}s"

  defp pick({:release, release}), do: release_text(release)

  defp pick({:season, selections}),
    do:
      "season " <>
        Enum.map_join(selections, ", ", fn {r, numbers} ->
          "#{release_text(r)} for #{Enum.join(numbers, " ")}"
        end)

  defp pick({:anime, assignments, waiting}),
    do:
      "episodes " <>
        Enum.map_join(assignments, ", ", fn {r, ids} ->
          "#{release_text(r)} for #{Enum.join(ids, " ")}"
        end) <>
        waiting_text(waiting)

  defp pick({:waiting, waiting}), do: "waiting" <> waiting_text(waiting)

  defp pick({:books, accepted, nil}), do: "#{length(accepted)} accepted, top none"

  defp pick({:books, accepted, {title, size}}),
    do: "#{length(accepted)} accepted, top #{release_text({title, size, nil})}"

  defp pick({:error, reason}), do: "error #{tag(reason)}"
  defp pick(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp pick(_other), do: "?"

  defp release_text({title, size, _rank}), do: "\"#{safe(title)}\" (#{safe(size)})"

  defp waiting_text(nil), do: ""

  defp waiting_text({ids, retry_at}),
    do:
      " (waiting for #{Enum.join(ids, " ")} until #{if retry_at, do: DateTime.to_iso8601(retry_at), else: "-"})"

  @doc "A closed tag as text: atoms, integers and times, in tuples; anything else `?`."
  @spec tag(term()) :: String.t()
  def tag(value) when is_atom(value), do: Atom.to_string(value)
  def tag(value) when is_integer(value), do: Integer.to_string(value)
  def tag(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def tag(value) when is_tuple(value), do: value |> Tuple.to_list() |> Enum.map_join(" ", &tag/1)
  def tag(_value), do: "?"
end
