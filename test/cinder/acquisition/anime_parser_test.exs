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

  test "treats a descending same-season tail as unparseable and keeps only the leading episode" do
    context = %{kind: :series, titles: ["Show"], year: 2020}

    assert %{coordinates: [%{scheme: "standard", values: ["S01E12"]}], role: :story} =
             AnimeParser.parse("[Group] Show S01E12-E01 [1080p]", context)
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

  test "treats a descending wave-dash same-season tail like a descending hyphen tail" do
    context = %{kind: :series, titles: ["Show"], year: 2020}

    assert %{coordinates: [%{scheme: "standard", values: ["S01E12"]}], role: :story} =
             AnimeParser.parse("[Group] Show S01E12~E01 [1080p]", context)
  end

  test "does not read a wave-dash-glued resolution token as a same-season episode tail" do
    context = %{kind: :series, titles: ["Show"], year: 2020}

    assert %{coordinates: [%{scheme: "standard", values: ["S01E01"]}], role: :story} =
             AnimeParser.parse("[Group] Show S01E01~1080p", context)
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
