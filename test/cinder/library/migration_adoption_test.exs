defmodule Cinder.Library.MigrationAdoptionTest do
  use Cinder.DataCase, async: false

  import Mox

  alias Cinder.Catalog
  alias Cinder.Catalog.{Identity, Movie}
  alias Cinder.Library.{Adoption, RadarrMigrationSourceMock, SonarrMigrationSourceMock}

  @fixture_path "test/support/fixtures/migration-provider-identity-v1.json"
  @cases @fixture_path |> File.read!() |> Jason.decode!() |> Map.fetch!("cases")

  setup :verify_on_exit!

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
    assert [%{status: :ready, tmdb_id: 10, key: key}] = preview.candidates

    assert %{adopted: 1, skipped: 0, failures: []} =
             Adoption.adopt_migration(:radarr, [%{key: key}])

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
               }
             ] = preview.candidates

      assert %{adopted: 1, skipped: 0, failures: []} =
               Adoption.adopt_migration(:sonarr, [%{key: key, choice: unquote(choice)}])

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
end
