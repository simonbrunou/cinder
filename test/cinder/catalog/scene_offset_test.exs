defmodule Cinder.Catalog.SceneOffsetTest do
  use Cinder.DataCase, async: false

  import Cinder.CatalogFixtures
  import Ecto.Query

  alias Cinder.Catalog
  alias Cinder.Catalog.{Episode, EpisodeCoordinate}
  alias Cinder.Repo

  # Monogatari-shaped tree: TMDB S1 (Bakemonogatari, 1:1), S3 (Second Season, 23 eps), S4
  # (Hanamonogatari, 5 eps). Releases number the Second Season continuously as S04, a +1 shift from
  # TMDB S3 — so `S04E05` collides with the real native Hanamonogatari S04E05.
  setup do
    series = series_fixture(%{media_profile: :anime, tvdb_id: 99, title: "Monogatari"})
    s1 = season_fixture(series, %{season_number: 1})
    s3 = season_fixture(series, %{season_number: 3})
    s4 = season_fixture(series, %{season_number: 4})

    e_s3 = for n <- 1..23, do: episode_fixture(s3, %{episode_number: n, tmdb_episode_id: 300 + n})
    for n <- 1..3, do: episode_fixture(s1, %{episode_number: n, tmdb_episode_id: 100 + n})
    for n <- 1..5, do: episode_fixture(s4, %{episode_number: n, tmdb_episode_id: 400 + n})

    %{series: series, s3: e_s3}
  end

  defp offset_coords(series) do
    Repo.all(
      from c in EpisodeCoordinate,
        where: c.series_id == ^series.id and c.source == "offset" and c.scheme == "scene",
        preload: :memberships
    )
  end

  defp offset_values(series), do: series |> offset_coords() |> Enum.map(& &1.canonical_value)

  test "save writes :curated scene coords shifted by (from, delta)", %{series: series, s3: s3} do
    assert {:ok, _} = Catalog.save_scene_offset_coordinates(series, 3, 1)

    by_value = Map.new(offset_coords(series), &{&1.canonical_value, &1})
    e5 = Enum.find(s3, &(&1.episode_number == 5))

    assert %EpisodeCoordinate{precedence: :curated} = by_value[Episode.code(4, 5)]
    assert Enum.map(by_value[Episode.code(4, 5)].memberships, & &1.episode_id) == [e5.id]
    # Second Season (TMDB S3, 23 eps) shifts to S04E01..S04E23.
    assert Enum.all?(1..23, &Map.has_key?(by_value, Episode.code(4, &1)))
    # Hanamonogatari (TMDB S4) shifts to S05.
    assert Map.has_key?(by_value, Episode.code(5, 5))
  end

  test "seasons below `from` get no offset coord", %{series: series} do
    {:ok, _} = Catalog.save_scene_offset_coordinates(series, 3, 1)
    values = offset_values(series)

    refute Enum.any?(values, &String.starts_with?(&1, "S01"))
    refute Enum.any?(values, &String.starts_with?(&1, "S02"))
    refute Enum.any?(values, &String.starts_with?(&1, "S03"))
  end

  test "a :manual coord in the offset namespace survives a re-generate", %{series: series, s3: s3} do
    e5 = Enum.find(s3, &(&1.episode_number == 5))

    episode_coordinate_fixture(
      series,
      %{
        source: "offset",
        namespace: "offset",
        scheme: "scene",
        canonical_value: "S99E99",
        precedence: :manual
      },
      [e5.id]
    )

    assert {:ok, _} = Catalog.save_scene_offset_coordinates(series, 3, 1)
    assert "S99E99" in offset_values(series)
  end

  test "clearing removes the :curated offset coords", %{series: series} do
    {:ok, _} = Catalog.save_scene_offset_coordinates(series, 3, 1)
    assert offset_coords(series) != []

    assert {:ok, _} = Catalog.save_scene_offset_coordinates(series, nil, nil)
    assert offset_coords(series) == []
  end

  test "preview flags the native collision and matches what save persists", %{series: series} do
    tree = Catalog.get_series_with_tree(series.id)
    preview = Catalog.preview_scene_offset(tree, 3, 1)

    s04 = Enum.find(preview, &(&1.scene_season == 4))
    assert s04.tmdb_season == 3
    assert s04.count == 23
    assert s04.episode_range == {1, 23}
    # S04E01..S04E05 collide with the real native Hanamonogatari episodes (TMDB S4E1..5).
    assert Enum.sort(s04.collisions) == Enum.sort(for n <- 1..5, do: Episode.code(4, n))

    s05 = Enum.find(preview, &(&1.scene_season == 5))
    assert s05.tmdb_season == 4
    assert s05.collisions == []

    {:ok, _} = Catalog.save_scene_offset_coordinates(series, 3, 1)
    assert Enum.count(offset_values(series), &String.starts_with?(&1, "S04")) == s04.count
  end

  test "an invalid offset is rejected and writes nothing", %{series: series} do
    assert {:error, :invalid_offset} = Catalog.save_scene_offset_coordinates(series, 0, 1)
    assert {:error, :invalid_offset} = Catalog.save_scene_offset_coordinates(series, 3, 0)
    assert offset_coords(series) == []

    # A shift that would derive season 0 / negative simply skips those episodes — no junk code.
    assert {:ok, _} = Catalog.save_scene_offset_coordinates(series, 1, -5)
    assert offset_coords(series) == []
    assert Catalog.preview_scene_offset(Catalog.get_series_with_tree(series.id), 0, 1) == []
  end
end
