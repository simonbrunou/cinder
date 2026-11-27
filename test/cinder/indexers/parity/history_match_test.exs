defmodule Cinder.Indexers.Parity.HistoryMatchTest do
  # Every entry is hand-written in the shape `ProwlarrReads.history/3` returns, with the fields
  # Prowlarr 3.1.0.5799's `HistoryService` writes (#1859).
  use ExUnit.Case, async: true

  alias Cinder.Acquisition.IndexerSource.Prowlarr
  alias Cinder.Indexers.Parity.HistoryMatch

  defp entry(query, query_type, categories, ids \\ %{}),
    do: %{
      id: 1,
      indexer_id: 4,
      date: ~U[2026-11-27 13:20:12Z],
      successful: true,
      query_results: 0,
      cached: false,
      query: query,
      query_type: query_type,
      categories: categories,
      ids: ids,
      source: "Prowlarr",
      paging: %{}
    }

  defp expected(callback, args),
    do: Enum.map(Prowlarr.requests(callback, args), &HistoryMatch.expected/1)

  describe "expected/1" do
    test "strips the brace tokens of the request's type, trims the term and reads the ids" do
      assert expected(:search_tv, [76_885, "Cowboy Bebop", 1]) == [
               %{
                 term: "",
                 type: "tvsearch",
                 categories: [],
                 ids: %{"tvdbId" => 76_885, "season" => 1}
               },
               %{term: "Cowboy Bebop", type: "tvsearch", categories: [], ids: %{"season" => 1}}
             ]

      assert expected(:search_tv, [nil, "Cowboy Bebop", 0]) == [
               %{term: "Cowboy Bebop", type: "tvsearch", categories: [], ids: %{"season" => 0}}
             ]

      assert expected(:search, ["tt0119282"]) == [
               %{term: "", type: "movie", categories: [], ids: %{"imdbId" => 119_282}}
             ]

      assert expected(:search_ebook, ["Philip K. Dick", "Beyond Lies the Wub", []]) == [
               %{
                 term: "",
                 type: "book",
                 categories: [7020],
                 ids: %{"author" => "Philip K. Dick", "title" => "Beyond Lies the Wub"}
               }
             ]

      assert expected(:search_tv_query, ["Cowboy Bebop", [categories: [5070]]]) == [
               %{term: "Cowboy Bebop", type: "tvsearch", categories: [5070], ids: %{}}
             ]
    end

    test "a basic search keeps its tokens in the term, and a token's name reads in any case" do
      assert [%{term: "Dune {Season:1}", ids: ids}] =
               expected(:search_movie_query, ["Dune {Season:1}", []])

      assert ids == %{}

      assert HistoryMatch.expected(%{
               query: " {SEASON:2}{tvdbid:5} x ",
               type: "tvsearch",
               categories: []
             }) ==
               %{
                 term: "x",
                 type: "tvsearch",
                 categories: [],
                 ids: %{"season" => 2, "tvdbId" => 5}
               }
    end

    test "an id Prowlarr cannot parse is not written, as Prowlarr drops it" do
      assert HistoryMatch.expected(%{
               query: "{TvdbId:abc}{ImdbId:tt0}",
               type: "tvsearch",
               categories: []
             }) ==
               %{term: "", type: "tvsearch", categories: [], ids: %{}}
    end
  end

  describe "matches?/2" do
    # Each row: a request, the entry its own query wrote, and one entry per field that the rule
    # reads, each changed alone from the own entry, which must not match.
    @rows [
      {"TVDB id", :search_tv, [76_885, "Cowboy Bebop", 1], 0,
       {"", "tvsearch", [], %{"tvdbId" => "76885", "season" => "1"}}},
      {"title", :search_tv, [76_885, "Cowboy Bebop", 1], 1,
       {"Cowboy Bebop", "tvsearch", [], %{"season" => "1"}}},
      {"title rewritten to search", :search_tv, [76_885, "Cowboy Bebop", 1], 1,
       {"Cowboy Bebop", "search", [], %{"season" => "1"}}},
      {"anime free text rewritten to search", :search_tv_query,
       ["Cowboy Bebop", [categories: [5070]]], 0, {"Cowboy Bebop", "search", [5070], %{}}},
      {"IMDb id", :search, ["tt0119282"], 0, {"", "movie", [], %{"imdbId" => "tt0119282"}}},
      {"movie title", :search_movie_query, ["Bridget Jones: The Edge of Reason 2004", []], 0,
       {"Bridget Jones: The Edge of Reason 2004", "search", [2000], %{}}},
      {"ISBN", :search_ebook_query, ["9781775414742", []], 0,
       {"9781775414742", "search", [7020], %{}}},
      {"structured book", :search_ebook, ["Philip K. Dick", "Beyond Lies the Wub", []], 0,
       {"", "book", [7020], %{"author" => "Philip K. Dick", "title" => "Beyond Lies the Wub"}}}
    ]

    test "the entry a request wrote matches it, and one with another term, type, category set, id, source or paging, or an id missing, does not" do
      for {label, callback, args, index, {query, type, categories, ids}} <- @rows do
        request = Enum.at(expected(callback, args), index)
        own = entry(query, type, categories, ids)
        assert HistoryMatch.matches?(own, request), label

        fields = [
          {:term, %{own | query: own.query <> " Kai"}},
          {:type, %{own | query_type: "music"}},
          {:categories, %{own | categories: [5000 | categories]}},
          {:extra_id, %{own | ids: Map.put(ids, "tmdbId", "1")}},
          # An id the entry holds but no request can carry matches none.
          {:unreadable_id, %{own | ids: Map.put(ids, "tvMazeId", "abc")}},
          # A Sonarr linked to Prowlarr, through `NewznabController`, and a paged request.
          {:source, %{own | source: "Sonarr"}},
          {:offset, %{own | paging: %{"offset" => "100"}}},
          {:limit, %{own | paging: %{"limit" => "100"}}}
        ]

        other_ids =
          for {field, value} <- ids, do: {field, %{own | ids: %{ids | field => value <> "9"}}}

        missing_ids =
          for {field, _value} <- ids,
              do: {{:missing, field}, %{own | ids: Map.delete(ids, field)}}

        for {what, entry} <- fields ++ other_ids ++ missing_ids do
          refute HistoryMatch.matches?(entry, request), "#{label}: #{inspect(what)}"
        end
      end
    end

    test "a live poller's entries, shaped as those of run 2's prod history, match none of the run's requests" do
      run =
        Enum.flat_map(
          [
            {:search_tv, [76_885, "Cowboy Bebop", 1]},
            {:search_tv_query, ["Cowboy Bebop", [categories: [5070]]]},
            {:search_ebook_query, ["9781775414742", []]},
            {:search_ebook_query, ["Beyond Lies the Wub Philip K. Dick", []]},
            {:search_audiobook_query, ["Project Hail Mary Andy Weir", []]}
          ],
          fn {callback, args} -> expected(callback, args) end
        )

      poller = [
        entry("Dragon Ball Z Kai", "tvsearch", [], %{"season" => "6"}),
        entry("", "tvsearch", [], %{"tvdbId" => "88031", "season" => "6"}),
        entry("Dragon Ball Z Kai", "search", [5070]),
        entry("Cowboy Bebop", "search", [5070, 5000]),
        entry("Cowboy Bebop", "tvsearch", [], %{"season" => "6"})
      ]

      for e <- poller, do: refute(Enum.any?(run, &HistoryMatch.matches?(e, &1)), inspect(e))

      # The control: the run's own entries match.
      assert Enum.any?(run, &HistoryMatch.matches?(entry("Cowboy Bebop", "search", [5070]), &1))
      assert Enum.any?(run, &HistoryMatch.matches?(entry("9781775414742", "search", [7020]), &1))
    end
  end
end
