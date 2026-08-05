defmodule Cinder.Acquisition.AnimeParserTest do
  use ExUnit.Case, async: true

  alias Cinder.Acquisition.AnimeParser

  @corpus_path "test/support/fixtures/anime/corpus-v1.json"
  @acquisition_path "test/support/fixtures/anime/acquisition-v1.json"

  setup_all do
    corpus = @corpus_path |> File.read!() |> Jason.decode!()
    acquisition = @acquisition_path |> File.read!() |> Jason.decode!()

    contracts =
      corpus["behavior_contracts"]
      |> Enum.filter(&(&1["phase"] == "A2" and &1["kind"] == "release"))

    assert length(contracts) == 15
    assert acquisition["version"] == 1

    %{contracts: contracts, contexts: acquisition["parser_contexts"]}
  end

  test "satisfies every A2 release parser contract", %{contracts: contracts, contexts: contexts} do
    for contract <- contracts do
      context = contexts |> Map.fetch!(contract["id"]) |> atomize_kind()
      result = AnimeParser.parse(contract["input"]["title"], context)

      assert coordinates_for_fixture(result.coordinates) == contract["expect"]["coordinates"],
             contract["id"]

      assert Atom.to_string(result.role) == contract["expect"]["role"], contract["id"]
    end
  end

  test "matches a native title before accepting a bare absolute coordinate" do
    context = %{kind: :series, titles: ["One Piece", "ワンピース"], year: 1999}

    assert %{
             coordinates: [%{scheme: "absolute", values: ["1122"]}],
             role: :story,
             group: "Fansub"
           } = AnimeParser.parse("[Fansub] ワンピース - 1122 [1080p]", context)
  end

  test "expands a scene-scoped arc batch written with an en dash (issue #312)" do
    context = %{
      kind: :series,
      titles: ["Monogatari", "Hanamonogatari"],
      scene_titles: [
        %{
          title: "Hanamonogatari",
          season: 6,
          source: "tmdb",
          namespace: "author-order"
        }
      ],
      year: 2009
    }

    expected = Enum.map(1..5, &"S06E0#{&1}")

    for separator <- ["-", "–", "—", "~", "〜", "～"] do
      assert %{
               coordinates: [
                 %{
                   scheme: "scene",
                   values: ^expected,
                   source: "tmdb",
                   namespace: "author-order"
                 }
               ],
               role: :story
             } = AnimeParser.parse("[DB] Hanamonogatari 01#{separator}05 [1080p]", context)
    end

    assert %{coordinates: [], role: :unknown} =
             AnimeParser.parse("[DB] Hanamonogatari 05-01 [1080p]", context)
  end

  test "a longer canonical title outranks a scoped title prefix" do
    context = %{
      kind: :series,
      titles: ["Foo 2", "Foo"],
      scene_titles: [
        %{title: "Foo", season: 11, source: "tmdb", namespace: "author-order"}
      ],
      year: 2020
    }

    assert %{
             coordinates: [%{scheme: "absolute", values: ["5"]}],
             role: :story
           } = AnimeParser.parse("[DB] Foo 2 - 05 [1080p]", context)

    blocked_context = Map.put(context, :blocked_titles, ["Foo"])

    assert %{
             coordinates: [%{scheme: "absolute", values: ["5"]}],
             role: :story
           } = AnimeParser.parse("[DB] Foo 2 - 05 [1080p]", blocked_context)
  end

  test "scene scope wins an exact title-length tie and no unmatched title is parsed" do
    context = %{
      kind: :series,
      titles: ["Show", "Arc"],
      scene_titles: [
        %{title: "Arc", season: 11, source: "tmdb", namespace: "author-order"}
      ],
      year: 2020
    }

    assert %{
             coordinates: [
               %{
                 scheme: "scene",
                 values: ["S11E05"],
                 source: "tmdb",
                 namespace: "author-order",
                 scope_title: "arc"
               }
             ]
           } = AnimeParser.parse("[DB] Arc - 05 [1080p]", context)

    assert %{coordinates: [], role: :unknown} =
             AnimeParser.parse("[DB] Unrelated - 05 [1080p]", context)

    blocked_context =
      Map.merge(context, %{titles: ["Foo"], blocked_titles: ["Foo"], scene_titles: []})

    assert %{coordinates: [%{scheme: "standard", values: ["S01E02"]}], role: :story} =
             AnimeParser.parse("[DB] Foo S01E02 [1080p]", blocked_context)

    longer_blocked_context = %{blocked_context | blocked_titles: ["Foo Bar"]}

    assert %{coordinates: [], role: :unknown, blocked_coordinate: true} =
             AnimeParser.parse("[DB] Foo Bar S01E02 [1080p]", longer_blocked_context)

    assert %{coordinates: [], role: :unknown} =
             AnimeParser.parse("[DB] Foo - 02 [1080p]", blocked_context)

    assert %{coordinates: [], role: :unknown} =
             AnimeParser.parse("[DB] Foo - The Arc S01E02 [1080p]", blocked_context)
  end

  test "rejects a chained standard range instead of parsing a later subset" do
    context = %{kind: :series, titles: ["Show"], scene_titles: [], year: 2020}

    assert %{coordinates: [%{scheme: "standard", values: ["S01E01", "S01E02"]}]} =
             AnimeParser.parse("[DB] Show S01E01-E02 [DDP5.1] [1080p]", context)

    assert %{coordinates: [%{scheme: "standard", values: ["S01E01", "S01E02"]}]} =
             AnimeParser.parse("[DB] Show S01E01-E02 AAC 2.0 [DDP 5.1] [1080p]", context)

    long_range =
      AnimeParser.parse(
        "Pokemon Horizons The Series S01E112-E123 1080p NF WEB-DL MULTi AAC2.0 H 264-VARYG",
        %{context | titles: ["Pokemon Horizons The Series"], year: 2023}
      )

    assert %{coordinates: [%{scheme: "standard", values: values}]} = long_range
    assert length(values) == 12
    assert hd(values) == "S01E112"
    assert List.last(values) == "S01E123"

    for metadata <- [
          "H.264",
          "H 264",
          "H.265",
          "H 265",
          "AV1",
          "WEB",
          "10-bit",
          "8-bit",
          "24fps",
          "2ch"
        ] do
      assert %{coordinates: [%{scheme: "standard", values: ["S01E01", "S01E02"]}]} =
               AnimeParser.parse("[DB] Show S01E01-E02 #{metadata} [1080p]", context)
    end

    checksums =
      ["ABE12345"] ++ Enum.map([8, 32, 40, 64], &String.pad_trailing("E03", &1, "A"))

    for checksum <- checksums do
      assert %{coordinates: [%{scheme: "standard", values: ["S01E01", "S01E02"]}]} =
               AnimeParser.parse("[DB] Show S01E01-E02 [#{checksum}] [1080p]", context)
    end

    for metadata <- [
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
          "2021.03"
        ] do
      assert %{coordinates: [%{scheme: "standard", values: ["S01E01", "S01E02"]}]} =
               AnimeParser.parse("[DB] Show S01E01-E02 [#{metadata}] [1080p]", context)

      for suffix <- [" E03", " 03", "E03", "S01E03"] do
        assert %{coordinates: [], role: :unknown, invalid_coordinate: true} =
                 AnimeParser.parse(
                   "[DB] Show S01E01-E02 [#{metadata}#{suffix}] [1080p]",
                   context
                 )
      end
    end

    for title <- [
          "[DB] Show S01E01-E02-E03 [1080p]",
          "[DB] Show S01E01-S01E02-S01E03 [1080p]",
          "[DB] Show S01E01-E02--E03 [1080p]",
          "[DB] Show S01E01-S01E02--S01E03 [1080p]",
          "[DB] Show S01E01-E02 E03 [1080p]",
          "[DB] Show S01E01-E02-2020-E03 [1080p]",
          "[DB] Show S01E01-E02-1080p-E03 [1080p]",
          "[DB] Show S01E01-E02-1080p.WEB-E03 [1080p]",
          "[DB] Show S01E01-E02.E03 [1080p]",
          "[DB] Show S01E01-E02+E03 [1080p]",
          "[DB] Show S01E01-E02/E03 [1080p]",
          "[DB] Show S01E01-E02:E03 [1080p]",
          "[DB] Show S01E01-E02,E03 [1080p]",
          "[DB] Show S01E01(E02) [1080p]",
          "[DB] Show S01E01-S1000E01 [1080p]",
          "[DB] Show S01E01-E02 WEB,E03 [1080p]",
          "[DB] Show S01E01-E02 WEB S02E03 [1080p]",
          "[DB] Show S01E01-E02 x264.E03 [1080p]",
          "[DB] Show S01E01-E02 x264E03 [1080p]",
          "[DB] Show S01E01-E02 x264S01E03 [1080p]",
          "[DB] Show S01E01-E02 CRC32E03 [1080p]",
          "[DB] Show S01E01-E02 AV1E03 [1080p]",
          "[DB] Show S01E01-E02 WEBE03 [1080p]",
          "[DB] Show S01E01-E02 1080pE03",
          "[DB] Show S01E01-E02 10bitE03 [1080p]",
          "[DB] Show S01E01-E02 24fpsE03 [1080p]",
          "[DB] Show S01E01-E02 2chE03 [1080p]",
          "[DB] Show S01E01-E02 DDP5.1E03 [1080p]",
          "[DB] Show S01E01-E02 2020E03 [1080p]",
          "[DB] Show S01E01-E02 03v2 [1080p]",
          "[DB] Show S01E01-E02 03话 [1080p]",
          "[DB] Show S01E01-E02 第03集 [1080p]",
          "[DB] Show S01E01-E02·E03 [1080p]",
          "[DB] Show S01E01-E02−E03 [1080p]",
          "[DB] Show S01E01-E02‑E03 [1080p]",
          "xS01E01-E02 meta Show S01E01-E02-E03",
          "xS01E01-E02 meta Show S01E01-E02--E03"
        ] do
      assert %{coordinates: [], role: :unknown} = AnimeParser.parse(title, context)
    end
  end

  test "keeps supported technical tails on absolute and scoped ranges" do
    context = %{
      kind: :series,
      titles: ["Show"],
      scene_titles: [
        %{title: "Arc", season: 11, source: "tmdb", namespace: "author-order"}
      ],
      year: 2020
    }

    for metadata <- ["E1234567", "10-bit", "23.976 fps", "5.1CH"] do
      assert %{coordinates: [%{scheme: "absolute", values: ["1", "2"]}]} =
               AnimeParser.parse("Show 01-02 [#{metadata}]", context)

      assert %{coordinates: [%{scheme: "scene", values: ["S11E01", "S11E02"]}]} =
               AnimeParser.parse("Arc 01-02 [#{metadata}]", context)
    end
  end

  test "does not reinterpret malformed coordinates as a typed special" do
    context = %{kind: :series, titles: ["Show"], scene_titles: [], year: 2020}
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
          {"01-02 WEB 03", uuid}
        ],
        typed_special <- ["OVA 1", "OAD 1", "ONA 1"] do
      assert %{coordinates: [], role: :unknown, invalid_coordinate: true} =
               AnimeParser.parse("Show #{malformed} #{typed_special}#{suffix}", context)
    end

    unknown_title_context = %{context | titles: ["Different Show"]}

    for release <- ["Unknown 01 WEB 02 OVA 1.mkv", "Unknown 01-02 WEB 03 OVA 1.mkv"] do
      assert %{coordinates: [], role: :unknown, invalid_coordinate: true} =
               AnimeParser.parse(release, unknown_title_context)
    end

    assert %{coordinates: [%{scheme: "typed_special", values: ["OVA:1"]}]} =
             AnimeParser.parse("Unknown 86 OVA 1.mkv", unknown_title_context)
  end

  test "rejects residual versioned and CJK absolute coordinates" do
    context = %{kind: :series, titles: ["Show"], scene_titles: [], year: 2020}

    for release <- [
          "Show 01-02 03v2.mkv",
          "Show 01-02 03话.mkv",
          "Show 01-02 第03集.mkv",
          "Show 01 WEB 02v2.mkv",
          "Show 01 WEB 02话.mkv",
          "Show 01 WEB 第02集.mkv"
        ] do
      assert %{coordinates: [], role: :unknown, invalid_coordinate: true} =
               AnimeParser.parse(release, context)
    end
  end

  test "keeps typed specials for numeric titles and release-date metadata" do
    cases = [
      {"11.22.63 OVA 1.mkv", "11.22.63"},
      {"Show [2021.03.05] OVA 1.mkv", "Show"},
      {"3-2-1 Penguins! OVA 1.mkv", "3-2-1 Penguins!"}
    ]

    for {release, title} <- cases do
      context = %{kind: :series, titles: [title], scene_titles: [], year: 2020}

      assert %{coordinates: [%{scheme: "typed_special", values: ["OVA:1"]}]} =
               AnimeParser.parse(release, context)
    end
  end

  test "rejects a zero-width coordinate separator without looping" do
    context = %{kind: :series, titles: ["Show"], scene_titles: [], year: 2020}

    task =
      Task.async(fn ->
        AnimeParser.parse("Show S01E01-E02\u200BE03", context)
      end)

    case Task.yield(task, 200) || Task.shutdown(task, :brutal_kill) do
      {:ok, parsed} -> assert %{coordinates: [], role: :unknown} = parsed
      nil -> flunk("parser did not terminate for a zero-width separator")
    end
  end

  test "keeps exact standard coordinates with numeric title and title-year prefixes" do
    id_context = %{
      kind: :series,
      titles: ["Show"],
      scene_titles: [],
      allow_unscoped_standard: true,
      year: nil
    }

    assert %{coordinates: [%{scheme: "standard", values: ["S01E01"]}]} =
             AnimeParser.parse("86 Eighty-Six S01E01 [1080p]", id_context)

    for release <- [
          "Show 2nd Season S01E01.mkv",
          "Show Part 2 S01E01.mkv",
          "Show 2 S01E01.mkv"
        ] do
      assert %{coordinates: [%{scheme: "standard", values: ["S01E01"]}]} =
               AnimeParser.parse(release, id_context)
    end

    for malformed <- ["Show 01-02 S01E01.mkv", "Show 01 WEB 02 S01E01.mkv"] do
      assert %{coordinates: [], role: :unknown} = AnimeParser.parse(malformed, id_context)
    end

    for malformed <- ["Alternate AV1S01E01 [1080p]", "Alternate WEBS01E01 [1080p]"] do
      assert %{coordinates: [], role: :unknown} = AnimeParser.parse(malformed, id_context)
    end

    known_context = %{id_context | allow_unscoped_standard: false, year: 2020}

    assert %{coordinates: [%{scheme: "standard", values: ["S01E01"]}]} =
             AnimeParser.parse("Show (2020) S01E01 [1080p]", known_context)

    assert %{coordinates: [], role: :unknown} =
             AnimeParser.parse("Show AV1S01E01 [1080p]", known_context)
  end

  test "rejects a chained scoped range instead of importing a truncated prefix" do
    context = %{
      kind: :series,
      titles: ["Show", "Arc"],
      scene_titles: [
        %{title: "Arc", season: 11, source: "tmdb", namespace: "author-order"}
      ],
      year: 2020
    }

    for title <- [
          "[DB] Arc 01-02-03 [1080p]",
          "[DB] Arc 01-02--03 [1080p]",
          "[DB] Arc 01-02--E03 [1080p]",
          "[DB] Arc 01-02 E03 [1080p]",
          "[DB] Arc 01-02-S11E03 [1080p]",
          "[DB] Arc 01-02--S11E03 [1080p]",
          "[DB] Arc 01-02 - - S11E03 [1080p]",
          "[DB] Arc 01-02-2020-03 [1080p]",
          "[DB] Arc 01-02-1080p-03 [1080p]",
          "[DB] Arc 01-02-1080p.WEB-03 [1080p]",
          "[DB] Arc 01-02.03 [1080p]",
          "[DB] Arc 01-02+03 [1080p]",
          "[DB] Arc 01-02/03 [1080p]",
          "[DB] Arc 01-02:03 [1080p]",
          "[DB] Arc 01-02,03 [1080p]",
          "[DB] Arc 01-02 WEB,03 [1080p]",
          "[DB] Arc 01-02 WEB 03 [1080p]",
          "[DB] Arc 01-02·03 [1080p]",
          "[DB] Arc 01-02−03 [1080p]",
          "[DB] Arc 01-02‑03 [1080p]"
        ] do
      assert %{coordinates: [], role: :unknown} = AnimeParser.parse(title, context)
    end
  end

  test "rejects arbitrary punctuation after an absolute range" do
    context = %{kind: :series, titles: ["Show"], scene_titles: [], year: 2020}

    for separator <- [".", "+", "/", ":", ",", "·", "−", "‑"] do
      assert %{coordinates: [], role: :unknown} =
               AnimeParser.parse("[DB] Show 01-02#{separator}03 [1080p]", context)
    end

    assert %{coordinates: [], role: :unknown} =
             AnimeParser.parse("[DB] Show 01-02 WEB,03 [1080p]", context)
  end

  test "keeps a bare arc-title number absolute without an explicit scene scope" do
    context = %{kind: :series, titles: ["Monogatari", "Koyomimonogatari"], year: 2009}

    assert %{coordinates: [%{scheme: "absolute", values: ["5"]}], role: :story} =
             AnimeParser.parse("[DB] Koyomimonogatari - 05 [1080p]", context)
  end

  test "rejects absolute ranges wider than one hundred values" do
    context = %{kind: :series, titles: ["Show"], year: 2020}
    assert %{coordinates: [], role: :unknown} = AnimeParser.parse("Show - 1-101", context)
  end

  test "keeps OAD releases unresolved as typed specials" do
    context = %{kind: :series, titles: ["Show"], year: 2020}

    assert %{coordinates: [%{scheme: "typed_special", values: ["OAD:2"]}], role: :unknown} =
             AnimeParser.parse("[Group] Show OAD 2 [1080p]", context)
  end

  test "expands a same-season E-tail batch shorthand (S01E01-E12) to the full episode range" do
    context = %{kind: :series, titles: ["Show"], year: 2020}

    expected = Enum.map(1..12, &"S01E#{String.pad_leading(Integer.to_string(&1), 2, "0")}")

    assert %{coordinates: [%{scheme: "standard", values: ^expected}], role: :story} =
             AnimeParser.parse("[Group] Show S01E01-E12 [1080p]", context)
  end

  test "expands a same-season dash-only batch shorthand (S01E01-12) to the full episode range" do
    context = %{kind: :series, titles: ["Show"], year: 2020}

    expected = Enum.map(1..12, &"S01E#{String.pad_leading(Integer.to_string(&1), 2, "0")}")

    assert %{coordinates: [%{scheme: "standard", values: ^expected}], role: :story} =
             AnimeParser.parse("[Group] Show S01E01-12 [1080p]", context)
  end

  test "expands a fully qualified ascending same-season range" do
    context = %{kind: :series, titles: ["Show"], year: 2020}

    assert %{
             coordinates: [
               %{scheme: "standard", values: ["S01E01", "S01E02", "S01E03"]}
             ],
             role: :story
           } = AnimeParser.parse("[Group] Show S01E01-S01E03 [1080p]", context)
  end

  test "rejects descending and oversized fully qualified standard ranges" do
    context = %{kind: :series, titles: ["Show"], year: 2020}

    for title <- [
          "[Group] Show S01E12-S01E01 [1080p]",
          "[Group] Show S02E01-S01E01 [1080p]",
          "[Group] Show S01E01-S01E101 [1080p]",
          "[Group] Show S001E0001-S999E9999 [1080p]"
        ] do
      assert %{coordinates: [], role: :unknown} = AnimeParser.parse(title, context)
    end
  end

  test "rejects descending and oversized same-season tails instead of keeping a prefix" do
    context = %{kind: :series, titles: ["Show"], year: 2020}

    for title <- [
          "[Group] Show S01E12-E01 [1080p]",
          "[Group] Show S01E01-E102 [1080p]"
        ] do
      assert %{coordinates: [], role: :unknown} = AnimeParser.parse(title, context)
    end
  end

  test "does not read a glued resolution token as a same-season episode tail" do
    context = %{kind: :series, titles: ["Show"], year: 2020}

    assert %{coordinates: [%{scheme: "standard", values: ["S01E01"]}], role: :story} =
             AnimeParser.parse("[Group] Show S01E01-1080p", context)
  end

  test "parses a wave-dash absolute batch range (总第67~77-style) like its hyphen equivalent" do
    context = %{kind: :series, titles: ["ワンピース"], year: 1999}
    hyphen = AnimeParser.parse("[字幕组] ワンピース - 67-77 [1080p]", context)

    expected = Enum.map(67..77, &Integer.to_string/1)
    assert %{coordinates: [%{scheme: "absolute", values: ^expected}], role: :story} = hyphen

    for separator <- ["~", "〜", "～"] do
      assert AnimeParser.parse("[字幕组] ワンピース - 67#{separator}77 [1080p]", context) ==
               hyphen,
             "separator #{inspect(separator)}"
    end
  end

  test "parses the verbatim F3 Chinese counter forms (总第67~77, 第67~77话) to the range" do
    context = %{kind: :series, titles: ["ワンピース"], year: 1999}
    expected = Enum.map(67..77, &Integer.to_string/1)

    assert %{coordinates: [%{scheme: "absolute", values: ^expected}], role: :story} =
             AnimeParser.parse("[字幕组] ワンピース 总第67~77", context)

    assert %{coordinates: [%{scheme: "absolute", values: ^expected}], role: :story} =
             AnimeParser.parse("[字幕组] ワンピース 第67~77话", context)
  end

  test "parses a plain 总第67 single-episode counter to a scalar absolute coordinate" do
    context = %{kind: :series, titles: ["ワンピース"], year: 1999}

    assert %{coordinates: [%{scheme: "absolute", values: ["67"]}], role: :story} =
             AnimeParser.parse("[字幕组] ワンピース 总第67", context)
  end

  test "treats a descending wave-dash absolute range as unparseable, same as a hyphen" do
    context = %{kind: :series, titles: ["ワンピース"], year: 1999}

    assert %{coordinates: [], role: :unknown} =
             AnimeParser.parse("[字幕组] ワンピース - 77~67 [1080p]", context)
  end

  test "expands a same-season wave-dash batch shorthand like its hyphen equivalent" do
    context = %{kind: :series, titles: ["Show"], year: 2020}
    hyphen = AnimeParser.parse("[Group] Show S01E01-E12 [1080p]", context)

    for separator <- ["~", "〜", "～"] do
      assert AnimeParser.parse("[Group] Show S01E01#{separator}E12 [1080p]", context) == hyphen
      assert AnimeParser.parse("[Group] Show S01E01#{separator}12 [1080p]", context) == hyphen
    end
  end

  test "rejects a descending wave-dash same-season tail" do
    context = %{kind: :series, titles: ["Show"], year: 2020}

    assert %{coordinates: [], role: :unknown} =
             AnimeParser.parse("[Group] Show S01E12~E01 [1080p]", context)
  end

  test "does not read a wave-dash-glued resolution token as a same-season episode tail" do
    context = %{kind: :series, titles: ["Show"], year: 2020}

    assert %{coordinates: [%{scheme: "standard", values: ["S01E01"]}], role: :story} =
             AnimeParser.parse("[Group] Show S01E01~1080p", context)
  end

  test "a deobfuscated SABnzbd .cinder-<uuid> suffix does not change parsed anime coordinates (issue #127)" do
    # PR #124 renames the SABnzbd job (and the deobfuscated video) to
    # "<title>.cinder-<uuid>"; an absolute-numbered release must resolve identically
    # once that suffix is appended.
    context = %{kind: :series, titles: ["One Piece"], year: 1999}
    base = AnimeParser.parse("[Fansub] One Piece - 1122 [1080p]", context)

    suffixed =
      AnimeParser.parse(
        "[Fansub] One Piece - 1122 [1080p].cinder-a1b2c3d4-e5f6-47a8-89b0-c1d2e3f4a5b6",
        context
      )

    suffixed_with_extension =
      AnimeParser.parse(
        "[Fansub] One Piece - 1122 [1080p].cinder-a1b2c3d4-e5f6-47a8-89b0-c1d2e3f4a5b6.mkv",
        context
      )

    assert base == suffixed
    assert base == suffixed_with_extension
  end

  defp atomize_kind(%{"kind" => kind} = context) do
    %{
      kind: if(kind == "movie", do: :movie, else: :series),
      titles: context["titles"],
      year: context["year"]
    }
  end

  defp coordinates_for_fixture(coordinates) do
    Enum.map(coordinates, fn coordinate ->
      %{"scheme" => coordinate.scheme, "values" => coordinate.values}
    end)
  end
end
