defmodule Cinder.Acquisition.AnimeSelectionTest do
  use ExUnit.Case, async: true

  import Mox

  alias Cinder.Acquisition
  alias Cinder.Acquisition.{Anime, AnimePreferences}
  alias Cinder.Acquisition.IndexerMock
  alias Cinder.Acquisition.Release
  alias Cinder.Acquisition.Scorer

  @fixture_path "test/support/fixtures/anime/acquisition-v1.json"
  @preferences_fixture_path "test/support/fixtures/anime/preferences-v1.json"

  setup :verify_on_exit!

  setup_all do
    fixture = @fixture_path |> File.read!() |> Jason.decode!()
    preferences_fixture = @preferences_fixture_path |> File.read!() |> Jason.decode!()
    assert fixture["version"] == 1
    assert preferences_fixture["version"] == 1

    %{
      cases: fixture["selection_cases"],
      preference_cases: preferences_fixture["cases"]
    }
  end

  test "satisfies every versioned stable-ID selection case", %{cases: cases} do
    for selection_case <- cases do
      result =
        Anime.select_episodes(
          Enum.map(selection_case["candidates"], &release_from_fixture/1),
          context_from_fixture(selection_case["context"]),
          selection_case["wanted_episode_ids"],
          opts_from_fixture(selection_case["opts"] || %{})
        )

      assert result_for_fixture(result) == selection_case["expect"], selection_case["id"]
    end
  end

  test "absent or empty preferred groups make missing publication time immediately eligible" do
    context = simple_standard_context()
    release = Release.new(raw("[Group] Show S01E01 [1080p]", "single"))

    assert {:ok, %{assignments: [%{episode_ids: [11]}], waiting: nil}} =
             Anime.select_episodes([release], context, [11], [])

    assert {:ok, %{assignments: [%{episode_ids: [11]}], waiting: nil}} =
             Anime.select_episodes([release], context, [11], preferred_groups: [])
  end

  test "episodic preference keeps a trailing group parsed by the standard release parser" do
    context = absolute_context(1..1)
    release = Release.new(raw("Show - 1 [1080p]-Trusted", "single"))

    assert {:ok, %{assignments: [%{release: selected}], waiting: nil}} =
             Anime.select_episodes([release], context, [1], preferred_groups: ["trusted"])

    assert selected.group == "Trusted"
  end

  test "an eighth alias cannot influence selection beyond the frozen parser context" do
    context = %{
      absolute_context(1..1)
      | aliases: Enum.map(1..8, &%{title: "Alias #{&1}"})
    }

    release = Release.new(raw("Alias 8 - 1 [1080p]", "eighth-alias"))

    assert :no_match = Anime.select_episodes([release], context, [1], [])
  end

  test "overlap components report only IDs not covered by an eligible release" do
    now = ~U[2026-07-13 12:00:00Z]
    context = absolute_context(1..12)

    preferred = Release.new(raw("[Trusted] Show - 1 [1080p]", "preferred"))

    delayed =
      Release.new(
        raw("[Other] Show - 1-12 [1080p]", "pack",
          size: 24_000_000_000,
          published_at: now
        )
      )

    assert {:ok,
            %{
              assignments: [%{episode_ids: [1]}],
              waiting: %{episode_ids: episode_ids, retry_at: ~U[2026-07-14 12:00:00Z]}
            }} =
             Anime.select_episodes([preferred, delayed], context, Enum.to_list(1..12),
               preferred_groups: [" trusted "],
               fallback_delay: 86_400,
               now: now
             )

    assert episode_ids == Enum.to_list(2..12)
  end

  test "selected assignments carry the same full-closure snapshot on both markers" do
    context = %{
      kind: :series,
      title: "Show",
      year: 2020,
      tvdb_id: 99,
      aliases: [],
      episodes: [episode(11, 1, 1), episode(12, 1, 2), episode(13, 1, 3)],
      mappings: [
        mapping("cinder", "standard", "canonical", "S01E01", [11]),
        mapping("cinder", "standard", "canonical", "S01E02", [12]),
        mapping("fixture", "absolute", "combined", "1-3", [11, 12, 13])
      ]
    }

    release = Release.new(raw("[Group] Show S01E01-S01E02 [1080p]", "standard-pack"))

    assert {:ok, %{assignments: [assignment]}} =
             Anime.select_episodes([release], context, [11, 12], [])

    snapshot = assignment.mapping_snapshot

    assert snapshot["version"] == 2
    assert snapshot["reserved_episode_ids"] == [11, 12]
    assert snapshot["selected_resolution"]["episode_ids"] == [11, 12]
    assert Enum.any?(snapshot["mappings"], &(&1["episode_ids"] == [11, 12, 13]))
    assert assignment.release.mapping_snapshot == snapshot
  end

  test "automatic episode selection freezes the exact hard policy used to select" do
    release = Release.new(raw("[SubsPlease] Show - 1 [1080p]", "anime-policy-episode"))

    policy =
      policy(
        required_audio_languages: ["ja", "fr"],
        embedded_subtitle_mode: :require,
        subtitle_languages: ["fr"]
      )

    assert {:ok, %{assignments: [%{release: selected}]}} =
             Anime.select_episodes(
               [release],
               absolute_context(1..1),
               [1],
               AnimePreferences.selection_opts(policy)
             )

    assert selected.release_policy_snapshot == %{
             "version" => 1,
             "required_audio_languages" => ["ja", "fr"],
             "required_embedded_subtitle_languages" => ["fr"],
             "release_group" => "subsplease",
             "release_title" => selected.title
           }
  end

  test "snapshot builder freezes the exact complete Catalog mapping closure" do
    mappings = [
      mapping("cinder", "standard", "canonical", "S01E01", [11, 12]),
      mapping("fixture", "absolute", "main", "12", [12, 13]),
      mapping("fixture", "scene", "scene", "12", [11, 14]),
      mapping("provider", "provider", "group", "p12", [12, 15]),
      mapping("fixture", "absolute", "irrelevant", "99", [99])
    ]

    context = %{
      kind: :series,
      title: "Frieren: Beyond Journey's End",
      year: 2023,
      tvdb_id: 99,
      aliases: [%{title: "Sousou no Frieren"}, %{title: "葬送のフリーレン"}],
      episodes: [],
      mappings: mappings
    }

    selected_identity = hd(mappings).identity

    release = %Release{
      title: "[Group] Show S01E01 [1080p]",
      protocol: :torrent,
      group: "Group",
      coordinates: [%{scheme: "standard", values: ["S01E01"]}],
      resolved_episode_ids: [11, 12],
      resolution_evidence: [
        %{
          scheme: "standard",
          canonical_value: "S01E01",
          episode_ids: [11, 12],
          precedence: :manual,
          mapping_identities: [selected_identity]
        }
      ]
    }

    snapshot = Anime.build_mapping_snapshot(release, [11, 12], context)

    assert snapshot["version"] == 2

    assert snapshot["parser_context"] == %{
             "title" => "Frieren: Beyond Journey's End",
             "aliases" => ["Sousou no Frieren", "葬送のフリーレン"],
             "year" => 2023
           }

    assert snapshot["mappings"] == Enum.map(Enum.take(mappings, 4), &snapshot_mapping/1)

    assert snapshot["selected_resolution"]["values"] == [
             %{
               "scheme" => "standard",
               "canonical_value" => "S01E01",
               "episode_ids" => [11, 12],
               "precedence" => "manual",
               "mapping_identities" => [stringify_identity(selected_identity)]
             }
           ]
  end

  test "a partial query failure cannot turn missing coverage into no-match" do
    context = simple_standard_context()
    expect(IndexerMock, :search_tv, fn 99, "Show", 1 -> {:error, :timeout} end)
    expect(IndexerMock, :search_tv_query, 2, fn _query, categories: [5070] -> {:ok, []} end)

    assert {:error, :incomplete_search} = Anime.best_episodes(IndexerMock, context, [11], [])
  end

  test "blocked groups are removed before stable-ID cover and one release freezes regular plus episode-zero IDs",
       %{preference_cases: cases} do
    context = preference_context()
    blocked = preference_release(cases, "blocked")
    preferred = preference_release(cases, "episode-preferred")
    policy = policy(blocked_groups: ["badgroup"])

    assert {:ok, %{assignments: [assignment], waiting: nil}} =
             Anime.select_episodes(
               [blocked, preferred],
               context,
               [11, 12],
               AnimePreferences.selection_opts(policy)
             )

    assert assignment.release.group == "SubsPlease"
    assert assignment.episode_ids == [11, 12]
    assert assignment.release.resolved_episode_ids == [11, 12]
    assert assignment.mapping_snapshot["version"] == 2
    assert assignment.mapping_snapshot["reserved_episode_ids"] == [11, 12]
  end

  test "Anime movie selection applies the same hard policy without changing Standard scoring", %{
    preference_cases: cases
  } do
    blocked =
      Release.new(%{
        title: "[BadGroup] Suzume 2022 [1080p] [JA Audio] [FR Subs]",
        size: 2_000_000_000,
        download_url: "blocked-movie",
        published_at: ~U[2026-07-13 12:00:00Z]
      })

    preferred = preference_release(cases, "movie-preferred")

    policy =
      policy(
        required_audio_languages: ["ja"],
        embedded_subtitle_mode: :require,
        subtitle_languages: ["fr"],
        blocked_groups: ["badgroup"]
      )

    assert {:ok, %Release{title: "[SubsPlease] Suzume 2022 [1080p] [JA Audio] [FR Subs]"}} =
             Anime.select_movie(
               [blocked, preferred],
               AnimePreferences.selection_opts(policy)
             )
  end

  test "automatic movie selection freezes the exact hard policy used to select" do
    release =
      Release.new(%{
        title: "[SubsPlease] Suzume 2022 [1080p]",
        size: 2_000_000_000,
        download_url: "anime-policy-movie"
      })

    policy =
      policy(
        required_audio_languages: ["ja", "fr"],
        embedded_subtitle_mode: :require,
        subtitle_languages: ["fr"]
      )

    assert {:ok, selected} =
             Anime.select_movie([release], AnimePreferences.selection_opts(policy))

    assert selected.release_policy_snapshot == %{
             "version" => 1,
             "required_audio_languages" => ["ja", "fr"],
             "required_embedded_subtitle_languages" => ["fr"],
             "release_group" => "subsplease",
             "release_title" => selected.title
           }
  end

  test "public Anime movie search uses complete audio claims instead of legacy singular language" do
    context = %{kind: :movie, title: "Suzume", year: 2022, aliases: []}

    expect(IndexerMock, :search, fn "tt4425200" ->
      {:ok,
       [
         raw("[Group] Suzume 2022 [1080p] [FR Audio]", "french-dub",
           published_at: ~U[2026-07-13 12:00:00Z]
         )
       ]}
    end)

    expect(IndexerMock, :search_movie_query, fn "Suzume 2022", categories: [5070] -> {:ok, []} end)

    opts =
      [preferred_language: "french", original_language: "ja"] ++
        AnimePreferences.selection_opts(policy(required_audio_languages: ["fr"]))

    assert {:ok, %Release{audio_languages: ["fr"], audio_claim_complete?: true}} =
             Acquisition.best_anime_movie("tt4425200", context, opts)
  end

  test "a complete contradictory audio claim is rejected while unknown evidence survives", %{
    preference_cases: cases
  } do
    policy = policy(required_audio_languages: ["ja"])

    assert {:ok, %{assignments: [%{release: selected}]}} =
             Anime.select_episodes(
               [
                 preference_release(cases, "dub-only"),
                 preference_release(cases, "unknown-undated")
               ],
               preference_context(),
               [11, 12],
               AnimePreferences.selection_opts(policy)
             )

    assert selected.group == "Mystery"
  end

  test "RAW is contradictory only when embedded subtitles are required", %{
    preference_cases: cases
  } do
    release = preference_release(cases, "raw")
    context = preference_context()

    assert :no_match =
             Anime.select_episodes(
               [release],
               context,
               [11, 12],
               AnimePreferences.selection_opts(
                 policy(embedded_subtitle_mode: :require, subtitle_languages: ["fr"])
               )
             )

    assert {:ok, %{assignments: [_]}} =
             Anime.select_episodes(
               [release],
               context,
               [11, 12],
               AnimePreferences.selection_opts(policy(embedded_subtitle_mode: :allow))
             )
  end

  test "preferred group wins the soft rank after a fallback becomes eligible", %{
    preference_cases: cases
  } do
    policy = policy(preferred_groups: ["subsplease"], group_fallback_delay: 3_600)
    opts = AnimePreferences.selection_opts(policy) ++ [now: ~U[2026-07-13 13:00:00Z]]

    assert {:ok, %{assignments: [%{release: selected}]}} =
             Anime.select_episodes(
               [
                 preference_release(cases, "episode-fallback"),
                 preference_release(cases, "episode-preferred")
               ],
               preference_context(),
               [11, 12],
               opts
             )

    assert selected.group == "SubsPlease"
  end

  test "fallback eligibility starts at the exact published_at plus delay boundary", %{
    preference_cases: cases
  } do
    policy = policy(preferred_groups: ["subsplease"], group_fallback_delay: 3_600)
    release = preference_release(cases, "episode-fallback")

    assert {:waiting_for_preferred_group,
            %{episode_ids: [11, 12], retry_at: ~U[2026-07-13 13:00:00Z]}} =
             Anime.select_episodes(
               [release],
               preference_context(),
               [11, 12],
               AnimePreferences.selection_opts(policy) ++ [now: ~U[2026-07-13 12:59:59Z]]
             )

    assert {:ok, %{assignments: [_], waiting: nil}} =
             Anime.select_episodes(
               [release],
               preference_context(),
               [11, 12],
               AnimePreferences.selection_opts(policy) ++ [now: ~U[2026-07-13 13:00:00Z]]
             )
  end

  test "undated candidates are automatic-omitted but manual-visible with exact stable IDs", %{
    preference_cases: cases
  } do
    release = preference_release(cases, "unknown-undated")
    context = preference_context()
    policy = policy(preferred_groups: ["subsplease"])
    opts = AnimePreferences.selection_opts(policy)

    assert :no_match = Anime.select_episodes([release], context, [11, 12], opts)

    assert [manual] = Anime.manual_episode_candidates([release], context, [11, 12], opts)
    assert manual.resolved_episode_ids == [11, 12]
    assert manual.mapping_snapshot["version"] == 2
    assert manual.mapping_snapshot["reserved_episode_ids"] == [11, 12]

    invalid = %{
      release
      | title: "[Mystery] Frieren - 29 [1080p] invalid-date",
        published_at: "bad"
    }

    assert :no_match = Anime.select_episodes([invalid], context, [11, 12], opts)

    assert [%Release{title: title}] =
             Anime.manual_episode_candidates([invalid], context, [11, 12], opts)

    assert title =~ "invalid-date"
  end

  test "stable-ID coverage dominates Anime rank and Standard order remains resolution then source then size" do
    wanted = [11, 12]
    policy = policy(preferred_groups: ["preferred"])

    covering_two = %Release{
      title: "two",
      group: "other",
      size: 2,
      resolution: "1080p",
      resolved_episode_ids: wanted
    }

    covering_one = %Release{
      title: "one",
      group: "preferred",
      size: 2,
      resolution: "1080p",
      resolved_episode_ids: [11]
    }

    assert {:ok, [{^covering_two, ^wanted}]} =
             Scorer.select_for_ids(
               [covering_one, covering_two],
               wanted,
               anime_policy: policy,
               preferred_resolutions: ["1080p"]
             )

    releases = [
      %Release{title: "larger", resolution: "720p", source: "webdl", size: 3},
      %Release{title: "source", resolution: "1080p", source: "bluray", size: 2},
      %Release{title: "resolution", resolution: "1080p", source: "webdl", size: 1}
    ]

    assert {:ok, %Release{title: "resolution"}} =
             Scorer.select(releases,
               preferred_resolutions: ["1080p", "720p"],
               preferred_sources: ["webdl", "bluray"]
             )

    assert {:ok, %Release{title: "larger"}} =
             Scorer.select(
               [
                 %Release{title: "smaller", resolution: "1080p", source: "webdl", size: 1},
                 %Release{title: "larger", resolution: "1080p", source: "webdl", size: 2}
               ],
               preferred_resolutions: ["1080p"],
               preferred_sources: ["webdl"]
             )
  end

  defp result_for_fixture(:no_match), do: %{"status" => "no_match", "assignments" => []}

  defp result_for_fixture({:ok, %{assignments: assignments}}) do
    %{
      "status" => "ok",
      "assignments" =>
        Enum.map(assignments, fn assignment ->
          %{"title" => assignment.release.title, "episode_ids" => assignment.episode_ids}
        end)
    }
  end

  defp context_from_fixture(context) do
    %{
      kind: :series,
      title: context["title"],
      year: context["year"],
      tvdb_id: context["tvdb_id"],
      aliases: [],
      episodes:
        Enum.map(context["episodes"], fn episode ->
          %{
            id: episode["id"],
            season_number: episode["season_number"],
            episode_number: episode["episode_number"]
          }
        end),
      mappings: Enum.map(context["mappings"], &mapping_from_fixture/1)
    }
  end

  defp mapping_from_fixture(mapping) do
    mapping(
      mapping["source"],
      mapping["scheme"],
      mapping["namespace"],
      mapping["canonical_value"],
      mapping["episode_ids"],
      String.to_existing_atom(mapping["precedence"])
    )
  end

  defp release_from_fixture(candidate) do
    candidate
    |> Map.new(fn {key, value} -> {String.to_existing_atom(key), value} end)
    |> Map.update!(:protocol, &String.to_existing_atom/1)
    |> Release.new()
  end

  defp opts_from_fixture(opts) do
    Enum.map(opts, fn
      {"protocols", protocols} -> {:protocols, Enum.map(protocols, &String.to_existing_atom/1)}
      {key, value} -> {String.to_existing_atom(key), value}
    end)
  end

  defp simple_standard_context do
    %{
      kind: :series,
      title: "Show",
      year: 2020,
      tvdb_id: 99,
      aliases: [],
      episodes: [episode(11, 1, 1)],
      mappings: [mapping("cinder", "standard", "canonical", "S01E01", [11])]
    }
  end

  defp absolute_context(range) do
    ids = Enum.to_list(range)

    %{
      kind: :series,
      title: "Show",
      year: 2020,
      tvdb_id: 99,
      aliases: [],
      episodes: Enum.map(ids, &episode(&1, 1, &1)),
      mappings: Enum.map(ids, &mapping("fixture", "absolute", "main", to_string(&1), [&1]))
    }
  end

  defp episode(id, season, number),
    do: %{id: id, season_number: season, episode_number: number}

  defp mapping(source, scheme, namespace, value, episode_ids, precedence \\ :manual) do
    %{
      identity: %{
        source: source,
        scheme: scheme,
        namespace: namespace,
        canonical_value: value
      },
      precedence: precedence,
      episode_ids: episode_ids,
      evidence: %{"kind" => "fixture"}
    }
  end

  defp raw(title, download_url, attrs \\ []) do
    Map.merge(
      %{
        title: title,
        size: 2_000_000_000,
        download_url: download_url,
        download_url_origin: nil,
        protocol: :torrent,
        category_ids: [],
        indexer_id: nil,
        published_at: nil
      },
      Map.new(attrs)
    )
  end

  defp preference_release(cases, id) do
    fixture_case = Enum.find(cases, &(&1["id"] == id))

    Release.new(%{
      title: fixture_case["title"],
      size: 2_000_000_000,
      download_url: id,
      protocol: :torrent,
      published_at: parse_datetime(fixture_case["published_at"])
    })
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(value) do
    {:ok, datetime, 0} = DateTime.from_iso8601(value)
    datetime
  end

  defp preference_context do
    %{
      kind: :series,
      title: "Frieren",
      year: 2023,
      tvdb_id: 99,
      aliases: [],
      episodes: [episode(11, 1, 29), episode(12, 0, 0)],
      mappings: [mapping("fixture", "absolute", "main", "29", [11, 12])]
    }
  end

  defp policy(overrides) do
    Map.merge(
      %{
        audio_mode: :any,
        required_audio_languages: [],
        subtitle_languages: [],
        embedded_subtitle_mode: :allow,
        preferred_groups: [],
        blocked_groups: [],
        group_fallback_delay: 0,
        provenance: %{}
      },
      Map.new(overrides)
    )
  end

  defp snapshot_mapping(mapping) do
    %{
      "identity" => stringify_identity(mapping.identity),
      "precedence" => Atom.to_string(mapping.precedence),
      "episode_ids" => mapping.episode_ids,
      "evidence" => mapping.evidence
    }
  end

  defp stringify_identity(identity) do
    %{
      "source" => identity.source,
      "scheme" => identity.scheme,
      "namespace" => identity.namespace,
      "canonical_value" => identity.canonical_value
    }
  end
end
