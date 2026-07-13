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
