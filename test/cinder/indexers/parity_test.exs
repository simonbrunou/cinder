defmodule Cinder.Indexers.ParityTest do
  # Every input is hand-written (#1624 point 1): no recorded body from a real site.
  use ExUnit.Case, async: true

  alias Cinder.Acquisition.AnimePreferences
  alias Cinder.Acquisition.IndexerSource.Report
  alias Cinder.Catalog.Series
  alias Cinder.Indexers.Parity
  alias Cinder.Indexers.Parity.Picks

  @gb 1_000_000_000
  @t0 ~U[2026-11-25 10:00:00Z]
  @old ~U[2026-11-01 10:00:00Z]
  @key "SYNTHETICKEY123"

  # Two configured indexers, Alpha (1) and Bravo (2), Prowlarr's 11 and 12.
  @alpha 1
  @bravo 2
  @map %{11 => @alpha, 12 => @bravo}

  defp movie_context,
    do: %{imdb_id: nil, title: "Dune", year: 2021, aliases: [], localized_titles: []}

  # A row as a source returns it; Native's carries the configured id, Prowlarr's its own.
  defp row(title, side, indexer, attrs \\ []) do
    id = if side == :native, do: indexer, else: prowlarr_id(indexer)

    Map.merge(
      %{
        title: title,
        size: 4 * @gb,
        download_url: "https://#{side}.example/#{indexer}/#{title}?apikey=#{@key}",
        protocol: :usenet,
        indexer_id: id,
        indexer_name: if(indexer == @alpha, do: "Alpha", else: "Bravo"),
        indexer_source: Atom.to_string(side),
        published_at: @old,
        category_ids: [2040]
      },
      Map.new(attrs)
    )
  end

  defp prowlarr_id(@alpha), do: 11
  defp prowlarr_id(@bravo), do: 12

  defp native_report(outcomes) do
    Enum.reduce(outcomes, Report.new(), fn {cid, outcome}, report ->
      Report.put(report, {"native", cid}, "indexer #{cid}", outcome)
    end)
  end

  defp call(callback, args, outcome, started_at \\ @t0),
    do: %{callback: callback, args: args, started_at: started_at, outcome: outcome}

  @movie_call {:search_movie_query, ["Dune 2021", []]}

  # One movie-by-title try: each side's rows, Native's report asked of both indexers.
  defp movie_try(p_rows, n_rows, opts \\ []) do
    {callback, args} = @movie_call
    native_outcomes = Keyword.get(opts, :native_outcomes, [{@alpha, :asked}, {@bravo, :asked}])
    p_outcome = Keyword.get(opts, :prowlarr_outcome, {:ok, p_rows})
    n_outcome = Keyword.get(opts, :native_outcome, {:ok, n_rows, native_report(native_outcomes)})

    %{
      prowlarr: side([call(callback, args, p_outcome)], Keyword.get(opts, :prowlarr_stops, [])),
      native:
        side(
          [call(callback, args, n_outcome, DateTime.add(@t0, 30))],
          Keyword.get(opts, :native_stops, [])
        )
    }
  end

  defp side(calls, stops),
    do: %{
      calls: calls,
      finished_at: DateTime.add(List.last(calls).started_at, 10),
      stops: stops,
      result: nil
    }

  defp search(label, kind, target, tries, opts \\ []) do
    search = %{
      label: label,
      kind: kind,
      first: :prowlarr,
      target: target,
      opts: Keyword.put(opts, :now, @t0),
      tries: tries
    }

    %{search | tries: Enum.map(tries, &record_results(search, &1))}
  end

  # Each side's recorded result is what its caller gave over the rows it saw.
  defp record_results(search, try) do
    Map.new(try, fn {name, side} ->
      result = side.result || elem(Picks.replay(search, search.opts, side.calls), 0)
      {name, %{side | result: result}}
    end)
  end

  defp movie_search(label, tries),
    do: search(label, :movie_title, %{context: movie_context()}, tries)

  # A successful history entry per indexer, inside the Prowlarr side's window.
  defp history(pids, opts \\ []) do
    for {pid, n} <- Enum.with_index(pids) do
      %{
        id: n + 1,
        indexer_id: pid,
        date: Keyword.get(opts, :date, DateTime.add(@t0, 2)),
        successful: Keyword.get(opts, :successful, true),
        query_results: 2
      }
    end
  end

  defp run(searches, attrs \\ []) do
    Map.merge(
      %{
        seed: 42,
        window: {@t0, DateTime.add(@t0, 3600)},
        indexers: [
          %{id: @alpha, name: "Alpha", kinds: [:movie_title], link_check: :passed},
          %{id: @bravo, name: "Bravo", kinds: [:movie_title], link_check: :passed}
        ],
        prowlarr_map: @map,
        history: history([11, 12]),
        statuses: [],
        searches: searches
      },
      Map.new(attrs)
    )
  end

  # Matching rows on both indexers: the base of most cases.
  defp matching_try do
    movie_try(
      [
        row("Dune.2021.1080p.WEB-DL-AAA", :prowlarr, @alpha),
        row("Dune.2021.720p.WEB-DL-BBB", :prowlarr, @bravo)
      ],
      [
        row("Dune.2021.1080p.WEB-DL-AAA", :native, @alpha),
        row("Dune.2021.720p.WEB-DL-BBB", :native, @bravo)
      ]
    )
  end

  defp lines(report), do: String.split(report, "\n")

  defp assert_line(report, fragment) do
    assert Enum.any?(lines(report), &String.contains?(&1, fragment)),
           "no line holds #{inspect(fragment)} in:\n#{report}"
  end

  defp refute_line(report, fragment) do
    refute Enum.any?(lines(report), &String.contains?(&1, fragment)),
           "a line holds #{inspect(fragment)} in:\n#{report}"
  end

  describe "the verdict" do
    test "matching rows and picks on every covered cell, with evidence and link checks, pass" do
      result = Parity.compare(run([movie_search("Dune", [matching_try()])]))
      assert result.verdict == :pass, result.report
      assert result.reasons == []
      assert result.retry == []
      assert_line(result.report, "Verdict: pass")
      assert_line(result.report, "Alpha (#1) movie_title: covered")
      assert_line(result.report, "Bravo (#2) movie_title: covered")
      assert_line(result.report, "history: Alpha (#1) 1 queries, 2 results")
    end

    test "renamed indexers: the same Prowlarr id maps, whatever the names, and the rows match" do
      try =
        movie_try(
          [
            row("Dune.2021.1080p.WEB-DL-AAA", :prowlarr, @alpha, indexer_name: "Old Alpha name"),
            row("Dune.2021.720p.WEB-DL-BBB", :prowlarr, @bravo, indexer_name: "Something else")
          ],
          [
            row("Dune.2021.1080p.WEB-DL-AAA", :native, @alpha),
            row("Dune.2021.720p.WEB-DL-BBB", :native, @bravo)
          ]
        )

      result = Parity.compare(run([movie_search("Dune", [try])]))
      assert result.verdict == :pass, result.report
      assert_line(result.report, "Verdict: pass")
      assert_line(result.report, "Alpha (#1) movie_title: covered")
      refute_line(result.report, "Old Alpha name")
    end

    test "a run with nothing in it is inconclusive, never pass" do
      assert %{verdict: :inconclusive, reasons: reasons} =
               Parity.compare(run([], indexers: [], prowlarr_map: %{}))

      assert :no_search in reasons
      assert :no_indexer in reasons
    end
  end

  describe "the mapping" do
    test "a missing map entry is reported by id, and leaves that indexer's cells uncovered" do
      result =
        Parity.compare(
          run([movie_search("Dune", [matching_try()])], prowlarr_map: %{11 => @alpha})
        )

      assert result.verdict == :inconclusive
      assert {:unmapped_prowlarr_indexer, 12} in result.reasons
      assert {:no_prowlarr_indexer, @bravo} in result.reasons
      assert {:cell_uncovered, @bravo, :movie_title, :no_prowlarr_indexer} in result.reasons
      assert_line(result.report, "Prowlarr indexer 12 has no configured indexer in the map")
      assert_line(result.report, "Bravo (#2) movie_title: uncovered no_prowlarr_indexer")
    end

    test "two Prowlarr ids mapped to one configured indexer are reported, and its cells uncovered" do
      result =
        Parity.compare(
          run([movie_search("Dune", [matching_try()])],
            prowlarr_map: %{11 => @alpha, 12 => @bravo, 13 => @bravo},
            history: history([11, 12, 13])
          )
        )

      assert result.verdict == :inconclusive
      assert {:ambiguous_map, @bravo, [12, 13]} in result.reasons
      assert {:cell_uncovered, @bravo, :movie_title, :ambiguous_map} in result.reasons
      assert_line(result.report, "Prowlarr indexers 12, 13 all map to Bravo (#2)")
      # Alpha's cell is not touched.
      assert_line(result.report, "Alpha (#1) movie_title: covered")
    end
  end

  @office_title "The.Office.S01.1080p.WEB-DL-GRP"

  defp office_row(side, attrs, indexer \\ @alpha),
    do: row(@office_title, side, indexer, Keyword.put(attrs, :category_ids, [5040]))

  # A season search of The Office: one search_tv/3 call with a TVDB id on each side, Native's
  # report asked of both indexers, and Prowlarr's history of the two queries that call sends each.
  defp office_season(p_rows, n_rows) do
    series = struct(%Series{tvdb_id: 123, title: "The Office"}, [])

    context = %{
      series: series,
      season_number: 1,
      episode_count: 2,
      episodes: [
        %{id: 1, episode_number: 1, state: :wanted},
        %{id: 2, episode_number: 2, state: :wanted}
      ],
      native_seasons: MapSet.new([1]),
      mappings: []
    }

    args = [123, "The Office", 1]

    try = %{
      prowlarr: side([call(:search_tv, args, {:ok, p_rows})], []),
      native:
        side(
          [
            call(
              :search_tv,
              args,
              {:ok, n_rows, native_report([{@alpha, :asked}, {@bravo, :asked}])}
            )
          ],
          []
        )
    }

    s = search("Office S1", :season, %{context: context, wanted_numbers: [1, 2]}, [try])

    indexers = [
      %{id: @alpha, name: "Alpha", kinds: [:season], link_check: :passed},
      %{id: @bravo, name: "Bravo", kinds: [:season], link_check: :passed}
    ]

    # A search_tv call with a TVDB id sends each indexer two queries.
    history =
      for {pid, n} <- [{11, 1}, {11, 2}, {12, 3}, {12, 4}],
          do: %{
            id: n,
            indexer_id: pid,
            date: DateTime.add(@t0, 2),
            successful: true,
            query_results: 1
          }

    {s, indexers, history}
  end

  # #1933: Prowlarr 3.1's `HttpIndexerBase.Fetch(TvSearchCriteria)` skips a TV search with a
  # TVDB id for an indexer whose caps lack `tvdbid`, and writes no history entry for it.
  defp with_tvdb_search(indexers, values),
    do: Enum.map(indexers, &Map.put(&1, :tvdb_search, Map.fetch!(values, &1.id)))

  # The Office season search with one history entry per indexer: the free-text query alone.
  defp office_one_query do
    p_rows = [office_row(:prowlarr, query_origins: [:free_text])]
    n_rows = [office_row(:native, query_origins: [:free_text])]
    {s, indexers, history} = office_season(p_rows, n_rows)
    {s, indexers, Enum.reject(history, &(&1.id in [2, 4]))}
  end

  describe "the Prowlarr queries of a search_tv call with a TVDB id" do
    test "one query covers an indexer whose caps lack tvdbid, and is one short for one whose caps list it" do
      {s, indexers, history} = office_one_query()
      indexers = with_tvdb_search(indexers, %{@alpha => false, @bravo => true})

      result = Parity.compare(run([s], indexers: indexers, history: history))
      assert_line(result.report, "Alpha (#1) season: covered")
      refute {:no_evidence, @alpha} in result.reasons
      assert {:cell_uncovered, @bravo, :season, :prowlarr_not_asked} in result.reasons
    end

    test "two queries cover an indexer whose caps list tvdbid" do
      p_rows = [office_row(:prowlarr, query_origins: [:id_scoped, :free_text])]

      n_rows = [
        office_row(:native, query_origins: [:id_scoped]),
        office_row(:native, query_origins: [:free_text])
      ]

      {s, indexers, history} = office_season(p_rows, n_rows)
      indexers = with_tvdb_search(indexers, %{@alpha => true, @bravo => true})

      result = Parity.compare(run([s], indexers: indexers, history: history))
      assert_line(result.report, "Alpha (#1) season: covered")
      assert_line(result.report, "Bravo (#2) season: covered")
    end

    # A run that could not read the caps keeps the rule from before #1933: two queries.
    test "an indexer whose caps were not read, or whose entry has no such field, expects two" do
      {s, indexers, history} = office_one_query()

      for indexers <- [with_tvdb_search(indexers, %{@alpha => nil, @bravo => nil}), indexers] do
        result = Parity.compare(run([s], indexers: indexers, history: history))
        assert {:cell_uncovered, @alpha, :season, :prowlarr_not_asked} in result.reasons
        assert {:cell_uncovered, @bravo, :season, :prowlarr_not_asked} in result.reasons
      end
    end
  end

  describe "rows" do
    test "two identical rows on one side and one on the other is a row difference" do
      try =
        movie_try(
          [
            row("Dune.2021.1080p.WEB-DL-AAA", :prowlarr, @alpha),
            row("Dune.2021.1080p.WEB-DL-AAA", :prowlarr, @alpha,
              download_url: "https://prowlarr.example/copy2"
            ),
            row("Dune.2021.720p.WEB-DL-BBB", :prowlarr, @bravo)
          ],
          [
            row("Dune.2021.1080p.WEB-DL-AAA", :native, @alpha),
            row("Dune.2021.720p.WEB-DL-BBB", :native, @bravo)
          ]
        )

      result = Parity.compare(run([movie_search("Dune", [try])]))
      assert result.verdict == :inconclusive
      assert result.retry == [0]
      assert {:retry_pending, 0} in result.reasons

      assert_line(
        result.report,
        ~s|difference: rows of Alpha (#1) in call 1 (search_movie_query): Prowlarr 2 rows, Native 1 row; Prowlarr only 1 x "Dune.2021.1080p.WEB-DL-AAA" (4000000000); Native only none|
      )
    end

    # #1916: an empty Native answer reads apart from a short one. Bravo's matching row on both
    # sides stays out of Alpha's counts.
    test "a row difference prints the rows of each side in that call and indexer" do
      aaa = "Dune.2021.1080p.WEB-DL-AAA"
      ccc = "Dune.2021.2160p.WEB-DL-CCC"
      bbb = "Dune.2021.720p.WEB-DL-BBB"

      p_rows = [
        row(aaa, :prowlarr, @alpha),
        row(aaa, :prowlarr, @alpha, download_url: "https://prowlarr.example/copy2"),
        row(ccc, :prowlarr, @alpha),
        row(bbb, :prowlarr, @bravo)
      ]

      bravo = row(bbb, :native, @bravo)
      empty = Parity.compare(run([movie_search("Dune", [movie_try(p_rows, [bravo])])]))

      assert_line(
        empty.report,
        ~s|difference: rows of Alpha (#1) in call 1 (search_movie_query): Prowlarr 3 rows, Native 0 rows; Prowlarr only 2 x "#{aaa}" (4000000000), 1 x "#{ccc}" (4000000000); Native only none|
      )

      short_try = movie_try(p_rows, [row(aaa, :native, @alpha), bravo])
      short = Parity.compare(run([movie_search("Dune", [short_try])]))

      assert_line(
        short.report,
        ~s|difference: rows of Alpha (#1) in call 1 (search_movie_query): Prowlarr 3 rows, Native 1 row; Prowlarr only 1 x "#{aaa}" (4000000000), 1 x "#{ccc}" (4000000000); Native only none|
      )
    end

    # #1916: a line held over 8,800 characters on #1690's run 2. Past 32 keys a map no longer
    # iterates in key order, so 40 titles also show the list sorted by title. An entry is one
    # title at one size, so one title at 11 sizes is 11 entries.
    test "a row difference lists at most 10 entries of a side and counts the rest" do
      titles =
        for n <- 40..1//-1, do: "Dune.2021.1080p.WEB-DL-R" <> String.pad_leading("#{n}", 2, "0")

      bravo = [row("Dune.2021.720p.WEB-DL-BBB", :prowlarr, @bravo)]
      n_bravo = [row("Dune.2021.720p.WEB-DL-BBB", :native, @bravo)]

      p_rows =
        Enum.map(titles, &row(&1, :prowlarr, @alpha)) ++
          [
            row("Dune.2021.1080p.WEB-DL-R40", :prowlarr, @alpha,
              download_url: "https://p.example/2"
            )
          ] ++
          bravo

      listed =
        Enum.map_join(1..10, ", ", fn n ->
          ~s|1 x "Dune.2021.1080p.WEB-DL-R#{String.pad_leading("#{n}", 2, "0")}" (4000000000)|
        end)

      result = Parity.compare(run([movie_search("Dune", [movie_try(p_rows, n_bravo)])]))

      assert_line(
        result.report,
        ~s|difference: rows of Alpha (#1) in call 1 (search_movie_query): Prowlarr 41 rows, Native 0 rows; Prowlarr only #{listed}, and 30 more entries (41 rows in all); Native only none|
      )

      ten = Enum.filter(titles, &(&1 <= "Dune.2021.1080p.WEB-DL-R10"))
      p_ten = Enum.map(ten, &row(&1, :prowlarr, @alpha)) ++ bravo
      result = Parity.compare(run([movie_search("Dune", [movie_try(p_ten, n_bravo)])]))

      assert_line(
        result.report,
        ~s|difference: rows of Alpha (#1) in call 1 (search_movie_query): Prowlarr 10 rows, Native 0 rows; Prowlarr only #{listed}; Native only none|
      )

      p_eleven = [row("Dune.2021.1080p.WEB-DL-R11", :prowlarr, @alpha) | p_ten]
      result = Parity.compare(run([movie_search("Dune", [movie_try(p_eleven, n_bravo)])]))

      assert_line(
        result.report,
        ~s|Prowlarr 11 rows, Native 0 rows; Prowlarr only #{listed}, and 1 more entry (11 rows in all); Native only none|
      )

      one = "Dune.2021.1080p.WEB-DL-ONE"
      p_sizes = for n <- 1..11, do: row(one, :prowlarr, @alpha, size: n * @gb)
      result = Parity.compare(run([movie_search("Dune", [movie_try(p_sizes ++ bravo, n_bravo)])]))

      assert_line(
        result.report,
        ~s|(10000000000), and 1 more entry (11 rows in all); Native only none|
      )
    end

    test "Native's two copies of one link from its id and text queries match Prowlarr's one row merged from both" do
      p_rows = [office_row(:prowlarr, query_origins: [:id_scoped, :free_text])]

      n_rows = [
        office_row(:native, query_origins: [:id_scoped]),
        office_row(:native, query_origins: [:free_text])
      ]

      {s, indexers, history} = office_season(p_rows, n_rows)
      result = Parity.compare(run([s], indexers: indexers, history: history))
      refute_line(result.report, "difference:")
      assert_line(result.report, "Alpha (#1) season: covered")
      # Bravo answered nothing on both sides: covered, matching, no evidence.
      assert {:no_evidence, @bravo} in result.reasons
      refute {:no_evidence, @alpha} in result.reasons

      # One history entry per indexer is one query short of the two a TVDB search_tv sends.
      short = Enum.reject(history, &(&1.id in [2, 4]))
      result = Parity.compare(run([s], indexers: indexers, history: short))
      assert {:cell_uncovered, @alpha, :season, :prowlarr_not_asked} in result.reasons
    end

    # #1914: on prod, Prowlarr's search_tv/3 merged none of the Usenet releases both its queries
    # found: each copy came back with a link of its own. Bravo's merged row of the same title and
    # size counts for Bravo only.
    test "Native's two copies of one link match Prowlarr's two copies that each carry a link of their own" do
      p_rows = [
        office_row(:prowlarr,
          query_origins: [:id_scoped],
          download_url: "https://prowlarr.example/1/id"
        ),
        office_row(:prowlarr,
          query_origins: [:free_text],
          download_url: "https://prowlarr.example/1/text"
        ),
        office_row(:prowlarr, [query_origins: [:id_scoped, :free_text]], @bravo)
      ]

      n_rows = [
        office_row(:native, query_origins: [:id_scoped]),
        office_row(:native, query_origins: [:free_text]),
        office_row(:native, [query_origins: [:id_scoped]], @bravo),
        office_row(:native, [query_origins: [:free_text]], @bravo)
      ]

      {s, indexers, history} = office_season(p_rows, n_rows)
      result = Parity.compare(run([s], indexers: indexers, history: history))
      refute_line(result.report, "difference:")
      assert_line(result.report, "Alpha (#1) season: covered")
      assert_line(result.report, "Bravo (#2) season: covered")
      refute {:no_evidence, @alpha} in result.reasons
      refute {:no_evidence, @bravo} in result.reasons
    end

    test "Native's copies of one link from both queries differ from Prowlarr's one row from one query" do
      p_rows = [office_row(:prowlarr, query_origins: [:id_scoped])]

      n_rows = [
        office_row(:native, query_origins: [:id_scoped]),
        office_row(:native, query_origins: [:free_text])
      ]

      {s, indexers, history} = office_season(p_rows, n_rows)
      result = Parity.compare(run([s], indexers: indexers, history: history))

      assert_line(
        result.report,
        ~s|difference: rows of Alpha (#1) in call 1 (search_tv): Prowlarr 1 row, Native 2 rows; Prowlarr only none; Native only 1 x "The.Office.S01.1080p.WEB-DL-GRP" (4000000000)|
      )
    end

    test "the timing cut drops a row published after the pair's first query on both sides; a row with no publication time stays" do
      late = DateTime.add(@t0, 5)

      try =
        movie_try(
          [
            row("Dune.2021.1080p.WEB-DL-AAA", :prowlarr, @alpha),
            row("Dune.2021.720p.WEB-DL-BBB", :prowlarr, @bravo)
          ],
          [
            row("Dune.2021.1080p.WEB-DL-AAA", :native, @alpha),
            row("Dune.2021.2160p.WEB-DL-NEW", :native, @alpha, published_at: late),
            row("Dune.2021.720p.WEB-DL-BBB", :native, @bravo)
          ]
        )

      result = Parity.compare(run([movie_search("Dune", [try])]))
      assert result.verdict == :pass, result.report
      assert_line(result.report, "Verdict: pass")
      refute_line(result.report, "Dune.2021.2160p.WEB-DL-NEW")

      undated =
        movie_try(
          [
            row("Dune.2021.1080p.WEB-DL-AAA", :prowlarr, @alpha),
            row("Dune.2021.720p.WEB-DL-BBB", :prowlarr, @bravo)
          ],
          [
            row("Dune.2021.1080p.WEB-DL-AAA", :native, @alpha),
            row("Dune.2021.480p.WEB-DL-OLD", :native, @alpha, published_at: nil),
            row("Dune.2021.2160p.WEB-DL-NEW", :native, @alpha, published_at: late),
            row("Dune.2021.720p.WEB-DL-BBB", :native, @bravo)
          ]
        )

      result = Parity.compare(run([movie_search("Dune", [undated])]))
      assert result.retry == [0]

      # The row counts leave out the row after the cut too (#1916).
      assert_line(
        result.report,
        ~s|Prowlarr 1 row, Native 2 rows; Prowlarr only none; Native only 1 x "Dune.2021.480p.WEB-DL-OLD"|
      )
    end

    test "the cut is the start of the pair's first query, whichever side went first" do
      # Native went first at t0; Prowlarr's call started 30 s later. A row published 10 s after t0
      # is after the cut on both sides.
      {callback, args} = @movie_call
      mid = DateTime.add(@t0, 10)

      p_rows = [
        row("Dune.2021.1080p.WEB-DL-AAA", :prowlarr, @alpha),
        row("Dune.2021.720p.WEB-DL-BBB", :prowlarr, @bravo),
        row("Dune.2021.2160p.WEB-DL-MID", :prowlarr, @alpha, published_at: mid)
      ]

      n_rows = [
        row("Dune.2021.1080p.WEB-DL-AAA", :native, @alpha),
        row("Dune.2021.720p.WEB-DL-BBB", :native, @bravo)
      ]

      try = %{
        prowlarr: side([call(callback, args, {:ok, p_rows}, DateTime.add(@t0, 30))], []),
        native:
          side(
            [
              call(
                callback,
                args,
                {:ok, n_rows, native_report([{@alpha, :asked}, {@bravo, :asked}])},
                @t0
              )
            ],
            []
          )
      }

      history = history([11, 12], date: DateTime.add(@t0, 32))

      assert %{verdict: :pass} =
               Parity.compare(run([movie_search("Dune", [try])], history: history))
    end
  end

  describe "coverage" do
    test "both sides {:ok, []} is covered and matching, but gives no evidence" do
      try = movie_try([], [])
      result = Parity.compare(run([movie_search("Dune", [try])]))

      assert result.verdict == :inconclusive
      assert {:no_evidence, @alpha} in result.reasons
      assert {:no_evidence, @bravo} in result.reasons
      refute Enum.any?(result.reasons, &match?({:cell_uncovered, _, _, _}, &1))

      assert_line(
        result.report,
        "Alpha (#1) has no search where both sides returned matching rows"
      )
    end

    test "Prowlarr {:ok, []} with a failed history entry leaves the cell uncovered" do
      try = movie_try([], [])

      history =
        history([11], successful: false) ++
          [
            %{
              id: 9,
              indexer_id: 12,
              date: DateTime.add(@t0, 2),
              successful: true,
              query_results: 0
            }
          ]

      result = Parity.compare(run([movie_search("Dune", [try])], history: history))

      assert {:cell_uncovered, @alpha, :movie_title, :prowlarr_query_failed} in result.reasons
      refute Enum.any?(result.reasons, &match?({:cell_uncovered, @bravo, _, _}, &1))
      assert result.verdict == :inconclusive
      assert_line(result.report, "Alpha (#1) movie_title: uncovered (prowlarr_query_failed)")
    end

    test "an answer from an indexer the status read shows in Prowlarr's backoff leaves the cell uncovered" do
      statuses = [
        %{
          indexer_id: 11,
          disabled_till: DateTime.add(@t0, 600),
          most_recent_failure: DateTime.add(@t0, -60)
        }
      ]

      result = Parity.compare(run([movie_search("Dune", [matching_try()])], statuses: statuses))

      assert result.verdict == :inconclusive
      assert {:cell_uncovered, @alpha, :movie_title, :prowlarr_backoff} in result.reasons
      assert_line(result.report, "Alpha (#1) movie_title: uncovered prowlarr_backoff")

      # A backoff that started after the search ended does not reach back into it.
      later = [
        %{
          indexer_id: 11,
          disabled_till: DateTime.add(@t0, 900),
          most_recent_failure: DateTime.add(@t0, 600)
        }
      ]

      assert %{verdict: :pass} =
               Parity.compare(run([movie_search("Dune", [matching_try()])], statuses: later))
    end

    test "a Native skip or failure leaves the cell uncovered" do
      for {outcome, reason} <- [
            {{:skipped, :deadline}, {:native_skipped, :deadline}},
            {{:failed, :timeout}, {:native_failed, :timeout}}
          ] do
        try =
          movie_try(
            [
              row("Dune.2021.1080p.WEB-DL-AAA", :prowlarr, @alpha),
              row("Dune.2021.720p.WEB-DL-BBB", :prowlarr, @bravo)
            ],
            [row("Dune.2021.720p.WEB-DL-BBB", :native, @bravo)],
            native_outcomes: [{@alpha, outcome}, {@bravo, :asked}]
          )

        result = Parity.compare(run([movie_search("Dune", [try])]))

        assert {outcome, {:cell_uncovered, @alpha, :movie_title, reason} in result.reasons} ==
                 {outcome, true}
      end
    end

    test "a Prowlarr call that errored leaves every cell of the search uncovered, whatever the history says" do
      try =
        movie_try(
          [],
          [
            row("Dune.2021.1080p.WEB-DL-AAA", :native, @alpha),
            row("Dune.2021.720p.WEB-DL-BBB", :native, @bravo)
          ],
          prowlarr_outcome: {:error, :timeout}
        )

      result = Parity.compare(run([movie_search("Dune", [try])]))
      assert {:cell_uncovered, @alpha, :movie_title, :prowlarr_call_failed} in result.reasons
      assert {:cell_uncovered, @bravo, :movie_title, :prowlarr_call_failed} in result.reasons
    end

    test "a Prowlarr answer from its cache is no query of the indexer, and leaves the cell uncovered" do
      cached = Enum.map(history([11, 12]), &Map.put(&1, :cached, &1.indexer_id == 11))
      result = Parity.compare(run([movie_search("Dune", [matching_try()])], history: cached))

      assert {:cell_uncovered, @alpha, :movie_title, :prowlarr_cached} in result.reasons
      refute Enum.any?(result.reasons, &match?({:cell_uncovered, @bravo, _, _}, &1))
    end

    test "an indexer Native's report does not name is uncovered" do
      try =
        movie_try(
          [
            row("Dune.2021.1080p.WEB-DL-AAA", :prowlarr, @alpha),
            row("Dune.2021.720p.WEB-DL-BBB", :prowlarr, @bravo)
          ],
          [
            row("Dune.2021.1080p.WEB-DL-AAA", :native, @alpha),
            row("Dune.2021.720p.WEB-DL-BBB", :native, @bravo)
          ],
          native_outcomes: [{@alpha, :asked}]
        )

      result = Parity.compare(run([movie_search("Dune", [try])]))
      assert {:cell_uncovered, @bravo, :movie_title, :native_no_answer} in result.reasons
    end

    test "a backoff that ended before the Prowlarr side's first call does not reach into it" do
      ended = [
        %{
          indexer_id: 11,
          disabled_till: DateTime.add(@t0, -1),
          most_recent_failure: DateTime.add(@t0, -600)
        }
      ]

      assert %{verdict: :pass} =
               Parity.compare(run([movie_search("Dune", [matching_try()])], statuses: ended))

      # The same backoff ending at the first call does.
      at_start = [
        %{indexer_id: 11, disabled_till: @t0, most_recent_failure: DateTime.add(@t0, -600)}
      ]

      result = Parity.compare(run([movie_search("Dune", [matching_try()])], statuses: at_start))
      assert {:cell_uncovered, @alpha, :movie_title, :prowlarr_backoff} in result.reasons
    end

    test "rows of an indexer Native left not asked in a call drop from that call on both sides" do
      # Bravo's caps take no movie search: Prowlarr still asked it and its row would be the pooled
      # pick; Native's report says not asked.
      try =
        movie_try(
          [
            row("Dune.2021.720p.WEB-DL-AAA", :prowlarr, @alpha),
            row("Dune.2021.1080p.WEB-DL-BBB", :prowlarr, @bravo)
          ],
          [row("Dune.2021.720p.WEB-DL-AAA", :native, @alpha)],
          native_outcomes: [{@alpha, :asked}, {@bravo, {:not_asked, :caps}}]
        )

      indexers = [
        %{id: @alpha, name: "Alpha", kinds: [:movie_title], link_check: :passed},
        %{id: @bravo, name: "Bravo", kinds: [], link_check: :passed}
      ]

      history = [
        %{id: 1, indexer_id: 11, date: DateTime.add(@t0, 2), successful: true, query_results: 1}
      ]

      result =
        Parity.compare(run([movie_search("Dune", [try])], indexers: indexers, history: history))

      refute_line(result.report, "difference:")
      assert_line(result.report, "Bravo (#2) movie_title: not_asked")
      assert result.reasons == [{:no_evidence, @bravo}]
    end

    # A movie-by-IMDb search: one `search_movie/3` call per side. Alpha's caps take the id; Bravo's
    # do not, so Prowlarr asks Bravo nothing and Native asks it by "Title Year" (#1632).
    defp imdb_run(p_rows, n_rows, opts \\ []) do
      imdb_context = %{movie_context() | imdb_id: "tt1160419"}
      args = ["tt1160419", "Dune 2021", []]
      report = native_report([{@alpha, :asked}, {@bravo, :asked}])

      imdb_try = %{
        prowlarr: side([call(:search_movie, args, {:ok, p_rows}, DateTime.add(@t0, 100))], []),
        native:
          side([call(:search_movie, args, {:ok, n_rows, report}, DateTime.add(@t0, 130))], [])
      }

      imdb =
        search(
          "Dune by id",
          :movie_imdb,
          %{imdb_id: "tt1160419", context: imdb_context},
          List.duplicate(imdb_try, Keyword.get(opts, :tries, 1))
        )

      indexers = [
        %{id: @alpha, name: "Alpha", kinds: [:movie_title, :movie_imdb], link_check: :passed},
        %{id: @bravo, name: "Bravo", kinds: [:movie_title], link_check: :passed}
      ]

      imdb_history =
        for {pid, n} <- Enum.with_index(Keyword.get(opts, :asked, [11]), 7),
            do: %{
              id: n,
              indexer_id: pid,
              date: DateTime.add(@t0, 102),
              successful: true,
              query_results: 1
            }

      Parity.compare(
        run([movie_search("Dune", [matching_try()]), imdb],
          indexers: indexers,
          history: history([11, 12]) ++ imdb_history
        )
      )
    end

    test "an indexer whose caps take no IMDb id is a not-asked cell of the movie-by-IMDb kind, its text rows left out" do
      result =
        imdb_run(
          [row("Dune.2021.720p.WEB-DL-AAA", :prowlarr, @alpha)],
          [
            row("Dune.2021.720p.WEB-DL-AAA", :native, @alpha, query_origins: [:id_scoped]),
            # Kept, it would be Native's pooled pick.
            row("Dune.2021.1080p.WEB-DL-TXT", :native, @bravo, query_origins: [:free_text])
          ]
        )

      assert result.verdict == :pass, result.report
      assert_line(result.report, "Bravo (#2) movie_imdb: not_asked")
      assert_line(result.report, "Alpha (#1) movie_imdb: covered")
      refute_line(result.report, "TXT")
    end

    test "a text row from an indexer whose caps take the IMDb id is a difference" do
      result =
        imdb_run(
          [row("Dune.2021.1080p.WEB-DL-AAA", :prowlarr, @alpha)],
          [
            row("Dune.2021.1080p.WEB-DL-AAA", :native, @alpha, query_origins: [:id_scoped]),
            row("Dune.2021.720p.WEB-DL-TXT", :native, @alpha, query_origins: [:free_text])
          ],
          tries: 2
        )

      assert result.verdict == :fail, result.report

      assert_line(
        result.report,
        ~s|confirmed difference: rows of Alpha (#1) in call 1 (search_movie): Prowlarr 1 row, Native 2 rows; Prowlarr only none; Native only 1 x "Dune.2021.720p.WEB-DL-TXT"|
      )
    end

    test "id-scoped rows from an indexer the kinds input lists without the IMDb kind are compared" do
      # Prowlarr asked Bravo by the id, so its caps do take it: the kinds input is wrong, and the
      # rows still meet.
      result =
        imdb_run(
          [
            row("Dune.2021.1080p.WEB-DL-AAA", :prowlarr, @alpha),
            row("Dune.2021.720p.WEB-DL-PPP", :prowlarr, @bravo)
          ],
          [
            row("Dune.2021.1080p.WEB-DL-AAA", :native, @alpha, query_origins: [:id_scoped]),
            row("Dune.2021.720p.WEB-DL-NNN", :native, @bravo, query_origins: [:id_scoped])
          ],
          tries: 2,
          asked: [11, 12]
        )

      assert result.verdict == :fail, result.report

      assert_line(
        result.report,
        ~s|confirmed difference: rows of Bravo (#2) in call 1 (search_movie)|
      )

      assert_line(result.report, "Bravo (#2) movie_imdb: covered")
    end

    test "a cell whose kind no search ran is uncovered" do
      indexers = [
        %{id: @alpha, name: "Alpha", kinds: [:movie_title, :ebook], link_check: :passed},
        %{id: @bravo, name: "Bravo", kinds: [:movie_title], link_check: :passed}
      ]

      result = Parity.compare(run([movie_search("Dune", [matching_try()])], indexers: indexers))
      assert result.verdict == :inconclusive
      assert {:cell_uncovered, @alpha, :ebook, :no_search} in result.reasons
    end
  end

  # #1915: a kind the run planned but drew no search of, since the library holds no candidate.
  describe "a kind the library cannot draw" do
    @alpha_tv [
      %{id: @alpha, name: "Alpha", kinds: [:movie_title, :season_zero], link_check: :passed},
      %{id: @bravo, name: "Bravo", kinds: [:movie_title], link_check: :passed}
    ]

    test "is not asked, names its kind in the header and keeps no verdict from pass" do
      result =
        Parity.compare(
          run([movie_search("Dune", [matching_try()])],
            indexers: @alpha_tv,
            planned: [:movie_title, :season_zero]
          )
        )

      assert result.verdict == :pass, result.report
      assert result.reasons == []
      assert "Verdict: pass" in lines(result.report)
      assert "not drawn: season_zero (no candidate in the library)" in lines(result.report)

      assert "  Alpha (#1) season_zero: not asked (no candidate in the library)" in lines(
               result.report
             )

      assert "  Alpha (#1) movie_title: covered" in lines(result.report)
      refute_line(result.report, "Bravo (#2) season_zero")
    end

    test "a kind the run did not plan still reads uncovered with no search" do
      result =
        Parity.compare(
          run([movie_search("Dune", [matching_try()])],
            indexers: @alpha_tv,
            planned: [:movie_title]
          )
        )

      assert result.verdict == :inconclusive
      assert result.reasons == [{:cell_uncovered, @alpha, :season_zero, :no_search}]
      assert "  Alpha (#1) season_zero: uncovered no_search" in lines(result.report)
      refute_line(result.report, "not drawn")
    end

    test "a drawn kind whose search did not run still keeps the verdict from pass" do
      result = Parity.compare(run([movie_search("Dune", [])], planned: [:movie_title]))

      assert result.verdict == :inconclusive
      assert {:cell_inconclusive, @alpha, :movie_title, :no_try} in result.reasons
      assert {:search_inconclusive, 0, :no_try} in result.reasons
      refute_line(result.report, "not drawn")
      refute_line(result.report, "no candidate")
    end

    test "a drawn kind that did not cover an indexer still keeps the verdict from pass" do
      # Prowlarr's history holds no query for Alpha (Prowlarr's 11).
      result =
        Parity.compare(
          run([movie_search("Dune", [matching_try()])],
            history: history([12]),
            planned: [:movie_title]
          )
        )

      assert result.verdict == :inconclusive
      assert {:cell_uncovered, @alpha, :movie_title, :prowlarr_not_asked} in result.reasons
      assert "  Alpha (#1) movie_title: uncovered prowlarr_not_asked" in lines(result.report)
      refute_line(result.report, "not drawn")
    end

    test "a run that drew nothing stays inconclusive" do
      result =
        Parity.compare(run([], indexers: @alpha_tv, planned: Picks.kinds()))

      assert result.verdict == :inconclusive
      assert :no_search in result.reasons
      assert {:no_evidence, @alpha} in result.reasons
      assert "not drawn: movie_title (no candidate in the library)" in lines(result.report)
    end
  end

  describe "stops" do
    test "an exhausted budget and a 429 stop leave that indexer's later searches inconclusive" do
      stopped =
        movie_try(
          [
            row("Dune.2021.1080p.WEB-DL-AAA", :prowlarr, @alpha),
            row("Dune.2021.720p.WEB-DL-BBB", :prowlarr, @bravo)
          ],
          [
            row("Dune.2021.1080p.WEB-DL-AAA", :native, @alpha),
            row("Dune.2021.720p.WEB-DL-BBB", :native, @bravo)
          ],
          native_stops: [%{indexer_id: @alpha, reason: :budget}],
          prowlarr_stops: [%{indexer_id: @bravo, reason: :rate_limited}]
        )

      searches = [
        movie_search("First", [matching_try()]),
        movie_search("Second", [stopped]),
        movie_search("Third", [matching_try()])
      ]

      result = Parity.compare(run(searches))

      assert result.verdict == :inconclusive
      assert {:cell_inconclusive, @alpha, :movie_title, :budget} in result.reasons
      assert {:cell_inconclusive, @bravo, :movie_title, :rate_limited} in result.reasons

      statuses = for s <- [1, 2], do: section_lines(result.report, "##{s} ")

      for lines <- statuses do
        assert Enum.any?(lines, &(&1 =~ "Alpha (#1): inconclusive budget"))
        assert Enum.any?(lines, &(&1 =~ "Bravo (#2): inconclusive rate_limited"))
      end

      # The search before the stop is untouched.
      first = section_lines(result.report, "#0 ")
      assert Enum.any?(first, &(&1 =~ "Alpha (#1): covered"))
    end
  end

  # The lines of one search in the report, from its heading to the next search's.
  defp section_lines(report, heading) do
    report
    |> lines()
    |> Enum.drop_while(&(not String.starts_with?(String.trim_leading(&1), heading)))
    |> Enum.take_while(
      &(not (String.starts_with?(&1, "  #") and not String.contains?(&1, heading)))
    )
  end

  describe "the retry rule" do
    defp differing_try do
      movie_try(
        [
          row("Dune.2021.1080p.WEB-DL-AAA", :prowlarr, @alpha),
          row("Dune.2021.720p.WEB-DL-BBB", :prowlarr, @bravo)
        ],
        [row("Dune.2021.720p.WEB-DL-BBB", :native, @bravo)]
      )
    end

    test "a difference on the first try only is not counted, and is listed in the report" do
      result = Parity.compare(run([movie_search("Dune", [differing_try(), matching_try()])]))

      assert result.verdict == :pass, result.report
      assert_line(result.report, "try 1: ok")

      assert_line(
        result.report,
        ~s|difference: rows of Alpha (#1) in call 1 (search_movie_query): Prowlarr 1 row, Native 0 rows; Prowlarr only 1 x "Dune.2021.1080p.WEB-DL-AAA"|
      )

      refute_line(result.report, "confirmed difference")
    end

    test "a difference on both tries that no known difference explains fails" do
      result = Parity.compare(run([movie_search("Dune", [differing_try(), differing_try()])]))

      assert result.verdict == :fail
      assert_line(result.report, "Verdict: fail")
      assert_line(result.report, ~s|confirmed difference: rows of Alpha (#1)|)
    end

    test "fail outranks every inconclusive reason" do
      result =
        Parity.compare(
          run([movie_search("Dune", [differing_try(), differing_try()])],
            indexers: [
              %{id: @alpha, name: "Alpha", kinds: [:movie_title], link_check: :not_run},
              %{id: @bravo, name: "Bravo", kinds: [:movie_title], link_check: :passed}
            ]
          )
        )

      assert result.verdict == :fail
      assert {:link_check, @alpha, :not_run} in result.reasons
    end
  end

  describe "known differences" do
    # The search, then a search whose rows match as recorded, the evidence an explained try
    # does not give.
    defp with_clean(search), do: [search, movie_search("Clean", [matching_try()])]

    test "a category-filter gap that re-judging explains is listed as explained, and the run passes" do
      # Native kept a TV-category row on Alpha that Prowlarr's filter after the fetch dropped.
      try =
        movie_try(
          [
            row("Dune.2021.1080p.WEB-DL-AAA", :prowlarr, @alpha),
            row("Dune.2021.720p.WEB-DL-BBB", :prowlarr, @bravo)
          ],
          [
            row("Dune.2021.1080p.WEB-DL-AAA", :native, @alpha),
            row("Dune.2021.2160p.WEB-DL-TVC", :native, @alpha, category_ids: [5040]),
            row("Dune.2021.720p.WEB-DL-BBB", :native, @bravo)
          ]
        )

      result = Parity.compare(run(with_clean(movie_search("Dune", [try]))))
      assert result.verdict == :pass, result.report
      assert_line(result.report, ~s|explained by category_filter: rows of Alpha (#1)|)

      # Rows that matched only once a known difference applied are no evidence.
      result = Parity.compare(run([movie_search("Dune", [try])]))
      assert result.verdict == :inconclusive
      assert result.reasons == [{:no_evidence, @alpha}, {:no_evidence, @bravo}]
    end

    test "an order gap that re-judging explains is listed as explained, and the run passes" do
      # Two releases that tie on rank: the scorer takes the first, and the sources order the
      # indexers the other way round.
      a = "Dune.2021.1080p.WEB-DL-AAA"
      b = "Dune.2021.1080p.WEB-DL-BBB"

      try =
        movie_try(
          [row(b, :prowlarr, @bravo), row(a, :prowlarr, @alpha)],
          [row(a, :native, @alpha), row(b, :native, @bravo)]
        )

      result = Parity.compare(run(with_clean(movie_search("Dune", [try]))))
      assert result.verdict == :pass, result.report
      assert_line(result.report, ~s|explained by order: pooled pick: Prowlarr "#{b}"|)
    end

    test "order never explains a gap inside one indexer" do
      # Alpha's own two rows come back reversed on Native: the per-indexer pick differs, and the
      # indexer order cannot change that.
      a = "Dune.2021.1080p.WEB-DL-AAA"
      b = "Dune.2021.1080p.WEB-DL-BBB"

      try =
        movie_try(
          [
            row(b, :prowlarr, @alpha),
            row(a, :prowlarr, @alpha),
            row("Dune.2021.720p.WEB-DL-CCC", :prowlarr, @bravo)
          ],
          [
            row(a, :native, @alpha),
            row(b, :native, @alpha),
            row("Dune.2021.720p.WEB-DL-CCC", :native, @bravo)
          ]
        )

      result = Parity.compare(run([movie_search("Dune", [try, try])]))
      assert result.verdict == :fail, result.report
      assert_line(result.report, "confirmed difference: pick of Alpha (#1) alone")
    end

    test "the row cap explains a gap only when Prowlarr held more than 1,000 rows and Native exactly 1,000" do
      filler = fn side, n ->
        for i <- 1..n, do: row("Dune.2021.480p.WEB-DL-F#{i}", side, @alpha, size: 1 * @gb)
      end

      extra = row("Dune.2021.2160p.WEB-DL-LATE", :prowlarr, @alpha)
      bravo = [row("Dune.2021.720p.WEB-DL-BBB", :prowlarr, @bravo)]

      capped =
        movie_try(
          filler.(:prowlarr, 1000) ++ [extra] ++ bravo,
          filler.(:native, 1000) ++ [row("Dune.2021.720p.WEB-DL-BBB", :native, @bravo)]
        )

      result = Parity.compare(run(with_clean(movie_search("Dune", [capped]))))
      assert result.verdict == :pass, result.report
      assert_line(result.report, "explained by row_cap")

      # Native stopping at 999 is a Native bug the cap does not explain.
      short =
        movie_try(
          filler.(:prowlarr, 999) ++ [extra] ++ bravo,
          filler.(:native, 999) ++ [row("Dune.2021.720p.WEB-DL-BBB", :native, @bravo)]
        )

      result = Parity.compare(run([movie_search("Dune", [short, short])]))
      assert result.verdict == :fail
    end
  end

  describe "pooled pick" do
    test "a pooled difference only an unmapped Prowlarr indexer's rows make is inconclusive, never fail" do
      # Prowlarr's 12 maps to no configured indexer, and its 1080p row wins Prowlarr's pooled pick.
      try =
        movie_try(
          [
            row("Dune.2021.720p.WEB-DL-AAA", :prowlarr, @alpha),
            row("Dune.2021.1080p.WEB-DL-BBB", :prowlarr, @bravo)
          ],
          [row("Dune.2021.720p.WEB-DL-AAA", :native, @alpha)],
          native_outcomes: [{@alpha, :asked}]
        )

      result =
        Parity.compare(
          run([movie_search("Dune", [try, try])],
            indexers: [%{id: @alpha, name: "Alpha", kinds: [:movie_title], link_check: :passed}],
            prowlarr_map: %{11 => @alpha},
            history: history([11])
          )
        )

      assert result.verdict == :inconclusive, result.report
      assert {:unmapped_prowlarr_indexer, 12} in result.reasons
      assert {:search_inconclusive, 0, :pooled_differs_with_uncovered} in result.reasons
      assert_line(result.report, "is inconclusive: pooled_differs_with_uncovered")
      refute_line(result.report, "confirmed difference")
    end

    test "a pooled pick from another indexer with the same title, size and rank_key matches" do
      # Both indexers carry the same release; each source takes its first indexer's copy.
      a = "Dune.2021.1080p.WEB-DL-AAA"

      try =
        movie_try(
          [row(a, :prowlarr, @bravo), row(a, :prowlarr, @alpha)],
          [row(a, :native, @alpha), row(a, :native, @bravo)]
        )

      result = Parity.compare(run([movie_search("Dune", [try])]))
      assert result.verdict == :pass, result.report
      refute_line(result.report, "explained by")
      refute_line(result.report, "difference:")
    end

    # Alpha's Prowlarr query failed in history, so Alpha is not covered; its Prowlarr row is the
    # pooled pick there.
    defp uncovered_alpha_history,
      do: [
        %{
          id: 1,
          indexer_id: 11,
          date: DateTime.add(@t0, 2),
          successful: false,
          query_results: nil
        },
        %{id: 2, indexer_id: 12, date: DateTime.add(@t0, 2), successful: true, query_results: 1}
      ]

    test "a pooled difference that goes without the uncovered indexers makes the search inconclusive" do
      try =
        movie_try(
          [
            row("Dune.2021.1080p.WEB-DL-AAA", :prowlarr, @alpha),
            row("Dune.2021.720p.WEB-DL-BBB", :prowlarr, @bravo)
          ],
          [row("Dune.2021.720p.WEB-DL-BBB", :native, @bravo)]
        )

      result =
        Parity.compare(
          run([movie_search("Dune", [try, try])], history: uncovered_alpha_history())
        )

      assert result.verdict == :inconclusive
      assert {:search_inconclusive, 0, :pooled_differs_with_uncovered} in result.reasons
      refute_line(result.report, "confirmed difference")
    end

    test "a covered indexer's row difference counts when the pooled pick is inconclusive" do
      # Without Alpha the pooled picks meet, so the pooled pick is inconclusive; Bravo's extra
      # Native row is a difference of its own.
      try =
        movie_try(
          [
            row("Dune.2021.1080p.WEB-DL-AAA", :prowlarr, @alpha),
            row("Dune.2021.720p.WEB-DL-BBB", :prowlarr, @bravo)
          ],
          [
            row("Dune.2021.720p.WEB-DL-BBB", :native, @bravo),
            row("Dune.2021.480p.WEB-DL-XTR", :native, @bravo)
          ]
        )

      result =
        Parity.compare(
          run([movie_search("Dune", [try, try])], history: uncovered_alpha_history())
        )

      assert result.verdict == :fail, result.report

      assert_line(
        result.report,
        ~s|confirmed difference: rows of Bravo (#2) in call 1 (search_movie_query): Prowlarr 1 row, Native 2 rows; Prowlarr only none; Native only 1 x "Dune.2021.480p.WEB-DL-XTR"|
      )
    end

    test "a try whose other gaps a known difference explains stays inconclusive on its pooled pick" do
      # Bravo's extra Native row has a TV category Prowlarr's filter drops; Alpha is uncovered and
      # holds Prowlarr's pooled pick.
      try =
        movie_try(
          [
            row("Dune.2021.1080p.WEB-DL-AAA", :prowlarr, @alpha),
            row("Dune.2021.720p.WEB-DL-BBB", :prowlarr, @bravo)
          ],
          [
            row("Dune.2021.720p.WEB-DL-BBB", :native, @bravo),
            row("Dune.2021.480p.WEB-DL-TVC", :native, @bravo, category_ids: [5040])
          ]
        )

      result =
        Parity.compare(run([movie_search("Dune", [try])], history: uncovered_alpha_history()))

      assert {:search_inconclusive, 0, :pooled_differs_with_uncovered} in result.reasons
      assert_line(result.report, "explained by category_filter: rows of Bravo (#2)")
      assert result.retry == []
    end

    test "a pooled difference that stays without the uncovered indexers counts" do
      try =
        movie_try(
          [
            row("Dune.2021.1080p.WEB-DL-AAA", :prowlarr, @alpha),
            row("Dune.2021.720p.WEB-DL-BBB", :prowlarr, @bravo)
          ],
          [row("Dune.2021.480p.WEB-DL-CCC", :native, @bravo)]
        )

      result =
        Parity.compare(
          run([movie_search("Dune", [try, try])], history: uncovered_alpha_history())
        )

      assert result.verdict == :fail, result.report

      assert_line(
        result.report,
        ~s|confirmed difference: pooled pick: Prowlarr "Dune.2021.720p.WEB-DL-BBB"|
      )
    end
  end

  describe "every kind" do
    # Each kind's caller, its seam calls as Replay sees them asked, in order, and two releases
    # that tie on its pick, so the order of one indexer's rows decides which it takes.
    defp kind_case(:season), do: season_case(1, "The.Office.S01.1080p.WEB-DL")
    defp kind_case(:season_zero), do: season_case(0, "The.Office.S00E01.1080p.WEB-DL")

    defp kind_case(:anime_episodes) do
      context = %{
        kind: :series,
        title: "Show",
        year: 2020,
        tvdb_id: 99,
        aliases: [],
        episodes: [%{id: 11, season_number: 1, episode_number: 1}],
        mappings: [
          %{
            identity: %{
              source: "fixture",
              scheme: "standard",
              namespace: "fixture",
              canonical_value: "S01E01"
            },
            precedence: :manual,
            episode_ids: [11],
            evidence: %{"kind" => "fixture"}
          }
        ]
      }

      %{
        target: %{context: context, wanted_ids: [11]},
        calls: [
          {:search_tv, [99, "Show", 1]},
          {:search_tv_query, ["Show", [categories: [5070]]]},
          {:search_tv_query, ["Show S01E01", [categories: [5070]]]}
        ],
        titles: {"Show.S01E01.1080p.WEB-DL-AAA", "Show.S01E01.1080p.WEB-DL-BBB"},
        attrs: [query_origins: [:id_scoped], category_ids: [5070]]
      }
    end

    defp kind_case(:anime_movie) do
      context = %{
        kind: :movie,
        title: "Your Name",
        year: 2016,
        aliases: [],
        localized_titles: [],
        profile: %{effective: :anime}
      }

      %{
        target: %{imdb_id: "tt1", context: context},
        calls: [
          {:search, ["tt1"]},
          {:search_movie_query, ["Your Name 2016", [categories: [5070]]]}
        ],
        titles: {"Your.Name.2016.1080p.BluRay-AAA", "Your.Name.2016.1080p.BluRay-BBB"},
        attrs: [query_origins: [:id_scoped], category_ids: [5070]],
        # Prowlarr's search/1 tags no query origin.
        prowlarr_attrs: [query_origins: nil]
      }
    end

    defp kind_case(:ebook),
      do: book_case(:search_ebook, "(epub)", "(epub) [retail]", 7020, 2_000_000)

    defp kind_case(:audiobook),
      do: book_case(:search_audiobook, "(M4B)", "(M4B) (Narrated by Jane Doe)", 3030, 100_000_000)

    defp season_case(season, title) do
      context = %{
        series: struct(%Series{tvdb_id: 123, title: "The Office"}, []),
        season_number: season,
        episode_count: 2,
        episodes: [
          %{id: 1, episode_number: 1, state: :wanted},
          %{id: 2, episode_number: 2, state: :wanted}
        ],
        native_seasons: MapSet.new([season]),
        mappings: []
      }

      %{
        target: %{context: context, wanted_numbers: [1, 2]},
        calls: [{:search_tv, [123, "The Office", season]}],
        titles: {title <> "-AAA", title <> "-BBB"},
        attrs: [query_origins: [:id_scoped], category_ids: [5040]]
      }
    end

    # Two releases the book scorer accepts; it ranks them by a full order, so no row order ties.
    defp book_case(callback, a_tail, b_tail, category, size) do
      work = %{title: "The Dispossessed", authors: ["Ursula K. Le Guin"]}

      %{
        target: %{work: work},
        calls: [
          {callback, ["Ursula K. Le Guin", "The Dispossessed", []]},
          {:"#{callback}_query", ["The Dispossessed Ursula K. Le Guin", []]}
        ],
        titles:
          {"Ursula K. Le Guin - The Dispossessed #{a_tail}",
           "Ursula K. Le Guin - The Dispossessed #{b_tail}"},
        # Both adapters tag the structured book call's rows id-scoped.
        attrs: [query_origins: [:id_scoped], category_ids: [category], size: size]
      }
    end

    # One try: the rows on the caller's first call, each later call answered with none.
    defp kind_try(%{calls: [{callback, args} | rest]}, p_rows, n_rows) do
      report = native_report([{@alpha, :asked}, {@bravo, :asked}])
      later = DateTime.add(@t0, 30)

      %{
        prowlarr:
          side(
            [
              call(callback, args, {:ok, p_rows}) | for({c, a} <- rest, do: call(c, a, {:ok, []}))
            ],
            []
          ),
        native:
          side(
            [
              call(callback, args, {:ok, n_rows, report}, later)
              | for({c, a} <- rest, do: call(c, a, {:ok, [], report}, later))
            ],
            []
          )
      }
    end

    defp kind_run(kind, tries, opts \\ []) do
      indexers =
        for {id, name} <- [{@alpha, "Alpha"}, {@bravo, "Bravo"}],
            do: %{id: id, name: name, kinds: [kind], link_check: :passed}

      # Four queries an indexer: as many as any of these callers sends it in one try.
      history =
        for {pid, n} <- Enum.with_index(List.duplicate(11, 4) ++ List.duplicate(12, 4), 1),
            do: %{
              id: n,
              indexer_id: pid,
              date: DateTime.add(@t0, 2),
              successful: true,
              query_results: 1,
              cached: false
            }

      search = search("#{kind}", kind, kind_case(kind).target, tries, opts)
      {Parity.compare(run([search], indexers: indexers, history: history)), search}
    end

    defp kind_rows(kind, side, titles, attrs \\ []) do
      c = kind_case(kind)
      side_attrs = if side == :prowlarr, do: Map.get(c, :prowlarr_attrs, []), else: []

      for {title, indexer} <- titles,
          do: row(title, side, indexer, c.attrs ++ side_attrs ++ attrs)
    end

    # What each caller's pick looks like over the rows of these cases, so a caller whose answer
    # no longer fits `Picks.key/2` (`{:error, :unexpected_pick}` on both sides) fails here.
    defp pick_shape?(kind, key) when kind in [:season, :season_zero],
      do: match?({:season, [_ | _]}, key)

    defp pick_shape?(:anime_episodes, key), do: match?({:anime, [_ | _], nil}, key)
    defp pick_shape?(:anime_movie, key), do: match?({:release, {_, _, _}}, key)
    defp pick_shape?(_book, key), do: match?({:books, [_, _], {_, _}}, key)

    for kind <- [:season, :season_zero, :anime_episodes, :anime_movie, :ebook, :audiobook] do
      test "#{kind}: the same rows give the same pick, and the run passes" do
        kind = unquote(kind)
        {a, b} = kind_case(kind).titles
        rows = &kind_rows(kind, &1, [{a, @alpha}, {b, @bravo}])
        try = kind_try(kind_case(kind), rows.(:prowlarr), rows.(:native))
        {result, search} = kind_run(kind, [try])

        assert result.verdict == :pass, result.report
        assert_line(result.report, "Alpha (#1) #{kind}: covered")
        assert_line(result.report, "Bravo (#2) #{kind}: covered")
        [%{prowlarr: %{result: key}}] = search.tries
        assert pick_shape?(kind, key), inspect(key)
      end
    end

    for kind <- [:season, :season_zero, :anime_episodes, :anime_movie] do
      test "#{kind}: one indexer's tied rows in another order give another pick, and the run fails" do
        kind = unquote(kind)
        {a, b} = kind_case(kind).titles
        p = kind_rows(kind, :prowlarr, [{b, @alpha}, {a, @alpha}])
        n = kind_rows(kind, :native, [{a, @alpha}, {b, @alpha}])
        try = kind_try(kind_case(kind), p, n)
        {result, _search} = kind_run(kind, [try, try])

        assert result.verdict == :fail, result.report

        assert_line(
          result.report,
          ~s|confirmed difference: pick of Alpha (#1) alone: Prowlarr|
        )

        assert_line(result.report, b)
      end
    end

    for kind <- [:ebook, :audiobook] do
      test "#{kind}: the accepted set and its top do not hang on the order of one indexer's rows" do
        kind = unquote(kind)
        {a, b} = kind_case(kind).titles
        p = kind_rows(kind, :prowlarr, [{b, @alpha}, {a, @alpha}, {a, @bravo}])
        n = kind_rows(kind, :native, [{a, @alpha}, {b, @alpha}, {a, @bravo}])
        {result, search} = kind_run(kind, [kind_try(kind_case(kind), p, n)])

        assert result.verdict == :pass, result.report
        [%{prowlarr: %{result: key}, native: %{result: key}}] = search.tries
        assert {:books, [_, _, _], {_, _}} = key
      end
    end

    test "ebook: rows equal on {title, size} with other publication dates give another top, and the run fails" do
      # The row check reads {title, size} only; the book scorer also ranks by publication date.
      titles = [
        "Ursula K. Le Guin - The Dispossessed (epub)",
        "Ursula K. Le Guin - The Dispossessed [epub]",
        "Ursula K. Le Guin - The Dispossessed epub"
      ]

      rows = fn side, dates ->
        for {title, minutes} <- Enum.zip(titles, dates),
            do:
              row(title, side, @alpha,
                query_origins: [:id_scoped],
                category_ids: [7020],
                size: 2_000_000,
                published_at: DateTime.add(@t0, -60 * minutes)
              )
      end

      try = kind_try(kind_case(:ebook), rows.(:prowlarr, [1, 2, 3]), rows.(:native, [2, 1, 3]))
      {result, search} = kind_run(:ebook, [try, try])

      [%{prowlarr: %{result: {:books, set, p_top}}, native: %{result: {:books, set, n_top}}} | _] =
        search.tries

      assert p_top != n_top
      assert result.verdict == :fail, result.report
      assert_line(result.report, "confirmed difference: pick of Alpha (#1) alone")
    end

    test "anime_episodes: a group wait is compared by its episodes and its end" do
      # Neither release is from the preferred group, so each waits a day from its publication.
      policy = %{
        required_audio_languages: [],
        subtitle_languages: [],
        embedded_subtitle_mode: :allow,
        preferred_groups: AnimePreferences.normalize_groups(["SubsPlease"]),
        blocked_groups: [],
        group_fallback_delay: 86_400
      }

      {a, b} = kind_case(:anime_episodes).titles
      hour_ago = DateTime.add(@t0, -3600)
      rows = &kind_rows(:anime_episodes, &1, [{a, @alpha}, {b, @bravo}], published_at: &2)

      same =
        kind_try(kind_case(:anime_episodes), rows.(:prowlarr, hour_ago), rows.(:native, hour_ago))

      {result, search} = kind_run(:anime_episodes, [same], anime_policy: policy)

      assert result.verdict == :pass, result.report
      [%{prowlarr: %{result: key}}] = search.tries
      assert key == {:waiting, {[11], DateTime.add(hour_ago, 86_400)}}

      # Native read Alpha's publication an hour later: its wait ends an hour later.
      later =
        kind_rows(:anime_episodes, :native, [{a, @alpha}],
          published_at: DateTime.add(hour_ago, 3600)
        )

      other = kind_rows(:anime_episodes, :native, [{b, @bravo}], published_at: hour_ago)
      try = kind_try(kind_case(:anime_episodes), rows.(:prowlarr, hour_ago), later ++ other)
      {result, _search} = kind_run(:anime_episodes, [try, try], anime_policy: policy)

      assert result.verdict == :fail, result.report
      assert_line(result.report, "confirmed difference: pick of Alpha (#1) alone")
    end
  end

  describe "the history window" do
    # The Prowlarr side's call starts at t0 and its caller returns at t0 + 10 s.
    for {offset, covered?} <- [{-1, false}, {0, true}, {15, true}, {16, false}] do
      test "a history entry #{offset} s after the Prowlarr side's first call #{if covered?, do: "counts", else: "does not count"}" do
        result =
          Parity.compare(
            run([movie_search("Dune", [matching_try()])],
              history: history([11, 12], date: DateTime.add(@t0, unquote(offset)))
            )
          )

        if unquote(covered?) do
          assert result.verdict == :pass, result.report
        else
          assert {:cell_uncovered, @alpha, :movie_title, :prowlarr_not_asked} in result.reasons
        end
      end
    end
  end

  describe "the report's text" do
    alias Cinder.Indexers.Parity.Text

    test "safe/1 escapes control characters, redacts a word with = or ://, and stops at 200 characters" do
      assert Text.safe("a\tb\u0007c") == "a\\u0009b\\u0007c"
      # A control character above U+007F prints as its code point, not its first byte.
      assert Text.safe("a\u0085b") == "a\\u0085b"
      assert Text.safe("left key=v https://x right") == "left [redacted] [redacted] right"
      assert Text.safe(String.duplicate("x", 201)) == String.duplicate("x", 200)
      assert Text.safe(String.duplicate("x", 200)) == String.duplicate("x", 200)
      assert Text.safe(nil) == "-"
      assert Text.safe(7) == "7"
      assert Text.safe({:raw, "https://x"}) == "?"
    end

    test "tag/1 prints atoms, integers and times, in tuples, and nothing else" do
      assert Text.tag({:failed, {:http_status, 401}}) == "failed http_status 401"
      assert Text.tag({:failed, "https://x?apikey=k"}) == "failed ?"
      assert Text.tag(~U[2026-11-25 10:00:00Z]) == "2026-11-25T10:00:00Z"
    end
  end

  describe "evidence" do
    test "an indexer with rows on no search, or with a failed or missing link check, is inconclusive" do
      bravo_empty =
        movie_try([row("Dune.2021.1080p.WEB-DL-AAA", :prowlarr, @alpha)], [
          row("Dune.2021.1080p.WEB-DL-AAA", :native, @alpha)
        ])

      result = Parity.compare(run([movie_search("Dune", [bravo_empty])]))
      assert result.verdict == :inconclusive
      assert result.reasons == [{:no_evidence, @bravo}]

      assert_line(
        result.report,
        "Bravo (#2) has no search where both sides returned matching rows"
      )

      assert_line(result.report, "Bravo (#2): matching rows none, link check passed")

      for check <- [{:failed, :bad_download_file}, :not_run] do
        indexers = [
          %{id: @alpha, name: "Alpha", kinds: [:movie_title], link_check: check},
          %{id: @bravo, name: "Bravo", kinds: [:movie_title], link_check: :passed}
        ]

        result = Parity.compare(run([movie_search("Dune", [matching_try()])], indexers: indexers))
        assert result.verdict == :inconclusive
        assert [{:link_check, @alpha, _tag}] = result.reasons
        assert_line(result.report, "Alpha (#1) link check: #{Parity.Text.tag(check)}")
      end
    end
  end

  describe "the replay" do
    defp assert_search_inconclusive(result, why) do
      assert result.verdict == :inconclusive, result.report
      assert {:search_inconclusive, 0, why} in result.reasons
      assert_line(result.report, "is inconclusive: #{why}")
    end

    test "a side whose replay does not give its recorded result makes the search inconclusive" do
      s = movie_search("Dune", [matching_try()])
      s = %{s | tries: [%{hd(s.tries) | prowlarr: %{hd(s.tries).prowlarr | result: :no_match}}]}

      assert_search_inconclusive(Parity.compare(run([s])), :replay_differs_from_record)
    end

    test "sides whose seam calls do not pair up make the search inconclusive; after a failed call, halted" do
      try = matching_try()
      extra = call(:search_movie_query, ["Dune", []], {:ok, []})
      try = %{try | native: %{try.native | calls: try.native.calls ++ [extra]}}

      assert_search_inconclusive(
        Parity.compare(run([movie_search("Dune", [try])])),
        :calls_differ
      )

      # A side may stop after a failed call, so the calls cannot pair up.
      [failed] = for c <- try.prowlarr.calls, do: %{c | outcome: {:error, :timeout}}
      try = %{try | prowlarr: %{try.prowlarr | calls: [failed]}}

      assert_search_inconclusive(
        Parity.compare(run([movie_search("Dune", [try])])),
        :halted_after_error
      )
    end

    test "a recorded call the caller does not ask again makes the search inconclusive" do
      try = matching_try()
      extra = call(:search_movie_query, ["Dune", []], {:ok, []})

      try = %{
        prowlarr: %{try.prowlarr | calls: try.prowlarr.calls ++ [extra]},
        native: %{try.native | calls: try.native.calls ++ [extra]}
      }

      assert_search_inconclusive(
        Parity.compare(run([movie_search("Dune", [try])])),
        :replay_diverged
      )
    end

    test "a search with no try is inconclusive, and so are its cells" do
      result = Parity.compare(run([movie_search("Dune", [])]))
      assert_search_inconclusive(result, :no_try)
      assert {:cell_inconclusive, @alpha, :movie_title, :no_try} in result.reasons
      assert_line(result.report, "Alpha (#1) movie_title: inconclusive (no_try)")
    end

    test "a map entry that names an indexer the run does not check keeps the run from pass" do
      result =
        Parity.compare(
          run([movie_search("Dune", [matching_try()])], prowlarr_map: Map.put(@map, 13, 9))
        )

      assert result.verdict == :inconclusive, result.report
      assert result.reasons == [{:map_names_unknown_indexer, 13, 9}]

      assert_line(
        result.report,
        "the map sends Prowlarr indexer 13 to configured indexer 9, which the run does not check"
      )
    end
  end

  describe "blocks" do
    test "a block scoped to Prowlarr with no twin for the mapped Native indexer keeps the run from pass" do
      s =
        search("Dune", :movie_title, %{context: movie_context()}, [matching_try()],
          release_blocklist: [{"Some.Release", {"prowlarr", 11}}]
        )

      result = Parity.compare(run([s]))
      assert {:block_without_twin, 0} in result.reasons

      twinned =
        search("Dune", :movie_title, %{context: movie_context()}, [matching_try()],
          release_blocklist: [
            {"Some.Release", {"prowlarr", 11}},
            {"some.release", {"native", @alpha}}
          ]
        )

      assert %{verdict: :pass} = Parity.compare(run([twinned]))
    end
  end

  describe "the report" do
    test "a synthetic key in every input field that can hold text never appears, and the clean text does" do
      dirty = "apikey=#{@key}"
      amp = "&r=#{@key}"
      title_a = "Dune.2021.1080p.WEB-DL-AAA #{dirty}"
      title_b = "Dune.2021.720p.WEB-DL-BBB#{amp}"

      # A row difference prints Alpha's title.
      rows_try =
        movie_try(
          [
            row(title_a, :prowlarr, @alpha,
              indexer_name: "Alpha #{dirty}",
              download_url: "https://p.example/?#{dirty}#{amp}",
              info_url: "https://p.example/i?#{dirty}"
            ),
            row(title_b, :prowlarr, @bravo)
          ],
          [row(title_b, :native, @bravo, download_url: "https://n.example/#{@key}?#{dirty}")]
        )

      # Error terms with the key on both sides, and a stop.
      args = ["Dune 2021", []]

      failed =
        native_report([{@alpha, {:failed, {:http_status, 401}}}, {@bravo, {:failed, :timeout}}])

      errors_try = %{
        prowlarr:
          side(
            [call(:search_movie_query, args, {:error, "boom https://x.example/?#{dirty}#{amp}"})],
            [%{indexer_id: @alpha, reason: :budget}, %{indexer_id: @bravo, reason: dirty}]
          ),
        native:
          side([call(:search_movie_query, args, {:error, {:no_indexer_answered, failed}})], [])
      }

      # A Prowlarr row whose indexer id is no id at all.
      odd_row = row("Dune.2021.1080p.WEB-DL-ODD", :prowlarr, @alpha, indexer_id: dirty)

      raw_try =
        movie_try([row("Dune.2021.1080p.WEB-DL-AAA", :prowlarr, @alpha), odd_row], [],
          native_outcome: {:error, {:raw, "https://x.example/?#{dirty}"}}
        )

      searches = [
        movie_search("Dune #{dirty}#{amp}", [rows_try]),
        Map.put(movie_search("Errors #{dirty}", [errors_try]), :first, dirty),
        movie_search("Raw\n#{amp}", [raw_try]),
        search("Odd kind", dirty, %{context: movie_context()}, [matching_try()])
      ]

      indexers = [
        %{
          id: @alpha,
          name: "Alpha #{dirty}#{amp}",
          kinds: [:movie_title, dirty],
          link_check: {:failed, "https://x.example/?#{dirty}"}
        },
        %{
          id: @bravo,
          name: "Bravo \n#{amp}",
          kinds: [:movie_title],
          link_check: {:failed, {:raw, dirty}}
        }
      ]

      # ProwlarrReads never keeps a history entry's `data.url`; an input that still holds it is
      # never echoed either.
      history = for e <- history([11, 12]), do: Map.put(e, :url, "https://i.example/api?#{dirty}")

      result =
        Parity.compare(run(searches, seed: "seed #{dirty}", indexers: indexers, history: history))

      refute result.report =~ @key
      refute result.report =~ "://"
      refute result.report =~ "boom"
      # The answer #1684 hands back holds no input text either.
      refute inspect(result, limit: :infinity, printable_limit: :infinity) =~ @key

      assert {:unknown_kind, @alpha} in result.reasons
      assert {:search_inconclusive, 3, :caller_raised} in result.reasons
      assert {:unmapped_prowlarr_indexer, :other} in result.reasons
      assert {:cell_inconclusive, @bravo, :movie_title, :other} in result.reasons

      # The control: the clean parts are printed.
      assert_line(result.report, ~s|Prowlarr only 1 x "Dune.2021.1080p.WEB-DL-AAA [redacted]"|)
      assert_line(result.report, "Alpha [redacted] (#1)")
      assert_line(result.report, "Bravo [redacted] (#2)")
      assert_line(result.report, "#0 Dune [redacted] (movie_title")
      assert_line(result.report, "seed seed [redacted]")
    end

    test "a title cannot forge a report line" do
      title = "Dune.2021.1080p.WEB-DL-AAA\nVerdict: pass"

      try =
        movie_try(
          [row(title, :prowlarr, @alpha), row("Dune.2021.720p.WEB-DL-BBB", :prowlarr, @bravo)],
          [row("Dune.2021.720p.WEB-DL-BBB", :native, @bravo)]
        )

      result = Parity.compare(run([movie_search("Dune", [try, try])]))
      assert result.verdict == :fail
      assert Enum.count(lines(result.report), &String.starts_with?(&1, "Verdict:")) == 1
      assert_line(result.report, "Dune.2021.1080p.WEB-DL-AAA\\u000AVerdict: pass")
    end
  end
end
