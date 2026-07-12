defmodule Mix.Tasks.Cinder.Anime.Probe.Report do
  @moduledoc false

  @references [
    {"TMDB API", "https://developer.themoviedb.org/reference/intro/getting-started"},
    {"TVDB API", "https://github.com/thetvdb/v4-api"},
    {"AniDB HTTP API", "https://wiki.anidb.net/HTTP_API_Definition"},
    {"Prowlarr", "https://github.com/Prowlarr/Prowlarr"}
  ]

  @spec build(map(), [map()]) :: map()
  def build(corpus, observations) do
    observations = Map.new(observations, &{&1.slug, &1})

    titles =
      corpus.titles
      |> Enum.map(&evaluate_title(&1, Map.get(observations, &1.slug, %{})))
      |> Enum.sort_by(& &1.slug)

    releases = release_inventory(observations)
    prowlarr_checks = prowlarr_checks(releases)
    blocking_prowlarr_gaps = failed_ids(prowlarr_checks)
    metadata_failures = titles |> Enum.flat_map(& &1.checks) |> Enum.filter(&failed?/1)
    wrong_mappings = Enum.sum(Enum.map(titles, & &1.automatic_wrong_mappings))
    passed = Enum.count(titles, & &1.passed)
    inventory = behavior_inventory(corpus.behavior_contracts)
    behavior_summary = behavior_summary(inventory)
    decision = decision(metadata_failures)

    a0_status =
      if behavior_summary.recorded == 24 and passed == length(titles) and wrong_mappings == 0 and
           blocking_prowlarr_gaps == [],
         do: "pass",
         else: "blocked"

    %{
      corpus_version: corpus.version,
      references: Enum.map(@references, fn {name, url} -> %{name: name, url: url} end),
      titles: titles,
      prowlarr_checks: prowlarr_checks,
      blocking_prowlarr_gaps: blocking_prowlarr_gaps,
      releases: releases,
      decision: decision,
      a0_status: a0_status,
      recommended_next_action: recommended_next_action(decision, a0_status),
      summary: %{
        titles: length(titles),
        passed: passed,
        failed: length(titles) - passed,
        automatic_wrong_mappings: wrong_mappings
      },
      behavior_contracts: behavior_summary,
      behavior_contract_inventory: inventory
    }
  end

  @spec markdown(map()) :: String.t()
  def markdown(report) do
    """
    # Anime provider contract report

    Corpus version: `#{report.corpus_version}`

    ## Official references

    #{reference_markdown(report.references)}

    ## Must-support title checks

    | Title | Check | Family | Status | Evidence |
    | --- | --- | --- | --- | --- |
    #{title_check_markdown(report.titles)}

    ## Prowlarr field coverage

    | Check | Status | Evidence |
    | --- | --- | --- |
    #{prowlarr_markdown(report.prowlarr_checks)}

    ## Sanitized release-title appendix

    | Title | Query | Mode | Release | Size | Protocol | Categories | Published at |
    | --- | --- | --- | --- | ---: | --- | --- | --- |
    #{release_markdown(report.releases)}

    ## Provider decision

    Decision: `#{report.decision}`

    A0 status: `#{report.a0_status}`

    Recommended next action: #{report.recommended_next_action}

    ## Future behavior contracts: #{report.behavior_contracts.recorded} recorded

    Status: `#{report.behavior_contracts.status}`

    | ID | Phase | Kind |
    | --- | --- | --- |
    #{behavior_markdown(report.behavior_contract_inventory)}
    """
  end

  defp evaluate_title(title, observation) do
    groups = Map.get(observation, :groups, [])
    wrong_mappings = wrong_mapping_count(groups)

    checks =
      discovery_checks(title, observation) ++
        [discovery_hits_check(title, observation), specials_check(title, observation)] ++
        group_type_checks(title, groups) ++
        [
          absolute_entries_check(title, groups),
          check("group-integrity", :episode_order, wrong_mappings == 0, %{
            automatic_wrong_mappings: wrong_mappings
          })
        ] ++ prowlarr_inventory_checks(title, observation)

    checks = Enum.sort_by(checks, & &1.id)

    %{
      slug: title.slug,
      tmdb_id: title.tmdb_id,
      passed: not Enum.any?(checks, &failed?/1),
      automatic_wrong_mappings: wrong_mappings,
      checks: checks
    }
  end

  defp discovery_checks(title, observation) do
    Enum.map(title.discovery_queries, fn query ->
      ids = search_ids(observation, query)

      check("discovery:#{query}", :discovery, title.tmdb_id in ids, %{
        expected_tmdb_id: title.tmdb_id,
        observed_tmdb_ids: ids
      })
    end)
  end

  defp discovery_hits_check(title, observation) do
    hits = Enum.count(title.discovery_queries, &(title.tmdb_id in search_ids(observation, &1)))

    check("discovery-hits", :discovery, hits >= title.expect.min_discovery_hits, %{
      observed: hits,
      required: title.expect.min_discovery_hits
    })
  end

  defp specials_check(title, observation) do
    observed =
      observation
      |> Map.get(:details, %{})
      |> Map.get(:seasons, [])
      |> Enum.any?(&(&1.season_number == 0))

    check("specials", :episode_order, not title.expect.require_specials or observed, %{
      observed: observed,
      required: title.expect.require_specials
    })
  end

  defp group_type_checks(title, groups) do
    types = groups |> Enum.map(& &1.type) |> Enum.uniq() |> Enum.sort()

    Enum.map(title.expect.required_group_types, fn type ->
      check("group-type:#{type}", :episode_order, type in types, %{
        observed: types,
        required: type
      })
    end)
  end

  defp absolute_entries_check(title, groups) do
    count =
      groups
      |> Enum.filter(&(&1.type == 2))
      |> Enum.flat_map(& &1.entries)
      |> Enum.map(& &1.episode_id)
      |> Enum.filter(&is_integer/1)
      |> Enum.uniq()
      |> length()

    check("absolute-entries", :episode_order, count >= title.expect.min_absolute_entries, %{
      observed: count,
      required: title.expect.min_absolute_entries
    })
  end

  defp wrong_mapping_count(groups) do
    groups
    |> Enum.group_by(& &1.id)
    |> Map.values()
    |> Enum.reduce(0, fn observations, count ->
      entries = observations |> Enum.flat_map(& &1.entries) |> Enum.uniq()
      missing = Enum.count(entries, &(not is_integer(&1.episode_id)))

      conflicts =
        entries
        |> Enum.group_by(&{&1.group_order, &1.order})
        |> Enum.count(fn {_coordinate, entries} ->
          entries
          |> Enum.map(& &1.episode_id)
          |> Enum.filter(&is_integer/1)
          |> Enum.uniq()
          |> length() > 1
        end)

      count + missing + conflicts
    end)
  end

  defp prowlarr_inventory_checks(title, observation) do
    for query <- title.prowlarr_queries, mode <- [:all, :anime] do
      count =
        observation
        |> Map.get(:prowlarr, [])
        |> Enum.filter(&(&1.query == query and &1.mode == mode))
        |> Enum.flat_map(& &1.results)
        |> length()

      %{
        id: "prowlarr-results:#{query}:#{mode}",
        family: :prowlarr_inventory,
        status: "recorded",
        evidence: %{count: count}
      }
    end
  end

  defp search_ids(observation, query) do
    observation
    |> Map.get(:searches, [])
    |> Enum.filter(&(&1.query == query))
    |> Enum.flat_map(& &1.results)
    |> Enum.map(& &1.id)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp release_inventory(observations) do
    observations
    |> Map.values()
    |> Enum.flat_map(fn observation ->
      for search <- Map.get(observation, :prowlarr, []), release <- search.results do
        %{
          slug: observation.slug,
          query: search.query,
          mode: Atom.to_string(search.mode),
          title: release.title,
          size: release.size,
          protocol: release.protocol,
          categories:
            release
            |> Map.get(:categories, [])
            |> Enum.map(&%{id: &1.id, name: &1.name})
            |> Enum.sort_by(&{&1.id, &1.name}),
          published_at: release.published_at
        }
      end
    end)
    |> Enum.sort_by(
      &{&1.slug, &1.query, &1.mode, &1.title, &1.size, &1.protocol, &1.categories,
       &1.published_at}
    )
  end

  defp prowlarr_checks(releases) do
    total = length(releases)
    anime = Enum.count(releases, &(&1.mode == "anime"))
    categorized = Enum.count(releases, &(Map.get(&1, :categories, []) != []))

    published =
      Enum.count(releases, fn release ->
        is_binary(release.published_at) and String.trim(release.published_at) != ""
      end)

    [
      check("prowlarr-sample", :prowlarr_contract, total > 0, %{observed: total}),
      check("prowlarr-anime-category-sample", :prowlarr_contract, anime > 0, %{
        observed: anime
      }),
      check("prowlarr-categories", :prowlarr_contract, categorized == total, %{
        complete: categorized,
        sampled: total
      }),
      check("prowlarr-published-at", :prowlarr_contract, published == total, %{
        complete: published,
        sampled: total
      })
    ]
    |> Enum.sort_by(& &1.id)
  end

  defp check(id, family, passed, evidence) do
    %{id: id, family: family, status: if(passed, do: "pass", else: "fail"), evidence: evidence}
  end

  defp failed?(%{status: "fail"}), do: true
  defp failed?(_check), do: false
  defp failed_ids(checks), do: checks |> Enum.filter(&failed?/1) |> Enum.map(& &1.id)

  defp decision(failures) do
    alias_gap? = Enum.any?(failures, &(&1.family == :discovery))
    order_gap? = Enum.any?(failures, &(&1.family == :episode_order))

    case {alias_gap?, order_gap?} do
      {false, false} -> "tmdb_sufficient"
      {true, false} -> "anidb_required"
      {false, true} -> "tvdb_required"
      {true, true} -> "provider_council_required"
    end
  end

  defp behavior_inventory(contracts) do
    contracts
    |> Enum.map(fn contract ->
      %{
        id: contract.id,
        phase: contract.phase,
        kind: contract.kind,
        input: contract.input,
        expectations: contract.expect
      }
    end)
    |> Enum.sort_by(& &1.id)
  end

  defp behavior_summary(inventory) do
    by_phase = Enum.frequencies_by(inventory, & &1.phase)

    %{
      recorded: length(inventory),
      by_phase: by_phase,
      status: "recorded_for_future_phases"
    }
  end

  defp recommended_next_action("tmdb_sufficient", "pass"),
    do: "Proceed to A1 with TMDB as the metadata provider."

  defp recommended_next_action("tmdb_sufficient", "blocked"),
    do: "Resolve the blocking A0 contract gaps before A1."

  defp recommended_next_action("anidb_required", _status),
    do: "Evaluate AniDB for discovery aliases before A1."

  defp recommended_next_action("tvdb_required", _status),
    do: "Evaluate TVDB for episode ordering before A1."

  defp recommended_next_action("provider_council_required", _status),
    do: "Run a provider council for discovery aliases and episode ordering before A1."

  defp reference_markdown(references) do
    Enum.map_join(references, "\n", &"- [#{&1.name}](#{&1.url})")
  end

  defp title_check_markdown(titles) do
    Enum.map_join(titles, "\n", fn title ->
      Enum.map_join(title.checks, "\n", fn check ->
        "| #{cell(title.slug)} | #{cell(check.id)} | #{check.family} | #{check.status} | #{cell(inspect(check.evidence))} |"
      end)
    end)
  end

  defp prowlarr_markdown(checks) do
    Enum.map_join(checks, "\n", fn check ->
      "| #{cell(check.id)} | #{check.status} | #{cell(inspect(check.evidence))} |"
    end)
  end

  defp release_markdown([]), do: "| - | - | - | No sampled releases | - | - | - | - |"

  defp release_markdown(releases) do
    Enum.map_join(releases, "\n", fn release ->
      categories = Enum.map_join(release.categories, ", ", &"#{&1.id}:#{&1.name}")

      "| #{cell(release.slug)} | #{cell(release.query)} | #{release.mode} | #{cell(release.title)} | #{release.size} | #{cell(release.protocol)} | #{cell(categories)} | #{cell(release.published_at)} |"
    end)
  end

  defp behavior_markdown(inventory) do
    Enum.map_join(inventory, "\n", fn contract ->
      "| #{cell(contract.id)} | #{contract.phase} | #{contract.kind} |"
    end)
  end

  defp cell(nil), do: ""

  defp cell(value) do
    value
    |> to_string()
    |> String.replace("|", "\\|")
    |> String.replace(["\r", "\n"], " ")
  end
end
