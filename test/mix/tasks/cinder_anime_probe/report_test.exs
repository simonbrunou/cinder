defmodule Mix.Tasks.Cinder.Anime.Probe.ReportTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Cinder.Anime.Probe.{Corpus, Report}

  @corpus_path "test/support/fixtures/anime/corpus-v1.json"
  @forbidden [
    "downloadUrl",
    "magnetUrl",
    "api_key",
    "token-secret",
    "\"indexerId\"",
    "\"indexer\":",
    "indexer-secret"
  ]

  setup do
    corpus = Corpus.load!(@corpus_path)
    %{corpus: corpus, observations: observations(corpus)}
  end

  test "reports sufficient TMDB coverage and a passing A0 gate", context do
    report = Report.build(context.corpus, context.observations)

    assert report.decision == "tmdb_sufficient"
    assert report.a0_status == "pass"

    assert report.summary == %{
             titles: 7,
             passed: 7,
             failed: 0,
             automatic_wrong_mappings: 0
           }

    assert report.behavior_contracts == %{
             recorded: 24,
             by_phase: %{"A1" => 4, "A2" => 15, "A3" => 5},
             status: "recorded_for_future_phases"
           }

    markdown = Report.markdown(report)
    assert markdown =~ "Decision: `tmdb_sufficient`"
    assert markdown =~ "A0 status: `pass`"
    assert markdown =~ "Future behavior contracts: 24 recorded"
  end

  test "keeps the corpus version in JSON and official references in Markdown only", context do
    report = Report.build(context.corpus, context.observations)
    json = Jason.encode!(report)
    markdown = Report.markdown(report)

    assert %{"version" => 1} = Jason.decode!(json)
    refute json =~ "http://"
    refute json =~ "https://"

    assert markdown =~ "https://developer.themoviedb.org/reference/intro/getting-started"
    assert markdown =~ "https://github.com/thetvdb/v4-api"
    assert markdown =~ "https://wiki.anidb.net/HTTP_API_Definition"
    assert markdown =~ "https://github.com/Prowlarr/Prowlarr"
  end

  test "selects AniDB when only discovery coverage fails", context do
    observations = fail_discovery(context.observations)

    assert %{decision: "anidb_required", a0_status: "blocked"} =
             Report.build(context.corpus, observations)
  end

  test "selects TVDB when only episode-order coverage fails", context do
    observations = fail_absolute_entries(context.observations)

    assert %{decision: "tvdb_required", a0_status: "blocked"} =
             Report.build(context.corpus, observations)
  end

  test "requires a provider council when discovery and episode-order coverage fail", context do
    observations = context.observations |> fail_discovery() |> fail_absolute_entries()

    assert %{decision: "provider_council_required", a0_status: "blocked"} =
             Report.build(context.corpus, observations)
  end

  test "blocks A0 for incomplete Prowlarr fields without changing provider selection", context do
    observations =
      update_first_release(context.observations, fn release ->
        %{release | published_at: nil}
      end)

    report = Report.build(context.corpus, observations)

    assert report.decision == "tmdb_sufficient"
    assert report.a0_status == "blocked"
    assert "prowlarr-published-at" in report.blocking_prowlarr_gaps
  end

  test "requires an anime-mode release that actually carries category 5070", context do
    without_anime_category =
      set_anime_categories(context.observations, [%{id: 5000, name: "TV"}])

    blocked = Report.build(context.corpus, without_anime_category)

    blocked_check =
      Enum.find(blocked.prowlarr_checks, &(&1.id == "prowlarr-anime-category-sample"))

    assert blocked.decision == "tmdb_sufficient"
    assert blocked.a0_status == "blocked"
    assert "prowlarr-anime-category-sample" in blocked.blocking_prowlarr_gaps

    assert blocked_check == %{
             id: "prowlarr-anime-category-sample",
             family: :prowlarr_contract,
             status: "fail",
             evidence: %{observed: 0}
           }

    with_anime_category =
      set_anime_categories(without_anime_category, [%{id: 5070, name: "TV/Anime"}])

    passed = Report.build(context.corpus, with_anime_category)
    passed_check = Enum.find(passed.prowlarr_checks, &(&1.id == "prowlarr-anime-category-sample"))
    qualifying = Enum.count(passed.releases, &(&1.mode == "anime"))

    assert passed.decision == "tmdb_sufficient"
    assert passed.a0_status == "pass"
    assert passed_check.status == "pass"
    assert passed_check.evidence == %{observed: qualifying}
  end

  test "blocks A0 when sampled releases lack indexer identity without changing provider selection",
       context do
    observations =
      update_first_release(context.observations, fn release ->
        %{release | has_indexer_identity: false}
      end)

    report = Report.build(context.corpus, observations)

    assert report.decision == "tmdb_sufficient"
    assert report.a0_status == "blocked"
    assert "prowlarr-indexer-identity" in report.blocking_prowlarr_gaps
  end

  test "treats wrong-type indexer identity evidence as unavailable", context do
    observations =
      update_first_release(context.observations, fn release ->
        %{release | has_indexer_identity: %{"indexer" => "forbidden"}}
      end)

    report = Report.build(context.corpus, observations)

    assert report.decision == "tmdb_sufficient"
    assert report.a0_status == "blocked"
    assert "prowlarr-indexer-identity" in report.blocking_prowlarr_gaps
    refute Jason.encode!(report) =~ "forbidden"
  end

  test "deduplicates repeated integrity errors and renders deterministically", context do
    bad_entries = [
      %{episode_id: nil, group_order: 0, order: 0, season_number: 1, episode_number: 1},
      %{episode_id: nil, group_order: 0, order: 0, season_number: 1, episode_number: 1},
      %{episode_id: 1, group_order: 1, order: 1, season_number: 1, episode_number: 2},
      %{episode_id: 2, group_order: 1, order: 1, season_number: 1, episode_number: 3},
      %{episode_id: 2, group_order: 1, order: 1, season_number: 1, episode_number: 3}
    ]

    observations =
      context.observations
      |> update_in([Access.at(0), :groups, Access.at(0), :entries], fn _ -> bad_entries end)
      |> update_in([Access.at(0), :groups], fn [group] -> [group, group] end)

    report = Report.build(context.corpus, observations)

    assert report.summary.automatic_wrong_mappings == 2
    assert report.decision == "tvdb_required"
    assert report.a0_status == "blocked"

    reversed = Report.build(context.corpus, Enum.reverse(observations))
    assert Jason.encode!(report) == Jason.encode!(reversed)
    assert Report.markdown(report) == Report.markdown(reversed)
  end

  test "detects coordinate conflicts split across observations of one episode group", context do
    observations =
      update_in(context.observations, [Access.at(0), :groups], fn [group] ->
        conflicting_entry = %{hd(group.entries) | episode_id: 99_999}
        [group, %{group | entries: [conflicting_entry]}]
      end)

    report = Report.build(context.corpus, observations)

    assert report.summary.automatic_wrong_mappings == 1
    assert report.decision == "tvdb_required"
    assert report.a0_status == "blocked"
  end

  test "counts missing or invalid group coordinates and episode IDs as wrong mappings", context do
    invalid_entries = [
      %{episode_id: 1, group_order: nil, order: 0, season_number: 1, episode_number: 1},
      %{
        episode_id: 2,
        group_order: 0,
        order: %{"token" => "forbidden"},
        season_number: 1,
        episode_number: 2
      },
      %{episode_id: 3, group_order: 0, order: 2, season_number: nil, episode_number: 3},
      %{episode_id: 4, group_order: 0, order: 3, season_number: 1},
      %{group_order: 0, order: 4, season_number: 1, episode_number: 5}
    ]

    observations =
      put_in(
        context.observations,
        [Access.at(0), :groups, Access.at(0), :entries],
        invalid_entries
      )

    report = Report.build(context.corpus, observations)

    assert report.summary.automatic_wrong_mappings == 5
    assert report.decision == "tvdb_required"
    assert report.a0_status == "blocked"
    refute Jason.encode!(report) =~ "forbidden"
  end

  test "generated artifacts contain no forbidden provider fields", context do
    observations =
      update_first_release(context.observations, fn release ->
        Map.merge(release, %{
          downloadUrl: "downloadUrl-secret",
          magnetUrl: "magnetUrl-secret",
          api_key: "api_key-secret",
          token: "token-secret",
          indexerId: 99,
          indexer: "indexer-secret"
        })
      end)

    report = Report.build(context.corpus, observations)
    artifacts = [Jason.encode!(report), Report.markdown(report)]

    for artifact <- artifacts, forbidden <- @forbidden do
      refute artifact =~ forbidden
    end
  end

  test "sorts sampled releases independently of provider order", context do
    observations =
      update_in(context.observations, [Access.at(0), :prowlarr, Access.at(0), :results], fn [
                                                                                              release
                                                                                            ] ->
        [release, %{release | published_at: "2026-06-01T12:00:00Z"}]
      end)

    reversed =
      update_in(observations, [Access.at(0), :prowlarr, Access.at(0), :results], &Enum.reverse/1)

    assert Jason.encode!(Report.build(context.corpus, observations)) ==
             Jason.encode!(Report.build(context.corpus, reversed))
  end

  defp observations(corpus), do: Enum.map(corpus.titles, &observation/1)

  defp observation(title) do
    %{
      slug: title.slug,
      kind: title.kind,
      tmdb_id: title.tmdb_id,
      searches:
        Enum.map(title.discovery_queries, fn query ->
          %{query: query, results: [%{id: title.tmdb_id, title: title.slug}]}
        end),
      alternatives: [],
      details: %{
        id: title.tmdb_id,
        title: title.slug,
        seasons: if(title.expect.require_specials, do: [%{season_number: 0}], else: [])
      },
      groups: groups(title),
      prowlarr:
        for query <- title.prowlarr_queries, mode <- [:all, :anime] do
          %{query: query, mode: mode, results: [release(title.slug, query, mode)]}
        end
    }
  end

  defp groups(%{kind: :movie}), do: []

  defp groups(title) do
    Enum.map(title.expect.required_group_types, fn type ->
      count = if type == 2, do: title.expect.min_absolute_entries, else: 1

      %{
        id: "#{title.slug}-#{type}",
        type: type,
        name: "Group #{type}",
        entries:
          for episode_id <- entries(count) do
            %{
              episode_id: episode_id,
              group_order: 0,
              order: episode_id,
              season_number: 1,
              episode_number: episode_id
            }
          end
      }
    end)
  end

  defp entries(0), do: []
  defp entries(count), do: 1..count

  defp release(slug, query, mode) do
    %{
      title: "[Group] #{slug} #{query} #{mode}",
      size: 1_000_000,
      protocol: "torrent",
      categories: [%{id: 5070, name: "TV/Anime"}],
      published_at: "2026-07-01T12:00:00Z",
      has_indexer_identity: true
    }
  end

  defp fail_discovery(observations) do
    update_in(observations, [Access.at(0), :searches, Access.at(0), :results], fn _ -> [] end)
  end

  defp fail_absolute_entries(observations) do
    update_in(observations, [Access.at(0), :groups, Access.at(0), :entries], fn _ -> [] end)
  end

  defp update_first_release(observations, function) do
    update_in(
      observations,
      [Access.at(0), :prowlarr, Access.at(0), :results, Access.at(0)],
      function
    )
  end

  defp set_anime_categories(observations, categories) do
    Enum.map(observations, fn observation ->
      Map.update!(
        observation,
        :prowlarr,
        &Enum.map(&1, fn search -> set_search_categories(search, categories) end)
      )
    end)
  end

  defp set_search_categories(%{mode: :anime} = search, categories),
    do: %{search | results: Enum.map(search.results, &Map.put(&1, :categories, categories))}

  defp set_search_categories(search, _categories), do: search
end
