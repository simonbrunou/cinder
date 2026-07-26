defmodule Cinder.Library.AdoptionTest do
  use Cinder.DataCase, async: false

  import Cinder.CatalogFixtures
  import Mox

  alias Cinder.Catalog
  alias Cinder.Catalog.{Movie, Series}
  alias Cinder.Library.Adoption

  setup :verify_on_exit!

  test "scan finds unmanaged movie and show trees, skips managed paths, and holds unknown episodes" do
    managed_movie =
      "/tmp/cinder-test-library/Managed (2019)/Managed (2019).mkv"

    movie_fixture(%{
      title: "Managed",
      status: :available,
      file_path: managed_movie
    })

    managed_series = series_fixture(title: "Managed Show")
    managed_season = season_fixture(managed_series)
    managed_episode = episode_fixture(managed_season)
    managed_tv = "/tmp/cinder-test-tv-library/Managed Show (2019)/S01E01.mkv"
    {:ok, _episode} = Catalog.transition_episode(managed_episode, %{file_path: managed_tv})

    movie_path = "/tmp/cinder-test-library/Dune (2021)/Dune (2021).mkv"
    episode_path = "/tmp/cinder-test-tv-library/Test Show (2001)/Test.Show.S01E01.mkv"
    unknown_path = "/tmp/cinder-test-tv-library/Test Show (2001)/Test.Show.S01E99.mkv"

    stub_roots(
      [{movie_path, 10}, {managed_movie, 20}],
      [{episode_path, 10}, {unknown_path, 9}, {managed_tv, 8}]
    )

    expect(Cinder.Catalog.TMDBMock, :search, fn "Dune", "en" ->
      {:ok, [movie_result(10, "Dune", 2021)]}
    end)

    expect(Cinder.Catalog.TMDBMock, :search_tv, fn "Test Show", "en" ->
      {:ok, [series_result(20, "Test Show", 2001)]}
    end)

    expect(Cinder.Catalog.TMDBMock, :get_series, fn 20 ->
      {:ok,
       series_result(20, "Test Show", 2001)
       |> Map.merge(%{tvdb_id: 200, seasons: [%{season_number: 1}]})}
    end)

    expect(Cinder.Catalog.TMDBMock, :get_season, fn 20, 1, "en" ->
      {:ok,
       %{
         season_number: 1,
         episodes: [
           %{tmdb_episode_id: 201, episode_number: 1, title: "Pilot", air_date: ~D[2001-01-01]}
         ]
       }}
    end)

    candidates = Adoption.scan()
    assert length(candidates) == 2

    movie = Enum.find(candidates, &(&1.kind == :movie))
    assert movie.status == :auto_matched
    assert movie.path == movie_path
    assert movie.match.tmdb_id == 10

    series = Enum.find(candidates, &(&1.kind == :series))
    assert series.status == :auto_matched
    assert Enum.find(series.files, &(&1.path == episode_path)).status == :matched

    assert %{status: :unmatched, reason: {:episode_not_found, [%{episode_number: 99}]}} =
             Enum.find(series.files, &(&1.path == unknown_path))

    refute Enum.any?(candidates, &(managed_movie in &1.paths))
    refute Enum.any?(candidates, &(managed_tv in &1.paths))
  end

  test "two files claiming the same episode are both held, never last-write-wins" do
    dupe_a = "/tmp/cinder-test-tv-library/Test Show (2001)/Test.Show.S01E01.1080p.mkv"
    dupe_b = "/tmp/cinder-test-tv-library/Test Show (2001)/Test.Show.S01E01.720p.mkv"
    clean = "/tmp/cinder-test-tv-library/Test Show (2001)/Test.Show.S01E02.mkv"

    stub_roots([], [{dupe_a, 10}, {dupe_b, 9}, {clean, 8}])

    expect(Cinder.Catalog.TMDBMock, :search_tv, fn "Test Show", "en" ->
      {:ok, [series_result(20, "Test Show", 2001)]}
    end)

    expect(Cinder.Catalog.TMDBMock, :get_series, fn 20 ->
      {:ok,
       series_result(20, "Test Show", 2001)
       |> Map.merge(%{tvdb_id: 200, seasons: [%{season_number: 1}]})}
    end)

    expect(Cinder.Catalog.TMDBMock, :get_season, fn 20, 1, "en" ->
      {:ok,
       %{
         season_number: 1,
         episodes: [
           %{tmdb_episode_id: 201, episode_number: 1, title: "One", air_date: ~D[2001-01-01]},
           %{tmdb_episode_id: 202, episode_number: 2, title: "Two", air_date: ~D[2001-01-08]}
         ]
       }}
    end)

    assert [%{kind: :series, status: :auto_matched} = candidate] = Adoption.scan()

    assert %{status: :matched} = Enum.find(candidate.files, &(&1.path == clean))

    for path <- [dupe_a, dupe_b] do
      assert %{status: :unmatched, reason: {:duplicate_episode_claim, [{1, 1}]}} =
               Enum.find(candidate.files, &(&1.path == path)),
             "expected #{path} to be held as a duplicate claim"
    end
  end

  test "a title or year near-miss is ambiguous" do
    path = "/tmp/cinder-test-library/Dune (2020)/Dune (2020).mkv"
    stub_roots([{path, 10}], [])

    expect(Cinder.Catalog.TMDBMock, :search, fn "Dune", "en" ->
      {:ok, [movie_result(10, "Dune", 2021)]}
    end)

    assert [
             %{
               kind: :movie,
               status: :ambiguous,
               match: nil,
               candidates: [%{tmdb_id: 10}]
             }
           ] = Adoption.scan()
  end

  test "a tmdb directory tag is trusted without searching TMDB" do
    path = "/tmp/cinder-test-library/Dune (2021) {tmdb-10}/Dune.mkv"
    stub_roots([{path, 10}], [])

    assert [
             %{
               kind: :movie,
               status: :auto_matched,
               tagged_tmdb_id: 10,
               match: %{tmdb_id: 10}
             }
           ] = Adoption.scan()
  end

  test "adopt creates an available movie through Catalog.transition, broadcasts, and is idempotent" do
    path = "/tmp/cinder-test-library/Dune (2021)/Dune (2021).mkv"

    candidate = %{
      kind: :movie,
      status: :auto_matched,
      path: path,
      match: %{tmdb_id: 10}
    }

    expect(Cinder.Catalog.TMDBMock, :get_movie, fn 10 ->
      {:ok,
       movie_result(10, "Dune", 2021)
       |> Map.merge(%{imdb_id: "tt1160419", localizations: %{}})}
    end)

    :ok = Catalog.subscribe()

    assert %{adopted: 1, skipped: 0} = Adoption.adopt([candidate])
    assert_receive {:movie_created, %Movie{tmdb_id: 10}}
    assert_receive {:movie_updated, %Movie{tmdb_id: 10, status: :available, file_path: ^path}}

    assert %Movie{status: :available, file_path: ^path} = Catalog.get_movie_by_tmdb_id(10)
    assert %{adopted: 0, skipped: 1} = Adoption.adopt([candidate])

    stub_roots([{path, 10}], [])
    assert Adoption.scan() == []
  end

  test "adopt creates an unmonitored series, maps episodes through transition_episode, and leaves holds untouched" do
    stub_series_create(42)

    episode_path = "/tmp/cinder-test-tv-library/Test Show (2001)/Test.Show.S01E01.mkv"
    held_path = "/tmp/cinder-test-tv-library/Test Show (2001)/Test.Show.S01E02.mkv"

    candidate = %{
      kind: :series,
      status: :auto_matched,
      match: %{tmdb_id: 42},
      files: [
        %{
          path: episode_path,
          season_number: 1,
          episode_numbers: [1],
          status: :matched
        },
        %{
          path: held_path,
          season_number: 1,
          episode_numbers: [2],
          status: :unmatched,
          reason: :held
        }
      ]
    }

    :ok = Catalog.subscribe_series()

    assert %{adopted: 1, skipped: 0} = Adoption.adopt([candidate])

    series = Catalog.get_series_by_tmdb_id(42)
    assert %Series{monitor_strategy: :none, monitored: false} = series
    assert_receive {:series_updated, series_id} when series_id == series.id

    [season] = Catalog.get_series_with_tree(series.id).seasons
    by_number = Map.new(season.episodes, &{&1.episode_number, &1})
    assert by_number[1].file_path == episode_path
    assert by_number[2].file_path == nil

    assert %{adopted: 0, skipped: 1} = Adoption.adopt([candidate])
    assert Catalog.count_series() == 1
  end

  defp stub_roots(movie_files, tv_files) do
    expect(Cinder.Library.FilesystemMock, :find_files, 2, fn
      "/tmp/cinder-test-library" -> {:ok, movie_files}
      "/tmp/cinder-test-tv-library" -> {:ok, tv_files}
    end)
  end

  defp stub_series_create(tmdb_id) do
    expect(Cinder.Catalog.TMDBMock, :get_series, fn ^tmdb_id ->
      {:ok,
       series_result(tmdb_id, "Test Show", 2001)
       |> Map.merge(%{tvdb_id: 999, seasons: [%{season_number: 1}]})}
    end)

    canonical = %{
      season_number: 1,
      episodes: [
        %{tmdb_episode_id: 101, episode_number: 1, title: "One", air_date: ~D[2001-01-01]},
        %{tmdb_episode_id: 102, episode_number: 2, title: "Two", air_date: ~D[2001-01-08]}
      ]
    }

    expect(Cinder.Catalog.TMDBMock, :get_season, fn ^tmdb_id, 1, "en" ->
      {:ok, canonical}
    end)

    stub(Cinder.Catalog.TMDBMock, :get_season, fn ^tmdb_id, 1, "fr" ->
      {:ok, %{canonical | episodes: Enum.map(canonical.episodes, &%{&1 | title: ""})}}
    end)

    expect(Cinder.Catalog.TMDBMock, :get_series_alternative_titles, fn ^tmdb_id -> {:ok, []} end)
    expect(Cinder.Catalog.TMDBMock, :get_episode_groups, fn ^tmdb_id -> {:ok, []} end)
  end

  defp movie_result(tmdb_id, title, year) do
    %{
      tmdb_id: tmdb_id,
      title: title,
      year: year,
      poster_path: "/poster.jpg",
      original_language: "en"
    }
  end

  defp series_result(tmdb_id, title, year) do
    %{
      tmdb_id: tmdb_id,
      title: title,
      year: year,
      poster_path: "/poster.jpg",
      original_language: "en"
    }
  end
end
