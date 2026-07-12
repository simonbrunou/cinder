defmodule Mix.Tasks.Cinder.Anime.Probe.CorpusTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Cinder.Anime.Probe.Corpus

  @corpus "test/support/fixtures/anime/corpus-v1.json"

  test "loads the complete v1 must-support corpus" do
    corpus = Corpus.load!(@corpus)

    assert corpus.version == 1

    assert Enum.map(corpus.titles, & &1.slug) == [
             "one-piece",
             "bleach",
             "attack-on-titan",
             "re-zero",
             "pokemon",
             "demon-slayer",
             "your-name"
           ]

    assert Enum.find(corpus.titles, &(&1.slug == "one-piece")).expect == %{
             min_discovery_hits: 3,
             required_group_types: [2],
             min_absolute_entries: 1_000,
             require_specials: true
           }

    assert length(corpus.behavior_contracts) == 24
    assert Enum.any?(corpus.behavior_contracts, &(&1.id == "absolute-over-999-v2-crc"))
    assert Enum.any?(corpus.behavior_contracts, &(&1.id == "unknown-video-needs-mapping"))

    assert Enum.any?(
             corpus.behavior_contracts,
             &(&1.id == "provider-renumbering-preserves-active-work")
           )
  end

  @tag :tmp_dir
  test "rejects incomplete requirements", %{tmp_dir: tmp} do
    path = Path.join(tmp, "bad.json")
    corpus = @corpus |> File.read!() |> Jason.decode!()
    File.write!(path, Jason.encode!(%{corpus | "titles" => [%{"slug" => "x"}]}))

    assert_raise ArgumentError, ~r/invalid anime corpus/, fn -> Corpus.load!(path) end
  end

  @tag :tmp_dir
  test "rejects duplicate slugs", %{tmp_dir: tmp} do
    corpus = @corpus |> File.read!() |> Jason.decode!()
    title = hd(corpus["titles"])
    path = Path.join(tmp, "duplicate.json")
    File.write!(path, Jason.encode!(%{corpus | "titles" => [title, title]}))

    assert_raise ArgumentError, ~r/duplicate slug/, fn -> Corpus.load!(path) end
  end

  @tag :tmp_dir
  test "rejects a missing behavior contract", %{tmp_dir: tmp} do
    corpus = @corpus |> File.read!() |> Jason.decode!()
    path = Path.join(tmp, "missing-behavior.json")

    File.write!(
      path,
      Jason.encode!(%{corpus | "behavior_contracts" => tl(corpus["behavior_contracts"])})
    )

    assert_raise ArgumentError, ~r/missing/, fn -> Corpus.load!(path) end
  end
end
