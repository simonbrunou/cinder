defmodule Cinder.Catalog.AnimeIdentityTest do
  use Cinder.DataCase, async: false

  import Cinder.CatalogFixtures

  alias Cinder.Catalog

  describe "media profiles" do
    test "explicit profiles win and weak evidence only suggests anime" do
      movie = movie_fixture(original_language: "ja")
      series = series_fixture(original_language: "ja", genres: ["Animation"])

      assert {:ok, movie} = Catalog.set_media_profile(movie, :standard)

      assert Catalog.media_profile_summary(movie) == %{
               selected: :standard,
               effective: :standard,
               suggestion: nil,
               evidence: [:explicit_standard]
             }

      assert Catalog.media_profile_summary(series) == %{
               selected: :auto,
               effective: :standard,
               suggestion: :anime,
               evidence: [:japanese_animation]
             }

      assert {:ok, series} = Catalog.set_media_profile(series, :anime)
      assert Catalog.media_profile_summary(series).effective == :anime
    end

    test "a TMDB absolute coordinate is bounded weak evidence" do
      series = series_fixture()
      season = season_fixture(series)
      episode = episode_fixture(season)

      episode_coordinate_fixture(
        series,
        %{
          source: "tmdb",
          scheme: "absolute",
          namespace: "group-1",
          canonical_value: "1",
          precedence: :inferred
        },
        [episode.id]
      )

      assert Catalog.media_profile_summary(series) == %{
               selected: :auto,
               effective: :standard,
               suggestion: :anime,
               evidence: [:absolute_episode_group]
             }
    end
  end

  describe "title aliases" do
    test "manual aliases can be listed, updated, and deleted only through their owner" do
      movie = movie_fixture()
      other = movie_fixture()

      assert {:ok, alias_record} = Catalog.save_manual_alias(movie, %{title: "  Local   Title "})
      assert [listed] = Catalog.list_title_aliases(movie)
      assert listed.id == alias_record.id
      assert listed.normalized_title == "local title"

      assert {:error, :not_manual_alias} =
               Catalog.update_manual_alias(other, alias_record.id, %{title: "Forged"})

      assert {:ok, updated} =
               Catalog.update_manual_alias(movie, alias_record.id, %{title: "Local Rename"})

      assert updated.source == "manual"
      assert updated.namespace == "manual"
      assert updated.precedence == :manual

      assert {:error, :not_manual_alias} = Catalog.delete_manual_alias(other, alias_record.id)
      assert {:ok, _} = Catalog.delete_manual_alias(movie, alias_record.id)
      assert Catalog.list_title_aliases(movie) == []
    end

    test "a manual alias write broadcasts on its owner's topic so a second open tab sees it" do
      movie = movie_fixture()
      series = series_fixture()
      movie_id = movie.id
      series_id = series.id
      Catalog.subscribe()
      Catalog.subscribe_series()

      assert {:ok, alias_record} = Catalog.save_manual_alias(movie, %{title: "Alias"})
      assert_receive {:movie_updated, %{id: ^movie_id}}

      assert {:ok, _} = Catalog.save_manual_alias(series, %{title: "Alias"})
      assert_receive {:series_updated, ^series_id}

      assert {:ok, _} =
               Catalog.update_manual_alias(movie, alias_record.id, %{title: "Renamed"})

      assert_receive {:movie_updated, %{id: ^movie_id}}

      assert {:ok, _} = Catalog.delete_manual_alias(movie, alias_record.id)
      assert_receive {:movie_updated, %{id: ^movie_id}}
    end

    test "manual alias de-duplication uses the owner-specific partial index" do
      movie = movie_fixture()
      series = series_fixture()

      assert {:ok, _} = Catalog.save_manual_alias(movie, %{title: "Alias"})
      assert {:error, changeset} = Catalog.save_manual_alias(movie, %{title: " alias "})
      refute changeset.valid?

      assert {:ok, _} = Catalog.save_manual_alias(series, %{title: "Alias"})
      assert length(Catalog.list_title_aliases(series)) == 1
    end
  end
end
