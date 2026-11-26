defmodule Cinder.Acquisition.IndexerSourceSitesTest do
  # The movie, season and anime seam call sites of `Cinder.Acquisition`, each driven through its
  # public entry. The source is `PassedIndexerMock`, passed as `indexer_source:`, while the env
  # names `IndexerMock` with no stub: a site that reads the env instead of the opt fails with
  # `Mox.UnexpectedCallError`. The site under test answers rows and a report naming an indexer of
  # its own; the entry's other calls answer `{:ok, []}`, so the report the entry carries can come
  # only from that site. The book sites are in `book_search_report_test.exs`.
  use ExUnit.Case, async: true

  import Mox

  alias Cinder.Acquisition
  alias Cinder.Acquisition.{Anime, PassedIndexerMock, ReleaseJudge}
  alias Cinder.Acquisition.IndexerSource.Report
  alias Cinder.Catalog.Series

  setup :verify_on_exit!

  @opts [indexer_source: PassedIndexerMock]

  # A report in which the indexer `id` failed, so the search it comes from is incomplete.
  defp report(id, reason \\ :timeout),
    do: Report.put(Report.new(), {"native", id}, "Indexer #{id}", {:failed, reason})

  defp urls(%ReleaseJudge{rows: rows}), do: Enum.map(rows, & &1.release.download_url)

  defp refute_source_opt(%ReleaseJudge{opts: opts}),
    do: refute(Keyword.has_key?(opts, :indexer_source))

  describe "judge_movie/3" do
    defp movie_context,
      do: %{imdb_id: "tt1", title: "Movie", year: 2020, aliases: [], localized_titles: []}

    defp movie_raw,
      do: %{title: "Movie.2020.1080p.BluRay.x264-GRP", size: 8_000_000_000, download_url: "m"}

    test "with an IMDb id judges the search_movie/3 rows and carries its report" do
      expect(PassedIndexerMock, :search_movie, fn "tt1", "Movie 2020", [] ->
        {:ok, [movie_raw()], report(1)}
      end)

      assert {:ok, judged} = Acquisition.judge_movie("tt1", movie_context(), @opts)
      assert urls(judged) == ["m"]
      assert judged.report == report(1)
      refute_source_opt(judged)
    end

    test "with a nil id judges the search_movie_query/2 rows and carries its report" do
      expect(PassedIndexerMock, :search_movie_query, fn "Movie 2020", [] ->
        {:ok, [movie_raw()], report(2)}
      end)

      assert {:ok, judged} = Acquisition.judge_movie(nil, movie_context(), @opts)
      assert urls(judged) == ["m"]
      assert judged.report == report(2)
      refute_source_opt(judged)
    end
  end

  describe "best_release/3" do
    defp skipped_report,
      do: Report.put(Report.new(), {"native", 20}, "Indexer 20", {:skipped, :deadline})

    test "a :no_match pick from a search where an indexer failed is an incomplete search" do
      expect(PassedIndexerMock, :search_movie, fn "tt1", _query, _opts ->
        {:ok, [], report(14)}
      end)

      assert Acquisition.best_release("tt1", movie_context(), @opts) ==
               {:error, :incomplete_search}
    end

    test "a :no_match pick from a search where an indexer was only skipped stays :no_match" do
      expect(PassedIndexerMock, :search_movie, fn "tt1", _query, _opts ->
        {:ok, [], skipped_report()}
      end)

      assert Acquisition.best_release("tt1", movie_context(), @opts) == :no_match
    end

    test "a :no_language_match pick reads the report the same way" do
      english = %{movie_raw() | title: "Movie.2020.1080p.BluRay.x264-EN"}
      french = [preferred_language: "french", original_language: "en"] ++ @opts

      expect(PassedIndexerMock, :search_movie, fn "tt1", _query, _opts ->
        {:ok, [english], report(15)}
      end)

      assert Acquisition.best_release("tt1", movie_context(), french) ==
               {:error, :incomplete_search}

      expect(PassedIndexerMock, :search_movie, fn "tt1", _query, _opts ->
        {:ok, [english], skipped_report()}
      end)

      assert Acquisition.best_release("tt1", movie_context(), french) == :no_language_match
    end

    test "a release found beside a failed indexer is still picked" do
      expect(PassedIndexerMock, :search_movie, fn "tt1", _query, _opts ->
        {:ok, [movie_raw()], report(16)}
      end)

      assert {:ok, %{download_url: "m"}} = Acquisition.best_release("tt1", movie_context(), @opts)
    end
  end

  describe "judge_season/3" do
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

    defp tv_raw(title),
      do: %{title: title, size: 2_000_000_000, download_url: title, seeders: 10}

    test "with one season judges the search_tv/3 rows and carries its report" do
      expect(PassedIndexerMock, :search_tv, fn 123, "The Office", 1 ->
        {:ok, [tv_raw("The.Office.S01E25.1080p.WEB-DL-GRP")], report(3)}
      end)

      assert {:ok, judged} = Acquisition.judge_season(season_context(), [25], @opts)
      assert urls(judged) == ["The.Office.S01E25.1080p.WEB-DL-GRP"]
      assert judged.report == report(3)
      refute_source_opt(judged)
    end

    test "with alternate seasons judges an alternate season's rows and carries its report" do
      expect(PassedIndexerMock, :search_tv, 2, fn
        123, "The Office", 1 -> {:ok, []}
        123, "The Office", 6 -> {:ok, [tv_raw("The.Office.S06E01.1080p.WEB-DL-GRP")], report(4)}
      end)

      assert {:ok, judged} = Acquisition.judge_season(alternate_context(), [25], @opts)
      assert urls(judged) == ["The.Office.S06E01.1080p.WEB-DL-GRP"]
      assert judged.report == report(4)
      refute_source_opt(judged)
    end

    test "merges the seasons' reports in search order, the earlier reason winning a tie" do
      expect(PassedIndexerMock, :search_tv, 2, fn
        123, "The Office", 1 -> {:ok, [], report(5, :timeout)}
        123, "The Office", 6 -> {:ok, [], report(5, :dns)}
      end)

      assert {:ok, judged} = Acquisition.judge_season(alternate_context(), [25], @opts)
      assert judged.report == report(5, :timeout)
    end

    test "still halts on the first failed season and returns its error unchanged" do
      expect(PassedIndexerMock, :search_tv, fn 123, "The Office", 1 -> {:error, :timeout} end)

      assert Acquisition.judge_season(alternate_context(), [25], @opts) == {:error, :timeout}
    end
  end

  describe "judge_anime_movie/3" do
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

    defp anime_raw(title, url),
      do: %{title: title, size: 2_000_000_000, download_url: url, protocol: :torrent}

    test "judges the free-text search_movie_query/2 rows and carries its report" do
      expect(PassedIndexerMock, :search, fn "tt9" -> {:ok, []} end)

      expect(PassedIndexerMock, :search_movie_query, fn "Your Name 2016", categories: [5070] ->
        {:ok, [anime_raw("[Group] Your Name (2016) [1080p]", "free")], report(6)}
      end)

      assert {:ok, judged, true} =
               Acquisition.judge_anime_movie("tt9", anime_movie_context(), @opts)

      assert urls(judged) == ["free"]
      assert judged.report == report(6)
      refute_source_opt(judged)
    end

    test "judges the id search/1 rows and carries its report" do
      expect(PassedIndexerMock, :search, fn "tt9" ->
        {:ok, [anime_raw("[Group] Your Name (2016) [1080p]", "id")], report(7)}
      end)

      expect(PassedIndexerMock, :search_movie_query, fn "Your Name 2016", categories: [5070] ->
        {:ok, []}
      end)

      assert {:ok, judged, true} =
               Acquisition.judge_anime_movie("tt9", anime_movie_context(), @opts)

      assert urls(judged) == ["id"]
      assert judged.report == report(7)
      refute_source_opt(judged)
    end
  end

  describe "judge_anime_episodes/3" do
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

    # Each of the three queries an episode search sends; `site` answers rows and a report.
    defp expect_episode_queries(site) do
      answer = fn query_site ->
        if query_site == site,
          do: {:ok, [anime_raw("[Group] Show S01E01 [1080p]", "#{site}")], report(8)},
          else: {:ok, []}
      end

      expect(PassedIndexerMock, :search_tv, fn 99, "Show", 1 -> answer.(:search_tv) end)

      expect(PassedIndexerMock, :search_tv_query, 2, fn
        "Show", categories: [5070] -> answer.(:title)
        "Show S01E01", categories: [5070] -> answer.(:coordinate)
      end)
    end

    for site <- [:search_tv, :title, :coordinate] do
      test "judges the #{site} query's rows and carries its report" do
        expect_episode_queries(unquote(site))

        assert {:ok, judged, true} =
                 Acquisition.judge_anime_episodes(anime_series_context(), [11], @opts)

        assert urls(judged) == ["#{unquote(site)}"]
        assert judged.report == report(8)
        refute_source_opt(judged)
      end
    end
  end

  describe "Anime.run_queries/2 through judge_anime_episodes/3" do
    @until ~U[2030-01-01 00:00:00Z]
    @later ~U[2030-01-02 00:00:00Z]

    # The search's three queries, in the order it sends them, answer `id`, `title` and
    # `coordinate`.
    defp answer_queries(id, title, coordinate) do
      expect(PassedIndexerMock, :search_tv, fn 99, "Show", 1 -> id end)

      expect(PassedIndexerMock, :search_tv_query, 2, fn
        "Show", categories: [5070] -> title
        "Show S01E01", categories: [5070] -> coordinate
      end)
    end

    defp episodes, do: Acquisition.judge_anime_episodes(anime_series_context(), [11], @opts)

    defp found, do: {:ok, [anime_raw("[Group] Show S01E01 [1080p]", "found")]}

    test "one query answering and one backing off is a complete answer" do
      answer_queries(found(), {:error, {:indexers_backing_off, @until}}, {:ok, []})

      assert {:ok, judged, false} = episodes()
      assert urls(judged) == ["found"]
      assert judged.report == Report.new()
    end

    test "one answering and one with no indexer answering is incomplete and lists its indexers" do
      answer_queries(found(), {:error, {:no_indexer_answered, report(9)}}, {:ok, []})

      assert {:ok, judged, true} = episodes()
      assert judged.report.indexers == report(9).indexers
      assert judged.report.failed_calls == 1
    end

    test "every query backing off gives the backoff that ends first" do
      answer_queries(
        {:error, {:indexers_backing_off, @later}},
        {:error, {:indexers_backing_off, @until}},
        {:error, {:indexers_backing_off, @later}}
      )

      assert episodes() == {:error, {:indexers_backing_off, @until}}
    end

    test "a backoff and a timeout give the timeout" do
      answer_queries(
        {:error, {:indexers_backing_off, @until}},
        {:error, :timeout},
        {:error, {:indexers_backing_off, @until}}
      )

      assert episodes() == {:error, :timeout}
    end

    test "a backoff and :no_indexers give the backoff; only :no_indexers gives :no_indexers" do
      answer_queries(
        {:error, :no_indexers},
        {:error, {:indexers_backing_off, @until}},
        {:error, :no_indexers}
      )

      assert episodes() == {:error, {:indexers_backing_off, @until}}

      answer_queries({:error, :no_indexers}, {:error, :no_indexers}, {:error, :no_indexers})

      assert episodes() == {:error, :no_indexers}
    end

    test "two with no indexer answering give one error with both reports merged" do
      answer_queries(
        {:error, {:no_indexer_answered, report(10)}},
        {:error, {:indexers_backing_off, @until}},
        {:error, {:no_indexer_answered, report(11, :dns)}}
      )

      assert {:error, {:no_indexer_answered, merged}} = episodes()
      assert merged == Report.merge(report(10), report(11, :dns))
      assert map_size(merged.indexers) == 2
    end

    test "a timeout before a query with no indexer answering wins as it is" do
      answer_queries(
        {:error, :timeout},
        {:error, {:no_indexer_answered, report(12)}},
        {:error, :no_indexers}
      )

      assert episodes() == {:error, :timeout}
    end

    test "merges the answers' reports in query order, the earlier reason winning a tie" do
      answer_queries({:ok, [], report(13, :timeout)}, {:ok, [], report(13, :dns)}, {:ok, []})

      assert {:ok, judged, true} = episodes()
      assert judged.report == report(13, :timeout)
    end
  end

  describe "the pick entries" do
    test "Anime.search_movie/4 flags a search in which an indexer failed as incomplete" do
      expect(PassedIndexerMock, :search, fn "tt9" -> {:ok, [], report(21)} end)
      expect(PassedIndexerMock, :search_movie_query, fn _query, _opts -> {:ok, []} end)

      assert Anime.search_movie(PassedIndexerMock, "tt9", anime_movie_context(), []) ==
               {:ok, [], true}
    end

    test "best_anime_movie/3 reads an incomplete report as an incomplete search" do
      expect(PassedIndexerMock, :search, fn "tt9" -> {:ok, [], report(17)} end)
      expect(PassedIndexerMock, :search_movie_query, fn _query, _opts -> {:ok, []} end)

      assert Acquisition.best_anime_movie("tt9", anime_movie_context(), @opts) ==
               {:error, :incomplete_search}
    end

    test "best_anime_releases/3 reads an incomplete report as an incomplete search" do
      expect(PassedIndexerMock, :search_tv, fn 99, "Show", 1 -> {:ok, [], report(18)} end)
      expect(PassedIndexerMock, :search_tv_query, 2, fn _query, _opts -> {:ok, []} end)

      assert Acquisition.best_anime_releases(anime_series_context(), [11], @opts) ==
               {:error, :incomplete_search}
    end

    test "best_anime_upgrades/4 reads an incomplete report as an incomplete search" do
      expect(PassedIndexerMock, :search_tv, fn 99, "Show", 1 -> {:ok, [], report(19)} end)
      expect(PassedIndexerMock, :search_tv_query, 2, fn _query, _opts -> {:ok, []} end)

      assert Acquisition.best_anime_upgrades(anime_series_context(), [11], & &1, @opts) ==
               {:error, :incomplete_search}
    end

    test "best_upgrade_releases/4 reads the season's rows and keeps no incomplete rule" do
      expect(PassedIndexerMock, :search_tv, fn 123, "The Office", 1 -> {:ok, [], report(20)} end)

      assert Acquisition.best_upgrade_releases(
               %Series{tvdb_id: 123, title: "The Office"},
               1,
               [25],
               @opts
             ) == :no_match
    end
  end
end
