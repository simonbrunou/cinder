defmodule Cinder.Acquisition.AnimeSelectionTest do
  use ExUnit.Case, async: true

  import Mox

  alias Cinder.Acquisition
  alias Cinder.Acquisition.{Anime, AnimePreferences}
  alias Cinder.Acquisition.IndexerMock
  alias Cinder.Acquisition.Release
  alias Cinder.Acquisition.Scorer
  alias Cinder.Catalog.TitleAlias
  alias Cinder.Download.Intent

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

  test "generated parser titles use the durable Unicode codepoint bound" do
    combining_title = String.duplicate("a\u0301", 100) <> "a"

    context =
      absolute_context(1..1)
      |> Map.put(:title, combining_title)
      |> Map.put(:aliases, [%{title: "Short Title", kind: :alternative, precedence: :manual}])

    release = Release.new(raw("Short Title - 1 [1080p]", "combining-title"))

    assert String.length(combining_title) == 101
    assert length(String.to_charlist(combining_title)) == 201

    assert {:ok, %{assignments: [assignment]}} =
             Anime.select_episodes([release], context, [1], [])

    assert assignment.mapping_snapshot["parser_context"]["title"] == "Short Title"
    refute combining_title in assignment.mapping_snapshot["parser_context"]["aliases"]
    assert Intent.valid_mapping_snapshot?(assignment.mapping_snapshot, :episode, [1])
  end

  test "an omitted over-limit canonical title blocks numeric parsing through a retained prefix" do
    canonical_title = "Foo 2 " <> String.duplicate("x", 195)

    context =
      absolute_context(1..2)
      |> Map.put(:title, canonical_title)
      |> Map.put(:aliases, [%{title: "Foo", kind: :alternative, precedence: :manual}])

    release = Release.new(raw("#{canonical_title} [1080p]", "over-limit-canonical-prefix"))

    assert length(String.codepoints(canonical_title)) == 201
    assert :no_match = Anime.select_episodes([release], context, [2], [])

    assert [%Release{mapping_snapshot: nil, resolved_episode_ids: nil}] =
             Anime.manual_episode_candidates([release], context, [2], [])
  end

  test "a longer canonical title outranks a blocked retained alias prefix" do
    omitted_extension = "Foo 3 " <> String.duplicate("x", 195)

    context =
      absolute_context(1..1)
      |> Map.put(:title, "Foo 2")
      |> Map.put(:aliases, [
        %{title: "Foo", kind: :alternative, precedence: :manual},
        %{title: omitted_extension, kind: :alternative, precedence: :manual}
      ])

    release = Release.new(raw("Foo 2 - 1 [1080p]", "longer-canonical"))

    assert {:ok, %{assignments: [assignment]}} =
             Anime.select_episodes([release], context, [1], [])

    assert assignment.mapping_snapshot["parser_context"]["title"] == "Foo 2"
    assert assignment.mapping_snapshot["parser_context"]["blocked_titles"] == ["Foo"]
    assert Intent.valid_mapping_snapshot?(assignment.mapping_snapshot, :episode, [1])
  end

  test "manual typed-special resolution declines an empty bounded parser snapshot" do
    context = %{
      kind: :series,
      title: String.duplicate("x", 201),
      year: 2020,
      tvdb_id: 99,
      aliases: [],
      episodes: [episode(11, 0, 2)],
      mappings: [mapping("fixture", "typed_special", "main", "OVA:2", [11])]
    }

    release = Release.new(raw("OVA 2 [1080p]", "typed-special-without-title"))

    assert [%Release{mapping_snapshot: nil, resolved_episode_ids: nil}] =
             Anime.manual_episode_candidates([release], context, [11], [])
  end

  test "automatic and manual standard selection preserve bounded metadata and checksums" do
    context = simple_standard_context()

    metadata =
      [
        "Vol.1",
        "Volume 1",
        "Disc 1",
        "Part 1",
        "Batch 1",
        "2 Audio Tracks",
        "3 Subs",
        "Dual Audio 2 Subs",
        "2021",
        "2021-03-05",
        "2021.03",
        "H 264",
        "H 265"
      ] ++ Enum.map([8, 32, 40, 64], &String.pad_trailing("E03", &1, "A"))

    for metadata <- metadata do
      release = Release.new(raw("Show S01E01 [#{metadata}] [1080p]", metadata))

      assert {:ok, %{assignments: [%{mapping_snapshot: snapshot}]}} =
               Anime.select_episodes([release], context, [11], [])

      assert Intent.valid_mapping_snapshot?(snapshot, :episode, [11])

      assert [%Release{mapping_snapshot: manual_snapshot, resolved_episode_ids: [11]}] =
               Anime.manual_episode_candidates([release], context, [11], [])

      assert Intent.valid_mapping_snapshot?(manual_snapshot, :episode, [11])
    end
  end

  test "automatic and manual selection reject malformed coordinates before typed specials" do
    context = %{
      kind: :series,
      title: "Show",
      year: 2020,
      tvdb_id: 99,
      aliases: [],
      episodes: [episode(11, 0, 1)],
      mappings: [mapping("fixture", "typed_special", "main", "OVA:1", [11])]
    }

    uuid = ".cinder-a1b2c3d4-e5f6-47a8-89b0-c1d2e3f4a5b6.mkv"

    for {malformed, suffix} <- [
          {"S01E01-E02-E03", ".mkv"},
          {"1-2-3", ".mkv"},
          {"01 WEB 02", ".mkv"},
          {"01-02 WEB 03", ".mkv"},
          {"01 WEB 02v2", ".mkv"},
          {"01 WEB 02话", ".mkv"},
          {"01 WEB 第02集", ".mkv"},
          {"01 WEB 02", uuid},
          {"01-02 WEB 03", uuid},
          {"01 WEB 02v2", uuid}
        ] do
      release =
        Release.new(raw("Show #{malformed} OVA 1#{suffix}", "malformed-typed-special"))

      assert :no_match = Anime.select_episodes([release], context, [11], [])

      assert [%Release{mapping_snapshot: nil, resolved_episode_ids: nil}] =
               Anime.manual_episode_candidates([release], context, [11], [])
    end
  end

  test "automatic and manual selection reject residual versioned and CJK coordinates" do
    context = absolute_context(1..3)

    for title <- [
          "Show 01-02 03v2 [1080p].mkv",
          "Show 01-02 03话 [1080p].mkv",
          "Show 01-02 第03集 [1080p].mkv",
          "Show 01 WEB 02v2 [1080p].mkv"
        ] do
      release = Release.new(raw(title, title))

      assert :no_match = Anime.select_episodes([release], context, [1, 2, 3], [])

      assert [%Release{mapping_snapshot: nil, resolved_episode_ids: nil}] =
               Anime.manual_episode_candidates([release], context, [1, 2, 3], [])
    end
  end

  test "manual typed-special selection preserves numeric titles and dates" do
    cases = [
      {"11.22.63 OVA 1 [1080p].mkv", "11.22.63"},
      {"Show [2021.03.05] OVA 1 [1080p].mkv", "Show"},
      {"3-2-1 Penguins! OVA 1 [1080p].mkv", "3-2-1 Penguins!"}
    ]

    for {title, canonical_title} <- cases do
      context = %{
        kind: :series,
        title: canonical_title,
        year: 2020,
        tvdb_id: 99,
        aliases: [],
        episodes: [episode(11, 0, 1)],
        mappings: [mapping("fixture", "typed_special", "main", "OVA:1", [11])]
      }

      release = Release.new(raw(title, title))

      assert [%Release{mapping_snapshot: manual_snapshot, resolved_episode_ids: [11]}] =
               Anime.manual_episode_candidates([release], context, [11], [])

      assert Intent.valid_mapping_snapshot?(manual_snapshot, :episode, [11])
    end
  end

  test "generated scoped titles use the same normalized Unicode codepoint bound" do
    decomposed_scope = String.duplicate("a\u0301", 100) <> "a"
    normalized_scope = TitleAlias.normalize(decomposed_scope)

    context = %{
      kind: :series,
      title: "Show",
      year: 2020,
      tvdb_id: 99,
      aliases: [%{title: normalized_scope, kind: :alternative, precedence: :manual}],
      scene_titles: [
        %{
          title: decomposed_scope,
          season: 11,
          source: "tmdb",
          namespace: "selected-order"
        }
      ],
      episodes: [episode(17, 0, 17)],
      mappings: [
        mapping("tmdb", "scene", "selected-order", "S11E05", [17], :inferred)
        |> Map.put(:scope_title, decomposed_scope)
      ]
    }

    release = Release.new(raw("#{normalized_scope} - 05 [1080p]", "combining-scope"))

    assert length(String.codepoints(decomposed_scope)) == 201
    assert length(String.codepoints(normalized_scope)) == 101

    assert {:ok, %{assignments: [assignment]}} =
             Anime.select_episodes([release], context, [17], [])

    assert [scene_title] = assignment.mapping_snapshot["parser_context"]["scene_titles"]
    assert scene_title["title"] == normalized_scope
    assert [mapping] = assignment.mapping_snapshot["mappings"]
    assert mapping["scope_title"] == normalized_scope
    assert Intent.valid_mapping_snapshot?(assignment.mapping_snapshot, :episode, [17])
  end

  test "automatic selection returns no match when snapshot validation drops every assignment" do
    over_limit_scope = String.duplicate("x", 201)

    context = %{
      kind: :series,
      title: "Show",
      year: 2020,
      tvdb_id: 99,
      aliases: [],
      scene_titles: [],
      episodes: [episode(11, 1, 1), episode(12, 1, 2)],
      mappings: [
        mapping("tmdb", "scene", "selected-order", "S01E01", [11], :manual)
        |> Map.put(:scope_title, over_limit_scope),
        mapping("tmdb", "scene", "selected-order", "S01E02", [12], :manual)
        |> Map.put(:scope_title, over_limit_scope),
        mapping("fixture", "absolute", "main", "1", [11], :inferred)
      ]
    }

    release = Release.new(raw("Show S01E01 [1080p]", "invalid-generated-snapshot"))
    safe = Release.new(raw("Show - 1 [720p]", "valid-lower-ranked-snapshot"))

    assert length(String.codepoints(over_limit_scope)) == 201
    assert :no_match = Anime.select_episodes([release], context, [11], [])

    assert {:ok, %{assignments: [%{release: selected}]}} =
             Anime.select_episodes([safe], context, [11], [])

    assert selected.download_url == "valid-lower-ranked-snapshot"

    assert {:ok, %{assignments: [%{release: selected}]}} =
             Anime.select_episodes([release, safe], context, [11], [])

    assert selected.download_url == "valid-lower-ranked-snapshot"

    assert [%Release{mapping_snapshot: nil, resolved_episode_ids: nil}] =
             Anime.manual_episode_candidates([release], context, [11], [])

    now = ~U[2026-08-05 12:00:00Z]

    unsafe_preferred =
      Release.new(raw("[Trusted] Show S01E01 [1080p]", "unsafe-preferred"))

    safe_delayed =
      Release.new(raw("[Other] Show - 1 [720p]", "safe-delayed", published_at: now))

    unsafe_delayed =
      Release.new(
        raw("[Other] Show S01E01 [1080p]", "unsafe-delayed",
          published_at: DateTime.add(now, -1000, :second)
        )
      )

    unsafe_bridge =
      Release.new(
        raw("[Other] Show S01E01-E02 [1080p]", "unsafe-delayed-bridge",
          published_at: DateTime.add(now, -1000, :second)
        )
      )

    selection_opts = [preferred_groups: ["trusted"], fallback_delay: 3600, now: now]

    assert :no_match = Anime.select_episodes([unsafe_delayed], context, [11], selection_opts)
    assert :no_match = Anime.select_episodes([unsafe_bridge], context, [11, 12], selection_opts)

    assert {:waiting_for_preferred_group, %{episode_ids: [11], retry_at: retry_at}} =
             Anime.select_episodes([safe_delayed], context, [11], selection_opts)

    assert retry_at == DateTime.add(now, 3600, :second)

    assert {:waiting_for_preferred_group, %{episode_ids: [11], retry_at: ^retry_at}} =
             Anime.select_episodes(
               [unsafe_bridge, safe_delayed],
               context,
               [11, 12],
               selection_opts
             )

    assert {:waiting_for_preferred_group, %{episode_ids: [11], retry_at: ^retry_at}} =
             Anime.select_episodes(
               [unsafe_preferred, safe_delayed],
               context,
               [11],
               selection_opts
             )
  end

  test "an ID-scoped result keeps an exact standard coordinate under an alternate title" do
    context = %{
      kind: :series,
      title: "Show",
      year: nil,
      tvdb_id: 99,
      aliases: [],
      episodes: [episode(11, 1, 1)],
      mappings: [mapping("cinder", "standard", "canonical", "S01E01", [11])]
    }

    id_release =
      Release.new(
        raw("86 Eighty-Six S01E01 [1080p]", "id-scoped-alternate", query_origins: [:id_scoped])
      )

    assert {:ok, %{assignments: [assignment]}} =
             Anime.select_episodes([id_release], context, [11], [])

    assert assignment.episode_ids == [11]
    assert assignment.mapping_snapshot["parser_context"]["allow_unscoped_standard"] == true
    assert Intent.valid_mapping_snapshot?(assignment.mapping_snapshot, :episode, [11])

    year_context = %{context | year: 2020}
    year_release = Release.new(raw("Show (2020) S01E01 [1080p]", "title-year"))

    assert {:ok, %{assignments: [%{episode_ids: [11]}]}} =
             Anime.select_episodes([year_release], year_context, [11], [])
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

    assert snapshot["version"] == 3
    assert snapshot["reserved_episode_ids"] == [11, 12]
    assert snapshot["selected_resolution"]["episode_ids"] == [11, 12]
    assert Enum.any?(snapshot["mappings"], &(&1["episode_ids"] == [11, 12, 13]))
    assert assignment.release.mapping_snapshot == snapshot

    combining_over_limit = String.duplicate("a\u0301", 100) <> "a"

    for parser_context <- [
          Map.put(snapshot["parser_context"], "title", combining_over_limit),
          Map.put(snapshot["parser_context"], "aliases", [combining_over_limit]),
          Map.put(snapshot["parser_context"], "aliases", ["Duplicate", " duplicate "]),
          Map.put(snapshot["parser_context"], "blocked_titles", [combining_over_limit]),
          Map.put(snapshot["parser_context"], "allow_unscoped_standard", "yes")
        ] do
      refute Intent.valid_mapping_snapshot?(
               Map.put(snapshot, "parser_context", parser_context),
               :episode,
               [11, 12]
             )
    end

    [first_mapping | other_mappings] = snapshot["mappings"]

    overlong_scope_snapshot =
      Map.put(
        snapshot,
        "mappings",
        [Map.put(first_mapping, "scope_title", combining_over_limit) | other_mappings]
      )

    refute Intent.valid_mapping_snapshot?(overlong_scope_snapshot, :episode, [11, 12])

    long_alias = String.duplicate("é", 201)

    for aliases <- [[long_alias], ["Duplicate", " duplicate "]] do
      legacy = %{
        snapshot
        | "version" => 2,
          "parser_context" => %{"title" => "Show", "aliases" => aliases, "year" => 2020}
      }

      assert Intent.valid_mapping_snapshot?(legacy, :episode, [11, 12])
    end

    metadata_release =
      Release.new(raw("[Group] Show S01E01-E02 H.264 10-bit 24fps 2ch [1080p]", "metadata-pack"))

    assert {:ok, %{assignments: [%{episode_ids: [11, 12]}]}} =
             Anime.select_episodes([metadata_release], context, [11, 12], [])

    for {title, url} <- [
          {"[Group] Show S01E02-S01E01 [1080p]", "descending-standard-pack"},
          {"[Group] Show S01E01-E02-2020-E03 [1080p]", "year-laundered-standard-pack"},
          {"[Group] Show S01E01-E02-1080p-E03 [1080p]", "quality-laundered-standard-pack"},
          {"[Group] Show S01E01-E02 WEB S02E03 [1080p]", "space-laundered-standard-pack"},
          {"[Group] Show S01E01-E02 x264.E03 [1080p]", "dotted-standard-pack"},
          {"[Group] Show S01E01-E02 x264E03 [1080p]", "codec-standard-pack"},
          {"[Group] Show S01E01-E02 x264S01E03 [1080p]", "qualified-codec-standard-pack"},
          {"[Group] Show S01E01-E02 CRC32E03 [1080p]", "crc-standard-pack"},
          {"[Group] Show S01E01-E02 AV1E03 [1080p]", "av1-standard-pack"},
          {"[Group] Show S01E01-E02 WEBE03 [1080p]", "web-standard-pack"},
          {"[Group] Show S01E01-E02 1080pE03", "resolution-standard-pack"},
          {"[Group] Show S01E01-E02 10bitE03 [1080p]", "bit-standard-pack"},
          {"[Group] Show S01E01-E02 24fpsE03 [1080p]", "rate-standard-pack"},
          {"[Group] Show S01E01-E02 2chE03 [1080p]", "channels-standard-pack"}
        ] do
      malformed = Release.new(raw(title, url))
      assert :no_match = Anime.select_episodes([malformed], context, [11, 12], [])

      assert [%{resolved_episode_ids: nil, mapping_snapshot: nil}] =
               Anime.manual_episode_candidates([malformed], context, [11, 12], [])
    end

    for {title, url} <- [
          {"[Group] Show S01E01(E02) [1080p]", "parenthesized-standard-tail"},
          {"[Group] Show S01E01-S1000E01 [1080p]", "over-width-standard-tail"}
        ] do
      malformed = Release.new(raw(title, url))
      assert :no_match = Anime.select_episodes([malformed], context, [11], [])

      assert [%{resolved_episode_ids: nil, mapping_snapshot: nil}] =
               Anime.manual_episode_candidates([malformed], context, [11], [])
    end
  end

  test "a scene-numbered release resolves via a persisted scene coordinate, but not without it" do
    context = %{
      kind: :series,
      title: "Frieren",
      year: 2023,
      tvdb_id: 209_867,
      aliases: [],
      episodes: [episode(29, 1, 29)],
      mappings: [
        mapping("cinder", "standard", "canonical", "S01E29", [29]),
        mapping("tmdb", "scene", "seasons-group", "S02E01", [29], :inferred)
      ]
    }

    release = Release.new(raw("[Group] Frieren S02E01 [1080p]", "scene-release"))

    assert {:ok, %{assignments: [%{episode_ids: [29]}]}} =
             Anime.select_episodes([release], context, [29], [])

    context_without_group = %{context | mappings: Enum.take(context.mappings, 1)}

    assert :no_match = Anime.select_episodes([release], context_without_group, [29], [])
  end

  test "a selected scene-group arc title scopes a bare number to that arc (issue #312)" do
    context = %{
      kind: :series,
      title: "Monogatari",
      year: 2009,
      tvdb_id: 102_261,
      aliases: [
        %{
          title: "Koyomimonogatari",
          kind: :alternative,
          precedence: :manual,
          normalized_title: "koyomimonogatari"
        }
      ],
      scene_titles: [
        %{
          title: "Koyomimonogatari",
          season: 11,
          source: "tmdb",
          namespace: "nisio-isin-order"
        }
      ],
      episodes: [episode(17, 0, 17), episode(99, 0, 99)],
      mappings: [
        mapping("cinder", "standard", "canonical", "S00E17", [17]),
        mapping("tmdb", "scene", "nisio-isin-order", "S11E05", [17], :inferred)
        |> Map.put(:scope_title, "Koyomimonogatari"),
        # A higher-precedence same-value mapping in another namespace must not hijack the title
        # scope. The parsed coordinate names the selected TMDB group exactly.
        mapping("manual", "scene", "other-order", "S11E05", [99], :manual)
      ]
    }

    release = Release.new(raw("[DB] Koyomimonogatari - 05 [1080p]", "issue-312"))

    assert {:ok, %{assignments: [assignment]}} =
             Anime.select_episodes([release], context, [17], [])

    scoped_coordinate = %{
      scheme: "scene",
      values: ["S11E05"],
      source: "tmdb",
      namespace: "nisio-isin-order",
      scope_title: "koyomimonogatari"
    }

    assert assignment.episode_ids == [17]
    assert assignment.release.coordinates == [scoped_coordinate]
    assert assignment.release.resolved_episode_ids == [17]

    assert assignment.mapping_snapshot["parser_context"]["scene_titles"] == [
             %{
               "title" => "koyomimonogatari",
               "season" => 11,
               "source" => "tmdb",
               "namespace" => "nisio-isin-order"
             }
           ]

    assert assignment.mapping_snapshot["release"]["coordinates"] == [
             %{
               "scheme" => "scene",
               "values" => ["S11E05"],
               "source" => "tmdb",
               "namespace" => "nisio-isin-order",
               "scope_title" => "koyomimonogatari"
             }
           ]

    assert assignment.mapping_snapshot["reserved_episode_ids"] == [17]
    assert Intent.valid_mapping_snapshot?(assignment.mapping_snapshot, :episode, [17])

    for tampered <- [
          put_in(
            assignment.mapping_snapshot,
            ["release", "coordinates", Access.at(0), "namespace"],
            "other-order"
          ),
          put_in(
            assignment.mapping_snapshot,
            ["selected_resolution", "values", Access.at(0), "namespace"],
            "other-order"
          ),
          put_in(
            assignment.mapping_snapshot,
            ["release", "coordinates", Access.at(0), "scope_title"],
            "other arc"
          ),
          put_in(
            assignment.mapping_snapshot,
            ["selected_resolution", "values", Access.at(0), "scope_title"],
            "other arc"
          ),
          put_in(
            assignment.mapping_snapshot,
            ["parser_context", "scene_titles", Access.at(0), "namespace"],
            "other-order"
          ),
          put_in(assignment.mapping_snapshot, ["parser_context", "scene_titles"], []),
          update_in(assignment.mapping_snapshot["mappings"], fn mappings ->
            Enum.map(mappings, fn
              %{"scope_title" => _title} = mapping ->
                %{mapping | "scope_title" => "Other Arc"}

              mapping ->
                mapping
            end)
          end)
        ] do
      refute Intent.valid_mapping_snapshot?(tampered, :episode, [17])
    end

    assert assignment.mapping_snapshot["selected_resolution"]["values"] == [
             %{
               "scheme" => "scene",
               "canonical_value" => "S11E05",
               "source" => "tmdb",
               "namespace" => "nisio-isin-order",
               "scope_title" => "koyomimonogatari",
               "episode_ids" => [17],
               "precedence" => "inferred",
               "mapping_identities" => [
                 %{
                   "source" => "tmdb",
                   "scheme" => "scene",
                   "namespace" => "nisio-isin-order",
                   "canonical_value" => "S11E05"
                 }
               ]
             }
           ]

    assert [manual] = Anime.manual_episode_candidates([release], context, [17], [])
    assert manual.coordinates == [scoped_coordinate]
    assert manual.resolved_episode_ids == [17]
    assert manual.mapping_snapshot == assignment.mapping_snapshot

    incomplete_batch =
      Release.new(raw("[DB] Koyomimonogatari - 04-05 [1080p]", "issue-312-gap"))

    assert :no_match = Anime.select_episodes([incomplete_batch], context, [17], [])

    assert [%{resolved_episode_ids: nil, mapping_snapshot: nil}] =
             Anime.manual_episode_candidates([incomplete_batch], context, [17], [])
  end

  test "a scoped range cannot cross into a different subgroup title" do
    context = %{
      kind: :series,
      title: "Show",
      year: 2020,
      tvdb_id: nil,
      aliases: [
        %{title: "Arc A", kind: :alternative, precedence: :manual, normalized_title: "arc a"}
      ],
      scene_titles: [
        %{
          title: "Arc A",
          normalized_title: "arc a",
          season: 11,
          source: "tmdb",
          namespace: "author-order"
        }
      ],
      episodes: [episode(1, 0, 1), episode(2, 0, 2)],
      mappings: [
        mapping("tmdb", "scene", "author-order", "S11E01", [1], :inferred)
        |> Map.put(:scope_title, "Arc A"),
        mapping("tmdb", "scene", "author-order", "S11E02", [2], :inferred)
        |> Map.put(:scope_title, "Arc B")
      ],
      anime_preferences: %{mode: :subbed, preferred_languages: [], version_preferences: []}
    }

    release = Release.new(raw("[DB] Arc A 01-02 [1080p]", "cross-scope-range"))

    assert :no_match = Anime.select_episodes([release], context, [1, 2], [])

    assert [%{resolved_episode_ids: nil, mapping_snapshot: nil}] =
             Anime.manual_episode_candidates([release], context, [1, 2], [])

    safe_context =
      update_in(context.mappings, fn mappings ->
        Enum.map(mappings, &Map.put(&1, :scope_title, "Arc A"))
      end)

    for {title, url} <- [
          {"[DB] Arc A 01-02-03 [1080p]", "chained-range"},
          {"[DB] Arc A 01-02--03 [1080p]", "doubled-chained-range"},
          {"[DB] Arc A 01-02-2020-03 [1080p]", "year-laundered-range"},
          {"[DB] Arc A 01-02-1080p-03 [1080p]", "quality-laundered-range"},
          {"[DB] Arc A 01-02.03 [1080p]", "dot-chained-range"},
          {"[DB] Arc A 01-02+03 [1080p]", "plus-chained-range"},
          {"[DB] Arc A 01-02,03 [1080p]", "comma-chained-range"},
          {"[DB] Arc A 01-02 WEB,03 [1080p]", "comma-laundered-range"},
          {"[DB] Arc A 01-02 WEB 03 [1080p]", "space-laundered-range"},
          {"[DB] Arc A 01-02−03 [1080p]", "unicode-minus-chained-range"}
        ] do
      malformed = Release.new(raw(title, url))
      assert :no_match = Anime.select_episodes([malformed], safe_context, [1, 2], [])

      assert [%{resolved_episode_ids: nil, mapping_snapshot: nil}] =
               Anime.manual_episode_candidates([malformed], safe_context, [1, 2], [])
    end

    malicious_context = %{
      safe_context
      | episodes: safe_context.episodes ++ [episode(3, 0, 3)],
        mappings:
          safe_context.mappings ++
            [
              mapping("tmdb", "scene", "author-order", "S11E03", [3], :inferred)
              |> Map.put(:scope_title, "Arc B")
            ]
    }

    malicious =
      Release.new(raw("[DB] Arc A 01-02-S11E03 [1080p]", "cross-scope-tail"))

    assert :no_match = Anime.select_episodes([malicious], malicious_context, [3], [])

    assert [%{resolved_episode_ids: nil, mapping_snapshot: nil}] =
             Anime.manual_episode_candidates([malicious], malicious_context, [3], [])

    assert {:ok, %{assignments: [%{release: selected}]}} =
             Anime.select_episodes([release], safe_context, [1, 2], [])

    assert Intent.valid_mapping_snapshot?(selected.mapping_snapshot, :season_pack, [1, 2])

    tampered =
      update_in(selected.mapping_snapshot["mappings"], fn mappings ->
        Enum.map(mappings, fn mapping ->
          if mapping["identity"]["canonical_value"] == "S11E02" do
            Map.put(mapping, "scope_title", "Arc B")
          else
            mapping
          end
        end)
      end)

    refute Intent.valid_mapping_snapshot?(tampered, :season_pack, [1, 2])
  end

  test "an omitted longer alias blocks a retained scoped prefix at the parser cap" do
    aliases =
      for title <- ["A1", "A2", "A3", "A4", "A5", "A6", "Foo", "Foo 2"] do
        %{
          title: title,
          kind: :alternative,
          precedence: :manual,
          normalized_title: String.downcase(title)
        }
      end

    scene_mappings =
      Enum.map(2..5, fn episode_number ->
        mapping(
          "tmdb",
          "scene",
          "author-order",
          "S11E0#{episode_number}",
          [episode_number],
          :inferred
        )
        |> Map.put(:scope_title, "Foo")
      end)

    context = %{
      kind: :series,
      title: "Show",
      year: 2020,
      tvdb_id: nil,
      aliases: aliases,
      scene_titles: [
        %{
          title: "Foo",
          normalized_title: "foo",
          season: 11,
          source: "tmdb",
          namespace: "author-order"
        }
      ],
      episodes: Enum.map(2..5, &episode(&1, 0, &1)),
      mappings: [mapping("fixture", "absolute", "main", "5", [5]) | scene_mappings],
      anime_preferences: %{mode: :subbed, preferred_languages: [], version_preferences: []}
    }

    unsafe = Release.new(raw("[DB] Foo 2 - 05 [1080p]", "capped-scoped-prefix"))
    assert :no_match = Anime.select_episodes([unsafe], context, [2, 3, 4, 5], [])

    assert [%{resolved_episode_ids: nil, mapping_snapshot: nil}] =
             Anime.manual_episode_candidates([unsafe], context, [2, 3, 4, 5], [])

    safe = Release.new(raw("[DB] Show - 05 [1080p]", "safe-capped-context"))

    assert {:ok, %{assignments: [%{episode_ids: [5], release: selected}]}} =
             Anime.select_episodes([safe], context, [2, 3, 4, 5], [])

    parser_context = selected.mapping_snapshot["parser_context"]
    refute "Foo" in parser_context["aliases"]
    refute Map.has_key?(parser_context, "scene_titles")
    assert parser_context["blocked_titles"] == ["Foo"]
    assert Intent.valid_mapping_snapshot?(selected.mapping_snapshot, :episode, [5])
  end

  test "an over-limit longer alias blocks a retained scoped prefix" do
    long_title = "Foo 2 " <> String.duplicate("x", 195)

    aliases =
      for title <- ["Foo", long_title] do
        %{
          title: title,
          kind: :alternative,
          precedence: :manual,
          normalized_title: String.downcase(title)
        }
      end

    context = %{
      kind: :series,
      title: "Show",
      year: 2020,
      tvdb_id: nil,
      aliases: aliases,
      scene_titles: [
        %{
          title: "Foo",
          normalized_title: "foo",
          season: 11,
          source: "tmdb",
          namespace: "author-order"
        }
      ],
      episodes: [episode(2, 0, 2)],
      mappings: [
        mapping("tmdb", "scene", "author-order", "S11E02", [2], :inferred)
        |> Map.put(:scope_title, "Foo")
      ],
      anime_preferences: %{mode: :subbed, preferred_languages: [], version_preferences: []}
    }

    unsafe = Release.new(raw("[DB] #{long_title} [1080p]", "over-limit-prefix"))
    assert :no_match = Anime.select_episodes([unsafe], context, [2], [])

    assert [%{resolved_episode_ids: nil, mapping_snapshot: nil}] =
             Anime.manual_episode_candidates([unsafe], context, [2], [])
  end

  test "an omitted longer alias blocks the canonical title at the parser cap" do
    aliases =
      for title <- ["A1", "A2", "A3", "A4", "A5", "A6", "A7", "Foo 2"] do
        %{
          title: title,
          kind: :alternative,
          precedence: :manual,
          normalized_title: String.downcase(title)
        }
      end

    context = %{
      kind: :series,
      title: "Foo",
      year: 2020,
      tvdb_id: nil,
      aliases: aliases,
      scene_titles: [],
      episodes: Enum.map(2..5, &episode(&1, 0, &1)),
      mappings:
        Enum.map(2..5, fn episode_number ->
          mapping("fixture", "absolute", "main", Integer.to_string(episode_number), [
            episode_number
          ])
        end) ++ [mapping("cinder", "standard", "canonical", "S01E02", [2])],
      anime_preferences: %{mode: :subbed, preferred_languages: [], version_preferences: []}
    }

    unsafe = Release.new(raw("[DB] Foo 2 - 05 [1080p]", "capped-canonical-prefix"))
    assert :no_match = Anime.select_episodes([unsafe], context, [2, 3, 4, 5], [])

    assert [%{resolved_episode_ids: nil, mapping_snapshot: nil}] =
             Anime.manual_episode_candidates([unsafe], context, [2, 3, 4, 5], [])

    unsafe_standard =
      Release.new(raw("[DB] Foo - The Arc S01E02 [1080p]", "blocked-standard-prefix"))

    assert :no_match = Anime.select_episodes([unsafe_standard], context, [2], [])

    assert [%{resolved_episode_ids: nil, mapping_snapshot: nil}] =
             Anime.manual_episode_candidates([unsafe_standard], context, [2], [])

    safe = Release.new(raw("[DB] A1 - 05 [1080p]", "safe-canonical-blocker-context"))

    assert {:ok, %{assignments: [%{episode_ids: [5], release: selected}]}} =
             Anime.select_episodes([safe], context, [2, 3, 4, 5], [])

    assert selected.mapping_snapshot["version"] == 3
    assert selected.mapping_snapshot["parser_context"]["blocked_titles"] == ["Foo"]
    assert Intent.valid_mapping_snapshot?(selected.mapping_snapshot, :episode, [5])

    # Blockers may name scoped aliases that were deliberately removed from the positive alias set;
    # their safety comes from only suppressing parser paths, while the bounded normalized list is
    # structurally validated below.

    downgraded =
      update_in(selected.mapping_snapshot["parser_context"], &Map.delete(&1, "blocked_titles"))

    refute Intent.valid_mapping_snapshot?(downgraded, :episode, [5])

    over_limit_alias =
      put_in(
        selected.mapping_snapshot,
        ["parser_context", "aliases"],
        ["A " <> String.duplicate("x", 199)]
      )

    refute Intent.valid_mapping_snapshot?(over_limit_alias, :episode, [5])

    over_limit_blocker =
      put_in(
        selected.mapping_snapshot,
        ["parser_context", "blocked_titles"],
        ["B " <> String.duplicate("x", 199)]
      )

    refute Intent.valid_mapping_snapshot?(over_limit_blocker, :episode, [5])

    duplicate_blockers =
      put_in(selected.mapping_snapshot, ["parser_context", "blocked_titles"], ["Foo", " foo "])

    refute Intent.valid_mapping_snapshot?(duplicate_blockers, :episode, [5])

    normalized_duplicate_aliases =
      put_in(selected.mapping_snapshot, ["parser_context", "aliases"], ["A1", " a1 "])

    refute Intent.valid_mapping_snapshot?(normalized_duplicate_aliases, :episode, [5])
  end

  test "a longer canonical title cannot be hijacked by a scoped prefix" do
    scene_mappings =
      Enum.map(2..5, fn episode_number ->
        mapping(
          "tmdb",
          "scene",
          "author-order",
          "S11E0#{episode_number}",
          [episode_number],
          :inferred
        )
        |> Map.put(:scope_title, "Foo")
      end)

    context = %{
      kind: :series,
      title: "Foo 2",
      year: 2020,
      tvdb_id: nil,
      aliases: [
        %{
          title: "Foo",
          kind: :alternative,
          precedence: :manual,
          normalized_title: "foo"
        }
      ],
      scene_titles: [
        %{
          title: "Foo",
          normalized_title: "foo",
          season: 11,
          source: "tmdb",
          namespace: "author-order"
        }
      ],
      episodes: Enum.map(2..5, &episode(&1, 0, &1)),
      mappings: [mapping("fixture", "absolute", "main", "5", [5]) | scene_mappings],
      anime_preferences: %{mode: :subbed, preferred_languages: [], version_preferences: []}
    }

    release = Release.new(raw("[DB] Foo 2 - 05 [1080p]", "scoped-prefix"))

    assert {:ok, %{assignments: [%{episode_ids: [5], release: selected}], waiting: nil}} =
             Anime.select_episodes([release], context, [5], [])

    assert selected.coordinates == [%{scheme: "absolute", values: ["5"]}]
    assert Intent.valid_mapping_snapshot?(selected.mapping_snapshot, :episode, [5])

    assert [%{resolved_episode_ids: [5], mapping_snapshot: manual_snapshot}] =
             Anime.manual_episode_candidates([release], context, [5], [])

    assert manual_snapshot == selected.mapping_snapshot
  end

  test "uses the catalog alias normalization contract for scene subgroup titles" do
    scoped_mapping =
      mapping("tmdb", "scene", "author-order", "S11E05", [17], :inferred)
      |> Map.put(:scope_title, "Foo  Arc")

    context = %{
      kind: :series,
      title: "Show",
      year: 2020,
      tvdb_id: nil,
      aliases: [
        %{
          title: "Foo Arc",
          kind: :alternative,
          precedence: :manual,
          normalized_title: "foo arc"
        }
      ],
      scene_titles: [
        %{
          title: "Foo  Arc",
          normalized_title: "foo arc",
          season: 11,
          source: "tmdb",
          namespace: "author-order"
        }
      ],
      episodes: [episode(17, 0, 17)],
      mappings: [
        mapping("cinder", "standard", "canonical", "S00E17", [17]),
        scoped_mapping
      ],
      anime_preferences: %{mode: :subbed, preferred_languages: [], version_preferences: []}
    }

    release = Release.new(raw("[DB] Foo Arc - 05 [1080p]", "normalized-scene-scope"))

    assert {:ok, %{assignments: [%{episode_ids: [17]}], waiting: nil}} =
             Anime.select_episodes([release], context, [17], [])

    assert [%{resolved_episode_ids: [17], mapping_snapshot: snapshot}] =
             Anime.manual_episode_candidates([release], context, [17], [])

    assert Intent.valid_mapping_snapshot?(snapshot, :episode, [17])
  end

  test "a canonical standard mapping outranks a conflicting persisted scene mapping for the same value" do
    context = %{
      kind: :series,
      title: "Show",
      year: 2020,
      tvdb_id: 99,
      aliases: [],
      episodes: [episode(5, 1, 5), episode(99, 9, 9)],
      mappings: [
        mapping("cinder", "standard", "canonical", "S01E05", [5]),
        mapping("tmdb", "scene", "group", "S01E05", [99], :inferred)
      ]
    }

    release = Release.new(raw("[Group] Show S01E05 [1080p]", "conflict"))

    assert {:ok, %{assignments: [%{episode_ids: [5]}]}} =
             Anime.select_episodes([release], context, [5], [])
  end

  test "an operator-reviewed (:curated) scene coordinate wins over the coincidental native code of a different episode (issue #156)" do
    # Monogatari-shaped: TMDB S04E05 is the real Hanamonogatari episode (id 405); the operator's
    # season offset marks S04E05 as Second-Season episode 5 (a :curated scene coordinate, id 5).
    # A [smol]-style S04E05 release must resolve to the Second-Season episode, not the native one.
    context = %{
      kind: :series,
      title: "Monogatari",
      year: 2013,
      tvdb_id: 99,
      aliases: [],
      episodes: [episode(5, 3, 5), episode(405, 4, 5)],
      mappings: [
        mapping("cinder", "standard", "canonical", "S03E05", [5]),
        mapping("cinder", "standard", "canonical", "S04E05", [405]),
        mapping("offset", "scene", "offset", "S04E05", [5], :curated)
      ]
    }

    release =
      Release.new(raw("[smol] Monogatari Series Second Season S04E05 [1080p]", "issue-156"))

    assert {:ok, %{assignments: [%{episode_ids: [5]}]}} =
             Anime.select_episodes([release], context, [5], [])
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

    assert snapshot["version"] == 3

    assert snapshot["parser_context"] == %{
             "title" => "Frieren: Beyond Journey's End",
             "aliases" => ["Sousou no Frieren", "葬送のフリーレン"],
             "blocked_titles" => [],
             "allow_unscoped_standard" => false,
             "year" => 2023
           }

    assert snapshot["mappings"] == Enum.map(Enum.take(mappings, 4), &snapshot_mapping/1)

    legacy_snapshot =
      snapshot
      |> Map.put("version", 2)
      |> update_in(["parser_context"], &Map.delete(&1, "blocked_titles"))
      |> update_in(["parser_context"], &Map.delete(&1, "allow_unscoped_standard"))

    assert Intent.valid_mapping_snapshot?(legacy_snapshot, :season_pack, [11, 12])

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

  test "snapshot-invalid delayed evidence cannot complete a partial search" do
    now = ~U[2026-08-05 12:00:00Z]
    over_limit_scope = String.duplicate("x", 201)

    context = %{
      kind: :series,
      title: "Show",
      year: 2020,
      tvdb_id: 99,
      aliases: [],
      scene_titles: [],
      episodes: [episode(11, 1, 1)],
      mappings: [
        mapping("tmdb", "scene", "selected-order", "S01E01", [11], :manual)
        |> Map.put(:scope_title, over_limit_scope)
      ]
    }

    invalid_delayed =
      raw("[Other] Show S01E01 [1080p]", "invalid-delayed-search-result", published_at: now)

    expect(IndexerMock, :search_tv, fn 99, "Show", 1 -> {:error, :timeout} end)

    expect(IndexerMock, :search_tv_query, 2, fn _query, categories: [5070] ->
      {:ok, [invalid_delayed]}
    end)

    assert {:error, :incomplete_search} =
             Anime.best_episodes(IndexerMock, context, [11],
               preferred_groups: ["trusted"],
               fallback_delay: 3600,
               now: now
             )
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
    assert assignment.mapping_snapshot["version"] == 3
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

  # Issue #195: an Anime movie TMDB has no IMDb id for used to park before ever reaching its own
  # free-text planner. The id-scoped query is now simply omitted; the title guard still applies.
  test "an Anime movie with no imdb id searches free-text only" do
    context = %{kind: :movie, title: "Suzume", year: 2022, aliases: []}

    expect(IndexerMock, :search_movie_query, fn "Suzume 2022", categories: [5070] ->
      {:ok, [raw("[Group] Suzume 2022 [1080p]", "no-imdb"), raw("[Group] Belle 2021", "other")]}
    end)

    assert {:ok, %Release{download_url: "no-imdb"}} =
             Acquisition.best_anime_movie(nil, context, [])
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
    assert manual.mapping_snapshot["version"] == 3
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
        required_audio_languages: [],
        subtitle_languages: [],
        embedded_subtitle_mode: :allow,
        preferred_groups: [],
        blocked_groups: [],
        group_fallback_delay: 0
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
