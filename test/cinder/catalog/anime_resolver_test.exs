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

  describe "strip_shadowed_canonical/1 (issue #156)" do
    test "an operator-reviewed scene coordinate drops the coincidental native canonical of a different episode" do
      native = canonical([5])
      scene = mapping("scene", "offset", "offset", :curated, [99])

      assert AnimeResolver.strip_shadowed_canonical([native, scene]) == [scene]
    end

    test "an auto-derived (:inferred) scene coordinate leaves the native canonical in place" do
      native = canonical([5])
      scene = mapping("scene", "tmdb", "grp", :inferred, [99])

      assert AnimeResolver.strip_shadowed_canonical([native, scene]) == [native, scene]
    end

    test "a scene coordinate pointing at the same episode leaves the native canonical" do
      native = canonical([5])
      scene = mapping("scene", "offset", "offset", :curated, [5])

      assert AnimeResolver.strip_shadowed_canonical([native, scene]) == [native, scene]
    end

    test "only the auto native canonical is dropped, never a manual standard correction" do
      manual_std = mapping("standard", "manual", "manual", :manual, [7])
      scene = mapping("scene", "offset", "offset", :curated, [99])

      assert AnimeResolver.strip_shadowed_canonical([manual_std, scene]) == [manual_std, scene]
    end

    test "two operator-reviewed scene coordinates for different episodes stay (resolver reports ambiguous)" do
      native = canonical([5])
      scene_a = mapping("scene", "offset", "offset", :curated, [99])
      scene_b = mapping("scene", "tmdb", "grp", :curated, [42])

      assert AnimeResolver.strip_shadowed_canonical([native, scene_a, scene_b]) == [
               scene_a,
               scene_b
             ]
    end
  end

  defp canonical(episode_ids),
    do: mapping("standard", "cinder", "canonical", :manual, episode_ids)

  defp mapping(scheme, source, namespace, precedence, episode_ids) do
    %{
      identity: %{source: source, scheme: scheme, namespace: namespace},
      precedence: precedence,
      episode_ids: episode_ids
    }
  end
end
