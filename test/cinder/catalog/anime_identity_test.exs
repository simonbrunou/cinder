defmodule Cinder.Catalog.AnimeIdentityTest do
  use Cinder.DataCase, async: false

  import Mox
  import Cinder.CatalogFixtures

  # The scene-numbering tests' Specials subgroup deliberately references episodes outside this
  # fixture's tree (skip-and-log, see frieren_seasons_group_detail/1), and one test exercises the
  # logged fetch-failure path — both expected, not noise.
  @moduletag :capture_log

  alias Cinder.Catalog
  alias Cinder.Catalog.Identity

  setup :verify_on_exit!

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

  # Exercises put_coordinate_or_rollback/3 through its live caller (the TMDB refresh path goes
  # Catalog.sync_absolute_coordinates → Identity.replace_provider_coordinates), the same direct
  # Identity seam tv_poller_test uses for replace_provider_aliases.
  describe "episode identity" do
    test "a provider coordinate cannot claim an episode from another series" do
      a = series_fixture()
      b = series_fixture()
      episode = b |> season_fixture() |> episode_fixture()

      assert {:error, :episode_series_mismatch} =
               Identity.replace_provider_coordinates(a, "tmdb", "group-1", [
                 %{
                   scheme: "absolute",
                   canonical_value: "12",
                   precedence: :inferred,
                   episode_ids: [episode.id]
                 }
               ])

      assert Catalog.list_episode_coordinates(a) == []
    end

    test "provider coordinates preserve caller-supplied membership order" do
      series = series_fixture()
      season = season_fixture(series)
      first = episode_fixture(season, episode_number: 1)
      second = episode_fixture(season, episode_number: 2)

      assert {:ok, [coordinate]} =
               Identity.replace_provider_coordinates(series, "tmdb", "group-1", [
                 %{
                   scheme: "combined",
                   canonical_value: "1-2",
                   precedence: :inferred,
                   episode_ids: [second.id, first.id]
                 }
               ])

      assert Enum.map(coordinate.memberships, & &1.position) == [0, 1]
      assert Enum.map(coordinate.memberships, & &1.episode_id) == [second.id, first.id]

      assert [listed] = Catalog.list_episode_coordinates(series)
      assert Enum.map(listed.memberships, & &1.episode_id) == [second.id, first.id]
    end
  end

  # A6: alternate-season numbering via an operator-chosen TMDB episode group. Mirrors the
  # Frieren case that motivated the feature — TMDB folds all 38 episodes into one season, a
  # "Seasons" (Production) episode group splits Specials(26)/Season 1(28)/Season 2(10), and
  # real releases are numbered against that split.
  describe "scene numbering (A6)" do
    setup do
      series = series_fixture(tvdb_id: 555_555)
      season = season_fixture(series, %{season_number: 1})

      episodes =
        for n <- 1..38 do
          episode_fixture(season, %{tmdb_episode_id: 90_000 + n, episode_number: n})
        end

      %{series: series, episodes: episodes, group_id: "seasons-group"}
    end

    test "choosing the group syncs S02E01..E10 to episodes 29-38 and a refresh preserves a manual correction",
         %{series: series, episodes: episodes, group_id: group_id} do
      ep29 = Enum.at(episodes, 28)
      ep38 = Enum.at(episodes, 37)
      detail = frieren_seasons_group_detail(group_id)

      expect(Cinder.Catalog.TMDBMock, :get_episode_group, fn ^group_id -> {:ok, detail} end)

      assert {:ok, updated} = Catalog.set_scene_numbering_group(series, group_id)
      assert updated.scene_numbering_group_id == group_id

      scene_coordinates =
        series |> Catalog.list_episode_coordinates() |> Enum.filter(&(&1.scheme == "scene"))

      assert length(scene_coordinates) == 38

      s02e01 = Enum.find(scene_coordinates, &(&1.canonical_value == "S02E01"))
      s02e10 = Enum.find(scene_coordinates, &(&1.canonical_value == "S02E10"))
      assert Enum.map(s02e01.memberships, & &1.episode_id) == [ep29.id]
      assert Enum.map(s02e10.memberships, & &1.episode_id) == [ep38.id]

      manual =
        episode_coordinate_fixture(
          series,
          %{
            source: "manual",
            scheme: "scene",
            namespace: "manual",
            canonical_value: "S02E99",
            precedence: :manual
          },
          [ep29.id]
        )

      expect(Cinder.Catalog.TMDBMock, :get_series, fn tmdb_id ->
        {:ok, minimal_series_info(series, tmdb_id)}
      end)

      expect(Cinder.Catalog.TMDBMock, :get_season, fn _tmdb_id, 1 ->
        {:ok, minimal_season_info(episodes)}
      end)

      expect(Cinder.Catalog.TMDBMock, :get_series_alternative_titles, fn _ -> {:ok, []} end)
      expect(Cinder.Catalog.TMDBMock, :get_episode_groups, fn _ -> {:ok, []} end)
      expect(Cinder.Catalog.TMDBMock, :get_episode_group, fn ^group_id -> {:ok, detail} end)

      assert {:ok, _} = Catalog.refresh_series(Repo.reload!(series))

      coordinates_after = Catalog.list_episode_coordinates(series)
      assert Enum.any?(coordinates_after, &(&1.id == manual.id))

      assert Enum.any?(
               coordinates_after,
               &(&1.scheme == "scene" and &1.canonical_value == "S02E01")
             )
    end

    # Finding 2 regression: the preview must show the order-derived S02E01..E10 Save actually
    # persists, not TMDB's raw canonical episode_number (29-38) — and must count only entries
    # matched to a real Cinder episode, surfacing the rest via unmatched_count instead.
    test "preview reads the order-derived scene numbering and excludes unmatched entries",
         %{series: series, group_id: group_id} do
      detail = frieren_seasons_group_detail(group_id)
      series = Catalog.get_series_with_tree(series.id)

      preview = Catalog.preview_scene_mapping(detail, series)

      season2 = Enum.find(preview, &(&1.season_number == 2))
      assert season2.alt_range == {1, 10}
      assert season2.canonical_range == {29, 38}
      assert season2.count == 10
      assert season2.unmatched_count == 0

      season1 = Enum.find(preview, &(&1.season_number == 1))
      assert season1.alt_range == {1, 28}
      assert season1.canonical_range == {1, 28}

      specials = Enum.find(preview, &(&1.season_number == 0))
      assert specials.count == 0
      assert specials.unmatched_count == 26
      assert specials.alt_range == nil
      assert specials.canonical_range == nil
    end

    test "switching groups clears the previous namespace, and clearing removes the rest",
         %{series: series, episodes: episodes, group_id: group_id} do
      ep1 = hd(episodes)

      single_entry_detail = fn id ->
        %{
          id: id,
          type: 6,
          name: "Seasons",
          entries: [
            %{
              tmdb_episode_id: ep1.tmdb_episode_id,
              group_name: "Season 1",
              group_order: 1,
              order: 0,
              season_number: 1,
              episode_number: 1
            }
          ]
        }
      end

      expect(Cinder.Catalog.TMDBMock, :get_episode_group, fn ^group_id ->
        {:ok, single_entry_detail.(group_id)}
      end)

      assert {:ok, series} = Catalog.set_scene_numbering_group(series, group_id)
      assert [_] = series |> Catalog.list_episode_coordinates() |> scene_only()

      other_group_id = "other-group"

      expect(Cinder.Catalog.TMDBMock, :get_episode_group, fn ^other_group_id ->
        {:ok, single_entry_detail.(other_group_id)}
      end)

      assert {:ok, series} = Catalog.set_scene_numbering_group(series, other_group_id)
      remaining = series |> Catalog.list_episode_coordinates() |> scene_only()
      assert [%{namespace: ^other_group_id}] = remaining

      assert {:ok, cleared} = Catalog.set_scene_numbering_group(series, nil)
      assert cleared.scene_numbering_group_id == nil
      assert cleared |> Catalog.list_episode_coordinates() |> scene_only() == []
    end

    test "a fetch failure keeps the last-synced rows and does not clobber the column",
         %{series: series, episodes: episodes, group_id: group_id} do
      detail = frieren_seasons_group_detail(group_id)

      expect(Cinder.Catalog.TMDBMock, :get_episode_group, fn ^group_id -> {:ok, detail} end)
      assert {:ok, series} = Catalog.set_scene_numbering_group(series, group_id)
      before_failure = series |> Catalog.list_episode_coordinates() |> scene_only()
      assert before_failure != []

      expect(Cinder.Catalog.TMDBMock, :get_series, fn tmdb_id ->
        {:ok, minimal_series_info(series, tmdb_id)}
      end)

      expect(Cinder.Catalog.TMDBMock, :get_season, fn _tmdb_id, 1 ->
        {:ok, minimal_season_info(episodes)}
      end)

      expect(Cinder.Catalog.TMDBMock, :get_series_alternative_titles, fn _ -> {:ok, []} end)
      expect(Cinder.Catalog.TMDBMock, :get_episode_groups, fn _ -> {:ok, []} end)

      expect(Cinder.Catalog.TMDBMock, :get_episode_group, fn ^group_id -> {:error, :not_found} end)

      assert {:ok, refreshed} = Catalog.refresh_series(Repo.reload!(series))
      assert refreshed.scene_numbering_group_id == group_id

      after_failure = refreshed |> Catalog.list_episode_coordinates() |> scene_only()
      assert coordinate_fingerprints(after_failure) == coordinate_fingerprints(before_failure)
    end
  end

  defp scene_only(coordinates), do: Enum.filter(coordinates, &(&1.scheme == "scene"))

  defp coordinate_fingerprints(coordinates) do
    coordinates
    |> Enum.map(fn coordinate ->
      {coordinate.namespace, coordinate.canonical_value,
       Enum.map(coordinate.memberships, & &1.episode_id)}
    end)
    |> Enum.sort()
  end

  # A "Seasons" (type 6) episode group shaped like Frieren's real payload: Specials(26, order 0)
  # / Season 1(28, order 1) / Season 2(10, order 2). Specials' tmdb_episode_ids deliberately
  # match no Cinder episode (season 0 isn't in this fixture's tree) — proving the skip-and-log
  # path never voids the sync for the rest of the group.
  defp frieren_seasons_group_detail(group_id) do
    specials =
      for i <- 0..25 do
        %{
          tmdb_episode_id: 80_000 + i,
          group_name: "Specials",
          group_order: 0,
          order: i,
          season_number: 0,
          episode_number: i + 1
        }
      end

    season1 =
      for i <- 0..27 do
        %{
          tmdb_episode_id: 90_000 + i + 1,
          group_name: "Season 1",
          group_order: 1,
          order: i,
          season_number: 1,
          episode_number: i + 1
        }
      end

    season2 =
      for i <- 0..9 do
        %{
          tmdb_episode_id: 90_000 + 28 + i + 1,
          group_name: "Season 2",
          group_order: 2,
          order: i,
          season_number: 1,
          episode_number: 29 + i
        }
      end

    %{id: group_id, type: 6, name: "Seasons", entries: specials ++ season1 ++ season2}
  end

  defp minimal_series_info(series, tmdb_id) do
    %{
      tmdb_id: tmdb_id,
      tvdb_id: series.tvdb_id,
      title: series.title,
      year: series.year,
      poster_path: nil,
      original_language: nil,
      overview: nil,
      genres: nil,
      vote_average: nil,
      first_air_date: nil,
      seasons: [%{season_number: 1}]
    }
  end

  defp minimal_season_info(episodes) do
    %{
      season_number: 1,
      episodes:
        for episode <- episodes do
          %{
            tmdb_episode_id: episode.tmdb_episode_id,
            episode_number: episode.episode_number,
            title: nil,
            air_date: nil
          }
        end
    }
  end
end
