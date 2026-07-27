defmodule Cinder.Library.MigrationReconcilerTest do
  use Cinder.DataCase, async: false

  import Cinder.CatalogFixtures
  import Mox

  alias Cinder.Catalog.Identity
  alias Cinder.Library.{MigrationReconciler, MigrationSourceMock}

  @fixture_path "test/support/fixtures/migration-provider-identity-v1.json"
  @cases @fixture_path |> File.read!() |> Jason.decode!() |> Map.fetch!("cases")

  setup :verify_on_exit!

  test "the normalized migration source contract is mockable" do
    snapshot = @cases |> fixture!("unique") |> Map.fetch!("snapshot") |> snapshot()

    expect(MigrationSourceMock, :snapshot, fn -> {:ok, snapshot} end)

    assert {:ok, ^snapshot} = MigrationSourceMock.snapshot()
  end

  test "fixture corpus resolves unique and N-to-one identities and fails closed" do
    Enum.each(@cases, fn fixture ->
      snapshot = snapshot(fixture["snapshot"])
      result = MigrationReconciler.reconcile(snapshot, lookups(fixture["lookups"]))

      assert normalized_result(result) == fixture["expect"], fixture["id"]
      assert result.files == snapshot.files
    end)
  end

  test "N-to-one results persist both TVDB coordinate schemes and preserve manual rows" do
    fixture = fixture!(@cases, "n_to_one")

    result =
      MigrationReconciler.reconcile(snapshot(fixture["snapshot"]), lookups(fixture["lookups"]))

    series = series_fixture(tmdb_id: 1100, tvdb_id: 200)
    season = season_fixture(series, season_number: 4)
    episode = episode_fixture(season, tmdb_episode_id: 2100, episode_number: 15)

    manual =
      episode_coordinate_fixture(
        series,
        %{
          source: "tvdb",
          scheme: "aired",
          namespace: "200",
          canonical_value: "manual",
          precedence: :manual
        },
        [episode.id]
      )

    assert {:ok, batches} =
             MigrationReconciler.coordinate_batches(result, %{2100 => episode.id})

    Enum.each(batches, fn batch ->
      assert {:ok, _} =
               Identity.replace_provider_coordinates(
                 series,
                 batch.source,
                 batch.namespace,
                 batch.scheme,
                 batch.coordinates
               )
    end)

    coordinates = Identity.list_coordinates(series)
    assert Enum.any?(coordinates, &(&1.id == manual.id))

    for {scheme, value} <- [
          {"episode_id", "2001"},
          {"episode_id", "2002"},
          {"aired", "S04E15"},
          {"aired", "S04E16"}
        ] do
      assert coordinate =
               Enum.find(coordinates, &(&1.scheme == scheme and &1.canonical_value == value))

      assert Enum.map(coordinate.memberships, & &1.episode_id) == [episode.id]
    end
  end

  defp fixture!(cases, id), do: Enum.find(cases, &(&1["id"] == id))

  defp snapshot(snapshot) do
    Map.new(snapshot, fn {collection, records} ->
      {String.to_existing_atom(collection), Enum.map(records, &atomize_record/1)}
    end)
  end

  defp lookups(lookups) do
    Map.new(lookups, fn lookup ->
      key = {String.to_existing_atom(lookup["source"]), lookup["external_id"]}
      {key, {:ok, Enum.map(lookup["results"], &atomize_record/1)}}
    end)
  end

  defp atomize_record(record) do
    Map.new(record, fn
      {"kind", kind} -> {:kind, String.to_existing_atom(kind)}
      {"type", type} -> {:type, String.to_existing_atom(type)}
      {key, value} -> {String.to_existing_atom(key), value}
    end)
  end

  defp normalized_result(result) do
    %{
      "movie_tmdb_ids" => Enum.map(result.movies, & &1.tmdb_id),
      "series_tmdb_ids" => Enum.map(result.series, & &1.tmdb_id),
      "episode_tmdb_ids" => Enum.map(result.episodes, & &1.tmdb_episode_id),
      "coordinates" =>
        for episode <- result.episodes, coordinate <- episode.coordinates do
          %{
            "tmdb_episode_id" => episode.tmdb_episode_id,
            "source" => coordinate.source,
            "scheme" => coordinate.scheme,
            "namespace" => coordinate.namespace,
            "canonical_value" => coordinate.canonical_value
          }
        end,
      "unresolved" => Enum.map(result.unresolved, &normalize_unresolved/1)
    }
  end

  defp normalize_unresolved(%{reason: {:wrong_series, expected, actual}} = unresolved) do
    unresolved
    |> Map.take([:kind, :provider_id])
    |> stringify()
    |> Map.merge(%{
      "reason" => "wrong_series",
      "expected_series_tmdb_id" => expected,
      "actual_series_tmdb_id" => actual
    })
  end

  defp normalize_unresolved(unresolved) do
    unresolved
    |> Map.update!(:reason, &Atom.to_string/1)
    |> stringify()
  end

  defp stringify(map) do
    Map.new(map, fn
      {:kind, kind} -> {"kind", Atom.to_string(kind)}
      {key, value} -> {Atom.to_string(key), value}
    end)
  end
end
