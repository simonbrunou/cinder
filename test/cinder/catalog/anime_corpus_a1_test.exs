defmodule Cinder.Catalog.AnimeCorpusA1Test do
  use ExUnit.Case, async: true

  alias Cinder.Catalog.AnimeResolver

  @corpus "test/support/fixtures/anime/corpus-v1.json"

  setup_all do
    contracts =
      @corpus
      |> load_behavior_contracts!()
      |> Enum.filter(&(&1.phase == "A1"))

    assert length(contracts) == 4
    %{contracts: Map.new(contracts, &{&1.id, &1})}
  end

  defp load_behavior_contracts!(path) do
    path
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("behavior_contracts")
    |> Enum.map(fn c ->
      %{id: c["id"], phase: c["phase"], kind: c["kind"], input: c["input"], expect: c["expect"]}
    end)
  end

  test "resolver contracts", %{contracts: contracts} do
    for id <- [
          "coordinate-to-many",
          "coordinates-to-one",
          "ambiguous-coordinate-needs-mapping"
        ] do
      contract = Map.fetch!(contracts, id)
      assert_contract(contract)
    end
  end

  test "provider renumbering preserves the active result and refreshes future resolution", %{
    contracts: contracts
  } do
    contract = Map.fetch!(contracts, "provider-renumbering-preserves-active-work")
    coordinate = contract.input["coordinate"]

    assert {:ok, active_episode_ids, active_evidence} =
             AnimeResolver.resolve(
               [coordinate],
               [mapping(coordinate, contract.input["snapshot_episode_keys"], :snapshot)]
             )

    assert {:ok, future_episode_ids, _future_evidence} =
             AnimeResolver.resolve(
               [coordinate],
               [mapping(coordinate, contract.input["refreshed_episode_keys"], :refreshed)]
             )

    assert active_episode_ids == contract.expect["active_episode_keys"]
    assert future_episode_ids == contract.expect["future_episode_keys"]

    assert active_evidence.matches == [
             mapping_evidence(coordinate, active_episode_ids, :snapshot)
           ]
  end

  defp assert_contract(%{input: input, expect: %{"outcome" => "resolved"} = expect}) do
    assert {:ok, episode_ids, _evidence} =
             AnimeResolver.resolve(input["coordinates"], mappings(input))

    assert episode_ids == expect["episode_keys"]
  end

  defp assert_contract(%{input: input, expect: %{"outcome" => "ambiguous"}}) do
    assert {:ambiguous, _candidates, _evidence} =
             AnimeResolver.resolve(input["coordinates"], mappings(input))
  end

  defp mappings(input) do
    Enum.map(input["coordinates"], fn coordinate ->
      mapping(coordinate, input["memberships"][coordinate], :fixture)
    end)
  end

  defp mapping(coordinate, episode_ids, evidence) do
    %{
      coordinate: coordinate,
      episode_ids: episode_ids,
      precedence: :inferred,
      evidence: evidence
    }
  end

  defp mapping_evidence(coordinate, episode_ids, evidence) do
    %{coordinate: coordinate, episode_ids: episode_ids, evidence: evidence}
  end
end
