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

  # #987: a saved season offset gives native S02E05 (id 205) the curated scene code S03E05, which
  # retires its native code. `with_value/2` gives each mapping its code.
  describe "strip_retired_canonical/2 (#987)" do
    test "a curated scene code in another season drops the episode's native canonical" do
      native = with_value(canonical([205]), "S02E05")
      offset = with_value(mapping("scene", "offset", "offset", :curated, [205]), "S03E05")

      assert AnimeResolver.strip_retired_canonical([native], [native, offset]) == []
      assert AnimeResolver.retired_canonical?(native, [native, offset])
    end

    # A retired code resolves only through a vetted mapping that names it: an inferred one never
    # wins in place of the native episode.
    test "a retired canonical takes the inferred matches with it and leaves the vetted ones" do
      native = with_value(canonical([205]), "S02E05")
      inferred = with_value(mapping("scene", "tmdb", "grp", :inferred, [105]), "S02E05")
      manual = with_value(mapping("aired", "tvdb", "99", :manual, [106]), "S02E05")
      offset = with_value(mapping("scene", "offset", "offset", :curated, [205]), "S03E05")

      assert AnimeResolver.strip_retired_canonical([native, inferred, manual], [offset]) == [
               manual
             ]

      assert AnimeResolver.strip_retired_canonical([native, inferred], [offset]) == []
    end

    # As #924 keeps a vetted mapping naming only a code's native episode: a fold of a file named by
    # the native code into the same episode keeps that code, of either scheme.
    for scheme <- ["scene", "aired"] do
      test "a vetted #{scheme} mapping naming the native code for the same episode keeps it" do
        native = with_value(canonical([205]), "S02E05")
        offset = with_value(mapping("scene", "offset", "offset", :curated, [205]), "S03E05")
        fold = with_value(mapping(unquote(scheme), "tvdb", "99", :manual, [205]), "S02E05")
        mappings = [native, offset, fold]

        refute AnimeResolver.retired_canonical?(native, mappings)
        assert AnimeResolver.strip_retired_canonical([native, fold], mappings) == [native, fold]
      end
    end

    test "an inferred mapping naming the native code for the same episode keeps nothing" do
      native = with_value(canonical([205]), "S02E05")
      offset = with_value(mapping("scene", "offset", "offset", :curated, [205]), "S03E05")
      sync = with_value(mapping("scene", "tmdb", "grp", :inferred, [205]), "S02E05")

      assert AnimeResolver.retired_canonical?(native, [native, offset, sync])
    end

    test "with no retired canonical, every match stays" do
      native = with_value(canonical([205]), "S02E05")
      inferred = with_value(mapping("scene", "tmdb", "grp", :inferred, [105]), "S02E05")
      offset = with_value(mapping("scene", "offset", "offset", :curated, [305]), "S04E05")

      assert AnimeResolver.strip_retired_canonical([native, inferred], [offset]) == [
               native,
               inferred
             ]
    end

    for {label, scheme, source, precedence, value} <- [
          {"a curated scene code in the episode's own season", "scene", "offset", :curated,
           "S02E07"},
          {"a manual scene code in another season", "scene", "offset", :manual, "S03E05"},
          {"a manual aired code in another season", "aired", "tvdb", :manual, "S03E05"},
          {"an inferred scene code in another season", "scene", "tmdb", :inferred, "S03E05"},
          {"a curated scene code with no season", "scene", "offset", :curated, "12"}
        ] do
      test "#{label} keeps the native canonical" do
        native = with_value(canonical([205]), "S02E05")

        moved =
          unquote(scheme)
          |> mapping(unquote(source), unquote(source), unquote(precedence), [205])
          |> with_value(unquote(value))

        assert AnimeResolver.strip_retired_canonical([native], [native, moved]) == [native]
        refute AnimeResolver.retired_canonical?(native, [native, moved])
      end
    end
  end

  defp with_value(mapping, value), do: put_in(mapping.identity[:canonical_value], value)

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
