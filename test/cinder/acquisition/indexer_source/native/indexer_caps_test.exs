defmodule Cinder.Acquisition.IndexerSource.Native.IndexerCapsTest do
  # The caps table Native owns (#1652), read and written apart from any HTTP: the fetch is a
  # function the test hands in. The request planner's tests (`Cinder.Acquisition.Indexer.NewznabTest`)
  # cover the 7-day bound and the config_version check through real caps requests.
  #
  # Not async: the table's clock is Native's global config.
  use Cinder.DataCase, async: false

  alias Cinder.Acquisition.IndexerSource.Native
  alias Cinder.Acquisition.IndexerSource.Native.IndexerCaps
  alias Cinder.ConfigCase
  alias Cinder.Indexers

  @caps %{
    "modes" => %{"search" => ["q"], "tv-search" => ["q", "season"]},
    "categories" => [2000, 5070],
    "limits" => %{"max" => 100, "default" => nil}
  }

  setup do
    now = ~U[2026-11-26 12:00:00Z]
    ConfigCase.put_env(Native, clock: fn -> now end)

    {:ok, indexer} =
      Indexers.create(nil, %{
        name: "Indexer",
        type: :newznab,
        base_url: "https://indexer.example",
        api_path: "/api"
      })

    %{indexer: indexer, now: now}
  end

  defp fetch(answer) do
    test_pid = self()

    fn ->
      send(test_pid, :fetched)
      answer
    end
  end

  test "a read with no row fetches and stores the caps as they read back", %{indexer: indexer} do
    assert IndexerCaps.read(indexer, fetch({:ok, @caps})) == {:ok, @caps}
    assert_received :fetched

    assert %IndexerCaps{config_version: 1, caps: @caps, fetched_at: fetched_at} =
             Repo.get!(IndexerCaps, indexer.id)

    assert fetched_at == ~U[2026-11-26 12:00:00.000000Z]

    assert IndexerCaps.read(indexer, fetch({:ok, %{}})) == {:ok, @caps}
    refute_received :fetched
  end

  test "a failed fetch answers its error and changes no row", %{indexer: indexer, now: now} do
    assert {:ok, @caps} = IndexerCaps.read(indexer, fetch({:ok, @caps}))

    assert IndexerCaps.refetch(indexer, fetch({:error, :timeout})) == {:error, :timeout}
    assert_received :fetched
    assert %IndexerCaps{caps: @caps, fetched_at: fetched_at} = Repo.get!(IndexerCaps, indexer.id)
    assert DateTime.compare(fetched_at, now) == :eq
  end

  test "a read for an indexer deleted during the fetch answers the caps and stores none",
       %{indexer: indexer} do
    fetch = fn ->
      :ok = Indexers.delete(nil, indexer.id)
      {:ok, @caps}
    end

    assert IndexerCaps.read(indexer, fetch) == {:ok, @caps}
    refute Repo.get(IndexerCaps, indexer.id)
  end

  test "a failed refetch leaves a usable row answering the next read", %{indexer: indexer} do
    assert {:ok, @caps} = IndexerCaps.read(indexer, fetch({:ok, @caps}))
    assert_received :fetched
    assert IndexerCaps.refetch(indexer, fetch({:error, :timeout})) == {:error, :timeout}
    assert_received :fetched

    assert IndexerCaps.read(indexer, fetch({:ok, %{}})) == {:ok, @caps}
    refute_received :fetched
  end
end
