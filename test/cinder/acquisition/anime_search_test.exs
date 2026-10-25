defmodule Cinder.Acquisition.AnimeSearchTest do
  use ExUnit.Case, async: true

  import Mox

  alias Cinder.Acquisition
  alias Cinder.Acquisition.Anime
  alias Cinder.Acquisition.IndexerMock
  alias Cinder.Catalog.Episode

  setup :verify_on_exit!

  test "movie search preserves provenance and unions metadata across a URL duplicate" do
    context = movie_context([alias_map("Kimi no Na wa", :romaji)])
    result = raw("[Group] Kimi no Na wa (2016) [1080p]", "same")

    expect(IndexerMock, :search, fn "tt1" -> {:ok, [result]} end)

    expect(IndexerMock, :search_movie_query, 2, fn query, categories: [5070] ->
      send(self(), {:movie_query, query})

      if query == "Kimi no Na wa 2016" do
        {:ok, [%{result | category_ids: [5070]}]}
      else
        {:ok, []}
      end
    end)

    assert {:ok, [release], false} = Anime.search_movie(IndexerMock, "tt1", context, [])
    assert Enum.sort(release.query_origins) == [:free_text, :id_scoped]
    assert release.category_ids == [5070]
    assert_receive {:movie_query, "Your Name 2016"}
    assert_receive {:movie_query, "Kimi no Na wa 2016"}
  end

  test "free-text movie results require a known Unicode title and the exact year" do
    context = movie_context([alias_map("君の名は。", :native)])
    expect(IndexerMock, :search, fn "tt1" -> {:ok, []} end)

    expect(IndexerMock, :search_movie_query, 2, fn
      "Your Name 2016", categories: [5070] ->
        {:ok, []}

      "君の名は。 2016", categories: [5070] ->
        {:ok,
         [
           raw("[Group] 君の名は。 (2016) [1080p]", "valid"),
           raw("Your Name Spinoff (2016) [1080p]", "spinoff"),
           raw("The Your Name (2016) [1080p]", "embedded"),
           raw("Your Name (2015) [1080p]", "wrong-year"),
           raw("Your Name [1080p]", "missing-year")
         ]}
    end)

    assert {:ok, [release], false} = Anime.search_movie(IndexerMock, "tt1", context, [])
    assert release.title == "[Group] 君の名は。 (2016) [1080p]"
    assert release.query_origins == [:free_text]
  end

  test "free-text movie guard accepts a remaster release naming a second, later year (#458)" do
    context = %{
      kind: :movie,
      title: "Akira",
      year: 1988,
      aliases: [],
      profile: %{effective: :anime}
    }

    expect(IndexerMock, :search, fn "tt2" -> {:ok, []} end)

    expect(IndexerMock, :search_movie_query, fn "Akira 1988", categories: [5070] ->
      {:ok, [raw("Akira.1988.4K.Remaster.2020.BluRay.2160p.x265-GROUP", "remaster")]}
    end)

    assert {:ok, [release], false} = Anime.search_movie(IndexerMock, "tt2", context, [])
    assert release.title == "Akira.1988.4K.Remaster.2020.BluRay.2160p.x265-GROUP"
  end

  test "a garbled indexer title in the free-text result set does not crash the movie search (#451)" do
    context = movie_context([])
    garbled = <<0xFF, 0xFE, 0x80, 0x81, "S01E01", 0xC0, 0xAF>>
    good = raw("Your Name (2016) [1080p]", "good")

    expect(IndexerMock, :search, fn "tt1" -> {:ok, []} end)

    expect(IndexerMock, :search_movie_query, fn "Your Name 2016", categories: [5070] ->
      {:ok, [raw(garbled, "garbled"), good]}
    end)

    assert {:ok, [release], false} = Anime.search_movie(IndexerMock, "tt1", context, [])
    assert release.title == "Your Name (2016) [1080p]"
  end

  test "id-scoped movie results must name the title or an alias, without the year requirement (#624)" do
    context = movie_context([alias_map("Kimi no Na wa", :romaji), alias_map("君の名は。", :native)])

    expect(IndexerMock, :search, fn "tt1" ->
      {:ok,
       [
         raw("[Group] Weathering With You (2019) [1080p]", "wrong-film"),
         raw("[Group] Kimi no Na wa [1080p]", "romaji-no-year"),
         raw("[Group] 君の名は。 (2016) [1080p]", "native"),
         raw("[Group] Your Name v2 [1080p]", "canonical-v2")
       ]}
    end)

    expect(IndexerMock, :search_movie_query, 3, fn _query, categories: [5070] -> {:ok, []} end)

    # The release judge's title stage holds the IMDb-scoped guard; the search keeps every result.
    assert {:ok, judged, false} = Acquisition.judge_anime_movie("tt1", context, [])

    assert Enum.map(judged.kept, & &1.download_url) == [
             "romaji-no-year",
             "native",
             "canonical-v2"
           ]
  end

  test "a movie with no usable title or alias keeps its id-scoped results (#624)" do
    context = %{movie_context([]) | title: "君の名は。"}

    expect(IndexerMock, :search, fn "tt1" ->
      {:ok, [raw("[Group] Anything Else (2019) [1080p]", "kept")]}
    end)

    expect(IndexerMock, :search_movie_query, fn _query, categories: [5070] -> {:ok, []} end)

    assert {:ok, %{kept: [release]}, false} = Acquisition.judge_anime_movie("tt1", context, [])
    assert release.download_url == "kept"
  end

  test "the Anime manual list keeps a guard-rejected id-scoped row as title_mismatch (#624)" do
    context = movie_context([])

    expect(IndexerMock, :search, fn "tt1" ->
      {:ok,
       [
         raw("[Group] Weathering With You (2019) [1080p]", "other-film"),
         raw("[Group] Your Name (2016) [1080p]", "right-film")
       ]}
    end)

    expect(IndexerMock, :search_movie_query, fn _query, categories: [5070] -> {:ok, []} end)

    assert {:ok, judged, false} = Acquisition.judge_anime_movie("tt1", context, [])

    verdicts = Map.new(judged.rows, &{&1.release.download_url, &1.verdict})
    assert verdicts == %{"right-film" => :ok, "other-film" => {:rejected, :title_mismatch}}
    assert Enum.map(judged.kept, & &1.download_url) == ["right-film"]
  end

  test "the anime movie sweep never takes the id-scoped row the panel lists as title_mismatch" do
    context = movie_context([])

    expect(IndexerMock, :search, fn "tt1" ->
      {:ok, [raw("[Group] Weathering With You (2019) [1080p]", "other-film")]}
    end)

    expect(IndexerMock, :search_movie_query, fn _query, categories: [5070] -> {:ok, []} end)

    assert :no_match = Acquisition.best_anime_movie("tt1", context, [])
  end

  test "an anime movie search with a failed query can't call a miss no match" do
    context = movie_context([])

    expect(IndexerMock, :search, fn "tt1" -> {:error, :timeout} end)
    expect(IndexerMock, :search_movie_query, fn _query, categories: [5070] -> {:ok, []} end)

    assert {:error, :incomplete_search} = Acquisition.best_anime_movie("tt1", context, [])
  end

  test "an anime movie search with a failed query still takes what it found" do
    context = movie_context([])

    expect(IndexerMock, :search, fn "tt1" -> {:error, :timeout} end)

    expect(IndexerMock, :search_movie_query, fn _query, categories: [5070] ->
      {:ok, [raw("[Group] Your Name (2016) [1080p]", "found")]}
    end)

    assert {:ok, %{download_url: "found"}} = Acquisition.best_anime_movie("tt1", context, [])
  end

  test "TVDB search remains ID-scoped and propagates canonical title and season" do
    context = series_context(99)

    expect(IndexerMock, :search_tv, fn tvdb_id, title, season ->
      send(self(), {:search_tv, tvdb_id, title, season})
      {:ok, [raw("Different Title S01E01 [1080p]", "id-result")]}
    end)

    expect(IndexerMock, :search_tv_query, 2, fn _query, categories: [5070] -> {:ok, []} end)

    assert {:ok, [release], false} = Anime.search_episodes(IndexerMock, context, [11], [])
    assert release.query_origins == [:id_scoped]
    assert_receive {:search_tv, 99, "Show", 1}
  end

  # #699: a TVDB-scoped result is scope, not identity proof. The indexer reporting the series' own
  # TVDB id proves it under any name, another series' id drops it, and otherwise its name has to
  # lead with the title or an alias.
  test "the anime episode sweep never takes an id-scoped result named after another series (#699)" do
    expect(IndexerMock, :search_tv, fn 99, "Show", 1 ->
      {:ok, [raw("86 Eighty-Six S01E01 [1080p]", "other-series")]}
    end)

    expect(IndexerMock, :search_tv_query, 2, fn _query, categories: [5070] -> {:ok, []} end)

    assert :no_match = Acquisition.best_anime_releases(series_context(99), [11])
  end

  test "an id-scoped episode result needs the series' TVDB id or a name leading with a title (#699)" do
    context = %{
      series_context(99)
      | title: "Frieren: Beyond Journey's End",
        aliases: [alias_map("Sousou no Frieren", :romaji), alias_map("葬送のフリーレン", :native)]
    }

    expect(IndexerMock, :search_tv, fn 99, "Frieren: Beyond Journey's End", 1 ->
      {:ok,
       [
         raw("86 Eighty-Six S01E01 [1080p]", "other-name"),
         Map.put(raw("86 Eighty-Six S01E01 [1080p]", "own-id"), :tvdb_id, 99),
         Map.put(raw("[Group] Sousou no Frieren S01E01 [1080p]", "other-id"), :tvdb_id, 77),
         raw("Not.Frieren.Beyond.Journeys.End.S01E01.1080p", "embedded"),
         # The scene spelling drops the colon and the apostrophe the TMDB title has.
         raw("Frieren.Beyond.Journeys.End.S01E01.1080p.WEB.H264-GRP", "scene"),
         raw("[SubsPlease] Sousou no Frieren S01E01 (1080p)", "romaji"),
         raw("[Group] 葬送のフリーレン S01E01 [1080p]", "native")
       ]}
    end)

    expect(IndexerMock, :search_tv_query, 4, fn _query, categories: [5070] -> {:ok, []} end)

    assert {:ok, judged, false} = Acquisition.judge_anime_episodes(context, [11], [])

    # The panel lists every dropped row as a title mismatch the operator may override.
    assert Map.new(judged.rows, &{&1.release.download_url, &1.verdict}) == %{
             "other-name" => {:rejected, :title_mismatch},
             "own-id" => :ok,
             "other-id" => {:rejected, :title_mismatch},
             "embedded" => {:rejected, :title_mismatch},
             "scene" => :ok,
             "romaji" => :ok,
             "native" => :ok
           }

    assert Enum.map(judged.kept, & &1.download_url) == ["own-id", "scene", "romaji", "native"]

    for release <- judged.kept do
      assert {:ok, %{assignments: [%{episode_ids: [11]}]}} =
               Anime.select_episodes([release], context, [11]),
             release.download_url
    end
  end

  # A same-titled series of another year is another series: the season guard's ±1 year rule.
  # With no series year, a year token can't conflict, so it opens a release tag.
  test "an id-scoped episode result naming the title with another year is another series (#699)" do
    expect(IndexerMock, :search_tv, fn 99, "Show", 1 ->
      {:ok,
       [
         raw("Show.1999.S01E01.1080p.WEB-DL-GRP", "scene-other-year"),
         raw("[Group] Show (1999) S01E01 [1080p]", "anime-other-year"),
         raw("Show.2021.S01E01.1080p.WEB-DL-GRP", "scene-own-year"),
         raw("[Group] Show (2020) S01E01 [1080p]", "anime-own-year")
       ]}
    end)

    expect(IndexerMock, :search_tv_query, 2, fn _query, categories: [5070] -> {:ok, []} end)

    assert {:ok, judged, false} = Acquisition.judge_anime_episodes(series_context(99), [11], [])

    assert Map.new(judged.rows, &{&1.release.download_url, &1.verdict}) == %{
             "scene-other-year" => {:rejected, :title_mismatch},
             "anime-other-year" => {:rejected, :title_mismatch},
             "scene-own-year" => :ok,
             "anime-own-year" => :ok
           }

    # A year-shaped token inside an alias is the title, not a year.
    context = %{
      series_context(99)
      | title: "Bubblegum Crisis Tokyo 2040",
        year: 1998,
        aliases: [alias_map("Bubblegum Crisis 2040", :alternative)]
    }

    expect(IndexerMock, :search_tv, fn 99, "Bubblegum Crisis Tokyo 2040", 1 ->
      {:ok,
       [
         raw("Bubblegum.Crisis.2040.S01E01.1080p.BluRay-GRP", "alias-scene"),
         raw("[Group] Bubblegum Crisis 2040 S01E01 [1080p]", "alias-anime")
       ]}
    end)

    expect(IndexerMock, :search_tv_query, 3, fn _query, categories: [5070] -> {:ok, []} end)

    assert {:ok, %{kept: kept}, false} = Acquisition.judge_anime_episodes(context, [11], [])
    assert Enum.map(kept, & &1.download_url) == ["alias-scene", "alias-anime"]

    context = %{series_context(99) | title: "Frieren: Beyond Journey's End", year: nil}

    expect(IndexerMock, :search_tv, fn 99, "Frieren: Beyond Journey's End", 1 ->
      {:ok, [raw("Frieren.Beyond.Journeys.End.2023.S01E01.1080p.WEB.H264-GRP", "no-year")]}
    end)

    expect(IndexerMock, :search_tv_query, 2, fn _query, categories: [5070] -> {:ok, []} end)

    assert {:ok, %{assignments: [%{episode_ids: [11]}]}} =
             Acquisition.best_anime_releases(context, [11])
  end

  # As #624 for movies: with no title or alias a scene name could spell (native script only),
  # nothing can confirm or refute a release name, so the id scope stays the only evidence.
  test "a series with no usable title keeps its id-scoped episode results (#699)" do
    context = %{series_context(99) | title: "葬送のフリーレン"}

    expect(IndexerMock, :search_tv, fn 99, "葬送のフリーレン", 1 ->
      {:ok, [raw("Sousou no Frieren S01E01 [1080p]", "kept")]}
    end)

    expect(IndexerMock, :search_tv_query, 2, fn _query, categories: [5070] -> {:ok, []} end)

    assert {:ok, %{assignments: [%{episode_ids: [11], release: release}]}} =
             Acquisition.best_anime_releases(context, [11])

    assert release.download_url == "kept"
  end

  test "URL duplicates keep the TVDB id their copies report, none when only some are the series' (#699)" do
    expect(IndexerMock, :search_tv, fn 99, "Show", 1 ->
      {:ok,
       [
         raw("Show S01E01 [1080p]", "one"),
         Map.put(raw("Show S01E01 [720p]", "two"), :tvdb_id, 99),
         Map.put(raw("Show S01E01 [480p]", "three"), :tvdb_id, 77),
         Map.put(raw("Show S01E01 [2160p]", "four"), :tvdb_id, 77)
       ]}
    end)

    expect(IndexerMock, :search_tv_query, 2, fn
      "Show", categories: [5070] ->
        {:ok,
         [
           Map.put(raw("Show S01E01 [1080p]", "one"), :tvdb_id, 99),
           Map.put(raw("Show S01E01 [720p]", "two"), :tvdb_id, 77),
           Map.put(raw("Show S01E01 [480p]", "three"), :tvdb_id, 88),
           Map.put(raw("Show S01E01 [2160p]", "four"), :tvdb_id, 88)
         ]}

      "Show S01E01", categories: [5070] ->
        {:ok,
         [
           Map.put(raw("Show S01E01 [720p]", "two"), :tvdb_id, 99),
           Map.put(raw("Show S01E01 [480p]", "three"), :tvdb_id, 99)
         ]}
    end)

    assert {:ok, [one, two, three, four], false} =
             Anime.search_episodes(IndexerMock, series_context(99), [11], [])

    assert {one.download_url, one.tvdb_id} == {"one", 99}
    assert {two.download_url, two.tvdb_id} == {"two", nil}
    assert {three.download_url, three.tvdb_id} == {"three", nil}
    # Copies naming only other series keep one of their ids, which still drops the result.
    assert {four.download_url, four.tvdb_id} == {"four", 77}
  end

  test "a free-text result from a TVDB search union remains title-guarded" do
    context = %{series_context(99) | title: "Puella Magi Madoka Magica"}

    result =
      "Magia.Record.Puella.Magi.Madoka.Magica.Side.Story.S01E01.1080p.BluRay.x265-ABJ"
      |> raw("union-free-text")
      |> Map.put(:query_origins, [:free_text])

    expect(IndexerMock, :search_tv, fn 99, "Puella Magi Madoka Magica", 1 ->
      {:ok, [result]}
    end)

    expect(IndexerMock, :search_tv_query, 2, fn _query, categories: [5070] -> {:ok, []} end)

    assert {:ok, [], false} = Anime.search_episodes(IndexerMock, context, [11], [])
  end

  test "a nil-TVDB search is guarded as free text" do
    context = series_context(nil)

    expect(IndexerMock, :search_tv, fn nil, "Show", 1 ->
      {:ok,
       [
         raw("Show S01E01 [1080p]", "valid"),
         raw("Show Spinoff S01E01 [1080p]", "spinoff")
       ]}
    end)

    expect(IndexerMock, :search_tv_query, 2, fn _query, categories: [5070] -> {:ok, []} end)

    assert {:ok, [release], false} = Anime.search_episodes(IndexerMock, context, [11], [])
    assert release.title == "Show S01E01 [1080p]"
    assert release.query_origins == [:free_text]
  end

  test "free-text guard rejects a dot-separated release for a differently-numbered sequel naming its own year (#468)" do
    context = series_context(nil)

    expect(IndexerMock, :search_tv, fn nil, "Show", 1 ->
      {:ok, [raw("Show.4.2024.1080p.WEB-DL-GROUP", "sequel")]}
    end)

    expect(IndexerMock, :search_tv_query, 2, fn _query, categories: [5070] -> {:ok, []} end)

    assert {:ok, [], false} = Anime.search_episodes(IndexerMock, context, [11], [])
  end

  test "free-text guard keeps a bracketed fansub absolute-numbered release (#468)" do
    context = series_context(nil)

    expect(IndexerMock, :search_tv, fn nil, "Show", 1 ->
      {:ok, [raw("[Fansub] Show - 12 [1080p]", "absolute")]}
    end)

    expect(IndexerMock, :search_tv_query, 2, fn _query, categories: [5070] -> {:ok, []} end)

    assert {:ok, [release], false} = Anime.search_episodes(IndexerMock, context, [11], [])
    assert release.title == "[Fansub] Show - 12 [1080p]"
  end

  test "free-text guard keeps an absolute release carrying a v2 revision tag (#468)" do
    context = series_context(nil)

    expect(IndexerMock, :search_tv, fn nil, "Show", 1 ->
      {:ok, [raw("Show - 03v2 [1080p]", "v2")]}
    end)

    expect(IndexerMock, :search_tv_query, 2, fn _query, categories: [5070] -> {:ok, []} end)

    assert {:ok, [release], false} = Anime.search_episodes(IndexerMock, context, [11], [])
    assert release.title == "Show - 03v2 [1080p]"
  end

  test "free-text guard keeps an absolute episode range (#468)" do
    context = series_context(nil)

    expect(IndexerMock, :search_tv, fn nil, "Show", 1 ->
      {:ok, [raw("Show - 01-05 [1080p]", "range")]}
    end)

    expect(IndexerMock, :search_tv_query, 2, fn _query, categories: [5070] -> {:ok, []} end)

    assert {:ok, [release], false} = Anime.search_episodes(IndexerMock, context, [11], [])
    assert release.title == "Show - 01-05 [1080p]"
  end

  test "partial query failures retain results and all-query failure returns the first reason" do
    context = movie_context([])

    expect(IndexerMock, :search, fn "tt1" -> {:error, :id_down} end)

    expect(IndexerMock, :search_movie_query, fn "Your Name 2016", categories: [5070] ->
      {:ok, [raw("Your Name (2016) [1080p]", "fallback")]}
    end)

    assert {:ok, [_release], true} = Anime.search_movie(IndexerMock, "tt1", context, [])

    expect(IndexerMock, :search, fn "tt2" -> {:error, :id_down} end)

    expect(IndexerMock, :search_movie_query, fn "Your Name 2016", categories: [5070] ->
      {:error, :free_text_down}
    end)

    assert {:error, :id_down} = Anime.search_movie(IndexerMock, "tt2", context, [])
  end

  test "movie search stops at nine requests and counts Unicode codepoints rather than graphemes" do
    counter = start_supervised!({Agent, fn -> 0 end})
    decomposed_200 = "A" <> String.duplicate("\u0301", 199)
    decomposed_201 = "A" <> String.duplicate("\u0301", 200)

    aliases =
      [
        alias_map(decomposed_200, :scene, :manual),
        alias_map(decomposed_201, :scene, :manual)
      ] ++ Enum.map(1..10, &alias_map("Alias #{&1}", :alternative, :inferred))

    context = movie_context(aliases)

    stub(IndexerMock, :search, fn "tt1" ->
      Agent.update(counter, &(&1 + 1))
      {:ok, []}
    end)

    stub(IndexerMock, :search_movie_query, fn query, categories: [5070] ->
      Agent.update(counter, &(&1 + 1))
      send(self(), {:bounded_movie_query, query})
      {:ok, []}
    end)

    assert {:ok, [], false} = Anime.search_movie(IndexerMock, "tt1", context, [])
    assert Agent.get(counter, & &1) == 9
    expected_200 = "#{decomposed_200} 2016"
    expected_201 = "#{decomposed_201} 2016"
    queries = receive_queries(:bounded_movie_query, 8)
    assert Enum.take(queries, 2) == ["Your Name 2016", expected_200]
    refute expected_201 in queries
  end

  test "episodic search stops at four seasons, three schemes, and 24 requests" do
    counter = start_supervised!({Agent, fn -> 0 end})
    coordinate_32 = String.duplicate("Z", 32)
    coordinate_33 = String.duplicate("A", 33)
    context = worst_case_series_context(coordinate_32, coordinate_33)

    stub(IndexerMock, :search_tv, fn _tvdb_id, _title, season ->
      Agent.update(counter, &(&1 + 1))
      send(self(), {:bounded_tv_season, season})
      {:ok, []}
    end)

    stub(IndexerMock, :search_tv_query, fn query, categories: [5070] ->
      Agent.update(counter, &(&1 + 1))
      send(self(), {:bounded_tv_query, query})
      {:ok, []}
    end)

    assert {:ok, [], false} =
             Anime.search_episodes(IndexerMock, context, Enum.map(1..5, &(&1 * 10)), [])

    assert Agent.get(counter, & &1) == 24
    assert receive_queries(:bounded_tv_season, 4) == [1, 2, 3, 4]
    refute_received {:bounded_tv_season, 5}
    expected_32 = "Show #{coordinate_32}"
    expected_33 = "Show #{coordinate_33}"
    assert_received {:bounded_tv_query, ^expected_32}
    refute_received {:bounded_tv_query, ^expected_33}
  end

  test "a persisted scene coordinate adds an id-scoped alt-season query alongside the TMDB season" do
    episodes = for n <- 1..38, do: %{id: n, season_number: 1, episode_number: n}

    scene_mappings =
      for n <- 29..38 do
        episode_number = n - 28
        code = Episode.code(2, episode_number)
        mapping("scene", code, [n])
      end

    context = %{
      kind: :series,
      title: "Frieren",
      year: 2023,
      tvdb_id: 209_867,
      aliases: [],
      episodes: episodes,
      mappings: scene_mappings
    }

    expect(IndexerMock, :search_tv, 2, fn 209_867, "Frieren", season ->
      send(self(), {:search_tv_season, season})
      {:ok, []}
    end)

    expect(IndexerMock, :search_tv_query, 2, fn _query, categories: [5070] -> {:ok, []} end)

    assert {:ok, [], false} =
             Anime.search_episodes(IndexerMock, context, Enum.to_list(29..38), [])

    assert Enum.sort(receive_queries(:search_tv_season, 2)) == [1, 2]
  end

  defp movie_context(aliases) do
    %{
      kind: :movie,
      title: "Your Name",
      year: 2016,
      aliases: aliases,
      localized_titles: [],
      profile: %{effective: :anime}
    }
  end

  defp series_context(tvdb_id) do
    %{
      kind: :series,
      title: "Show",
      year: 2020,
      tvdb_id: tvdb_id,
      aliases: [],
      episodes: [%{id: 11, season_number: 1, episode_number: 1}],
      mappings: [mapping("standard", "S01E01", [11])]
    }
  end

  defp worst_case_series_context(coordinate_32, coordinate_33) do
    episodes =
      Enum.map(1..5, fn season ->
        %{id: season * 10, season_number: season, episode_number: 1}
      end)

    aliases = Enum.map(1..10, &alias_map("Alias #{&1}", :alternative, :inferred))

    mappings =
      Enum.flat_map(1..5, fn season ->
        id = season * 10

        [
          mapping("standard", Episode.code(season, 1), [id]),
          mapping("absolute", Integer.to_string(season), [id]),
          mapping("scene", if(season == 1, do: coordinate_32, else: "scene-#{season}"), [id])
        ]
      end) ++ [mapping("scene", coordinate_33, [10])]

    %{
      kind: :series,
      title: "Show",
      year: 2020,
      tvdb_id: 99,
      aliases: aliases,
      episodes: episodes,
      mappings: mappings
    }
  end

  defp alias_map(title, kind, precedence \\ :manual) do
    %{
      title: title,
      kind: kind,
      precedence: precedence,
      normalized_title: title |> String.normalize(:nfkc) |> String.downcase()
    }
  end

  defp mapping(scheme, value, episode_ids) do
    %{
      identity: %{
        source: "fixture",
        scheme: scheme,
        namespace: "fixture",
        canonical_value: value
      },
      precedence: :manual,
      episode_ids: episode_ids,
      evidence: %{"kind" => "fixture"}
    }
  end

  defp raw(title, download_url) do
    %{
      title: title,
      size: 2_000_000_000,
      download_url: download_url,
      download_url_origin: nil,
      protocol: :torrent,
      category_ids: [],
      indexer_id: nil,
      published_at: nil
    }
  end

  defp receive_queries(tag, count) do
    Enum.map(1..count, fn _index ->
      assert_receive {^tag, query}
      query
    end)
  end
end
