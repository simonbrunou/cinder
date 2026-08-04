defmodule Cinder.AcquisitionTest do
  use ExUnit.Case, async: true

  import Mox

  alias Cinder.Acquisition
  alias Cinder.Acquisition.Anime
  alias Cinder.Acquisition.Release
  alias Cinder.Catalog.Series

  setup :verify_on_exit!

  @gb 1_000_000_000

  # A raw indexer result map with sensible defaults; override per case.
  defp raw(attrs) do
    Map.merge(
      %{title: "Movie.2020.1080p.BluRay.x264-GRP", size: 8 * @gb, download_url: "u", seeders: 10},
      Map.new(attrs)
    )
  end

  defp series(attrs \\ []), do: struct(%Series{tvdb_id: 123, title: "The Office"}, attrs)

  defp raw_tv(title, attrs \\ []),
    do: Map.merge(%{title: title, size: 2 * @gb, download_url: "u", seeders: 10}, Map.new(attrs))

  test "anime movie waiting is advisory and empty preferences are a no-op" do
    now = ~U[2026-07-13 12:00:00Z]

    fallback =
      %{
        Release.new(%{
          title: "Your Name (2016) [1080p]",
          size: 8 * @gb,
          download_url: "fallback",
          published_at: now
        })
        | group: "Other"
      }

    assert {:waiting_for_preferred_group, %{retry_at: ~U[2026-07-14 12:00:00Z]}} =
             Anime.select_movie([fallback],
               preferred_groups: ["Trusted"],
               fallback_delay: 86_400,
               now: now
             )

    no_timestamp = %{fallback | published_at: nil}
    assert {:ok, ^no_timestamp} = Anime.select_movie([no_timestamp])
    assert {:ok, ^no_timestamp} = Anime.select_movie([no_timestamp], preferred_groups: [])
  end

  test "anime movie preference recognizes a leading bracketed group" do
    release =
      Release.new(%{
        title: "[Trusted] Your Name (2016) [1080p]",
        size: 8 * @gb,
        download_url: "preferred"
      })

    assert {:ok, %Release{group: "Trusted"}} =
             Anime.select_movie([release], preferred_groups: ["trusted"])
  end

  test "best_anime_releases/3 exposes stable-ID selection without changing the TV poller API" do
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
            source: "cinder",
            scheme: "standard",
            namespace: "canonical",
            canonical_value: "S01E01"
          },
          precedence: :manual,
          episode_ids: [11],
          evidence: %{"kind" => "canonical_standard"}
        }
      ]
    }

    expect(Cinder.Acquisition.IndexerMock, :search_tv, fn 99, "Show", 1 ->
      {:ok, [raw_tv("[Group] Show S01E01 [1080p]", download_url: "anime")]}
    end)

    expect(Cinder.Acquisition.IndexerMock, :search_tv_query, 2, fn _query, categories: [5070] ->
      {:ok, []}
    end)

    assert {:ok, %{assignments: [%{episode_ids: [11]}]}} =
             Acquisition.best_anime_releases(context, [11])
  end

  test "best_anime_releases/3 skips indexer work for an empty wanted set" do
    stub(Cinder.Acquisition.IndexerMock, :search_tv_query, fn _query, _opts ->
      send(self(), :unexpected_empty_search)
      {:ok, []}
    end)

    assert :no_match =
             Acquisition.best_anime_releases(
               %{
                 kind: :series,
                 title: "Show",
                 year: 2020,
                 tvdb_id: 99,
                 aliases: [],
                 episodes: [],
                 mappings: []
               },
               []
             )

    refute_received :unexpected_empty_search
  end

  test "best_release/2 composes indexer search, parse, and scoring" do
    expect(Cinder.Acquisition.IndexerMock, :search, fn "tt1375666" ->
      {:ok,
       [
         raw(title: "Movie.2020.720p.BluRay.x264-GOOD", size: 4 * @gb),
         raw(title: "Movie.2020.1080p.BluRay.x264-BEST", size: 9 * @gb)
       ]}
    end)

    assert {:ok, %Release{group: "BEST", resolution: "1080p"}} =
             Acquisition.best_release("tt1375666", max_size: 20 * @gb)
  end

  test "best_release/2 returns :no_match when nothing survives the rules" do
    expect(Cinder.Acquisition.IndexerMock, :search, fn _ ->
      {:ok, [raw(title: "Movie.2020.1080p.BluRay.x264-GRP", size: 50 * @gb)]}
    end)

    assert :no_match = Acquisition.best_release("tt1375666", max_size: 20 * @gb)
  end

  test "best_release/2 returns :no_match on an empty indexer result" do
    expect(Cinder.Acquisition.IndexerMock, :search, fn _ -> {:ok, []} end)

    assert :no_match = Acquisition.best_release("tt1375666")
  end

  test "best_release/2 passes an indexer error straight through" do
    expect(Cinder.Acquisition.IndexerMock, :search, fn _ -> {:error, :timeout} end)

    assert {:error, :timeout} = Acquisition.best_release("tt1375666")
  end

  test "best_release/2 excludes releases whose protocol has no configured client" do
    expect(Cinder.Acquisition.IndexerMock, :search, fn _ ->
      {:ok,
       [
         raw(title: "Movie.2020.1080p.WEB-DL-USE", protocol: :usenet, size: 9 * @gb),
         raw(title: "Movie.2020.720p.BluRay.x264-TOR", protocol: :torrent, size: 4 * @gb)
       ]}
    end)

    # Only torrent clients available: the 1080p Usenet release is filtered out
    # before scoring, so the 720p torrent wins despite the lower resolution.
    assert {:ok, %Release{resolution: "720p", protocol: :torrent}} =
             Acquisition.best_release("tt1", protocols: [:torrent], max_size: 20 * @gb)
  end

  test "best_release/2 with no :protocols opt keeps every protocol" do
    expect(Cinder.Acquisition.IndexerMock, :search, fn _ ->
      {:ok, [raw(title: "Movie.2020.1080p.WEB-DL-USE", protocol: :usenet, size: 9 * @gb)]}
    end)

    assert {:ok, %Release{protocol: :usenet}} =
             Acquisition.best_release("tt1", max_size: 20 * @gb)
  end

  test "best_release filters by language: french pick keeps a FRENCH release" do
    expect(Cinder.Acquisition.IndexerMock, :search, fn "tt1" ->
      {:ok,
       [
         raw(title: "Movie.2020.1080p.BluRay.x264-EN", size: 8 * @gb),
         raw(title: "Movie.2020.FRENCH.1080p.BluRay.x264-FR", size: 8 * @gb)
       ]}
    end)

    assert {:ok, %Release{group: "FR", language: "FRENCH"}} =
             Acquisition.best_release("tt1",
               max_size: 20 * @gb,
               preferred_language: "french",
               original_language: "en"
             )
  end

  test "best_release: a french 480p is rejected, not grabbed, when 1080p was asked for" do
    # The reported bug: a French pick where the only in-band French release is 480p (the higher-res
    # French one is absent/too big) used to grab the 480p. With the resolution allow-list it parks.
    expect(Cinder.Acquisition.IndexerMock, :search, fn "tt1" ->
      {:ok,
       [
         raw(title: "Movie.2020.FRENCH.480p.WEB-DL-FR", size: 2 * @gb),
         raw(title: "Movie.2020.1080p.BluRay.x264-EN", size: 8 * @gb)
       ]}
    end)

    assert :no_match =
             Acquisition.best_release("tt1",
               max_size: 20 * @gb,
               preferred_language: "french",
               original_language: "en",
               preferred_resolutions: ["1080p", "720p"]
             )
  end

  test "best_release returns :no_language_match when nothing satisfies the pick" do
    expect(Cinder.Acquisition.IndexerMock, :search, fn "tt1" ->
      {:ok, [raw(title: "Movie.2020.1080p.BluRay.x264-EN", size: 8 * @gb)]}
    end)

    assert :no_language_match =
             Acquisition.best_release("tt1",
               max_size: 20 * @gb,
               preferred_language: "french",
               original_language: "en"
             )
  end

  test "best_release with original pick on an English title accepts untagged, rejects a FRENCH tag" do
    expect(Cinder.Acquisition.IndexerMock, :search, fn "tt1" ->
      {:ok,
       [
         raw(title: "Movie.2020.FRENCH.1080p.BluRay.x264-FR", size: 8 * @gb),
         raw(title: "Movie.2020.1080p.BluRay.x264-EN", size: 8 * @gb)
       ]}
    end)

    assert {:ok, %Release{group: "EN"}} =
             Acquisition.best_release("tt1",
               max_size: 20 * @gb,
               preferred_language: "original",
               original_language: "en"
             )
  end

  test "best_release with no language preference is unchanged (any/nil)" do
    expect(Cinder.Acquisition.IndexerMock, :search, fn "tt1" ->
      {:ok, [raw(title: "Movie.2020.FRENCH.1080p.BluRay.x264-FR", size: 8 * @gb)]}
    end)

    assert {:ok, %Release{group: "FR"}} =
             Acquisition.best_release("tt1",
               max_size: 20 * @gb,
               preferred_language: "any",
               original_language: "en"
             )
  end

  test "best_release with original pick falls back when a title-word collision tags every release" do
    # The parser tags `language` from the whole release name, so "The Italian Job" is tagged
    # ITALIAN. Under the soft default (original/en), nothing satisfies — but rather than parking,
    # best_release falls back to scoring the unfiltered candidates so the title isn't stranded.
    expect(Cinder.Acquisition.IndexerMock, :search, fn "tt1" ->
      {:ok,
       [
         raw(title: "The.Italian.Job.2003.720p.BluRay.x264-GRP", size: 6 * @gb),
         raw(title: "The.Italian.Job.2003.1080p.BluRay.x264-GRP", size: 8 * @gb)
       ]}
    end)

    assert {:ok, %Release{language: "ITALIAN", resolution: "1080p"}} =
             Acquisition.best_release("tt1",
               max_size: 20 * @gb,
               preferred_language: "original",
               original_language: "en"
             )
  end

  test "best_release with an explicit language pick still parks on a title-word collision (strict)" do
    expect(Cinder.Acquisition.IndexerMock, :search, fn "tt1" ->
      {:ok,
       [
         raw(title: "The.Italian.Job.2003.720p.BluRay.x264-GRP", size: 6 * @gb),
         raw(title: "The.Italian.Job.2003.1080p.BluRay.x264-GRP", size: 8 * @gb)
       ]}
    end)

    assert :no_language_match =
             Acquisition.best_release("tt1",
               max_size: 20 * @gb,
               preferred_language: "french",
               original_language: "en"
             )
  end

  test "best_release: a recognised foreign dub never outranks the original-language release" do
    # The Hungarian bug: the dub used to parse to nil, was assumed 'original', and could outscore
    # the French release. Now it's tagged HUNGARIAN and dropped, so French wins despite being smaller.
    expect(Cinder.Acquisition.IndexerMock, :search, fn "tt1" ->
      {:ok,
       [
         raw(title: "Chasse.Gardee.2024.HUNGARIAN.1080p.WEB-DL.x264-GRP", size: 12 * @gb),
         raw(title: "Chasse.Gardee.2024.FRENCH.1080p.BluRay.x264-FR", size: 8 * @gb)
       ]}
    end)

    assert {:ok, %Release{language: "FRENCH"}} =
             Acquisition.best_release("tt1",
               max_size: 20 * @gb,
               preferred_language: "original",
               original_language: "fr"
             )
  end

  test "best_release: an untagged release never outranks a confirmed original-language one" do
    # No language token → not a confirmed match → ranked below the tagged FRENCH release, so it
    # can't masquerade as the French original and outscore the real one (it is a bigger 1080p,
    # which wins on every non-language axis).
    expect(Cinder.Acquisition.IndexerMock, :search, fn "tt1" ->
      {:ok,
       [
         raw(title: "Chasse.Gardee.2024.1080p.WEB-DL.x264-GRP", size: 12 * @gb),
         raw(title: "Chasse.Gardee.2024.FRENCH.1080p.BluRay.x264-FR", size: 8 * @gb)
       ]}
    end)

    assert {:ok, %Release{language: "FRENCH"}} =
             Acquisition.best_release("tt1",
               max_size: 20 * @gb,
               preferred_language: "original",
               original_language: "fr"
             )
  end

  test "best_release: a non-English title grabs an untagged release when no tagged one fits" do
    # Issue #191 ("Guru", original_language fr): French scene groups publish original-audio
    # releases with a bare name. The tagged alternatives here are out of band (a 19 GB BluRay),
    # so a strict untagged=English read left the movie at :no_match with a perfect candidate on
    # the indexer.
    expect(Cinder.Acquisition.IndexerMock, :search, fn "tt1" ->
      {:ok,
       [
         raw(title: "Guru.2025.FRENCH.1080p.BluRay.x264-GRP", size: 19 * @gb),
         raw(title: "Guru.2025.1080p.WEB.H.264-FW", size: 8 * @gb)
       ]}
    end)

    assert {:ok, %Release{group: "FW"}} =
             Acquisition.best_release("tt1",
               max_size: 12 * @gb,
               preferred_language: "original",
               original_language: "fr"
             )
  end

  describe "list_releases/2" do
    test "returns every release annotated with its verdict, acceptable first" do
      Cinder.Acquisition.IndexerMock
      |> expect(:search, fn "tt1" ->
        {:ok,
         [
           %{
             title: "Good 1080p",
             size: 5_000_000_000,
             seeders: 9,
             download_url: "u",
             protocol: :torrent
           },
           %{
             title: "Huge 1080p",
             size: 90_000_000_000,
             seeders: 9,
             download_url: "u",
             protocol: :torrent
           }
         ]}
      end)

      assert {:ok, [{first, v1}, {_second, v2}]} =
               Acquisition.list_releases("tt1",
                 protocols: [:torrent],
                 preferred_resolutions: ["1080p"],
                 max_size: 10_000_000_000
               )

      assert v1 == :ok
      assert first.title == "Good 1080p"
      assert v2 == {:rejected, :out_of_band}
    end

    test "flags a release on an unconfigured protocol" do
      Cinder.Acquisition.IndexerMock
      |> expect(:search, fn _ ->
        {:ok, [%{title: "U", size: 1_000_000_000, protocol: :usenet, download_url: "u"}]}
      end)

      assert {:ok, [{_r, {:rejected, :wrong_protocol}}]} =
               Acquisition.list_releases("tt1", protocols: [:torrent])
    end

    test "passes through an indexer error" do
      Cinder.Acquisition.IndexerMock |> expect(:search, fn _ -> {:error, :down} end)
      assert Acquisition.list_releases("tt1", []) == {:error, :down}
    end
  end

  # Issue #195 — the free-text fallback for a TMDB title with no IMDb id. Without the id token
  # the title+year guard is the only thing pinning identity, so both halves are load-bearing.
  describe "best_release_by_title/3" do
    test "queries \"Title Year\" and selects a release the guard accepts" do
      expect(Cinder.Acquisition.IndexerMock, :search_movie_query, fn "Dune 2021", [] ->
        {:ok, [raw(title: "[TGx] Dune.2021.1080p.BluRay.x264-GRP")]}
      end)

      assert {:ok, %Release{title: "[TGx] Dune.2021.1080p.BluRay.x264-GRP"}} =
               Acquisition.best_release_by_title("Dune", 2021)
    end

    # The title must be EVERYTHING before the year token — a run-anywhere match takes all three of
    # these, and the biggest one would win the scoring.
    test "rejects a remake, a longer title, and a title the needle only ends" do
      expect(Cinder.Acquisition.IndexerMock, :search_movie_query, fn _query, [] ->
        {:ok,
         [
           raw(title: "Dune.1984.1080p.BluRay.x264-GRP"),
           raw(title: "Dune.Drifter.2021.1080p.WEB-DL-GRP"),
           raw(title: "Sand.Dune.2021.2160p.BluRay.x265-GRP")
         ]}
      end)

      assert Acquisition.best_release_by_title("Dune", 2021) == :no_match
    end

    test "with no known year, anchors on the LAST year token only" do
      expect(Cinder.Acquisition.IndexerMock, :search_movie_query, fn "Dune", [] ->
        {:ok,
         [
           raw(title: "Dune.Drifter.1080p.WEB-DL-GRP"),
           raw(title: "Sand.Dune.2021.2160p.BluRay.x265-GRP"),
           raw(title: "Dune.1984.1080p.BluRay.x264-GRP")
         ]}
      end)

      assert {:ok, %Release{title: "Dune.1984.1080p.BluRay.x264-GRP"}} =
               Acquisition.best_release_by_title("Dune", nil)
    end

    # Anchoring on *any* year token would read the 2049 in this release's title as its year and
    # hand the sequel over for plain "Blade Runner".
    test "with no known year, a title ending in a year is not a match for its prefix" do
      expect(Cinder.Acquisition.IndexerMock, :search_movie_query, 2, fn _query, [] ->
        {:ok, [raw(title: "Blade.Runner.2049.2017.1080p.BluRay.x264-GRP")]}
      end)

      assert Acquisition.best_release_by_title("Blade Runner", nil) == :no_match
      assert {:ok, %Release{}} = Acquisition.best_release_by_title("Blade Runner 2049", nil)
    end

    test "accepts a title that itself ends in a year" do
      expect(Cinder.Acquisition.IndexerMock, :search_movie_query, fn _query, [] ->
        {:ok, [raw(title: "Blade.Runner.2049.2017.1080p.BluRay.x264-GRP")]}
      end)

      assert {:ok, %Release{}} = Acquisition.best_release_by_title("Blade Runner 2049", 2017)
    end

    test "drops a release naming no year at all when the movie's year is known" do
      expect(Cinder.Acquisition.IndexerMock, :search_movie_query, fn _query, [] ->
        {:ok, [raw(title: "Dune.1080p.BluRay.x264-GRP")]}
      end)

      assert Acquisition.best_release_by_title("Dune", 2021) == :no_match
    end

    test "passes through an indexer error" do
      expect(Cinder.Acquisition.IndexerMock, :search_movie_query, fn _q, _o -> {:error, :down} end)

      assert Acquisition.best_release_by_title("Dune", 2021) == {:error, :down}
    end

    # The guard is strict enough to fail closed on real conventions it can't parse (German scene
    # puts the language before the year). Fine for automatic selection — but the manual panel is
    # the operator's override, so it must keep listing them, exactly as `list_releases/2` does.
    test "list_releases_by_title/3 still lists a release the guard rejects" do
      expect(Cinder.Acquisition.IndexerMock, :search_movie_query, 2, fn _query, [] ->
        {:ok, [raw(title: "Dune.German.2021.AC3.BDRiP.x264-GRP")]}
      end)

      assert :no_match = Acquisition.best_release_by_title("Dune", 2021, max_size: 20 * @gb)

      assert {:ok, [{%Release{title: "Dune.German.2021.AC3.BDRiP.x264-GRP"}, _verdict}]} =
               Acquisition.list_releases_by_title("Dune", 2021, max_size: 20 * @gb)
    end
  end

  describe "list_releases_tv/3 alternate numbering" do
    test "unions and deduplicates scene and aired season searches with stable episode ids" do
      episodes = [
        %{id: 29, episode_number: 29},
        %{id: 30, episode_number: 30}
      ]

      context = %{
        mappings: [
          %{
            identity: %{
              source: "tmdb",
              scheme: "scene",
              namespace: "operator-group",
              canonical_value: "S02E01"
            },
            precedence: :inferred,
            episode_ids: [29],
            evidence: nil
          },
          %{
            identity: %{
              source: "tvdb",
              scheme: "aired",
              namespace: "123",
              canonical_value: "S03E01"
            },
            precedence: :inferred,
            episode_ids: [30],
            evidence: nil
          }
        ]
      }

      numbering = Acquisition.standard_tv_numbering(context, episodes, MapSet.new([1]))
      test_pid = self()

      expect(Cinder.Acquisition.IndexerMock, :search_tv, 3, fn 123, "The Office", season ->
        send(test_pid, {:searched_manual_season, season})

        case season do
          1 -> {:ok, [raw_tv("The.Office.S02E01.1080p.WEB-DL-GRP", download_url: "scene")]}
          2 -> {:ok, [raw_tv("The.Office.S02E01.1080p.WEB-DL-GRP", download_url: "scene")]}
          3 -> {:ok, [raw_tv("The.Office.S03E01.1080p.WEB-DL-GRP", download_url: "aired")]}
        end
      end)

      assert {:ok, results} =
               Acquisition.list_releases_tv(series(), 1, standard_numbering: numbering)

      assert [
               {%Release{season: 2, resolved_episode_ids: [29]}, _},
               {%Release{season: 3, resolved_episode_ids: [30]}, _}
             ] = Enum.sort_by(results, fn {release, _verdict} -> release.season end)

      assert_received {:searched_manual_season, 1}
      assert_received {:searched_manual_season, 2}
      assert_received {:searched_manual_season, 3}
    end

    test "marks an ambiguous bridged coordinate instead of choosing an episode" do
      episodes = [%{id: 29, episode_number: 29}, %{id: 30, episode_number: 30}]

      context = %{
        mappings:
          for id <- [29, 30] do
            %{
              identity: %{
                source: "tmdb",
                scheme: "scene",
                namespace: "conflict",
                canonical_value: "S02E01"
              },
              precedence: :inferred,
              episode_ids: [id],
              evidence: nil
            }
          end
      }

      numbering = Acquisition.standard_tv_numbering(context, episodes, MapSet.new([1]))

      expect(Cinder.Acquisition.IndexerMock, :search_tv, 2, fn 123, "The Office", season ->
        if season == 2,
          do: {:ok, [raw_tv("The.Office.S02E01.1080p.WEB-DL-GRP")]},
          else: {:ok, []}
      end)

      assert {:ok,
              [
                {%Release{
                   resolved_episode_ids: nil,
                   resolution_evidence: :conflicting_standard_numbering
                 }, {:rejected, :conflicting_standard_numbering}}
              ]} = Acquisition.list_releases_tv(series(), 1, standard_numbering: numbering)
    end
  end

  describe "best_releases/4 (TV)" do
    test "composes search_tv, parse, title-match, and set-cover scoring (release ⇒ coverage)" do
      # Patterns confirm the series' tvdb_id, title, and season number are passed through.
      expect(Cinder.Acquisition.IndexerMock, :search_tv, fn 123, "The Office", 1 ->
        {:ok,
         [
           raw_tv("The.Office.US.S01E01.1080p.WEB-DL-GRP"),
           raw_tv("The.Office.US.S01E02.1080p.WEB-DL-GRP")
         ]}
      end)

      assert {:ok, chosen} = Acquisition.best_releases(series(), 1, [1, 2])
      assert chosen |> Enum.map(fn {_r, cov} -> cov end) |> Enum.sort() == [[1], [2]]
    end

    test "unions canonical and alternate-season queries before scoring" do
      test_pid = self()

      expect(Cinder.Acquisition.IndexerMock, :search_tv, 2, fn
        123, "The Office", season_number ->
          send(test_pid, {:searched_season, season_number})

          if season_number == 2,
            do: {:ok, [raw_tv("The.Office.S02E01.1080p.WEB-DL-GRP")]},
            else: {:ok, []}
      end)

      assert {:ok, [{%Release{season: 2, episodes: [1]}, [29]}]} =
               Acquisition.best_releases(series(), 1, [29],
                 alternate_numbering: %{2 => %{1 => [29]}}
               )

      assert_received {:searched_season, 1}
      assert_received {:searched_season, 2}
    end

    test "keeps the TV language gate strict about untagged releases" do
      # The #191 relaxation is movie-only. Set-cover sorts by coverage BEFORE the scorer's
      # language rank, so an untagged season pack would beat the confirmed-FRENCH singles it
      # covers and the ranking safety net would never engage. Untagged stays filtered out here.
      expect(Cinder.Acquisition.IndexerMock, :search_tv, fn _tvdb, _title, _season ->
        {:ok,
         [
           raw_tv("The.Office.S01.1080p.WEB-DL.x264-FW"),
           raw_tv("The.Office.S01E01.FRENCH.1080p.WEB-DL-GRP"),
           raw_tv("The.Office.S01E02.FRENCH.1080p.WEB-DL-GRP")
         ]}
      end)

      assert {:ok, chosen} =
               Acquisition.best_releases(series(), 1, [1, 2],
                 preferred_language: "original",
                 original_language: "fr"
               )

      assert chosen |> Enum.map(fn {r, _cov} -> r.language end) == ["FRENCH", "FRENCH"]
    end

    # #268: 4 of 22 episodes wanted banded a 19.7 GB season pack at 4×4 GB and parked the tail.
    # One `expect` (not two) also pins that the retry re-scores the SAME candidates rather than
    # searching the indexer again.
    test "retries a whole-season pack against the season's episode count when nothing else fits" do
      expect(Cinder.Acquisition.IndexerMock, :search_tv, fn 123, "The Office", 3 ->
        {:ok, [raw_tv("The.Office.S03.1080p.BluRay.x265-GRP", size: 197 * div(@gb, 10))]}
      end)

      assert {:ok, [{%Release{episodes: nil}, [19, 20, 21, 22]}]} =
               Acquisition.best_releases(series(), 3, [19, 20, 21, 22],
                 max_size: 4 * @gb,
                 season_episode_count: 22
               )
    end

    # The reason the widened band is a retry and not the first pass: `Scorer.cover/6` sorts by
    # coverage before rank, so a pack that fits takes the whole want and the singles behind it are
    # never scored. Running it only after a clean :no_match keeps four 1 GB grabs from collapsing
    # into one 19.7 GB grab on an unattended sweep.
    test "viable singles still win over a fat pack — the widened band never runs" do
      expect(Cinder.Acquisition.IndexerMock, :search_tv, fn _tvdb, _title, 3 ->
        {:ok,
         [
           raw_tv("The.Office.S03.1080p.BluRay.x265-GRP", size: 197 * div(@gb, 10))
           | Enum.map(19..22, fn n ->
               raw_tv("The.Office.S03E#{n}.1080p.WEB-DL-GRP", size: 1 * @gb)
             end)
         ]}
      end)

      assert {:ok, chosen} =
               Acquisition.best_releases(series(), 3, [19, 20, 21, 22],
                 max_size: 4 * @gb,
                 season_episode_count: 22
               )

      assert chosen |> Enum.map(fn {_r, cov} -> cov end) |> Enum.sort() ==
               [[19], [20], [21], [22]]
    end

    test "rejects a same-season release of a different series on the free-text path" do
      expect(Cinder.Acquisition.IndexerMock, :search_tv, fn _tvdb, _title, _season ->
        {:ok, [raw_tv("Parks.and.Recreation.S01E01.1080p.WEB-DL-GRP")]}
      end)

      assert :no_match = Acquisition.best_releases(series(tvdb_id: nil), 1, [1])
    end

    test "rejects a spinoff that carries the wanted series title as an inner token run" do
      expect(Cinder.Acquisition.IndexerMock, :search_tv, fn _tvdb, _title, _season ->
        {:ok,
         [
           raw_tv(
             "Magia.Record.Puella.Magi.Madoka.Magica.Side.Story.S01E02.German.DL.DTS.1080p.BluRay.x265-ABJ",
             query_origins: [:free_text]
           )
         ]}
      end)

      assert :no_match =
               Acquisition.best_releases(
                 series(title: "Puella Magi Madoka Magica"),
                 1,
                 [2]
               )
    end

    test "keeps an AKA-titled release from the TVDB-id half of the union" do
      # TMDB title "Money Heist", release under the original title — the TvdbId
      # token already scoped the search to the right show.
      expect(Cinder.Acquisition.IndexerMock, :search_tv, fn 123, _title, _season ->
        {:ok, [raw_tv("La.Casa.de.Papel.S01E01.1080p.WEB-DL-GRP", query_origins: [:id_scoped])]}
      end)

      assert {:ok, [{%Release{episodes: [1]}, [1]}]} =
               Acquisition.best_releases(series(title: "Money Heist"), 1, [1])
    end

    test "a numeric title is token-anchored: a year in another show's name can't match" do
      # Regression: substring matching let series "24" accept "Other.Show.2024..." —
      # the scorer then matched on season number alone and imported the wrong show.
      expect(Cinder.Acquisition.IndexerMock, :search_tv, fn _tvdb, _title, _season ->
        {:ok, [raw_tv("Other.Show.2024.S01E05.1080p.WEB-DL-GRP")]}
      end)

      assert :no_match = Acquisition.best_releases(series(tvdb_id: nil, title: "24"), 1, [5])
    end

    test "an all-numeric title still matches its own releases" do
      expect(Cinder.Acquisition.IndexerMock, :search_tv, fn _tvdb, _title, _season ->
        {:ok, [raw_tv("24.S01E05.1080p.WEB-DL-GRP")]}
      end)

      assert {:ok, [{%Release{episodes: [5]}, [5]}]} =
               Acquisition.best_releases(series(tvdb_id: nil, title: "24"), 1, [5])
    end

    test "a tag-prefixed release name still matches a short title (token, not prefix, anchor)" do
      expect(Cinder.Acquisition.IndexerMock, :search_tv, fn _tvdb, _title, _season ->
        {:ok, [raw_tv("[TGx] 24.S01E05.1080p.WEB-DL-GRP")]}
      end)

      assert {:ok, [{%Release{episodes: [5]}, [5]}]} =
               Acquisition.best_releases(series(tvdb_id: nil, title: "24"), 1, [5])
    end

    test "a year-conflicting same-name release is rejected even on the id-scoped path" do
      # search_tv/3 unions in a free-text title query (so scraper indexers contribute),
      # which can surface a same-named different show: "Charmed (2018)" packs for the
      # year-1998 series. A conflicting year token rejects; a matching, ±1, or absent
      # year passes.
      expect(Cinder.Acquisition.IndexerMock, :search_tv, fn 123, "Charmed", 1 ->
        {:ok,
         [
           raw_tv("Charmed.2018.S01E01.1080p.WEB-DL-GRP"),
           raw_tv("Charmed.1998.S01E01.1080p.WEB-DL-GRP"),
           raw_tv("Charmed.S01E02.1080p.WEB-DL-GRP"),
           raw_tv("Charmed.1997.S01E03.1080p.WEB-DL-GRP")
         ]}
      end)

      assert {:ok, chosen} =
               Acquisition.best_releases(series(title: "Charmed", year: 1998), 1, [1, 2, 3])

      assert chosen |> Enum.map(fn {r, _cov} -> r.title end) |> Enum.sort() == [
               "Charmed.1997.S01E03.1080p.WEB-DL-GRP",
               "Charmed.1998.S01E01.1080p.WEB-DL-GRP",
               "Charmed.S01E02.1080p.WEB-DL-GRP"
             ]
    end

    test "a franchise-prefixed release name still matches (series '1883' in 'Yellowstone.1883')" do
      expect(Cinder.Acquisition.IndexerMock, :search_tv, fn _tvdb, _title, _season ->
        {:ok, [raw_tv("Yellowstone.1883.S01E01.1080p.WEB-DL-GRP")]}
      end)

      assert {:ok, [{%Release{episodes: [1]}, [1]}]} =
               Acquisition.best_releases(series(tvdb_id: nil, title: "1883"), 1, [1])
    end

    test "a title embedded inside another token is rejected ('Dark' vs 'Darkwing.Duck')" do
      expect(Cinder.Acquisition.IndexerMock, :search_tv, fn _tvdb, _title, _season ->
        {:ok, [raw_tv("Darkwing.Duck.S01E05.1080p.WEB-DL-GRP")]}
      end)

      assert :no_match = Acquisition.best_releases(series(tvdb_id: nil, title: "Dark"), 1, [5])
    end

    test "a title that folds to nothing (non-Latin) fails closed instead of matching everything" do
      # "Дом" tokenizes to [] — matching would accept EVERY same-season release. Those series
      # need the tvdb_id-scoped path (which skips the guard).
      expect(Cinder.Acquisition.IndexerMock, :search_tv, fn _tvdb, _title, _season ->
        {:ok, [raw_tv("Random.Show.S01E05.1080p.WEB-DL-GRP")]}
      end)

      assert :no_match = Acquisition.best_releases(series(tvdb_id: nil, title: "Дом"), 1, [5])
    end

    test "a non-decomposable letter is transliterated, not stripped mid-token ('Æon Flux')" do
      # æ has no NFD decomposition; stripping it would leave the unmatchable needle "onflux".
      expect(Cinder.Acquisition.IndexerMock, :search_tv, fn _tvdb, _title, _season ->
        {:ok, [raw_tv("Aeon.Flux.S01E01.1080p.WEB-DL-GRP")]}
      end)

      assert {:ok, [{%Release{episodes: [1]}, [1]}]} =
               Acquisition.best_releases(series(tvdb_id: nil, title: "Æon Flux"), 1, [1])
    end

    test "an '&' in a mostly-non-Latin title can't inflate the needle past the fail-closed guard" do
      # "&"→"and" expansion must count on BOTH sides of the ratio: otherwise "Дом & Сад"
      # folds to the needle "and", which matches half the releases on any indexer.
      expect(Cinder.Acquisition.IndexerMock, :search_tv, fn _tvdb, _title, _season ->
        {:ok, [raw_tv("Law.and.Order.S01E05.1080p.WEB-DL-GRP")]}
      end)

      assert :no_match =
               Acquisition.best_releases(series(tvdb_id: nil, title: "Дом & Сад"), 1, [5])
    end

    test "title-match folds diacritics so an ASCII-ized release still matches" do
      expect(Cinder.Acquisition.IndexerMock, :search_tv, fn _tvdb, _title, _season ->
        {:ok, [raw_tv("Pokemon.S01E01.1080p.WEB-DL-GRP")]}
      end)

      assert {:ok, [{%Release{episodes: [1]}, [1]}]} =
               Acquisition.best_releases(series(tvdb_id: nil, title: "Pokémon"), 1, [1])
    end

    test "title-match equates '&' and 'and' so scene names match ampersand titles" do
      expect(Cinder.Acquisition.IndexerMock, :search_tv, fn _tvdb, _title, _season ->
        {:ok, [raw_tv("Law.and.Order.S01E01.1080p.WEB-DL-GRP")]}
      end)

      assert {:ok, [{%Release{episodes: [1]}, [1]}]} =
               Acquisition.best_releases(series(tvdb_id: nil, title: "Law & Order"), 1, [1])
    end

    test "drops releases whose protocol has no configured client before scoring" do
      expect(Cinder.Acquisition.IndexerMock, :search_tv, fn _tvdb, _title, _season ->
        {:ok,
         [
           raw_tv("The.Office.US.S01E01.1080p.WEB-DL-USE", protocol: :usenet),
           raw_tv("The.Office.US.S01E02.720p.WEB-DL-TOR", protocol: :torrent)
         ]}
      end)

      assert {:ok, [{%Release{protocol: :torrent, episodes: [2]}, [2]}]} =
               Acquisition.best_releases(series(), 1, [1, 2], protocols: [:torrent])
    end

    test ":no_match when nothing survives; indexer error passes through" do
      expect(Cinder.Acquisition.IndexerMock, :search_tv, fn _, _, _ -> {:ok, []} end)
      assert :no_match = Acquisition.best_releases(series(), 1, [1])

      expect(Cinder.Acquisition.IndexerMock, :search_tv, fn _, _, _ -> {:error, :timeout} end)
      assert {:error, :timeout} = Acquisition.best_releases(series(), 1, [1])
    end

    test "best_releases filters episodes by language: french pick covers only FRENCH/MULTI episodes" do
      expect(Cinder.Acquisition.IndexerMock, :search_tv, fn 123, "The Office", 1 ->
        {:ok,
         [
           raw_tv("The.Office.S01E01.FRENCH.1080p.WEB-DL-FR"),
           raw_tv("The.Office.S01E02.1080p.WEB-DL-EN")
         ]}
      end)

      assert {:ok, chosen} =
               Acquisition.best_releases(series(), 1, [1, 2],
                 preferred_language: "french",
                 original_language: "en"
               )

      # E02 has only an English release -> not covered; E01 (FRENCH) is covered.
      assert chosen |> Enum.flat_map(fn {_r, cov} -> cov end) |> Enum.sort() == [1]
    end

    test "best_releases with original pick falls back when a title-word collision tags every episode" do
      # Same soft-default fallback as the movie path: every episode is tagged ITALIAN by the
      # release name, nothing satisfies original/en, so it covers via the unfiltered candidates.
      expect(Cinder.Acquisition.IndexerMock, :search_tv, fn 123, "The Office", 1 ->
        {:ok,
         [
           raw_tv("The.Office.S01E01.ITALIAN.1080p.WEB-DL-GRP"),
           raw_tv("The.Office.S01E02.ITALIAN.1080p.WEB-DL-GRP")
         ]}
      end)

      assert {:ok, chosen} =
               Acquisition.best_releases(series(), 1, [1, 2],
                 preferred_language: "original",
                 original_language: "en"
               )

      assert chosen |> Enum.flat_map(fn {_r, cov} -> cov end) |> Enum.sort() == [1, 2]
    end

    test "best_releases returns :no_match when no episode has a satisfying release" do
      expect(Cinder.Acquisition.IndexerMock, :search_tv, fn 123, "The Office", 1 ->
        {:ok,
         [
           raw_tv("The.Office.S01E01.1080p.WEB-DL-EN"),
           raw_tv("The.Office.S01E02.1080p.WEB-DL-EN")
         ]}
      end)

      assert :no_match =
               Acquisition.best_releases(series(), 1, [1, 2],
                 preferred_language: "french",
                 original_language: "en"
               )
    end
  end

  describe "title_guard/3" do
    test "keeps an id-scoped AKA while dropping a free-text title continued by spinoff words" do
      target = series(title: "Money Heist")

      releases =
        [
          raw_tv("Berlin.Money.Heist.Side.Story.S01E01.1080p.WEB-DL-GRP",
            query_origins: [:free_text]
          ),
          raw_tv("La.Casa.de.Papel.S01E01.1080p.WEB-DL-GRP",
            query_origins: [:id_scoped]
          )
        ]
        |> Enum.map(&Release.new/1)

      assert [%Release{title: "La.Casa.de.Papel.S01E01.1080p.WEB-DL-GRP"}] =
               Acquisition.title_guard(releases, :tv, target)
    end
  end
end
