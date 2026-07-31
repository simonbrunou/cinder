defmodule Cinder.Library.AdoptionDecisionsTest do
  # Pure decision-building extracted from the adoption LiveView: candidates plus
  # the operator's selections/decisions in, confirmed candidates or migration
  # commands out. No filesystem, TMDB, or catalog access.
  use ExUnit.Case, async: true

  alias Cinder.Library.Adoption

  describe "confirmed_candidates/2" do
    test "keeps only selected auto-matched candidates" do
      candidates = [movie_candidate(1), movie_candidate(2)]

      assert [%{id: 1, status: :auto_matched}] =
               Adoption.confirmed_candidates(candidates, %{"selected" => ["1"]})
    end

    test "parses selected ids defensively and ignores junk" do
      candidates = [movie_candidate(1), movie_candidate(2), movie_candidate(3)]
      params = %{"selected" => ["1", "x", "2.5", 3, nil]}

      assert [%{id: 1}, %{id: 3}] = Adoption.confirmed_candidates(candidates, params)
    end

    test "an empty or missing selection confirms nothing" do
      candidates = [movie_candidate(1)]

      assert Adoption.confirmed_candidates(candidates, %{}) == []
      assert Adoption.confirmed_candidates(candidates, %{"selected" => []}) == []
    end

    test "unmatched candidates are dropped even when selected" do
      candidates = [movie_candidate(1, %{status: :unmatched, reason: :no_match})]

      assert Adoption.confirmed_candidates(candidates, %{"selected" => ["1"]}) == []
    end

    test "applies a part choice to the matching file" do
      file = held_file(7, part_candidates: [part(1, 2, "Two"), part(1, 3, "Three")])
      candidates = [series_candidate(5, [file])]
      params = %{"selected" => ["5"], "parts" => %{"5" => %{"7" => "3"}}}

      assert [%{id: 5, files: [confirmed]}] = Adoption.confirmed_candidates(candidates, params)
      assert confirmed.status == :part
      assert confirmed.part_of == %{season_number: 1, episode_number: 3}
    end

    test "leaves the file held when the choice matches no part candidate" do
      file = held_file(7, part_candidates: [part(1, 2, "Two")])
      candidates = [series_candidate(5, [file])]

      for choice <- ["9", "", "junk"] do
        params = %{"selected" => ["5"], "parts" => %{"5" => %{"7" => choice}}}

        assert [%{files: [confirmed]}] = Adoption.confirmed_candidates(candidates, params)
        assert confirmed.status == :unmatched
        assert confirmed.part_of == nil
      end
    end

    test "malformed parts payloads are ignored" do
      file = held_file(7, part_candidates: [part(1, 2, "Two")])
      candidates = [series_candidate(5, [file])]

      for parts <- ["junk", %{"5" => "junk"}, %{"other" => %{"7" => "2"}}] do
        params = %{"selected" => ["5"], "parts" => parts}

        assert [%{files: [confirmed]}] = Adoption.confirmed_candidates(candidates, params)
        assert confirmed.status == :unmatched
      end
    end

    test "ambiguous candidates are confirmed only with a chosen TMDB id" do
      candidates = [ambiguous_candidate(4)]

      assert [%{id: 4, chosen_tmdb_id: 42}] =
               Adoption.confirmed_candidates(candidates, %{"chosen" => %{"4" => "42"}})

      assert Adoption.confirmed_candidates(candidates, %{}) == []
      assert Adoption.confirmed_candidates(candidates, %{"chosen" => %{"4" => ""}}) == []
      assert Adoption.confirmed_candidates(candidates, %{"chosen" => %{"4" => "abc"}}) == []
      assert Adoption.confirmed_candidates(candidates, %{"chosen" => "junk"}) == []
    end

    test "selecting an ambiguous candidate without choosing a match skips it" do
      candidates = [ambiguous_candidate(4)]

      assert Adoption.confirmed_candidates(candidates, %{"selected" => ["4"]}) == []
    end

    test "mixed buckets resolve independently" do
      candidates = [
        movie_candidate(1),
        ambiguous_candidate(2),
        movie_candidate(3, %{status: :unmatched, reason: :no_match})
      ]

      params = %{"selected" => ["1", "3"], "chosen" => %{"2" => "77"}}

      assert [%{id: 1}, %{id: 2, chosen_tmdb_id: 77}] =
               Adoption.confirmed_candidates(candidates, params)
    end
  end

  describe "confirmed_migration_commands/3" do
    test "selected ready candidates become plain adopt commands" do
      ready = [migration_candidate(1, :ready), migration_candidate(2, :ready)]
      buckets = buckets(ready: ready)

      assert [command] =
               Adoption.confirmed_migration_commands(buckets, MapSet.new([1]), %{})

      assert command.key == "key-1"
      assert command.candidate.id == 1
      refute Map.has_key?(command, :choice)
    end

    test "decided needs-decision candidates carry their fold or part choice" do
      decision = [
        migration_candidate(3, :needs_decision),
        migration_candidate(4, :needs_decision)
      ]

      buckets = buckets(needs_decision: decision)
      decisions = %{3 => "fold", 4 => "part"}

      assert [
               %{key: "key-3", choice: "fold", candidate: %{id: 3}},
               %{key: "key-4", choice: "part", candidate: %{id: 4}}
             ] = Adoption.confirmed_migration_commands(buckets, MapSet.new(), decisions)
    end

    test "undecided or invalidly decided candidates produce no command" do
      decision = [
        migration_candidate(3, :needs_decision),
        migration_candidate(4, :needs_decision)
      ]

      buckets = buckets(needs_decision: decision)

      assert Adoption.confirmed_migration_commands(buckets, MapSet.new(), %{}) == []

      assert Adoption.confirmed_migration_commands(buckets, MapSet.new(), %{3 => "skip"}) == []
    end

    test "blocked and already-managed buckets never produce commands" do
      buckets =
        buckets(
          blocked: [migration_candidate(8, :blocked)],
          already_managed: [migration_candidate(9, :already_managed)]
        )

      selected = MapSet.new([8, 9])
      decisions = %{8 => "fold", 9 => "part"}

      assert Adoption.confirmed_migration_commands(buckets, selected, decisions) == []
    end

    test "ready commands come before decision commands" do
      buckets =
        buckets(
          ready: [migration_candidate(1, :ready)],
          needs_decision: [migration_candidate(3, :needs_decision)]
        )

      assert [%{key: "key-1"}, %{key: "key-3", choice: "fold"}] =
               Adoption.confirmed_migration_commands(buckets, MapSet.new([1]), %{3 => "fold"})
    end
  end

  describe "undecided_count/2" do
    test "counts needs-decision candidates without a recorded choice" do
      decision = for id <- 1..3, do: migration_candidate(id, :needs_decision)

      assert Adoption.undecided_count(decision, %{}) == 3
      assert Adoption.undecided_count(decision, %{2 => "fold"}) == 2
      assert Adoption.undecided_count(decision, %{1 => "fold", 2 => "part", 3 => "fold"}) == 0
      assert Adoption.undecided_count([], %{1 => "fold"}) == 0
    end
  end

  defp movie_candidate(id, attrs \\ %{}) do
    Map.merge(
      %{
        id: id,
        kind: :movie,
        status: :auto_matched,
        title: "Movie #{id}",
        year: 2020,
        match: %{tmdb_id: 100 + id, title: "Movie #{id}", year: 2020, poster_path: nil},
        candidates: [],
        reason: nil
      },
      attrs
    )
  end

  defp ambiguous_candidate(id) do
    movie_candidate(id, %{
      status: :ambiguous,
      match: nil,
      candidates: [
        %{tmdb_id: 42, title: "Movie #{id}", year: 2019, poster_path: nil},
        %{tmdb_id: 77, title: "Movie #{id}", year: 2020, poster_path: nil}
      ]
    })
  end

  defp series_candidate(id, files) do
    %{
      id: id,
      kind: :series,
      status: :auto_matched,
      title: "Show #{id}",
      year: 2020,
      match: %{tmdb_id: 100 + id, title: "Show #{id}", year: 2020, poster_path: nil},
      candidates: [],
      files: files,
      reason: nil
    }
  end

  defp held_file(id, attrs) do
    Map.merge(
      %{
        id: id,
        path: "/tv/Show/Show.S01E0#{id}.mkv",
        season_number: 1,
        episode_numbers: [id],
        status: :unmatched,
        mappings: [],
        part_candidates: [],
        part_of: nil,
        reason: {:episode_not_found, [%{season_number: 1, episode_number: id}]}
      },
      Map.new(attrs)
    )
  end

  defp part(season, episode, title),
    do: %{season_number: season, episode_number: episode, title: title}

  defp migration_candidate(id, status) do
    %{id: id, key: "key-#{id}", status: status, title: "Title #{id}", path: "/media/#{id}.mkv"}
  end

  defp buckets(overrides) do
    Map.merge(
      %{ready: [], needs_decision: [], blocked: [], already_managed: []},
      Map.new(overrides)
    )
  end
end
