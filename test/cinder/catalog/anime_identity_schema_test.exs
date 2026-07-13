defmodule Cinder.Catalog.AnimeIdentitySchemaTest do
  use Cinder.DataCase, async: false

  alias Cinder.Catalog.{EpisodeCoordinate, EpisodeCoordinateMembership, Movie, Series, TitleAlias}
  import Cinder.CatalogFixtures

  test "movie and series profiles default to auto and explicit profiles cast" do
    movie = movie_fixture()
    series = series_fixture()

    assert movie.media_profile == :auto
    assert series.media_profile == :auto

    assert Movie.profile_changeset(movie, %{media_profile: :anime}).changes.media_profile ==
             :anime

    assert Series.profile_changeset(series, %{media_profile: :standard}).changes.media_profile ==
             :standard
  end

  test "a title alias must have exactly one owner" do
    movie = movie_fixture()
    series = series_fixture()

    assert {:error, _} =
             %TitleAlias{}
             |> TitleAlias.changeset(%{
               title: "Alias",
               source: "manual",
               namespace: "manual",
               kind: :alternative,
               precedence: :manual
             })
             |> Repo.insert()

    assert {:error, _} =
             %TitleAlias{movie_id: movie.id, series_id: series.id}
             |> TitleAlias.changeset(%{
               title: "Alias",
               source: "manual",
               namespace: "manual",
               kind: :alternative,
               precedence: :manual
             })
             |> Repo.insert()
  end

  test "duplicate movie aliases return a changeset error" do
    movie = movie_fixture()
    attrs = alias_attrs()

    Repo.insert!(TitleAlias.changeset(%TitleAlias{movie_id: movie.id}, attrs))

    assert {:error, changeset} =
             Repo.insert(TitleAlias.changeset(%TitleAlias{movie_id: movie.id}, attrs))

    refute changeset.valid?
  end

  test "duplicate series aliases return a changeset error" do
    series = series_fixture()
    attrs = alias_attrs()

    Repo.insert!(TitleAlias.changeset(%TitleAlias{series_id: series.id}, attrs))

    assert {:error, changeset} =
             Repo.insert(TitleAlias.changeset(%TitleAlias{series_id: series.id}, attrs))

    refute changeset.valid?
  end

  test "coordinate membership is ordered and unique" do
    series = series_fixture()
    season = season_fixture(series)
    episode = episode_fixture(season)

    coordinate =
      Repo.insert!(
        EpisodeCoordinate.changeset(%EpisodeCoordinate{series_id: series.id}, %{
          source: "fixture",
          scheme: "absolute",
          namespace: "fixture",
          canonical_value: "12",
          precedence: :inferred
        })
      )

    membership = %EpisodeCoordinateMembership{
      episode_coordinate_id: coordinate.id,
      episode_id: episode.id
    }

    Repo.insert!(EpisodeCoordinateMembership.changeset(membership, %{position: 0}))

    assert {:error, _} =
             Repo.insert(EpisodeCoordinateMembership.changeset(membership, %{position: 0}))
  end

  defp alias_attrs do
    %{
      title: "Alias",
      source: "manual",
      namespace: "manual",
      kind: :alternative,
      precedence: :manual
    }
  end
end
