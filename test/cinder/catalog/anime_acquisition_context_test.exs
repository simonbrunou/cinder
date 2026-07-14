defmodule Cinder.Catalog.AnimeAcquisitionContextTest do
  use Cinder.DataCase, async: false

  import Cinder.CatalogFixtures

  alias Cinder.Catalog

  test "builds a plain movie context with aliases and profile summary" do
    movie = movie_fixture(title: "Your Name", year: 2016, media_profile: :anime)

    assert {:ok, _alias_record} =
             Catalog.save_manual_alias(movie, %{title: "君の名は。", kind: :native})

    assert %{
             kind: :movie,
             title: "Your Name",
             year: 2016,
             aliases: aliases,
             profile: %{effective: :anime}
           } = Catalog.anime_movie_acquisition_context(movie)

    assert aliases == [
             %{
               title: "君の名は。",
               kind: :native,
               precedence: :manual,
               normalized_title: "君の名は。"
             }
           ]
  end

  test "builds a deterministic series context with canonical and persisted mappings" do
    series = series_fixture(title: "Show", year: 2008, tvdb_id: 99)
    first_season = season_fixture(series, season_number: 1)
    second_season = season_fixture(series, season_number: 2)
    first = episode_fixture(first_season, episode_number: 25)
    second = episode_fixture(second_season, episode_number: 1)

    assert {:ok, _alias_record} =
             Catalog.save_manual_alias(series, %{title: "ショー", kind: :native})

    episode_coordinate_fixture(
      series,
      %{
        source: "manual",
        scheme: "absolute",
        namespace: "manual",
        canonical_value: "25",
        precedence: :manual
      },
      [second.id, first.id]
    )

    assert %{
             kind: :series,
             title: "Show",
             year: 2008,
             tvdb_id: 99,
             aliases: aliases,
             episodes: episodes,
             mappings: mappings
           } = Catalog.anime_series_acquisition_context(series)

    assert Enum.map(aliases, & &1.title) == ["ショー"]

    assert Enum.map(episodes, &Map.take(&1, [:id, :season_number, :episode_number])) == [
             %{id: first.id, season_number: 1, episode_number: 25},
             %{id: second.id, season_number: 2, episode_number: 1}
           ]

    assert Enum.any?(mappings, fn mapping ->
             mapping.identity.scheme == "standard" and mapping.episode_ids == [first.id]
           end)

    assert Enum.any?(mappings, fn mapping ->
             mapping.identity == %{
               source: "manual",
               scheme: "absolute",
               namespace: "manual",
               canonical_value: "25"
             } and mapping.episode_ids == [second.id, first.id]
           end)

    assert mappings == Enum.sort_by(mappings, &mapping_sort_key/1)
  end

  defp mapping_sort_key(mapping) do
    identity = mapping.identity
    {identity.source, identity.scheme, identity.namespace, identity.canonical_value}
  end
end
