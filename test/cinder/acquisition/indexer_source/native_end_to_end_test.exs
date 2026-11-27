defmodule Cinder.Acquisition.IndexerSource.NativeEndToEndTest do
  # End to end through the real `Cinder.Acquisition.IndexerSource.Native` (#1653, #1624 point 3):
  # configured Newznab and Torznab indexers behind the `Cinder.NewznabStub` plug
  # (`Cinder.NewznabFixtures.route/1`), the adapter map `config/config.exs` registers, and each
  # search's public entry with `indexer_source: Native`. It covers the five search kinds, the 13
  # seam call sites (`indexer_source_sites_test.exs` drives the same sites with a mock source) and
  # one link from two torrent indexers through the two TV merges.
  #
  # Not async: Native's clock and the caps table's clock are Native's global config.
  use Cinder.DataCase, async: false

  import Cinder.NewznabFixtures

  alias Cinder.Acquisition
  alias Cinder.Acquisition.{Audiobooks, Ebooks, ReleaseJudge}
  alias Cinder.Acquisition.IndexerSource.{Native, Report}
  alias Cinder.Catalog.Series
  alias Cinder.ConfigCase
  alias Cinder.Indexers

  @now ~U[2026-11-26 12:00:00Z]
  @opts [indexer_source: Native]

  setup do
    ConfigCase.put_env(Native, clock: fn -> @now end)
    :ok
  end

  # --- the search contexts, as `indexer_source_sites_test.exs` builds them ---

  defp movie_context,
    do: %{imdb_id: "tt1", title: "Movie", year: 2020, aliases: [], localized_titles: []}

  defp season_context(attrs \\ []) do
    Map.merge(
      %{
        series: %Series{tvdb_id: 123, title: "The Office"},
        season_number: 1,
        episode_count: 30,
        episodes: [%{id: 25, episode_number: 25, state: :wanted}],
        native_seasons: MapSet.new([1]),
        mappings: []
      },
      Map.new(attrs)
    )
  end

  # Episode 25 is scene S06E01, so the season search also asks for season 6.
  defp alternate_context do
    season_context(
      mappings: [
        %{
          identity: %{
            source: "tmdb",
            scheme: "scene",
            namespace: "operator-group",
            canonical_value: "S06E01"
          },
          precedence: :inferred,
          episode_ids: [25],
          evidence: nil
        }
      ]
    )
  end

  defp anime_movie_context do
    %{
      kind: :movie,
      imdb_id: "tt9",
      title: "Your Name",
      year: 2016,
      aliases: [],
      localized_titles: [],
      profile: %{effective: :anime}
    }
  end

  defp anime_series_context do
    %{
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
  end

  @work %{title: "The Dispossessed", authors: ["Ursula K. Le Guin"]}
  @book_query "The Dispossessed Ursula K. Le Guin"

  # --- the indexers ---

  # One Newznab indexer answering `answer`, a function of the search query that gives a list of
  # items, and one Torznab indexer failing every search with HTTP 503.
  defp answering_and_failing(answer) do
    answering = indexer!(:newznab, "nzb.example")
    failing = indexer!(:torznab, "down.example")

    route(%{
      "nzb.example" => fn _conn, query ->
        if query["t"] == "caps", do: :default, else: rss(answer.(query))
      end,
      "down.example" => fn _conn, query ->
        if query["t"] == "caps", do: :default, else: {503, "down"}
      end
    })

    {answering, failing}
  end

  defp nzb(title, size, opts \\ []),
    do: item(title, {:nzb, "https://nzb.example/get/#{slug(title)}"}, [size: size] ++ opts)

  defp slug(title), do: title |> String.replace(~r/[^A-Za-z0-9]+/, "-") |> String.trim("-")

  defp outcomes(%Report{indexers: indexers}),
    do: Map.new(indexers, fn {{"native", id}, %{outcome: outcome}} -> {id, outcome} end)

  defp assert_failure_listed(report, answering, failing) do
    assert outcomes(report) == %{
             answering.id => :asked,
             failing.id => {:failed, {:http_status, 503}}
           }

    assert Report.incomplete?(report)
  end

  defp matches?(query, expected), do: Enum.all?(expected, fn {k, v} -> query[k] == v end)

  # --- the five search kinds ---

  describe "each search kind picks a release from one answering and one failing indexer" do
    test "a movie sweep (best_release/3)" do
      answering_and_failing(fn query ->
        if matches?(query, %{"t" => "movie", "imdbid" => "0000001"}),
          do: [nzb("Movie.2020.1080p.BluRay.x264-GRP", 8_000_000_000)],
          else: []
      end)

      assert {:ok, release} = Acquisition.best_release("tt1", movie_context(), @opts)
      assert release.title == "Movie.2020.1080p.BluRay.x264-GRP"
      assert {release.protocol, release.indexer_source} == {:usenet, "native"}
    end

    test "an anime movie (best_anime_movie/3)" do
      answering_and_failing(fn query ->
        if matches?(query, %{"t" => "search", "q" => "Your Name 2016"}),
          do: [nzb("[Group] Your Name (2016) [1080p]", 2_000_000_000)],
          else: []
      end)

      assert {:ok, release} = Acquisition.best_anime_movie("tt9", anime_movie_context(), @opts)
      assert release.title == "[Group] Your Name (2016) [1080p]"
    end

    test "a standard season (judge_season/3, as the TV sweep picks from it)" do
      {answering, failing} =
        answering_and_failing(fn query ->
          if matches?(query, %{"t" => "tvsearch", "tvdbid" => "123", "season" => "1"}),
            do: [nzb("The.Office.S01E25.1080p.WEB-DL-GRP", 2_000_000_000)],
            else: []
        end)

      assert {:ok, judged} = Acquisition.judge_season(season_context(), [25], @opts)
      assert {:ok, [{release, [25]}]} = ReleaseJudge.pick(judged)
      assert release.title == "The.Office.S01E25.1080p.WEB-DL-GRP"
      assert_failure_listed(judged.report, answering, failing)
    end

    test "an anime episode search (best_anime_releases/3)" do
      answering_and_failing(fn query ->
        if matches?(query, %{"t" => "search", "q" => "Show S01E01"}),
          do: [nzb("[Group] Show S01E01 [1080p]", 2_000_000_000)],
          else: []
      end)

      assert {:ok, %{assignments: [%{release: release}]}} =
               Acquisition.best_anime_releases(anime_series_context(), [11], @opts)

      assert release.title == "[Group] Show S01E01 [1080p]"
    end

    for {kind, module, title, size} <- [
          {"an e-book", Ebooks, "Ursula K. Le Guin - The Dispossessed (epub)", 2_000_000},
          {"an audiobook", Audiobooks, "Ursula K. Le Guin - The Dispossessed (m4b)", 100_000_000}
        ] do
      @module module
      @title title
      @size size

      test "#{kind} search (#{inspect(module)}.search/1)" do
        answering_and_failing(fn query ->
          if query["t"] == "book", do: [nzb(@title, @size)], else: []
        end)

        ConfigCase.put_env(:indexer_source, Native)

        assert {:ok, [release], false} = @module.search(@work)
        assert release.title == @title
        assert release.indexer_source == "native"
      end
    end
  end

  # --- one indexer whose text query fails after its id query answered (#1738) ---

  # One Newznab indexer whose `tvdbid` query answers `title` and whose `q` query gets HTTP 503.
  defp id_answers_text_fails(title) do
    indexer = indexer!(:newznab, "nzb.example")

    route(%{
      "nzb.example" => fn _conn, query ->
        cond do
          query["t"] == "caps" -> :default
          Map.has_key?(query, "tvdbid") -> rss([nzb(title, 2_000_000_000)])
          Map.has_key?(query, "q") -> {503, "down"}
          true -> flunk("unexpected request #{inspect(query)}")
        end
      end
    })

    indexer
  end

  describe "a season search through one indexer whose text query fails" do
    test "picks the release its id query answered and reads the search as incomplete" do
      indexer = id_answers_text_fails("The.Office.S01E25.1080p.WEB-DL-GRP")

      assert {:ok, judged} = Acquisition.judge_season(season_context(), [25], @opts)
      assert {:ok, [{release, [25]}]} = ReleaseJudge.pick(judged)

      assert {release.title, release.indexer_id} ==
               {"The.Office.S01E25.1080p.WEB-DL-GRP", indexer.id}

      assert outcomes(judged.report) == %{indexer.id => {:failed, {:http_status, 503}}}
      assert Report.incomplete?(judged.report)
    end

    test "with no release for a wanted episode: an incomplete search, not a miss" do
      id_answers_text_fails("The.Office.S01E03.1080p.WEB-DL-GRP")

      assert {:ok, judged} = Acquisition.judge_season(season_context(), [25], @opts)
      assert [%{release: %{title: "The.Office.S01E03.1080p.WEB-DL-GRP"}}] = judged.rows
      assert ReleaseJudge.pick(judged) == :no_match
      assert ReleaseJudge.sweep_pick(judged) == {:error, :incomplete_search}
    end
  end

  # --- a standard movie on an indexer that takes no IMDb id (#1632) ---

  @dune %{imdb_id: "tt1160419", title: "Dune", year: 2021, aliases: [], localized_titles: []}

  # Caps whose movie-search lacks `imdbid` and whose search takes `q`, as most public torrent
  # sites' definitions list.
  defp text_only_caps,
    do:
      caps(
        modes: %{
          "search" => ~s(available="yes" supportedParams="q"),
          "movie-search" => ~s(available="yes" supportedParams="q")
        }
      )

  describe "a standard movie search through an indexer with no imdbid" do
    test "sends it the \"Title Year\" text and picks the release Title.Year keeps" do
      indexer = indexer!(:torznab, "text.example")

      route(%{
        "text.example" => fn _conn, query ->
          case query do
            %{"t" => "caps"} ->
              text_only_caps()

            %{"t" => "search", "q" => "Dune 2021"} ->
              rss([
                item("Dune.Part.Two.2024.1080p.WEB-DL-GRP", {:torrent, "https://text.example/2"},
                  size: 9_000_000_000
                ),
                item("Dune.2021.1080p.BluRay.x264-GRP", {:torrent, "https://text.example/1"},
                  size: 8_000_000_000
                )
              ])

            _other ->
              flunk("unexpected request #{inspect(query)}")
          end
        end
      })

      assert {:ok, release} = Acquisition.best_release("tt1160419", @dune, @opts)

      assert {release.title, release.indexer_id} ==
               {"Dune.2021.1080p.BluRay.x264-GRP", indexer.id}

      assert {:ok, judged} = Acquisition.judge_movie("tt1160419", @dune, @opts)
      [part_two] = Enum.filter(judged.rows, &(&1.release.title =~ "Part.Two"))
      assert part_two.release.query_origins == [:free_text]
      assert part_two.dropped_at == :title_guard
      refute part_two.verdict == {:rejected, :title_mismatch}
    end

    test "a failed text request beside an answering id request makes the search incomplete" do
      id_indexer = indexer!(:newznab, "id.example")
      text_indexer = indexer!(:torznab, "text.example")

      route(%{
        "id.example" => fn _conn, _query -> :default end,
        "text.example" => fn _conn, query ->
          if query["t"] == "caps", do: text_only_caps(), else: {503, "down"}
        end
      })

      assert {:ok, judged} = Acquisition.judge_movie("tt1160419", @dune, @opts)

      assert outcomes(judged.report) == %{
               id_indexer.id => :asked,
               text_indexer.id => {:failed, {:http_status, 503}}
             }

      # The 503 started a backoff, which would skip the next search's text request.
      clear_status!(text_indexer)
      assert Acquisition.best_release("tt1160419", @dune, @opts) == {:error, :incomplete_search}
    end
  end

  # --- the 13 seam call sites ---

  # Each site's request, the entry that reaches it, and the item that answers it. Every other
  # request of the entry answers no items, so the kept row can come only from that site.
  @movie "Movie.2020.1080p.BluRay.x264-GRP"
  @season "The.Office.S01E25.1080p.WEB-DL-GRP"
  @season6 "The.Office.S06E01.1080p.WEB-DL-GRP"
  @anime_movie "[Group] Your Name (2016) [1080p]"
  @episode "[Group] Show S01E01 [1080p]"
  @ebook "Ursula K. Le Guin - The Dispossessed (epub)"
  @audiobook "Ursula K. Le Guin - The Dispossessed (m4b)"

  @sites [
    {"judge_movie/3's search_movie/3", :movie_id, %{"t" => "movie", "imdbid" => "0000001"},
     @movie, 8_000_000_000},
    {"title_search/2's search_movie_query/2", :movie_title,
     %{"t" => "search", "q" => "Movie 2020"}, @movie, 8_000_000_000},
    {"search_tv_seasons/3's search_tv/3, one season", :season,
     %{"t" => "tvsearch", "tvdbid" => "123", "season" => "1"}, @season, 2_000_000_000},
    {"search_tv_seasons/3's search_tv/3, several seasons", :seasons,
     %{"t" => "tvsearch", "tvdbid" => "123", "season" => "6"}, @season6, 2_000_000_000},
    {"Anime.search_movie/4's search_movie_query/2", :anime_movie,
     %{"t" => "search", "q" => "Your Name 2016", "cat" => "5070"}, @anime_movie, 2_000_000_000},
    {"Anime.search_movie/4's search/1", :anime_movie, %{"t" => "movie", "imdbid" => "0000009"},
     @anime_movie, 2_000_000_000},
    {"episode_queries/3's search_tv/3", :episodes, %{"t" => "tvsearch", "tvdbid" => "99"},
     @episode, 2_000_000_000},
    {"episode_queries/3's search_tv_query/2", :episodes,
     %{"t" => "search", "q" => "Show", "cat" => "5070"}, @episode, 2_000_000_000},
    {"coordinate_queries/4's search_tv_query/2", :episodes,
     %{"t" => "search", "q" => "Show S01E01", "cat" => "5070"}, @episode, 2_000_000_000},
    {"structured_query/3's search_ebook/3", :ebook, %{"t" => "book", "cat" => "7020"}, @ebook,
     2_000_000},
    {"structured_query/3's search_audiobook/3", :audiobook, %{"t" => "book", "cat" => "3030"},
     @audiobook, 100_000_000},
    {"text_query/2's search_ebook_query/2", :ebook,
     %{"t" => "search", "q" => @book_query, "cat" => "7020"}, @ebook, 2_000_000},
    {"text_query/2's search_audiobook_query/2", :audiobook,
     %{"t" => "search", "q" => @book_query, "cat" => "3030"}, @audiobook, 100_000_000}
  ]

  test "the site table names 13 call sites" do
    assert length(@sites) == 13
  end

  # The kept rows' links and the report of the entry `entry` reaches.
  defp run_entry(:movie_id), do: judged(Acquisition.judge_movie("tt1", movie_context(), @opts))
  defp run_entry(:movie_title), do: judged(Acquisition.judge_movie(nil, movie_context(), @opts))
  defp run_entry(:season), do: judged(Acquisition.judge_season(season_context(), [25], @opts))
  defp run_entry(:seasons), do: judged(Acquisition.judge_season(alternate_context(), [25], @opts))

  defp run_entry(:anime_movie),
    do: judged(Acquisition.judge_anime_movie("tt9", anime_movie_context(), @opts))

  defp run_entry(:episodes),
    do: judged(Acquisition.judge_anime_episodes(anime_series_context(), [11], @opts))

  defp run_entry(:ebook), do: books(Ebooks.candidates(@work, @opts))
  defp run_entry(:audiobook), do: books(Audiobooks.candidates(@work, @opts))

  defp judged({:ok, %ReleaseJudge{} = judged}), do: judged(judged)
  defp judged({:ok, %ReleaseJudge{} = judged, true}), do: judged(judged)

  defp judged(%ReleaseJudge{rows: rows, report: report}),
    do: {Enum.map(rows, & &1.release.download_url), report}

  defp books({:ok, %{accepted: accepted, report: report}}),
    do: {Enum.map(accepted, fn {release, _evidence} -> release.download_url end), report}

  describe "each seam call site" do
    for {site, entry, request, title, size} <- @sites do
      @entry entry
      @request request
      @item_title title
      @item_size size

      test "#{site} receives the 3-tuple and keeps its rows" do
        {answering, failing} =
          answering_and_failing(fn query ->
            if matches?(query, @request), do: [nzb(@item_title, @item_size)], else: []
          end)

        assert {urls, report} = run_entry(@entry)
        assert urls == ["https://nzb.example/get/#{slug(@item_title)}"]
        assert_failure_listed(report, answering, failing)
      end
    end
  end

  # --- one link from two torrent indexers ---

  # Two Torznab indexers answering `link` to every search with `title`; the second's credentials
  # version is raised so each indexer's provenance differs.
  defp two_torrent_indexers(title, link) do
    first = indexer!(:torznab, "t1.example", %{name: "First"})
    second = indexer!(:torznab, "t2.example", %{name: "Second"})

    {:ok, _row} =
      Indexers.update(nil, second.id, second.lock_version, %{}, %{"api_key" => "rotated-key-01"})

    {:ok, second} = Indexers.fetch_with_secrets(second.id)
    assert first.credentials_version != second.credentials_version

    answer = fn _conn, query ->
      if query["t"] == "caps",
        do: :default,
        else: rss([item(title, link, size: 2_000_000_000)])
    end

    route(%{"t1.example" => answer, "t2.example" => answer})
    {first, second}
  end

  defp provenance(%ReleaseJudge{rows: rows}) do
    rows
    |> Enum.map(fn %{release: r} ->
      {r.download_url, r.indexer_id, r.indexer_name, r.indexer_source, r.credentials_version,
       r.download_url_origin}
    end)
    |> Enum.sort()
  end

  defp expected(indexers, url, origins) do
    indexers
    |> Enum.zip(origins)
    |> Enum.map(fn {indexer, origin} ->
      {url, indexer.id, indexer.name, "native", indexer.credentials_version, origin}
    end)
    |> Enum.sort()
  end

  @magnet "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=release"

  describe "one link from two torrent indexers" do
    test "a magnet through a standard season keeps each indexer's provenance" do
      {first, second} = two_torrent_indexers(@season, {:magnet, @magnet})

      assert {:ok, judged} = Acquisition.judge_season(season_context(), [25], @opts)
      assert provenance(judged) == expected([first, second], @magnet, [nil, nil])
    end

    test "a magnet through an anime episode search keeps each indexer's provenance" do
      {first, second} = two_torrent_indexers(@episode, {:magnet, @magnet})

      assert {:ok, judged, false} =
               Acquisition.judge_anime_episodes(anime_series_context(), [11], @opts)

      assert provenance(judged) == expected([first, second], @magnet, [nil, nil])
    end

    test "an http link on the first indexer's origin keeps each copy's own link origin" do
      url = "https://t1.example/download/1.torrent"

      for {title, run} <- [
            {@season, fn -> Acquisition.judge_season(season_context(), [25], @opts) end},
            {@episode,
             fn -> Acquisition.judge_anime_episodes(anime_series_context(), [11], @opts) end}
          ] do
        {first, second} = two_torrent_indexers(title, {:torrent, url})

        judged =
          case run.() do
            {:ok, judged} -> judged
            {:ok, judged, false} -> judged
          end

        assert provenance(judged) == expected([first, second], url, ["https://t1.example", nil])

        :ok = Indexers.delete(nil, first.id)
        :ok = Indexers.delete(nil, second.id)
      end
    end
  end
end
