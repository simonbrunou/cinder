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
               Identity.replace_provider_coordinates(a, "tmdb", "group-1", "absolute", [
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
               Identity.replace_provider_coordinates(series, "tmdb", "group-1", "combined", [
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

    # A6 lets "absolute" and "scene" schemes share one namespace (an operator can pick the same
    # TMDB group id for both purposes), so the delete each resync issues must not wipe the other
    # scheme's rows.
    test "absolute and scene coordinates under the same namespace coexist independently" do
      series = series_fixture()
      season = season_fixture(series)
      episode = episode_fixture(season, episode_number: 1)
      namespace = "shared-group"

      assert {:ok, _} =
               Identity.replace_provider_coordinates(series, "tmdb", namespace, "absolute", [
                 %{
                   scheme: "absolute",
                   canonical_value: "1",
                   precedence: :inferred,
                   episode_ids: [episode.id]
                 }
               ])

      assert {:ok, _} =
               Identity.replace_provider_coordinates(series, "tmdb", namespace, "scene", [
                 %{
                   scheme: "scene",
                   canonical_value: "S01E01",
                   precedence: :inferred,
                   episode_ids: [episode.id]
                 }
               ])

      coordinates = Catalog.list_episode_coordinates(series)
      assert length(coordinates) == 2
      assert Enum.any?(coordinates, &(&1.scheme == "absolute" and &1.canonical_value == "1"))
      assert Enum.any?(coordinates, &(&1.scheme == "scene" and &1.canonical_value == "S01E01"))

      # Re-syncing scene must not touch the absolute row under the same namespace.
      assert {:ok, _} =
               Identity.replace_provider_coordinates(series, "tmdb", namespace, "scene", [
                 %{
                   scheme: "scene",
                   canonical_value: "S01E02",
                   precedence: :inferred,
                   episode_ids: [episode.id]
                 }
               ])

      coordinates_after = Catalog.list_episode_coordinates(series)
      assert length(coordinates_after) == 2

      assert Enum.any?(
               coordinates_after,
               &(&1.scheme == "absolute" and &1.canonical_value == "1")
             )

      assert Enum.any?(
               coordinates_after,
               &(&1.scheme == "scene" and &1.canonical_value == "S01E02")
             )
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

    # Finding 2: unlike the refresh path's drift rule (a fetch failure keeps last-synced rows,
    # exercised above), a *save-time* fetch failure has nothing yet synced for the newly-chosen
    # group — committing the column would silently strand it at zero coordinates while reporting
    # success. It must error out before any transaction opens instead.
    test "a save-time fetch failure returns an error and persists nothing",
         %{series: series, group_id: group_id} do
      expect(Cinder.Catalog.TMDBMock, :get_episode_group, fn ^group_id -> {:error, :not_found} end)

      assert {:error, :group_fetch_failed} = Catalog.set_scene_numbering_group(series, group_id)

      reloaded = Repo.reload!(series)
      assert reloaded.scene_numbering_group_id == nil
      assert Catalog.list_episode_coordinates(reloaded) == []
    end

    # R2 finding 3: the round-1 fail-loud fix overshot — re-saving the group that is ALREADY the
    # persisted current group during a TMDB blip is a harmless no-op (nothing was going to
    # change), not an error. Existing coordinates must survive untouched.
    test "re-saving the already-current group during a TMDB blip is a logged no-op, coordinates intact",
         %{series: series, group_id: group_id} do
      detail = frieren_seasons_group_detail(group_id)

      expect(Cinder.Catalog.TMDBMock, :get_episode_group, fn ^group_id -> {:ok, detail} end)
      assert {:ok, series} = Catalog.set_scene_numbering_group(series, group_id)
      before_resave = series |> Catalog.list_episode_coordinates() |> scene_only()
      assert before_resave != []

      expect(Cinder.Catalog.TMDBMock, :get_episode_group, fn ^group_id -> {:error, :timeout} end)

      assert {:ok, resaved} = Catalog.set_scene_numbering_group(series, group_id)
      assert resaved.scene_numbering_group_id == group_id

      after_resave = resaved |> Catalog.list_episode_coordinates() |> scene_only()
      assert coordinate_fingerprints(after_resave) == coordinate_fingerprints(before_resave)
    end

    # R2 finding 3: unlike a same-group re-save (above), choosing a NEW/different group still
    # fails loud on a fetch failure — nothing is synced yet for it, and the currently-configured
    # group's own coordinates must be left exactly as they were.
    test "a fetch failure choosing a genuinely different group still fails loud and persists nothing",
         %{series: series, group_id: group_id} do
      detail = frieren_seasons_group_detail(group_id)

      expect(Cinder.Catalog.TMDBMock, :get_episode_group, fn ^group_id -> {:ok, detail} end)
      assert {:ok, series} = Catalog.set_scene_numbering_group(series, group_id)
      before_attempt = series |> Catalog.list_episode_coordinates() |> scene_only()

      other_group_id = "other-group"

      expect(Cinder.Catalog.TMDBMock, :get_episode_group, fn ^other_group_id ->
        {:error, :timeout}
      end)

      assert {:error, :group_fetch_failed} =
               Catalog.set_scene_numbering_group(series, other_group_id)

      reloaded = Repo.reload!(series)
      assert reloaded.scene_numbering_group_id == group_id

      after_attempt = reloaded |> Catalog.list_episode_coordinates() |> scene_only()
      assert coordinate_fingerprints(after_attempt) == coordinate_fingerprints(before_attempt)
    end

    # Finding 5: `previous` must come from a fresh DB read, not the caller's in-memory struct —
    # otherwise a second writer holding a stale struct clears a bygone namespace instead of the
    # one actually current, orphaning it.
    test "set_scene_numbering_group clears the actually-current namespace even from a stale caller struct",
         %{series: series, episodes: episodes, group_id: group_id} do
      ep1 = hd(episodes)
      ep2 = Enum.at(episodes, 1)
      ep3 = Enum.at(episodes, 2)

      entry_for = fn tmdb_episode_id ->
        %{
          tmdb_episode_id: tmdb_episode_id,
          group_name: "Season 1",
          group_order: 1,
          order: 0,
          season_number: 1,
          episode_number: 1
        }
      end

      expect(Cinder.Catalog.TMDBMock, :get_episode_group, fn ^group_id ->
        {:ok,
         %{id: group_id, type: 6, name: "Seasons", entries: [entry_for.(ep1.tmdb_episode_id)]}}
      end)

      assert {:ok, session_a} = Catalog.set_scene_numbering_group(series, group_id)
      # `session_b` is loaded before session A's write and never refreshed — still carrying
      # `scene_numbering_group_id: group_id` in memory once session A has moved it on.
      session_b = series

      group_y = "group-y"
      group_z = "group-z"

      expect(Cinder.Catalog.TMDBMock, :get_episode_group, fn ^group_y ->
        {:ok,
         %{id: group_y, type: 6, name: "Seasons", entries: [entry_for.(ep2.tmdb_episode_id)]}}
      end)

      assert {:ok, _session_a} = Catalog.set_scene_numbering_group(session_a, group_y)

      expect(Cinder.Catalog.TMDBMock, :get_episode_group, fn ^group_z ->
        {:ok,
         %{id: group_z, type: 6, name: "Seasons", entries: [entry_for.(ep3.tmdb_episode_id)]}}
      end)

      assert {:ok, final} = Catalog.set_scene_numbering_group(session_b, group_z)
      assert final.scene_numbering_group_id == group_z

      remaining = final |> Catalog.list_episode_coordinates() |> scene_only()
      assert Enum.map(remaining, & &1.namespace) == [group_z]
    end

    # Finding 12: a caller (the series-detail picker) that already fetched the group detail for
    # its own preview can pass it straight through, skipping a redundant TMDB round trip — but
    # only when it matches the group id being saved.
    test "set_scene_numbering_group/3 reuses a pre-fetched detail for the same group id",
         %{series: series, group_id: group_id} do
      detail = frieren_seasons_group_detail(group_id)

      # No `get_episode_group` expectation at all — proves the passed-in detail is used as-is
      # rather than re-fetched.
      assert {:ok, updated} = Catalog.set_scene_numbering_group(series, group_id, detail: detail)
      assert updated.scene_numbering_group_id == group_id

      scene_coordinates = updated |> Catalog.list_episode_coordinates() |> scene_only()
      assert length(scene_coordinates) == 38
    end

    test "set_scene_numbering_group/3 ignores a pre-fetched detail for a different group id and fetches fresh",
         %{series: series, group_id: group_id} do
      mismatched_detail = %{id: "some-other-group", type: 6, name: "Seasons", entries: []}
      fresh_detail = frieren_seasons_group_detail(group_id)

      expect(Cinder.Catalog.TMDBMock, :get_episode_group, fn ^group_id -> {:ok, fresh_detail} end)

      assert {:ok, updated} =
               Catalog.set_scene_numbering_group(series, group_id, detail: mismatched_detail)

      scene_coordinates = updated |> Catalog.list_episode_coordinates() |> scene_only()
      assert length(scene_coordinates) == 38
    end

    # Finding 4: refresh_series pre-fetches the scene group detail for whatever group id it read
    # before its transaction opened. If a racing save switches the series to a different group in
    # between, the transaction's fresh re-read sees the new group — the pre-fetched (now-stale)
    # detail must NOT be synced under that new namespace, or the racing save's own entries would
    # be silently overwritten with the wrong group's data.
    test "refresh_series skips the scene sync when the group changed mid-refresh, keeping the racing save's rows",
         %{series: series, episodes: episodes, group_id: group_id} do
      ep1 = hd(episodes)
      ep2 = Enum.at(episodes, 1)
      other_group_id = "other-group"

      entry_for = fn tmdb_episode_id, episode_number ->
        %{
          tmdb_episode_id: tmdb_episode_id,
          group_name: "Season 1",
          group_order: 1,
          order: episode_number - 1,
          season_number: 1,
          episode_number: episode_number
        }
      end

      expect(Cinder.Catalog.TMDBMock, :get_episode_group, fn ^group_id ->
        {:ok,
         %{id: group_id, type: 6, name: "Seasons", entries: [entry_for.(ep1.tmdb_episode_id, 1)]}}
      end)

      assert {:ok, stale_series} = Catalog.set_scene_numbering_group(series, group_id)
      assert stale_series.scene_numbering_group_id == group_id

      # A racing save commits after `stale_series` was read, switching the series to
      # `other_group_id` with its own (unrelated) entry.
      expect(Cinder.Catalog.TMDBMock, :get_episode_group, fn ^other_group_id ->
        {:ok,
         %{
           id: other_group_id,
           type: 6,
           name: "Seasons",
           entries: [entry_for.(ep2.tmdb_episode_id, 2)]
         }}
      end)

      assert {:ok, current} = Catalog.set_scene_numbering_group(stale_series, other_group_id)
      assert current.scene_numbering_group_id == other_group_id

      # refresh_series is called with the STALE struct (still `scene_numbering_group_id:
      # group_id`), so its identity fetch re-fetches group_id's (now-superseded) detail.
      expect(Cinder.Catalog.TMDBMock, :get_series, fn tmdb_id ->
        {:ok, minimal_series_info(current, tmdb_id)}
      end)

      expect(Cinder.Catalog.TMDBMock, :get_season, fn _tmdb_id, 1 ->
        {:ok, minimal_season_info(episodes)}
      end)

      expect(Cinder.Catalog.TMDBMock, :get_series_alternative_titles, fn _ -> {:ok, []} end)
      expect(Cinder.Catalog.TMDBMock, :get_episode_groups, fn _ -> {:ok, []} end)

      expect(Cinder.Catalog.TMDBMock, :get_episode_group, fn ^group_id ->
        {:ok,
         %{id: group_id, type: 6, name: "Seasons", entries: [entry_for.(ep1.tmdb_episode_id, 1)]}}
      end)

      assert {:ok, _} = Catalog.refresh_series(stale_series)

      scene_coordinates = current |> Catalog.list_episode_coordinates() |> scene_only()
      assert [only] = scene_coordinates
      assert only.namespace == other_group_id
      assert Enum.map(only.memberships, & &1.episode_id) == [ep2.id]
    end

    # Finding 6: a Story Arc-shaped group (type 5) can legitimately place the same episode in two
    # subgroups. Guessing which one is "right" would violate the anime program's safety
    # invariant, so both entries are dropped — never persisted as two conflicting coordinates for
    # the same episode.
    test "an episode claimed by more than one subgroup is dropped from both, not silently guessed",
         %{series: series, episodes: episodes, group_id: group_id} do
      ep1 = hd(episodes)
      ep2 = Enum.at(episodes, 1)

      detail = %{
        id: group_id,
        type: 5,
        name: "Story Arcs",
        entries: [
          %{
            tmdb_episode_id: ep1.tmdb_episode_id,
            group_name: "Arc A",
            group_order: 0,
            order: 0,
            season_number: 1,
            episode_number: 1
          },
          %{
            tmdb_episode_id: ep1.tmdb_episode_id,
            group_name: "Arc B",
            group_order: 1,
            order: 0,
            season_number: 1,
            episode_number: 1
          },
          %{
            tmdb_episode_id: ep2.tmdb_episode_id,
            group_name: "Arc A",
            group_order: 0,
            order: 1,
            season_number: 1,
            episode_number: 2
          }
        ]
      }

      expect(Cinder.Catalog.TMDBMock, :get_episode_group, fn ^group_id -> {:ok, detail} end)

      assert {:ok, updated} = Catalog.set_scene_numbering_group(series, group_id)

      scene_coordinates = updated |> Catalog.list_episode_coordinates() |> scene_only()

      refute Enum.any?(scene_coordinates, fn coordinate ->
               Enum.any?(coordinate.memberships, &(&1.episode_id == ep1.id))
             end)

      assert Enum.any?(scene_coordinates, fn coordinate ->
               Enum.any?(coordinate.memberships, &(&1.episode_id == ep2.id))
             end)

      # The picker's preview must surface the same ambiguity rather than drift from what Save
      # persisted (both read through derive_scene_entries/2).
      preview = Catalog.preview_scene_mapping(detail, Catalog.get_series_with_tree(series.id))
      assert Enum.sum(Enum.map(preview, & &1.unmatched_count)) >= 2
    end

    # R2 finding 2: the mirror case of the one above — two DIFFERENT tmdb_episode_ids (not the
    # same one twice) deriving the identical (season_number, episode_number) pair, e.g. a
    # name-parsed "Season 1" subgroup and an order-fallback subgroup both landing on season 1
    # with overlapping entry orders. Both entries are individually valid matches to a real
    # episode, so without a dedicated guard they'd both persist as "S01E01" for two different
    # episodes under one namespace. Both must be dropped instead, and surfaced in the preview's
    # unmatched count.
    test "two subgroups colliding on the derived season/episode are both dropped, not silently guessed",
         %{series: series, episodes: episodes, group_id: group_id} do
      ep1 = hd(episodes)
      ep2 = Enum.at(episodes, 1)

      detail = %{
        id: group_id,
        type: 5,
        name: "Story Arcs",
        entries: [
          %{
            tmdb_episode_id: ep1.tmdb_episode_id,
            group_name: "Season 1",
            group_order: 9,
            order: 0,
            season_number: 1,
            episode_number: 1
          },
          %{
            tmdb_episode_id: ep2.tmdb_episode_id,
            group_name: "OVA Batch",
            group_order: 1,
            order: 0,
            season_number: 1,
            episode_number: 1
          }
        ]
      }

      expect(Cinder.Catalog.TMDBMock, :get_episode_group, fn ^group_id -> {:ok, detail} end)

      assert {:ok, updated} = Catalog.set_scene_numbering_group(series, group_id)

      scene_coordinates = updated |> Catalog.list_episode_coordinates() |> scene_only()
      assert scene_coordinates == []

      preview = Catalog.preview_scene_mapping(detail, Catalog.get_series_with_tree(series.id))
      season1 = Enum.find(preview, &(&1.season_number == 1))
      assert season1.count == 0
      assert season1.unmatched_count == 2
    end

    # Finding 7: the season-number-from-subgroup-order fallback is a convention, not an API
    # guarantee — the preview must expose the raw subgroup name and whether the season came from
    # parsing that name or from the order fallback, so an unusual group is visibly flagged.
    test "preview exposes the raw subgroup name and whether its season came from the name or the order fallback",
         %{series: series, group_id: group_id} do
      detail = %{
        id: group_id,
        type: 6,
        name: "Seasons",
        entries: [
          %{
            tmdb_episode_id: 1,
            group_name: "Season 1",
            group_order: 1,
            order: 0,
            season_number: 1,
            episode_number: 1
          },
          %{
            tmdb_episode_id: 2,
            group_name: "OVA",
            group_order: 2,
            order: 0,
            season_number: 1,
            episode_number: 1
          }
        ]
      }

      preview = Catalog.preview_scene_mapping(detail, Catalog.get_series_with_tree(series.id))

      named = Enum.find(preview, &(&1.season_number == 1))
      assert named.season_source == :name
      assert named.group_name == "Season 1"

      fallback = Enum.find(preview, &(&1.season_number == 2))
      assert fallback.season_source == :order
      assert fallback.group_name == "OVA"
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
