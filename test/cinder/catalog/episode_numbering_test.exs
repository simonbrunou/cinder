defmodule Cinder.Catalog.EpisodeNumberingTest do
  use ExUnit.Case, async: true

  alias Cinder.Catalog.EpisodeNumbering

  # Each mapping is `{scheme, source, precedence, value, episode_ids}`. `:canonical` is the native
  # code every episode carries (`source: "cinder"`, `namespace: "canonical"`, `:manual`).
  #
  # The #987 rows share one saved season offset: native S02E05 (id 205) gets the curated scene
  # code S03E05, which retires the native code S02E05.
  @offset {"scene", "offset", :curated, "S03E05", [205]}

  describe "resolve/4" do
    for {label, kind, value, mappings, expected} <- [
          {"a native code names its episode", :standard, "S04E05", [{:canonical, "S04E05", [5]}],
           {:ok, [5]}},
          {"the standard search bridges an aired code", :standard, "S04E05",
           [{"aired", "tvdb", :inferred, "S04E05", [9]}], {:ok, [9]}},
          {"the anime search does not bridge an aired code", :anime, "S04E05",
           [{"aired", "tvdb", :inferred, "S04E05", [9]}], :unmatched},
          {"the standard search bridges a scene code", :standard, "S04E05",
           [{"scene", "tmdb", :inferred, "S04E05", [9]}], {:ok, [9]}},
          {"the anime search bridges a scene code", :anime, "S04E05",
           [{"scene", "tmdb", :inferred, "S04E05", [9]}], {:ok, [9]}},
          # #156: an auto-derived scene code never overrides the native episode.
          {"an inferred scene code leaves the native reading", :anime, "S04E05",
           [{:canonical, "S04E05", [5]}, {"scene", "tmdb", :inferred, "S04E05", [99]}],
           {:ok, [5]}},
          {"a curated scene code for another episode shadows the native code", :standard,
           "S04E05", [{:canonical, "S04E05", [5]}, {"scene", "offset", :curated, "S04E05", [99]}],
           {:ok, [99]}},
          {"a manual scene code for another episode shadows the native code", :anime, "S04E05",
           [{:canonical, "S04E05", [5]}, {"scene", "offset", :manual, "S04E05", [99]}],
           {:ok, [99]}},
          # Shadowing counts scene codes only; the aired extension is contested_native_codes/2's.
          {"a curated aired code does not shadow the native code", :standard, "S04E05",
           [{:canonical, "S04E05", [5]}, {"aired", "tvdb", :curated, "S04E05", [99]}],
           {:ok, [5]}},
          {"a vetted scene code for the same episode keeps the native code", :anime, "S04E05",
           [{:canonical, "S04E05", [5]}, {"scene", "offset", :curated, "S04E05", [5]}],
           {:ok, [5]}},
          {"a manual standard correction is never shadowed", :anime, "S04E05",
           [
             {"standard", "manual", :manual, "S04E05", [7]},
             {"scene", "offset", :curated, "S04E05", [99]}
           ], {:ok, [7]}},
          {"two vetted scene codes for different episodes resolve two ways", :standard, "S04E05",
           [
             {:canonical, "S04E05", [5]},
             {"scene", "offset", :curated, "S04E05", [99]},
             {"scene", "tmdb", :curated, "S04E05", [42]}
           ], {:ambiguous, [[42], [99]]}},
          # #987: a saved season offset retires the native code of the episode it moves.
          {"a retired native code names no episode", :standard, "S02E05",
           [{:canonical, "S02E05", [205]}, @offset], :unmatched},
          {"a retired native code takes the inferred matches with it", :anime, "S02E05",
           [
             {:canonical, "S02E05", [205]},
             {"scene", "tmdb", :inferred, "S02E05", [105]},
             @offset
           ], :unmatched},
          {"a retired native code reads through a vetted scene code naming it", :anime, "S02E05",
           [
             {:canonical, "S02E05", [205]},
             {"scene", "tmdb", :inferred, "S02E05", [105]},
             {"scene", "tvdb", :manual, "S02E05", [106]},
             @offset
           ], {:ok, [106]}},
          {"a retired native code reads through a vetted aired code in the standard search",
           :standard, "S02E05",
           [{:canonical, "S02E05", [205]}, {"aired", "tvdb", :manual, "S02E05", [106]}, @offset],
           {:ok, [106]}},
          {"a fold naming the native code for the same episode keeps it", :anime, "S02E05",
           [{:canonical, "S02E05", [205]}, {"scene", "tvdb", :manual, "S02E05", [205]}, @offset],
           {:ok, [205]}},
          {"an aired fold naming the native code for the same episode keeps it", :standard,
           "S02E05",
           [{:canonical, "S02E05", [205]}, {"aired", "tvdb", :manual, "S02E05", [205]}, @offset],
           {:ok, [205]}},
          {"an inferred code naming the native code for the same episode keeps nothing",
           :standard, "S02E05",
           [
             {:canonical, "S02E05", [205]},
             {"scene", "tmdb", :inferred, "S02E05", [205]},
             @offset
           ], :unmatched},
          {"a curated scene code in the episode's own season retires nothing", :standard,
           "S02E05",
           [{:canonical, "S02E05", [205]}, {"scene", "offset", :curated, "S02E07", [205]}],
           {:ok, [205]}},
          {"a manual scene code in another season retires nothing", :anime, "S02E05",
           [{:canonical, "S02E05", [205]}, {"scene", "offset", :manual, "S03E05", [205]}],
           {:ok, [205]}},
          {"a manual aired code in another season retires nothing", :standard, "S02E05",
           [{:canonical, "S02E05", [205]}, {"aired", "tvdb", :manual, "S03E05", [205]}],
           {:ok, [205]}},
          {"an inferred scene code in another season retires nothing", :anime, "S02E05",
           [{:canonical, "S02E05", [205]}, {"scene", "tmdb", :inferred, "S03E05", [205]}],
           {:ok, [205]}},
          {"a curated scene code with no season retires nothing", :anime, "S02E05",
           [{:canonical, "S02E05", [205]}, {"scene", "offset", :curated, "12", [205]}],
           {:ok, [205]}},
          {"an offset of another episode leaves the native code", :standard, "S02E05",
           [{:canonical, "S02E05", [205]}, {"scene", "offset", :curated, "S04E05", [305]}],
           {:ok, [205]}},
          {"a mapping with no episode names nothing", :anime, "S04E05",
           [{"scene", "offset", :manual, "S04E05", []}], :unmatched}
        ] do
      test "#{label} (#{kind})" do
        mappings = Enum.map(unquote(Macro.escape(mappings)), &mapping/1)

        assert unquote(Macro.escape(expected)) ==
                 unquote(kind)
                 |> EpisodeNumbering.resolve("standard", unquote(value), mappings)
                 |> without_evidence()
      end
    end

    test "an anime code of another scheme matches only that scheme" do
      mappings = [
        mapping({"absolute", "tvdb", :inferred, "12", [3]}),
        mapping({"scene", "tmdb", :manual, "12", [4]})
      ]

      assert {:ok, [3], %{precedence: :inferred, matches: [%{coordinate: coordinate}]}} =
               EpisodeNumbering.resolve(:anime, "absolute", "12", mappings)

      assert coordinate.scheme == "absolute"
    end

    test "the evidence names the mappings at the winning precedence" do
      native = mapping({:canonical, "S04E05", [5]})
      scene = mapping({"scene", "offset", :curated, "S04E05", [99]})

      assert {:ok, [99], %{precedence: :curated, matches: [match]}} =
               EpisodeNumbering.resolve(:standard, "standard", "S04E05", [native, scene])

      assert match == %{coordinate: scene.identity, episode_ids: [99], evidence: scene.evidence}
    end
  end

  # Native S02E05 is episode 205 and native S02E06 is episode 206.
  describe "contested_native_codes/2" do
    for {label, extra, expected} <- [
          {"no other mapping contests a native code", [], []},
          {"a curated scene code for another episode contests the code (#924)",
           [{"scene", "offset", :curated, "S02E05", [99]}], ["S02E05"]},
          {"a manual aired code for another episode contests the code (#924)",
           [{"aired", "tvdb", :manual, "S02E06", [99]}], ["S02E06"]},
          {"a vetted code for another episode of the same season contests the code (#986)",
           [{"scene", "offset", :curated, "S02E05", [206]}], ["S02E05"]},
          {"a vetted code no episode carries natively counts as elsewhere",
           [{"scene", "offset", :manual, "S02E09", [206]}], ["S02E09"]},
          {"an inferred scene code for another episode contests nothing",
           [{"scene", "tmdb", :inferred, "S02E05", [99]}], []},
          {"an inferred aired code for another episode contests nothing",
           [{"aired", "tvdb", :inferred, "S02E05", [99]}], []},
          {"a vetted code naming only its native episode contests nothing",
           [{"scene", "offset", :manual, "S02E05", [205]}], []},
          {"a vetted absolute code contests nothing",
           [{"absolute", "tvdb", :manual, "S02E05", [99]}], []},
          {"a vetted code of another season is not this season's",
           [{"scene", "offset", :curated, "S03E05", [99]}], []},
          {"a saved offset retires the native code it moves (#987)", [@offset], ["S02E05"]},
          {"a fold naming the native code keeps it from the offset (#987)",
           [@offset, {"scene", "tvdb", :manual, "S02E05", [205]}], []},
          {"a manual scene code in another season retires nothing (#987)",
           [{"scene", "offset", :manual, "S03E05", [205]}], []}
        ] do
      test label do
        mappings =
          Enum.map(
            [{:canonical, "S02E05", [205]}, {:canonical, "S02E06", [206]}] ++
              unquote(Macro.escape(extra)),
            &mapping/1
          )

        assert EpisodeNumbering.contested_native_codes(mappings, 2) ==
                 MapSet.new(unquote(expected))
      end
    end
  end

  describe "queryable_code?/2" do
    for {label, subject, expected} <- [
          {"a native code an offset retired is not queryable", {:canonical, "S02E05", [205]},
           false},
          {"a native code no offset moved is queryable", {:canonical, "S02E06", [206]}, true},
          {"the offset's own code is queryable", @offset, true},
          # The guard: an auto-derived code of the moved episode in its native season reads as
          # retired to the retirement rule, which only a native code may be.
          {"an inferred code of the moved episode is queryable",
           {"scene", "tmdb", :inferred, "S02E05", [205]}, true}
        ] do
      test label do
        subject = mapping(unquote(Macro.escape(subject)))

        mappings =
          Enum.map(
            [{:canonical, "S02E05", [205]}, {:canonical, "S02E06", [206]}, @offset],
            &mapping/1
          )

        assert EpisodeNumbering.queryable_code?(subject, [subject | mappings]) ==
                 unquote(expected)
      end
    end
  end

  describe "bridged_schemes/1 and grab_schemes/2" do
    test "the standard search bridges scene before aired, the anime search scene only" do
      assert EpisodeNumbering.bridged_schemes(:standard) == ~w(scene aired)
      assert EpisodeNumbering.bridged_schemes(:anime) == ~w(scene)
    end

    test "a frozen grab's standard code matches its kind's bridge, any other code only itself" do
      assert EpisodeNumbering.grab_schemes(:anime, "standard") == ~w(standard scene)
      assert EpisodeNumbering.grab_schemes(:standard, "standard") == ~w(standard scene aired)
      assert EpisodeNumbering.grab_schemes(:anime, "absolute") == ~w(absolute)
      assert EpisodeNumbering.grab_schemes(:anime, "scene") == ~w(scene)
    end
  end

  defp without_evidence({:ok, ids, _evidence}), do: {:ok, ids}
  defp without_evidence({:ambiguous, candidates, _evidence}), do: {:ambiguous, candidates}
  defp without_evidence(other), do: other

  defp mapping({:canonical, value, episode_ids}),
    do: mapping({"standard", "cinder", :manual, value, episode_ids}, "canonical")

  defp mapping({scheme, source, precedence, value, episode_ids}),
    do: mapping({scheme, source, precedence, value, episode_ids}, source)

  defp mapping({scheme, source, precedence, value, episode_ids}, namespace) do
    %{
      identity: %{
        source: source,
        scheme: scheme,
        namespace: namespace,
        canonical_value: value
      },
      precedence: precedence,
      episode_ids: episode_ids,
      evidence: %{"kind" => "#{source}:#{scheme}:#{value}"}
    }
  end
end
