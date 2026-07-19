defmodule Cinder.Acquisition.AnimeSearchTest do
  use ExUnit.Case, async: true

  import Mox

  alias Cinder.Acquisition.Anime
  alias Cinder.Acquisition.IndexerMock

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
        code = "S02E#{String.pad_leading(Integer.to_string(episode_number), 2, "0")}"
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
          mapping("standard", "S#{String.pad_leading(Integer.to_string(season), 2, "0")}E01", [id]),
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
