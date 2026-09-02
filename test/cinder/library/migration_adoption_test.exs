defmodule Cinder.Library.MigrationAdoptionTest do
  use Cinder.DataCase, async: false

  import Mox

  alias Cinder.Catalog
  alias Cinder.Catalog.Adoption, as: CatalogAdoption
  alias Cinder.Catalog.{GrabFile, Identity, Movie}
  alias Cinder.Library.{Adoption, RadarrMigrationSourceMock, SonarrMigrationSourceMock}
  alias Cinder.Library.MigrationSource.Sonarr
  alias Cinder.Repo

  @fixture_path "test/support/fixtures/migration-provider-identity-v1.json"
  @cases @fixture_path |> File.read!() |> Jason.decode!() |> Map.fetch!("cases")

  setup :verify_on_exit!

  setup do
    stub(Cinder.Library.FilesystemMock, :lstat, fn _path -> {:ok, %File.Stat{}} end)
    :ok
  end

  test "a Radarr fixture previews and adopts a movie by TMDB id" do
    snapshot =
      "unique"
      |> fixture_snapshot()
      |> Map.update!(:movies, &Enum.take(&1, 1))
      |> Map.update!(:files, &Enum.filter(&1, fn file -> file.provider_id == 501 end))
      |> Map.merge(%{series: [], episodes: []})

    stub(RadarrMigrationSourceMock, :snapshot, fn -> {:ok, snapshot} end)

    stub(Cinder.Catalog.TMDBMock, :get_movie, fn 10 ->
      {:ok, movie_details(10)}
    end)

    assert {:ok, preview} = Adoption.preview_migration(:radarr)
    assert [%{status: :ready, tmdb_id: 10, key: key} = candidate] = preview.candidates

    assert %{adopted: 1, skipped: 0, failures: []} =
             Adoption.adopt_migration(:radarr, [%{key: key, candidate: candidate}])

    assert %Movie{status: :available, file_path: "/radarr/Movie One.mkv"} =
             Catalog.get_movie_by_tmdb_id(10)
  end

  for choice <- [:fold, :part] do
    test "a Sonarr TVDB split requires and applies #{choice}" do
      snapshot = fixture_snapshot("n_to_one")
      stub(SonarrMigrationSourceMock, :snapshot, fn -> {:ok, snapshot} end)
      stub_n_to_one_tmdb()

      assert {:ok, preview} = Adoption.preview_migration(:sonarr)

      assert [
               %{
                 status: :needs_decision,
                 primary_file: %{provider_id: 602},
                 extra_files: [%{provider_id: 603}],
                 key: key
               } = candidate
             ] = preview.candidates

      assert %{adopted: 1, skipped: 0, failures: []} =
               Adoption.adopt_migration(:sonarr, [
                 %{key: key, choice: unquote(choice), candidate: candidate}
               ])

      series = Catalog.get_series_by_tmdb_id(1100)
      [season] = Catalog.get_series_with_tree(series.id).seasons
      [episode] = season.episodes
      assert episode.file_path == "/sonarr/Show S04E15.mkv"

      expected_parts =
        if unquote(choice) == :part, do: ["/sonarr/Show S04E16.mkv"], else: []

      assert episode.part_file_paths == expected_parts

      coordinates = Identity.list_coordinates(series)

      assert MapSet.new(coordinates, &{&1.scheme, &1.canonical_value}) ==
               MapSet.new([
                 {"episode_id", "2001"},
                 {"episode_id", "2002"},
                 {"aired", "S04E15"},
                 {"aired", "S04E16"}
               ])
    end
  end

  test "a Sonarr TVDB split with a book-only choice (preferred/all_formats) is skipped, not adopted" do
    snapshot = fixture_snapshot("n_to_one")
    stub(SonarrMigrationSourceMock, :snapshot, fn -> {:ok, snapshot} end)
    stub_n_to_one_tmdb()

    assert {:ok, preview} = Adoption.preview_migration(:sonarr)
    assert [%{status: :needs_decision, key: key} = candidate] = preview.candidates

    # "preferred"/"all_formats" are Readarr's own multi-format choices — kind-scoped
    # `MigrationAdoption.selected_candidates/2` refuses them against an episode candidate rather
    # than silently applying whatever fold/part-shaped behavior `normalize_choice/1` would
    # otherwise default to.
    assert %{adopted: 0, skipped: 1, failures: []} =
             Adoption.adopt_migration(:sonarr, [
               %{key: key, choice: "preferred", candidate: candidate}
             ])

    series = Catalog.get_series_by_tmdb_id(1100)
    assert series == nil
  end

  test "a Fold coordinate survives re-running the Sonarr migration adoption" do
    snapshot = fixture_snapshot("n_to_one")
    stub(SonarrMigrationSourceMock, :snapshot, fn -> {:ok, snapshot} end)
    stub_n_to_one_tmdb()

    assert {:ok, preview} = Adoption.preview_migration(:sonarr)
    assert [%{key: key} = candidate] = preview.candidates

    assert %{adopted: 1, skipped: 0, failures: []} =
             Adoption.adopt_migration(:sonarr, [
               %{key: key, choice: :fold, candidate: candidate}
             ])

    series = Catalog.get_series_by_tmdb_id(1100)
    [season] = Catalog.get_series_with_tree(series.id).seasons
    [episode] = season.episodes

    assert {:ok, grab} =
             Catalog.create_grab(
               "fold-before-remigrate",
               :usenet,
               [episode.id],
               nil,
               allow_available: true
             )

    assert {:ok, grab} = Catalog.mark_grab_downloaded(grab, "/sonarr/fold-pack")

    file =
      Repo.insert!(%GrabFile{
        grab_id: grab.id,
        relative_path: "Show.S04E16.mkv",
        size: 5_000,
        device: 1,
        inode: 2,
        source: "tvdb",
        scheme: "aired",
        namespace: "200",
        canonical_value: "S04E16"
      })

    assert {:ok, :decided, _file} =
             Catalog.decide_grab_file(file, Repo.reload!(episode), :fold, nil)

    assert {:ok, :closed, _grab} = Catalog.close_grab(grab)

    manual =
      series
      |> Identity.list_coordinates()
      |> Enum.find(&(&1.scheme == "aired" and &1.canonical_value == "S04E16"))

    assert manual.precedence == :manual
    manual_id = manual.id
    episode_id = episode.id

    assert {:ok, [_action]} =
             CatalogAdoption.adopt_episode_files(
               [
                 %{
                   episode: Repo.reload!(episode),
                   episode_code: "S04E15",
                   path: "/sonarr/Show S04E15.mkv",
                   type: :primary
                 }
               ],
               [
                 %{
                   series: series,
                   source: "tvdb",
                   namespace: "200",
                   scheme: "aired",
                   coordinates: [
                     %{
                       scheme: "aired",
                       canonical_value: "S04E15",
                       precedence: :inferred,
                       episode_ids: [episode.id]
                     },
                     %{
                       scheme: "aired",
                       canonical_value: "S04E16",
                       precedence: :inferred,
                       episode_ids: [episode.id]
                     }
                   ]
                 }
               ]
             )

    assert %{
             id: ^manual_id,
             precedence: :manual,
             memberships: [%{episode_id: ^episode_id}]
           } =
             series
             |> Identity.list_coordinates()
             |> Enum.find(&(&1.scheme == "aired" and &1.canonical_value == "S04E16"))
  end

  test "zero-result and wrong-series fixture identities are blocked" do
    zero = fixture_snapshot("zero_result")
    wrong = fixture_snapshot("wrong_series")

    snapshot =
      for key <- [:movies, :series, :episodes, :files], into: %{} do
        {key, Map.fetch!(zero, key) ++ Map.fetch!(wrong, key)}
      end

    stub(SonarrMigrationSourceMock, :snapshot, fn -> {:ok, snapshot} end)

    stub(Cinder.Catalog.TMDBMock, :find_by_external_id, fn
      300, :tvdb_id -> {:ok, [%{type: :tv, tmdb_id: 1200, title: "Zero"}]}
      3001, :tvdb_id -> {:ok, []}
      500, :tvdb_id -> {:ok, [%{type: :tv, tmdb_id: 1400, title: "Wrong"}]}
      5001, :tvdb_id -> {:ok, [%{type: :episode, tmdb_episode_id: 2400, series_tmdb_id: 9999}]}
    end)

    assert {:ok, preview} = Adoption.preview_migration(:sonarr)
    assert preview.counts.blocked == 2
    assert Enum.all?(preview.candidates, &(&1.status == :blocked))

    assert MapSet.new(preview.candidates, & &1.reason) ==
             MapSet.new([:no_match, {:wrong_series, 1400, 9999}])
  end

  test "a timed-out Sonarr series is blocked without hiding the other series" do
    original_sources = Application.fetch_env!(:cinder, :migration_sources)

    Application.put_env(
      :cinder,
      :migration_sources,
      Map.put(original_sources, :sonarr, Sonarr)
    )

    on_exit(fn -> Application.put_env(:cinder, :migration_sources, original_sources) end)

    Req.Test.stub(Cinder.SonarrStub, fn conn ->
      case conn.request_path do
        "/api/v3/series" ->
          Req.Test.json(conn, [
            sonarr_series(1, 100, "First"),
            sonarr_series(2, 200, "Middle"),
            sonarr_series(3, 300, "Last")
          ])

        "/api/v3/episode" ->
          case conn.params["seriesId"] do
            "2" -> Req.Test.transport_error(conn, :timeout)
            id -> Req.Test.json(conn, [sonarr_episode(String.to_integer(id))])
          end
      end
    end)

    stub(Cinder.Catalog.TMDBMock, :find_by_external_id, fn
      id, :tvdb_id when id in [100, 300] ->
        {:ok, [%{type: :tv, tmdb_id: id * 10, title: if(id == 100, do: "First", else: "Last")}]}

      id, :tvdb_id when id in [1001, 3001] ->
        {:ok,
         [
           %{
             type: :episode,
             tmdb_episode_id: id * 10,
             series_tmdb_id: div(id, 1000) * 1000,
             season_number: 1,
             episode_number: 1
           }
         ]}
    end)

    assert {:ok, preview} = Adoption.preview_migration(:sonarr)
    assert preview.counts == %{ready: 2, needs_decision: 0, blocked: 1, already_managed: 0}

    assert %{status: :blocked, title: "Middle", reason: {:series_snapshot_failed, :timeout}} =
             Enum.find(preview.candidates, &(&1.series_provider_id == 2))

    assert MapSet.new(
             Enum.filter(preview.candidates, &(&1.status == :ready)),
             & &1.series_provider_id
           ) == MapSet.new([1, 3])
  end

  test "Sonarr planning loads one Cinder episode tree for many file candidates" do
    episode_count = 30
    stub_large_series_tmdb(episode_count)
    assert {:ok, _series} = Catalog.add_series(9_000, monitor_strategy: :none)

    snapshot = large_series_snapshot(episode_count)
    stub(SonarrMigrationSourceMock, :snapshot, fn -> {:ok, snapshot} end)

    {result, tree_queries} =
      count_episode_tree_queries(fn -> Adoption.preview_migration(:sonarr) end)

    assert {:ok, %{counts: %{ready: ^episode_count}}} = result
    assert tree_queries == 1
  end

  test "adoption skips a selected candidate whose Cinder episode was deleted after preview" do
    snapshot = fixture_snapshot("n_to_one")
    expect(SonarrMigrationSourceMock, :snapshot, fn -> {:ok, snapshot} end)
    stub_n_to_one_tmdb()

    assert {:ok, series} = Catalog.add_series(1100, monitor_strategy: :none)
    assert {:ok, preview} = Adoption.preview_migration(:sonarr)
    assert [%{key: key} = candidate] = preview.candidates

    [season] = Catalog.get_series_with_tree(series.id).seasons
    [episode] = season.episodes
    Repo.delete!(episode)

    assert %{
             adopted: 0,
             skipped: 1,
             failures: [],
             adopted_keys: [],
             stale_keys: [^key]
           } =
             Adoption.adopt_migration(:sonarr, [
               %{key: key, choice: :fold, candidate: candidate}
             ])

    assert Catalog.get_series_with_tree(series.id).seasons |> hd() |> Map.fetch!(:episodes) == []
  end

  defp fixture_snapshot(id) do
    @cases
    |> Enum.find(&(&1["id"] == id))
    |> Map.fetch!("snapshot")
    |> Map.new(fn {collection, records} ->
      {String.to_existing_atom(collection), Enum.map(records, &atomize_record/1)}
    end)
  end

  defp atomize_record(record) do
    Map.new(record, fn
      {"kind", kind} -> {:kind, String.to_existing_atom(kind)}
      {key, value} -> {String.to_existing_atom(key), value}
    end)
  end

  defp stub_n_to_one_tmdb do
    stub(Cinder.Catalog.TMDBMock, :find_by_external_id, fn
      200, :tvdb_id ->
        {:ok, [%{type: :tv, tmdb_id: 1100, title: "Show", year: 2008}]}

      2001, :tvdb_id ->
        {:ok,
         [
           %{
             type: :episode,
             tmdb_episode_id: 2100,
             series_tmdb_id: 1100,
             season_number: 4,
             episode_number: 15
           }
         ]}

      2002, :tvdb_id ->
        {:ok,
         [
           %{
             type: :episode,
             tmdb_episode_id: 2100,
             series_tmdb_id: 1100,
             season_number: 4,
             episode_number: 15
           }
         ]}
    end)

    stub(Cinder.Catalog.TMDBMock, :get_series, fn 1100 ->
      {:ok,
       %{
         tmdb_id: 1100,
         tvdb_id: 200,
         title: "Show",
         year: 2008,
         poster_path: nil,
         original_language: "en",
         overview: nil,
         localizations: %{},
         genres: [],
         vote_average: nil,
         first_air_date: nil,
         seasons: [%{season_number: 4}]
       }}
    end)

    stub(Cinder.Catalog.TMDBMock, :get_season, fn 1100, 4, _locale ->
      {:ok,
       %{
         season_number: 4,
         episodes: [
           %{
             tmdb_episode_id: 2100,
             episode_number: 15,
             title: "Combined",
             air_date: ~D[2008-04-24]
           }
         ]
       }}
    end)

    stub(Cinder.Catalog.TMDBMock, :get_series_alternative_titles, fn 1100 -> {:ok, []} end)
    stub(Cinder.Catalog.TMDBMock, :get_episode_groups, fn 1100 -> {:ok, []} end)
  end

  defp movie_details(tmdb_id) do
    %{
      tmdb_id: tmdb_id,
      imdb_id: "tt0000010",
      title: "Movie One",
      year: 2001,
      poster_path: nil,
      original_language: "en",
      localizations: %{}
    }
  end

  defp sonarr_series(id, tvdb_id, title),
    do: %{"id" => id, "tvdbId" => tvdb_id, "title" => title, "path" => "/tv/#{title}"}

  defp sonarr_episode(series_id) do
    file_id = series_id * 100
    tvdb_id = series_id * 1000 + 1

    %{
      "id" => series_id * 10,
      "tvdbId" => tvdb_id,
      "seasonNumber" => 1,
      "episodeNumber" => 1,
      "episodeFileId" => file_id,
      "episodeFile" => %{
        "id" => file_id,
        "relativePath" => "Episode.mkv",
        "size" => 10
      }
    }
  end

  defp stub_large_series_tmdb(episode_count) do
    stub(Cinder.Catalog.TMDBMock, :find_by_external_id, fn
      900, :tvdb_id ->
        {:ok, [%{type: :tv, tmdb_id: 9_000, title: "Large Show", year: 2020}]}

      tvdb_id, :tvdb_id ->
        episode_number = tvdb_id - 90_000

        {:ok,
         [
           %{
             type: :episode,
             tmdb_episode_id: 91_000 + episode_number,
             series_tmdb_id: 9_000,
             season_number: 1,
             episode_number: episode_number
           }
         ]}
    end)

    stub(Cinder.Catalog.TMDBMock, :get_series, fn 9_000 ->
      {:ok,
       %{
         tmdb_id: 9_000,
         tvdb_id: 900,
         title: "Large Show",
         year: 2020,
         poster_path: nil,
         original_language: "en",
         overview: nil,
         localizations: %{},
         genres: [],
         vote_average: nil,
         first_air_date: nil,
         seasons: [%{season_number: 1}]
       }}
    end)

    stub(Cinder.Catalog.TMDBMock, :get_season, fn 9_000, 1, _locale ->
      {:ok,
       %{
         season_number: 1,
         episodes:
           for number <- 1..episode_count do
             %{
               tmdb_episode_id: 91_000 + number,
               episode_number: number,
               title: "Episode #{number}",
               air_date: ~D[2020-01-01]
             }
           end
       }}
    end)

    stub(Cinder.Catalog.TMDBMock, :get_series_alternative_titles, fn 9_000 -> {:ok, []} end)
    stub(Cinder.Catalog.TMDBMock, :get_episode_groups, fn 9_000 -> {:ok, []} end)
  end

  defp large_series_snapshot(episode_count) do
    %{
      movies: [],
      series: [%{provider_id: 90, tvdb_id: 900}],
      episodes:
        for number <- 1..episode_count do
          %{
            provider_id: 10_000 + number,
            series_id: 90,
            tvdb_id: 90_000 + number,
            season_number: 1,
            episode_number: number,
            file_id: 20_000 + number
          }
        end,
      files:
        for number <- 1..episode_count do
          %{
            provider_id: 20_000 + number,
            kind: :episode,
            path: "/sonarr/Large.Show.S01E#{number}.mkv",
            size: 10
          }
        end
    }
  end

  defp count_episode_tree_queries(fun) do
    counter = :counters.new(1, [])
    ref = make_ref()

    :telemetry.attach(
      ref,
      [:cinder, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if is_binary(metadata.query) and
             String.contains?(
               metadata.query,
               ~s(ORDER BY e0."season_id", e0."episode_number")
             ) do
          :counters.add(counter, 1, 1)
        end
      end,
      nil
    )

    try do
      {fun.(), :counters.get(counter, 1)}
    after
      :telemetry.detach(ref)
    end
  end
end
