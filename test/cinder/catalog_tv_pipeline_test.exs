defmodule Cinder.CatalogTvPipelineTest do
  # async: false — create_grab/3 wraps a Repo.transaction; the SQLite sandbox needs shared
  # mode for nested transactions (same reason as catalog_series_test.exs).
  use Cinder.DataCase, async: false

  alias Cinder.Catalog
  alias Cinder.Catalog.{Episode, Grab, Season, Series}
  alias Ecto.Adapters.SQL, as: EctoSQL

  import Cinder.CatalogFixtures
  import Mox

  @past ~D[2001-01-01]
  @future ~D[2099-01-01]

  setup :verify_on_exit!

  @anime_preferences %{
    audio_mode: :dual,
    subtitle_languages: [" JPN ", "ja", "FRA"],
    embedded_subtitle_mode: :require,
    preferred_release_groups: [" SubsPlease ", "subsplease"],
    blocked_release_groups: [" BadGroup "],
    group_fallback_delay: 21_600
  }

  defp series_with_season do
    series = series_fixture(%{monitor_strategy: :all})
    season = season_fixture(series)
    {series, season}
  end

  defp episode(season, attrs) do
    episode_fixture(
      season,
      Map.merge(%{episode_number: System.unique_integer([:positive])}, attrs)
    )
  end

  defp anime_fixture!(name) do
    Path.join(["test", "support", "fixtures", "anime", name])
    |> File.read!()
    |> Jason.decode!()
  end

  defp episode_from_special_case!(case_data) do
    profile = String.to_existing_atom(case_data["profile"])
    classification = String.to_existing_atom(case_data["classification"])
    series = series_fixture(%{media_profile: profile})
    season = season_fixture(series, %{season_number: case_data["season"]})

    episode(season, %{
      episode_number: case_data["episode"],
      classification: classification,
      monitored: case_data["monitored"],
      air_date: if(case_data["aired"], do: @past, else: @future)
    })
  end

  defp wanted_ids, do: Enum.map(Catalog.wanted_episodes(), & &1.id)

  defp episode_by_tmdb_id(series, tmdb_episode_id) do
    series.id
    |> Catalog.get_series_with_tree()
    |> Map.fetch!(:seasons)
    |> Enum.flat_map(& &1.episodes)
    |> Enum.find(&(&1.tmdb_episode_id == tmdb_episode_id))
  end

  describe "Anime preference persistence" do
    test "anime_preferences_changeset/2 exclusively casts and normalizes preferences" do
      changeset = Series.anime_preferences_changeset(%Series{}, @anime_preferences)

      assert changeset.valid?

      assert %Series{
               audio_mode: :dual,
               subtitle_languages: ["ja", "fr"],
               embedded_subtitle_mode: :require,
               preferred_release_groups: ["subsplease"],
               blocked_release_groups: ["badgroup"],
               group_fallback_delay: 21_600
             } = apply_changes(changeset)

      general =
        @anime_preferences
        |> Map.merge(%{tmdb_id: 1, title: "Ignored preferences"})
        |> Series.create_changeset()

      for field <- Map.keys(@anime_preferences), do: refute(get_change(general, field))
    end

    test "anime_preferences_changeset/2 rejects a negative fallback delay" do
      changeset = Series.anime_preferences_changeset(%Series{}, %{group_fallback_delay: -1})
      assert "must be greater than or equal to 0" in errors_on(changeset).group_fallback_delay
    end

    test "refresh, metadata, admin, and language changesets preserve stored preferences" do
      stored = struct(%Series{tmdb_id: 1, title: "Stored"}, @anime_preferences)
      replacements = Map.new(@anime_preferences, fn {key, _value} -> {key, nil} end)

      for changeset <- [
            Series.refresh_changeset(stored, Map.put(replacements, :title, "Provider")),
            Series.metadata_changeset(stored, replacements),
            Series.admin_changeset(stored, Map.put(replacements, :title, "Admin")),
            Series.language_changeset(
              stored,
              Map.put(replacements, :preferred_language, "any")
            )
          ],
          field <- Map.keys(@anime_preferences) do
        assert Map.fetch!(apply_changes(changeset), field) == Map.fetch!(stored, field)
      end
    end
  end

  describe "transition_episode/2" do
    test "sets a pipeline field, persists, and broadcasts {:series_updated, series_id}" do
      {series, season} = series_with_season()
      ep = episode(season, %{})
      series_id = series.id
      Catalog.subscribe_series()

      assert {:ok, ep} = Catalog.transition_episode(ep, %{file_path: "/library/x.mkv"})
      assert ep.file_path == "/library/x.mkv"
      assert_receive {:series_updated, ^series_id}
      assert Repo.get(Episode, ep.id).file_path == "/library/x.mkv"
    end
  end

  describe "grab lifecycle" do
    test "create_grab/3 links episodes, persists, and broadcasts" do
      {series, season} = series_with_season()
      e1 = episode(season, %{})
      e2 = episode(season, %{})
      series_id = series.id
      Catalog.subscribe_series()

      assert {:ok, grab} = Catalog.create_grab("HASH1", :torrent, [e1.id, e2.id])
      assert grab.download_id == "HASH1"
      assert grab.download_protocol == :torrent
      assert is_nil(grab.content_path)
      assert %Grab{release_policy_snapshot: nil} = grab
      assert_receive {:series_updated, ^series_id}

      assert Repo.get(Episode, e1.id).grab_id == grab.id
      assert Repo.get(Episode, e2.id).grab_id == grab.id
    end

    test "create_grab/4 persists the release_title on the grab" do
      {_series, season} = series_with_season()
      e1 = episode(season, %{})

      assert {:ok, grab} =
               Catalog.create_grab("HASH1", :torrent, [e1.id], "Show.S01.1080p.WEB-GRP")

      assert grab.release_title == "Show.S01.1080p.WEB-GRP"
      assert Repo.get(Grab, grab.id).release_title == "Show.S01.1080p.WEB-GRP"
    end

    test "mark_grab_downloaded/2 sets content_path, moves the grab between the lists, broadcasts" do
      {series, season} = series_with_season()
      e1 = episode(season, %{})
      {:ok, grab} = Catalog.create_grab("HASH2", :usenet, [e1.id])
      series_id = series.id
      # Subscribe after create_grab so we assert mark's broadcast, not create's.
      Catalog.subscribe_series()

      assert [%Grab{id: id}] = Catalog.list_grabs_downloading()
      assert id == grab.id
      assert Catalog.list_grabs_downloaded() == []

      assert {:ok, grab} = Catalog.mark_grab_downloaded(grab, "/downloads/pack")
      assert grab.content_path == "/downloads/pack"
      assert_receive {:series_updated, ^series_id}
      assert Catalog.list_grabs_downloading() == []
      assert [%Grab{id: ^id}] = Catalog.list_grabs_downloaded()
    end

    test "delete_grab/1 removes the grab and nilifies its episodes' grab_id" do
      {series, season} = series_with_season()
      e1 = episode(season, %{})
      series_id = series.id
      {:ok, grab} = Catalog.create_grab("HASH3", :torrent, [e1.id])
      Catalog.subscribe_series()

      assert {:ok, _} = Catalog.delete_grab(grab)
      assert_receive {:series_updated, ^series_id}
      assert Repo.get(Grab, grab.id) == nil
      assert Repo.get(Episode, e1.id).grab_id == nil
    end

    test "create_grab/3 does not link an unmonitored episode (post-cancel race guard)" do
      {_series, season} = series_with_season()
      e1 = episode(season, %{monitored: false})

      # The search pass snapshots wanted (monitored) episodes, then spends seconds in
      # indexer/client I/O — a cancel_series in that window unmonitors them. Linking
      # anyway would resurrect the download the user just cancelled.
      assert {:error, :no_episodes_linked} = Catalog.create_grab("H9", :torrent, [e1.id])
      assert Repo.get(Episode, e1.id).grab_id == nil
      assert Repo.all(Grab) == []
    end

    test "create_grab/3 does not re-link an episode another grab already owns" do
      {_series, season} = series_with_season()
      e1 = episode(season, %{})
      {:ok, first} = Catalog.create_grab("H1", :torrent, [e1.id])

      # e1 is already grabbed → nothing links → the whole grab rolls back (no orphan grab),
      # and e1 stays on the first grab.
      assert {:error, :no_episodes_linked} = Catalog.create_grab("H2", :torrent, [e1.id])
      assert Repo.get(Episode, e1.id).grab_id == first.id
      assert Repo.all(Grab) |> length() == 1
    end

    test "create_grab/3 links only the free episodes when some are already grabbed" do
      {_series, season} = series_with_season()
      taken = episode(season, %{})
      free = episode(season, %{})
      {:ok, _first} = Catalog.create_grab("H1", :torrent, [taken.id])

      # A partial set (one free, one taken) still succeeds, linking just the free episode.
      assert {:ok, second} = Catalog.create_grab("H2", :torrent, [taken.id, free.id])
      assert Repo.get(Episode, free.id).grab_id == second.id
      refute Repo.get(Episode, taken.id).grab_id == second.id
    end
  end

  describe "finish_grab/2" do
    # Quality maps carry the media-info capture lists too (import_episodes always sets them).
    @q1 %{
      resolution: "1080p",
      size: 5_000_000_000,
      language: nil,
      source: nil,
      audio_languages: ["eng"],
      embedded_subtitles: [],
      sidecar_subtitles: []
    }
    @q2 %{
      resolution: "720p",
      size: 3_000_000_000,
      language: "FRENCH",
      source: nil,
      audio_languages: ["fre"],
      embedded_subtitles: [],
      sidecar_subtitles: []
    }

    test "sets each imported episode's own file_path, clears grab_id, deletes the grab, broadcasts" do
      {series, season} = series_with_season()
      e1 = episode(season, %{})
      e2 = episode(season, %{})
      {:ok, grab} = Catalog.create_grab("H", :torrent, [e1.id, e2.id])
      series_id = series.id
      Catalog.subscribe_series()

      assert {:ok, _} =
               Catalog.finish_grab(grab, [
                 {e1.id, "/lib/s01e01.mkv", @q1},
                 {e2.id, "/lib/s01e02.mkv", @q2}
               ])

      assert_receive {:series_updated, ^series_id}

      r1 = Repo.get(Episode, e1.id)
      r2 = Repo.get(Episode, e2.id)
      # Distinct dests, not one path forced onto all.
      assert r1.file_path == "/lib/s01e01.mkv"
      assert r2.file_path == "/lib/s01e02.mkv"
      assert is_nil(r1.grab_id) and is_nil(r2.grab_id)
      assert Repo.get(Grab, grab.id) == nil
    end

    test "persists imported quality + media-info capture lists per episode" do
      {_series, season} = series_with_season()
      ep = episode(season, %{})
      dest = "/lib/s01e01.mkv"
      {:ok, grab} = Catalog.create_grab("H", :torrent, [ep.id])

      assert {:ok, _} =
               Catalog.finish_grab(grab, [
                 {ep.id, dest,
                  %{
                    resolution: "1080p",
                    size: 123,
                    language: "FRENCH",
                    source: "bluray",
                    audio_languages: ["fre", "eng"],
                    embedded_subtitles: ["eng"],
                    sidecar_subtitles: ["fr"]
                  }}
               ])

      r = Repo.get!(Episode, ep.id)
      assert r.file_path == dest
      assert r.imported_resolution == "1080p"
      assert r.imported_size == 123
      assert r.imported_language == "FRENCH"
      assert r.imported_source == "bluray"
      assert r.imported_audio_languages == ["fre", "eng"]
      assert r.imported_embedded_subtitles == ["eng"]
      assert r.imported_sidecar_subtitles == ["fr"]
    end

    test "partial pack: bumps search_attempts on the non-imported episode, deletes the grab" do
      {_series, season} = series_with_season()
      got = episode(season, %{})
      missing = episode(season, %{search_attempts: 2})
      {:ok, grab} = Catalog.create_grab("H", :torrent, [got.id, missing.id])

      assert {:ok, _} = Catalog.finish_grab(grab, [{got.id, "/lib/got.mkv", @q1}])

      assert Repo.get(Episode, got.id).file_path == "/lib/got.mkv"
      m = Repo.get(Episode, missing.id)
      assert is_nil(m.file_path)
      assert is_nil(m.grab_id)
      assert m.search_attempts == 3
      assert Repo.get(Grab, grab.id) == nil
    end

    test "announces a season only when its final aired episode imports" do
      Cinder.TestNotifier.subscribe()
      {series, season} = series_with_season()
      poster_path = series.poster_path
      first = episode(season, %{})
      final = episode(season, %{})
      {:ok, first_grab} = Catalog.create_grab("H1", :torrent, [first.id])

      assert {:ok, _} = Catalog.finish_grab(first_grab, [{first.id, "/lib/first.mkv", @q1}])
      refute_receive {:notify, {:season_available, _}}

      {:ok, final_grab} = Catalog.create_grab("H2", :torrent, [final.id])

      assert {:ok, _} = Catalog.finish_grab(final_grab, [{final.id, "/lib/final.mkv", @q2}])

      assert_receive {:notify,
                      {:season_available,
                       %{title: "Show", season_number: 1, poster_path: ^poster_path}}}
    end
  end

  describe "park_grab/1" do
    test "deletes the grab and bumps every linked episode's search_attempts" do
      {_series, season} = series_with_season()
      e1 = episode(season, %{search_attempts: 0})
      e2 = episode(season, %{search_attempts: 5})
      {:ok, grab} = Catalog.create_grab("H", :torrent, [e1.id, e2.id])

      assert {:ok, _} = Catalog.park_grab(grab)
      assert Repo.get(Episode, e1.id).search_attempts == 1
      assert Repo.get(Episode, e2.id).search_attempts == 6
      assert Repo.get(Grab, grab.id) == nil
    end
  end

  describe "grab/episode retry counters" do
    test "increment_grab_attempts/1 bumps download_attempts" do
      {_series, season} = series_with_season()
      {:ok, grab} = Catalog.create_grab("H", :torrent, [episode(season, %{}).id])

      assert :ok = Catalog.increment_grab_attempts(grab)
      assert Repo.get(Grab, grab.id).download_attempts == 1
    end

    test "mark_grab_downloaded/2 resets download_attempts to 0 at the download boundary" do
      {_series, season} = series_with_season()
      {:ok, grab} = Catalog.create_grab("H", :torrent, [episode(season, %{}).id])
      :ok = Catalog.increment_grab_attempts(grab)
      grab = Repo.get(Grab, grab.id)
      assert grab.download_attempts == 1

      assert {:ok, grab} = Catalog.mark_grab_downloaded(grab, "/downloads/x")
      assert grab.download_attempts == 0
    end

    test "increment_search_attempts/1 bumps the given episodes; empty list is a no-op" do
      {_series, season} = series_with_season()
      e1 = episode(season, %{search_attempts: 0})
      e2 = episode(season, %{search_attempts: 3})

      assert :ok = Catalog.increment_search_attempts([e1.id, e2.id])
      assert Repo.get(Episode, e1.id).search_attempts == 1
      assert Repo.get(Episode, e2.id).search_attempts == 4

      assert :ok = Catalog.increment_search_attempts([])
    end
  end

  describe "wanted_episodes/0 index" do
    test "is backed by the partial wanted index (no full episodes scan)" do
      %{rows: idx_rows} =
        Repo.query!("SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='episodes'")

      assert "episodes_wanted_index" in List.flatten(idx_rows)

      q =
        from e in Episode,
          join: s in assoc(e, :season),
          join: series in assoc(s, :series),
          where:
            e.monitored == true and is_nil(e.file_path) and is_nil(e.grab_id) and
              not is_nil(e.air_date) and e.air_date <= ^Date.utc_today(),
          where:
            (s.season_number > 0 and e.episode_number > 0) or
              (series.media_profile == :anime and
                 e.classification in [:story_special, :recap]),
          select: e.id

      {sql, params} = EctoSQL.to_sql(:all, Repo, q)
      %{rows: plan_rows} = Repo.query!("EXPLAIN QUERY PLAN " <> sql, params)
      plan = Enum.map_join(plan_rows, "\n", &Enum.join(&1, " "))

      refute plan =~ ~r/SCAN episodes\b/, "wanted query should not full-scan episodes:\n#{plan}"
    end
  end

  describe "wanted_episodes/0" do
    test "matches the versioned Anime specials eligibility matrix" do
      assert anime_fixture!("specials-v1.json")["version"] == 1

      for case_data <- anime_fixture!("specials-v1.json")["cases"] do
        episode = episode_from_special_case!(case_data)
        assert episode.id in wanted_ids() == case_data["wanted"], case_data["id"]
      end
    end

    test "excludes Anime specials already owned by a grab or imported" do
      series = series_fixture(%{media_profile: :anime})
      specials = season_fixture(series, %{season_number: 0})

      owned =
        episode(specials, %{
          episode_number: 20,
          classification: :story_special,
          monitored: true
        })

      imported =
        episode(specials, %{
          episode_number: 21,
          classification: :recap,
          monitored: true,
          file_path: "/library/special.mkv"
        })

      assert {:ok, _grab} = Catalog.create_grab("special-owned", :torrent, [owned.id])
      refute owned.id in wanted_ids()
      refute imported.id in wanted_ids()
    end

    test "new provider-classified specials default unmonitored and refresh preserves an operator toggle" do
      tmdb_id = System.unique_integer([:positive])
      calls = start_supervised!({Agent, fn -> 0 end})

      stub(Cinder.Catalog.TMDBMock, :get_series, fn ^tmdb_id ->
        {:ok,
         %{
           tmdb_id: tmdb_id,
           tvdb_id: 77,
           title: "Anime",
           year: 2026,
           poster_path: nil,
           original_language: "ja",
           seasons: [%{season_number: 0}]
         }}
      end)

      stub(Cinder.Catalog.TMDBMock, :get_season, fn ^tmdb_id, 0 ->
        refresh? = Agent.get_and_update(calls, &{&1 > 0, &1 + 1})

        episodes = [
          %{tmdb_episode_id: 7001, episode_number: 1, title: "OVA", air_date: @past},
          %{tmdb_episode_id: 7003, episode_number: 3, title: "NCOP", air_date: @past}
        ]

        episodes =
          if refresh? do
            episodes ++
              [%{tmdb_episode_id: 7002, episode_number: 2, title: "Recap", air_date: @past}]
          else
            episodes
          end

        {:ok, %{season_number: 0, episodes: episodes}}
      end)

      stub(Cinder.Catalog.TMDBMock, :get_series_alternative_titles, fn ^tmdb_id -> {:ok, []} end)
      stub(Cinder.Catalog.TMDBMock, :get_episode_groups, fn ^tmdb_id -> {:ok, []} end)

      assert {:ok, series} =
               Catalog.add_series(tmdb_id, monitor_strategy: :all, media_profile: :anime)

      special = episode_by_tmdb_id(series, 7001)
      refute special.monitored
      assert special.classification == :story_special
      assert special.classification_source == "tmdb"

      extra = episode_by_tmdb_id(series, 7003)
      refute extra.monitored
      assert extra.classification == :extra
      assert extra.classification_source == "tmdb"

      assert {:ok, _} = Catalog.set_episode_monitored(special, true)
      assert {:ok, _} = Catalog.refresh_series(series)
      assert Repo.reload!(special).monitored

      recap = episode_by_tmdb_id(series, 7002)
      refute recap.monitored
      assert recap.classification == :recap
      assert recap.classification_source == "tmdb"

      assert {:ok, _} = Catalog.set_episode_classification(Repo.reload!(special), :recap, "OVA")
      assert Repo.reload!(special).monitored
    end

    test "returns monitored, aired (incl. today), file-less, grab-less episodes only" do
      {_series, season} = series_with_season()
      past = episode(season, %{air_date: @past, monitored: true})
      today = episode(season, %{air_date: Date.utc_today(), monitored: true})
      unaired = episode(season, %{air_date: @future, monitored: true})
      tba = episode(season, %{air_date: nil, monitored: true})
      unmonitored = episode(season, %{air_date: @past, monitored: false})

      ids = Enum.map(Catalog.wanted_episodes(), & &1.id)
      assert Enum.sort(ids) == Enum.sort([past.id, today.id])
      refute unaired.id in ids
      refute tba.id in ids
      refute unmonitored.id in ids
    end

    test "excludes a non-positive episode_number (a real episode is always >= 1)" do
      {_series, season} = series_with_season()
      ok = episode(season, %{episode_number: 1, air_date: @past, monitored: true})
      stranded = episode(season, %{episode_number: -7, air_date: @past, monitored: true})

      ids = Enum.map(Catalog.wanted_episodes(), & &1.id)
      assert ok.id in ids
      refute stranded.id in ids
    end

    test "excludes episodes with a file or an active grab" do
      {_series, season} = series_with_season()
      imported = episode(season, %{})
      grabbed = episode(season, %{})
      free = episode(season, %{})

      {:ok, _} = Catalog.transition_episode(imported, %{file_path: "/x.mkv"})
      {:ok, _} = Catalog.create_grab("H", :torrent, [grabbed.id])

      assert Enum.map(Catalog.wanted_episodes(), & &1.id) == [free.id]
    end

    test "preloads season and series for the poller" do
      {series, season} = series_with_season()
      episode(season, %{})

      assert [ep] = Catalog.wanted_episodes()
      assert ep.season.id == season.id
      assert ep.season.series.id == series.id
    end

    test "keeps Standard season 0 excluded" do
      {series, season} = series_with_season()
      regular = episode(season, %{air_date: @past, monitored: true})
      specials = Repo.insert!(%Season{series_id: series.id, season_number: 0, monitored: true})

      special =
        episode(specials, %{
          air_date: @past,
          monitored: true,
          classification: :story_special
        })

      ids = Enum.map(Catalog.wanted_episodes(), & &1.id)
      assert regular.id in ids
      refute special.id in ids
    end
  end

  describe "upcoming_episodes/0" do
    test "returns monitored, dated, in-window, non-special episodes ordered by air_date" do
      {series, season} = series_with_season()
      today = Date.utc_today()
      recent = episode(season, %{air_date: Date.add(today, -3), monitored: true})
      soon = episode(season, %{air_date: Date.add(today, 10), monitored: true})

      # Excluded: before the window, after the window, undated, unmonitored, specials.
      episode(season, %{air_date: Date.add(today, -30), monitored: true})
      episode(season, %{air_date: Date.add(today, 200), monitored: true})
      episode(season, %{air_date: nil, monitored: true})
      episode(season, %{air_date: Date.add(today, 5), monitored: false})
      specials = Repo.insert!(%Season{series_id: series.id, season_number: 0, monitored: true})
      episode(specials, %{air_date: Date.add(today, 2), monitored: true})

      assert Enum.map(Catalog.upcoming_episodes(), & &1.id) == [recent.id, soon.id]
    end

    test "preloads season and series" do
      {series, season} = series_with_season()
      episode(season, %{air_date: Date.utc_today()})

      assert [ep] = Catalog.upcoming_episodes()
      assert ep.season.series.id == series.id
    end
  end
end
