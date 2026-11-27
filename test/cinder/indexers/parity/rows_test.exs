defmodule Cinder.Indexers.Parity.RowsTest do
  # Hand-written rows (#1624 point 1). The engine's own tests (`Cinder.Indexers.ParityTest`) run
  # these rules through `compare/1`; these pin each limit of one rule.
  use ExUnit.Case, async: true

  alias Cinder.Indexers.Parity.Rows

  # Prowlarr's 11 and 12 are the configured 1 and 2.
  @map %{11 => 1, 12 => 2}

  defp row(title, indexer_id, attrs \\ []),
    do:
      Map.merge(
        %{
          title: title,
          size: 1,
          download_url: "u/#{indexer_id}/#{title}",
          indexer_id: indexer_id
        },
        Map.new(attrs)
      )

  defp call(callback, args, rows),
    do: %{callback: callback, args: args, started_at: nil, outcome: {:ok, rows}}

  defp native(pair),
    do: pair |> elem(1) |> Map.fetch!(:outcome) |> Rows.rows() |> Enum.map(& &1.title)

  defp prowlarr(pair),
    do: pair |> elem(0) |> Map.fetch!(:outcome) |> Rows.rows() |> Enum.map(& &1.title)

  defp apply_one(
         difference,
         p_rows,
         n_rows,
         callback \\ :search_movie_query,
         args \\ ["Dune 2021", []]
       ) do
    [pair] =
      Rows.apply_differences(
        [{call(callback, args, p_rows), call(callback, args, n_rows)}],
        [difference],
        @map
      )

    pair
  end

  describe "align/2" do
    test "pairs calls by callback and arguments, and refuses a call either side lacks" do
      a = call(:search_tv_query, ["A", []], [])
      b = call(:search_tv_query, ["B", []], [])

      assert {:ok, [{^a, ^a}, {^b, ^b}]} = Rows.align([b, a], [a, b])
      assert :calls_differ = Rows.align([a, b], [a])
      assert :calls_differ = Rows.align([a], [a, b])
      assert :calls_differ = Rows.align([a, a], [a, b])
    end
  end

  describe ":order" do
    test "puts id-scoped rows first, then each indexer at its first place in Prowlarr's rows, keeping the order of one indexer's rows of one origin" do
      # Prowlarr's rows: Alpha's id-scoped row, Bravo's, then Alpha's free-text row.
      p = [
        row("A1", 11, query_origins: [:id_scoped]),
        row("B", 12, query_origins: [:id_scoped]),
        row("A2", 11, query_origins: [:free_text])
      ]

      n = [
        row("A1", 1, query_origins: [:id_scoped]),
        row("A2", 1, query_origins: [:free_text]),
        row("B", 2, query_origins: [:id_scoped])
      ]

      assert native(apply_one(:order, p, n)) == ["A1", "B", "A2"]

      # Rows of one indexer keep their order, and an indexer Prowlarr has no row of goes last.
      p = [row("B", 12), row("A1", 11)]
      n = [row("C", 3), row("A2", 1), row("A1", 1), row("B", 2)]
      assert native(apply_one(:order, p, n)) == ["B", "A2", "A1", "C"]

      # One indexer's free-text row moves behind its id-scoped one.
      n = [row("F", 1, query_origins: [:free_text]), row("I", 1, query_origins: [:id_scoped])]
      assert native(apply_one(:order, [row("I", 11)], n)) == ["I", "F"]
    end

    test "ranks the indexers of each query origin by Prowlarr's rows of that origin" do
      # Prowlarr's search_tv/3 answers its id query's rows, then its free-text query's. Alpha, a
      # text scraper, answers only the free-text query, ahead of Bravo there.
      p = [
        row("B-id", 12, query_origins: [:id_scoped]),
        row("A-ft", 11, query_origins: [:free_text]),
        row("B-ft", 12, query_origins: [:free_text])
      ]

      n = [
        row("B-id", 2, query_origins: [:id_scoped]),
        row("B-ft", 2, query_origins: [:free_text]),
        row("A-ft", 1, query_origins: [:free_text])
      ]

      assert native(apply_one(:order, p, n, :search_tv, [123, "Show", 1])) ==
               ["B-id", "A-ft", "B-ft"]

      # A link both queries found is one Prowlarr row with both origins: it ranks its indexer in
      # each.
      p = [
        row("B-m", 12, query_origins: [:id_scoped, :free_text]),
        row("A-ft", 11, query_origins: [:free_text])
      ]

      n = [
        row("B-m", 2, query_origins: [:id_scoped]),
        row("A-ft", 1, query_origins: [:free_text]),
        row("B-m", 2, query_origins: [:free_text])
      ]

      assert native(apply_one(:order, p, n, :search_tv, [123, "Show", 1])) ==
               ["B-m", "B-m", "A-ft"]
    end
  end

  describe ":category_filter" do
    test "keeps a row with no category, an equal one, or a child of a searched parent, on a call that sent categories" do
      n = [
        row("none", 1, category_ids: []),
        row("nil", 1),
        row("movie", 1, category_ids: [2000]),
        row("movie child", 1, category_ids: [2040]),
        row("next parent", 1, category_ids: [3000]),
        row("tv", 1, category_ids: [5040]),
        row("one of two", 1, category_ids: [5040, 2045])
      ]

      assert native(apply_one(:category_filter, [], n)) == [
               "none",
               "nil",
               "movie",
               "movie child",
               "one of two"
             ]

      # An explicit category is not a parent: 2040 does not reach 2041.
      assert native(
               apply_one(
                 :category_filter,
                 [],
                 [row("sibling", 1, category_ids: [2041])],
                 :search_movie_query,
                 ["Dune", [categories: [2040]]]
               )
             ) == []

      # Book calls default to their own category.
      assert native(
               apply_one(
                 :category_filter,
                 [],
                 [row("book", 1, category_ids: [7020]), row("audio", 1, category_ids: [3030])],
                 :search_ebook_query,
                 ["Dune", []]
               )
             ) == ["book"]

      assert native(
               apply_one(
                 :category_filter,
                 [],
                 [row("book", 1, category_ids: [7020]), row("audio", 1, category_ids: [3030])],
                 :search_audiobook_query,
                 ["Dune", []]
               )
             ) == ["audio"]
    end

    test "leaves a call to which Prowlarr's adapter sent no category alone" do
      n = [row("tv", 1, category_ids: [5040]), row("movie", 1, category_ids: [2000])]

      for {callback, args} <- [
            {:search, ["tt1160419"]},
            {:search_tv, [123, "The Office", 1]},
            {:search_tv_query, ["The Office", []]}
          ] do
        assert {callback, native(apply_one(:category_filter, [], n, callback, args))} ==
                 {callback, ["tv", "movie"]}
      end
    end
  end

  describe ":row_cap" do
    # Prowlarr's adapter tags no query origin on search_movie_query/2, the default call here
    # (`tag_query_origin/2` runs on search_tv/3 and the book calls only); Native tags every row
    # with exactly one.
    defp rows(prefix, id, n, origins \\ nil),
      do: for(i <- 1..n, do: row("#{prefix}#{i}", id, query_origins: origins))

    defp native_rows(prefix, id, n), do: rows(prefix, id, n, [:free_text])

    test "keeps the first 1,000 Prowlarr rows of a group when Prowlarr has more and Native exactly 1,000" do
      pair =
        apply_one(:row_cap, rows("P", 11, 1002) ++ rows("Q", 12, 3), native_rows("P", 1, 1000))

      assert prowlarr(pair) == Enum.map(1..1000, &"P#{&1}") ++ ["Q1", "Q2", "Q3"]
      # Native's side is never changed.
      assert length(native(pair)) == 1000

      # On search_tv/3 the group is one origin's rows.
      tv = [123, "Show", 1]
      p = rows("I", 11, 2, [:id_scoped]) ++ rows("P", 11, 1001, [:free_text])
      n = rows("I", 1, 2, [:id_scoped]) ++ native_rows("P", 1, 1000)
      titles = prowlarr(apply_one(:row_cap, p, n, :search_tv, tv))
      assert {length(titles), "P1001" in titles, "I2" in titles} == {1002, false, true}
    end

    test "caps only the group where Native has exactly 1,000" do
      p = rows("P", 11, 1001) ++ rows("Q", 12, 1001)

      pair = apply_one(:row_cap, p, native_rows("P", 1, 1000) ++ native_rows("Q", 2, 999))
      titles = prowlarr(pair)
      refute "P1001" in titles
      assert "Q1001" in titles

      # Native's count reads each recorded row, so two copies of one link count twice here.
      copies = native_rows("P", 1, 1000) ++ [row("P1000", 1, query_origins: [:free_text])]
      assert "P1001" in prowlarr(apply_one(:row_cap, rows("P", 11, 1001), copies))

      # An untagged Prowlarr group whose Native rows came from two queries has no one query, even
      # when their sum is 1,000.
      two = native_rows("P", 1, 999) ++ rows("I", 1, 1, [:id_scoped])
      assert "P1001" in prowlarr(apply_one(:row_cap, rows("P", 11, 1001), two))
    end

    test "leaves a call alone when a Prowlarr row of it merged both query origins" do
      p =
        rows("P", 11, 1001, [:free_text]) ++
          [row("M", 12, query_origins: [:id_scoped, :free_text])]

      pair = apply_one(:row_cap, p, native_rows("P", 1, 1000), :search_tv, [123, "Show", 1])
      assert "P1001" in prowlarr(pair)
    end
  end

  # The rows of one indexer in one search_tv/3 call, tagged as each source tags them: Native one
  # origin per row, Prowlarr one per row, or both on a row its adapter merged by link.
  describe "count_keys/1 and native_count_keys/2" do
    test "counts Native's copies of one link once where Prowlarr's rows hold a merged row of that title and size" do
      p = [row("S", 11, query_origins: [:id_scoped, :free_text])]
      n = [row("S", 1, query_origins: [:id_scoped]), row("S", 1, query_origins: [:free_text])]

      assert Rows.count_keys(p) == %{{"S", 1} => 1}
      assert Rows.native_count_keys(n, p) == %{{"S", 1} => 1}
    end

    test "counts each Native copy where Prowlarr's copies each carry a link of their own (#1914)" do
      p = [
        row("S", 11, download_url: "p/id", query_origins: [:id_scoped]),
        row("S", 11, download_url: "p/text", query_origins: [:free_text])
      ]

      n = [row("S", 1, query_origins: [:id_scoped]), row("S", 1, query_origins: [:free_text])]

      assert Rows.count_keys(p) == %{{"S", 1} => 2}
      assert Rows.native_count_keys(n, p) == %{{"S", 1} => 2}

      # Prowlarr's link in one query only: Native's two copies count twice, a difference.
      assert Rows.native_count_keys(n, [hd(p)]) == %{{"S", 1} => 2}
    end

    test "a merged Prowlarr row of another title or size leaves Native's copies counted apart" do
      n = [row("S", 1, query_origins: [:id_scoped]), row("S", 1, query_origins: [:free_text])]

      for merged <- [row("T", 11), row("S", 11, size: 2)] do
        p = [Map.put(merged, :query_origins, [:id_scoped, :free_text])]
        assert Rows.native_count_keys(n, p) == %{{"S", 1} => 2}
      end
    end

    test "Native's copies of two links count apart beside a merged Prowlarr row of their title and size" do
      p = [row("S", 11, query_origins: [:id_scoped, :free_text])]

      n = [
        row("S", 1, download_url: "u/1/a", query_origins: [:id_scoped]),
        row("S", 1, download_url: "u/1/b", query_origins: [:free_text])
      ]

      assert Rows.native_count_keys(n, p) == %{{"S", 1} => 2}
    end

    # Two releases of one title and size on one indexer: one Prowlarr merged, one it split.
    test "each merged Prowlarr row makes the copies of one Native link count once, never two" do
      both = fn link ->
        for o <- [:id_scoped, :free_text], do: row("S", 1, download_url: link, query_origins: [o])
      end

      n = both.("u/1/a") ++ both.("u/1/d")
      merged = row("S", 11, download_url: "p/a", query_origins: [:id_scoped, :free_text])
      by_id = row("S", 11, download_url: "p/b-id", query_origins: [:id_scoped])
      by_text = row("S", 11, download_url: "p/b-text", query_origins: [:free_text])

      # Prowlarr found the split release by both queries: 3 rows on each side.
      p = [merged, by_id, by_text]
      assert Rows.count_keys(p) == %{{"S", 1} => 3}
      assert Rows.native_count_keys(n, p) == %{{"S", 1} => 3}

      # Prowlarr found it by the id query only: 2 against Native's 3, a difference.
      assert Rows.native_count_keys(n, [merged, by_id]) == %{{"S", 1} => 3}
      assert Rows.count_keys([merged, by_id]) == %{{"S", 1} => 2}

      # Copies with no link never count once, even with a merged row left over for them.
      unlinked =
        for o <- [:id_scoped, :free_text], do: row("S", 1, download_url: nil, query_origins: [o])

      three = for l <- ~w(p/a p/d p/x), do: %{merged | download_url: l}
      assert Rows.native_count_keys(unlinked ++ n, three) == %{{"S", 1} => 4}
    end

    test "a Native link found by one query, before a link found by both, leaves the merged row to the second" do
      x = row("S", 1, download_url: "u/1/x", query_origins: [:id_scoped])

      a =
        for o <- [:id_scoped, :free_text],
            do: row("S", 1, download_url: "u/1/a", query_origins: [o])

      p = [
        row("S", 11, download_url: "p/x", query_origins: [:id_scoped]),
        row("S", 11, download_url: "p/a", query_origins: [:id_scoped, :free_text])
      ]

      assert Rows.count_keys(p) == %{{"S", 1} => 2}
      assert Rows.native_count_keys([x | a], p) == %{{"S", 1} => 2}
    end

    # `Release.per_indexer_rows/3` gives each indexer's row of one link the origins of every copy,
    # so a row Prowlarr merged from two indexers' copies holds an origin its own indexer never
    # answered. Counting a row once per origin would count it twice here.
    test "a link two Prowlarr indexers share counts once for the indexer that returned it in one query" do
      p_bravo = [row("S", 12, download_url: "magnet:s", query_origins: [:id_scoped, :free_text])]
      n_bravo = [row("S", 2, download_url: "magnet:s", query_origins: [:free_text])]

      assert Rows.count_keys(p_bravo) == %{{"S", 1} => 1}
      assert Rows.native_count_keys(n_bravo, p_bravo) == %{{"S", 1} => 1}
    end
  end
end
