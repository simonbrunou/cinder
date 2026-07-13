defmodule Cinder.Acquisition.AnimeSelectionTest do
  use ExUnit.Case, async: true

  import Mox

  alias Cinder.Acquisition.Anime
  alias Cinder.Acquisition.IndexerMock
  alias Cinder.Acquisition.Release

  @fixture_path "test/support/fixtures/anime/acquisition-v1.json"

  setup :verify_on_exit!

  setup_all do
    fixture = @fixture_path |> File.read!() |> Jason.decode!()
    assert fixture["version"] == 1
    %{cases: fixture["selection_cases"]}
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

  test "overlap components wait as a whole for a delayed covering pack" do
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

    assert {:waiting_for_preferred_group,
            %{episode_ids: episode_ids, retry_at: ~U[2026-07-14 12:00:00Z]}} =
             Anime.select_episodes([preferred, delayed], context, Enum.to_list(1..12),
               preferred_groups: [" trusted "],
               fallback_delay: 86_400,
               now: now
             )

    assert episode_ids == Enum.to_list(1..12)
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

    assert snapshot["version"] == 1
    assert snapshot["reserved_episode_ids"] == [11, 12]
    assert snapshot["selected_resolution"]["episode_ids"] == [11, 12]
    assert Enum.any?(snapshot["mappings"], &(&1["episode_ids"] == [11, 12, 13]))
    assert assignment.release.mapping_snapshot == snapshot
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
      title: "Show",
      year: 2020,
      tvdb_id: 99,
      aliases: [],
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
