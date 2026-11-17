defmodule Cinder.Catalog.AnimeResolverTest do
  use ExUnit.Case, async: true

  alias Cinder.Catalog.AnimeResolver

  test "manual mapping suppresses lower-precedence ambiguity" do
    mappings = [
      %{
        coordinate: "absolute:12",
        episode_ids: [1],
        precedence: :manual,
        evidence: :local
      },
      %{
        coordinate: "scene:12",
        episode_ids: [2],
        precedence: :inferred,
        evidence: :provider
      }
    ]

    assert {:ok, [1],
            %{
              precedence: :manual,
              matches: [
                %{coordinate: "absolute:12", episode_ids: [1], evidence: :local}
              ]
            }} = AnimeResolver.resolve(["absolute:12", "scene:12"], mappings)
  end

  test "curated mapping suppresses inferred ambiguity" do
    mappings = [
      %{coordinate: "absolute:12", episode_ids: [1], precedence: :inferred},
      %{coordinate: "scene:12", episode_ids: [2], precedence: :curated}
    ]

    assert {:ok, [2], %{precedence: :curated}} =
             AnimeResolver.resolve(["absolute:12", "scene:12"], mappings)
  end

  test "grab overrides take manual precedence" do
    mappings = [
      %{coordinate: "absolute:12", episode_ids: [1], precedence: :curated}
    ]

    overrides = [
      %{
        coordinate: "absolute:12",
        episode_ids: [2],
        precedence: :manual,
        evidence: :grab_override
      }
    ]

    assert {:ok, [2], %{precedence: :manual}} =
             AnimeResolver.resolve(["absolute:12"], mappings, overrides: overrides)
  end

  test "same-precedence conflicting ordered candidates are ambiguous" do
    mappings = [
      %{coordinate: "absolute:12", episode_ids: [2, 1], precedence: :inferred},
      %{coordinate: "scene:12", episode_ids: [1, 2], precedence: :inferred}
    ]

    assert {:ambiguous, [[1, 2], [2, 1]], %{precedence: :inferred, matches: matches}} =
             AnimeResolver.resolve(["scene:12", "absolute:12"], mappings)

    assert Enum.all?(matches, &(is_map(&1) and not is_struct(&1)))
  end

  test "identical ordered candidates resolve once and retain all matching evidence" do
    mappings = [
      %{
        coordinate: "absolute:12",
        episode_ids: [1, 2],
        precedence: :inferred,
        evidence: :absolute
      },
      %{
        coordinate: "standard:S01E12",
        episode_ids: [1, 2],
        precedence: :inferred,
        evidence: :standard
      }
    ]

    assert {:ok, [1, 2], %{matches: matches}} =
             AnimeResolver.resolve(["absolute:12", "standard:S01E12"], mappings)

    assert Enum.map(matches, & &1.evidence) == [:absolute, :standard]
  end

  test "only positive extra evidence is ignorable" do
    assert {:ignore, :extra, %{role: :extra, evidence: :typed_marker}} =
             AnimeResolver.resolve([], [], role: :extra, extra_evidence: :typed_marker)

    assert :unmatched = AnimeResolver.resolve([], [], role: :extra)
    assert :unmatched = AnimeResolver.resolve([], [], role: :extra, extra_evidence: false)
  end

  test "empty episode mappings do not resolve" do
    mappings = [%{coordinate: "absolute:12", episode_ids: [], precedence: :manual}]

    assert :unmatched = AnimeResolver.resolve(["absolute:12"], mappings)
  end
end
