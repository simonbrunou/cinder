defmodule Cinder.Books.CorpusB2bTest do
  @moduledoc """
  The B2b acceptance gate: `Cinder.Books.Identity`'s matcher against the frozen 40-case B0 corpus.

  The fixtures carry two independent provider evaluations of the same 40 queries —
  `metadata-provider-pair-v1.json` for Open Library and `provider-v1.json` for the Hardcover
  proxy — each with an operator-confirmed judgement per case. This asserts the contract's numbers,
  not the implementation's: >= 90% combined coverage, and the three named cases staying unresolved.

  Note the corpus's own `expect.resolution` field is deliberately *not* asserted here. It records
  what the existing Bookshelf deployment does (its `provider_outcome` mirrors the Hardcover
  disposition exactly), so four cases Open Library resolves perfectly well are labelled
  `no_reliable_match` there. The contract's 37/40 union is the target for Cinder.
  """
  use ExUnit.Case, async: true

  alias Cinder.Books.Identity

  @pair "test/support/fixtures/books/metadata-provider-pair-v1.json"
  @hardcover "test/support/fixtures/books/provider-v1.json"

  # Frozen by the parity contract's provider decision: these stay explained unresolved states
  # until an operator corrects them. Adding Hardcover did not authorize a guess.
  @must_stay_unresolved ~w(count-monte-cristo leviathan-wakes time-war)

  setup_all do
    %{open_library: open_library_cases(), hardcover: hardcover_cases()}
  end

  test "the configured pair resolves at least 90% of the corpus", ctx do
    assert length(ctx.open_library) == 40

    resolved =
      Enum.count(ctx.open_library, fn {id, _query, _candidates} ->
        selected?(ctx.open_library, id) or selected?(ctx.hardcover, id)
      end)

    assert resolved == 36
    assert resolved / 40 >= 0.9
  end

  test "the one case the frozen evaluation resolves and this matcher does not is three-body-problem",
       ctx do
    # The proxy credits "Liu Cixin"; the query says "Cixin Liu Ken Liu". Token-set matching
    # reconciles the name order, but "Ken Liu" is the translator and the provider does not credit
    # him — so query-minus-contributors keeps a leftover the title cannot absorb. The frozen
    # evaluation accepted it on a known-contributor list (its own assessment records
    # `contributor_match: false, known_contributor_match: true`), which a resolver holding only a
    # query does not have. Widening the title rule to tolerate leftovers is exactly the fuzzy
    # match the contract forbids, so this stays a rejection.
    refute selected?(ctx.hardcover, "three-body-problem")
    refute selected?(ctx.open_library, "three-body-problem")
  end

  test "the three contract-frozen cases stay unresolved in both providers", ctx do
    for id <- @must_stay_unresolved do
      refute selected?(ctx.open_library, id), "#{id} must not resolve via Open Library"
      refute selected?(ctx.hardcover, id), "#{id} must not resolve via Hardcover"
    end
  end

  test "the matcher agrees with Open Library's frozen per-case judgement", ctx do
    {agree, disagree} =
      Enum.split_with(ctx.open_library, fn {id, query, candidates} ->
        reliable?(Identity.select(candidates, query)) == fixture_reliable(id)
      end)

    assert length(agree) == 39

    # The one disagreement is recorded rather than tuned away: the fixture's labelling used a year
    # check against an operator-supplied expected year, which a resolver holding only a query does
    # not have. Hardcover accepts the case anyway, so the combined outcome is unchanged.
    assert Enum.map(disagree, fn {id, _q, _c} -> id end) == ["the-talisman"]
  end

  test "no candidate is ever selected without contributor evidence in the query", ctx do
    checked =
      for {id, query, candidates} <- ctx.open_library,
          {:ok, selected, evidence} <- [Identity.select(candidates, query)] do
        assert evidence.contributors_matched != [],
               "#{id} selected #{selected.title} with no contributor evidence"

        for name <- evidence.contributors_matched do
          assert Enum.any?(selected.contributors, &(&1.name == name)),
                 "#{id} reported a contributor the selected work does not credit"
        end

        id
      end

    # The generator above skips unresolved cases, so state the sample size: without this the test
    # would pass just as happily if the matcher resolved nothing at all.
    assert length(checked) == 32
  end

  test "a first-result-shaped near miss is rejected, not accepted" do
    # A real Open Library trap: the top hit for "Beloved Toni Morrison" by title similarity is a
    # study guide *about* the book, credited to someone else entirely.
    candidates = [
      candidate("study-guide", "Beloved, Toni Morrison", ["Selena Ward"], 40),
      candidate("real", "Beloved", ["Toni Morrison"], 1)
    ]

    assert {:ok, %{foreign_id: "real"}, _evidence} =
             Identity.select(candidates, "Beloved Toni Morrison")
  end

  defp selected?(cases, id) do
    case Enum.find(cases, fn {case_id, _query, _candidates} -> case_id == id end) do
      nil -> false
      {_id, query, candidates} -> reliable?(Identity.select(candidates, query))
    end
  end

  defp reliable?({:ok, _candidate, _evidence}), do: true
  defp reliable?(_other), do: false

  defp fixture_reliable(id) do
    @pair
    |> read!()
    |> Map.fetch!("cases")
    |> Enum.find(&(&1["id"] == id))
    |> get_in(["open_library", "reliable"])
  end

  # Open Library search results, shaped exactly as `Metadata.OpenLibrary.search/1` returns them.
  defp open_library_cases do
    @pair
    |> read!()
    |> Map.fetch!("cases")
    |> Enum.map(fn c ->
      candidates =
        c["open_library"]["results"]
        |> Enum.with_index()
        |> Enum.map(fn {result, index} ->
          candidate(
            result["key"],
            result["title"],
            result["contributors"],
            result["edition_count"] || index
          )
        end)

      {c["id"], c["query"], candidates}
    end)
  end

  # The Hardcover proxy returns bare ids from search, so its adapter builds candidates out of the
  # fetched work documents — which is what `selected_work` freezes.
  defp hardcover_cases do
    @hardcover
    |> read!()
    |> Map.fetch!("cases")
    |> Enum.map(fn c ->
      work = c["selected_work"] || %{}
      names = Enum.map(work["authors"] || [], & &1["name"])
      editions = length(work["editions"] || [])

      candidates =
        if work["title"],
          do: [candidate(to_string(work["foreign_id"]), work["title"], names, editions)],
          else: []

      {c["id"], c["query"], candidates}
    end)
  end

  defp candidate(foreign_id, title, contributors, edition_count) do
    %{
      provider: :fixture,
      foreign_id: to_string(foreign_id),
      title: title,
      contributors: Enum.map(contributors, &%{foreign_id: &1, name: &1, role: "author"}),
      first_published_year: nil,
      edition_count: edition_count
    }
  end

  defp read!(path), do: path |> File.read!() |> Jason.decode!()
end
