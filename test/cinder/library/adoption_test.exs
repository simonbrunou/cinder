defmodule Cinder.Library.AdoptionTest do
  use Cinder.DataCase, async: false

  import Cinder.CatalogFixtures
  import Mox

  alias Cinder.Catalog
  alias Cinder.Catalog.{Episode, Movie, Series}
  alias Cinder.Library.Adoption
  alias Cinder.Repo

  setup :verify_on_exit!

  test "episode adoption refuses an episode owned by an active grab" do
    series = series_fixture()
    season = season_fixture(series)
    episode = episode_fixture(season)
    assert {:ok, _grab} = Catalog.create_grab("active-grab", :torrent, [episode.id])

    action = %{
      episode: episode,
      episode_code: "S01E01",
      path: "/library/Show.S01E01.mkv",
      type: :primary
    }

    assert {:error, [%{reason: :acquisition_in_progress}]} =
             Catalog.adopt_episode_files([action])

    assert %Episode{file_path: nil, grab_id: grab_id} = Repo.reload!(episode)
    assert is_integer(grab_id)
  end

  test "scan finds unmanaged movie and show trees, skips managed paths, and holds unknown episodes" do
    managed_movie =
      "/tmp/cinder-test-library/Managed (2019)/Managed (2019).mkv"

    managed_movie_part =
      "/tmp/cinder-test-library/Managed (2019)/Managed (2019)-cd2.mkv"

    movie_fixture(%{
      title: "Managed",
      status: :available,
      file_path: managed_movie,
      part_file_paths: [managed_movie_part]
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
      [{movie_path, 10}, {managed_movie, 20}, {managed_movie_part, 20}],
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
    assert Enum.all?(candidates, &(&1.media_profile == :auto))

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
    refute Enum.any?(candidates, &(managed_movie_part in &1.paths))
    refute Enum.any?(candidates, &(managed_tv in &1.paths))
  end

  test "scan covers a nested Anime root once and adopts its movie with the Anime profile" do
    standard = "/tmp/cinder-test-library/Dune (2021)/Dune (2021).mkv"
    anime_root = "/tmp/cinder-test-library/anime"
    anime = "#{anime_root}/Akira (1988)/Akira (1988).mkv"
    saved = Application.get_env(:cinder, :movies_anime_library_path)
    Application.put_env(:cinder, :movies_anime_library_path, anime_root)

    on_exit(fn ->
      if saved,
        do: Application.put_env(:cinder, :movies_anime_library_path, saved),
        else: Application.delete_env(:cinder, :movies_anime_library_path)
    end)

    expect(Cinder.Library.FilesystemMock, :find_files, 3, fn
      ^anime_root -> {:ok, [{anime, 10}]}
      "/tmp/cinder-test-library" -> {:ok, [{standard, 20}, {anime, 10}]}
      "/tmp/cinder-test-tv-library" -> {:ok, []}
    end)

    expect(Cinder.Catalog.TMDBMock, :search, 2, fn
      "Dune", "en" -> {:ok, [movie_result(10, "Dune", 2021)]}
      "Akira", "en" -> {:ok, [movie_result(20, "Akira", 1988)]}
    end)

    candidates = Adoption.scan()

    assert Enum.map(candidates, & &1.path) |> Enum.sort() == Enum.sort([standard, anime])
    assert Enum.count(candidates, &(anime in &1.paths)) == 1
    assert Enum.find(candidates, &(&1.path == standard)).media_profile == :auto
    anime_candidate = Enum.find(candidates, &(&1.path == anime))
    assert anime_candidate.media_profile == :anime

    expect(Cinder.Catalog.TMDBMock, :get_movie, fn 20 ->
      {:ok,
       movie_result(20, "Akira", 1988)
       |> Map.merge(%{imdb_id: "tt0094625", localizations: %{}})}
    end)

    assert %{adopted: 1, skipped: 0} = Adoption.adopt([anime_candidate])
    assert %Movie{media_profile: :anime, file_path: ^anime} = Catalog.get_movie_by_tmdb_id(20)
  end

  test "adoption from an explicit named root assigns that exact profile" do
    root = "/tmp/cinder-family-adoption"
    path = "#{root}/Paddington (2014)/Paddington (2014).mkv"

    assert {:ok, profile} =
             Catalog.create_profile(%{
               name: "Family adoption",
               kind: :movies,
               handling: :standard,
               library_path: root
             })

    stub(Cinder.Library.FilesystemMock, :find_files, fn
      ^root -> {:ok, [{path, 10}]}
      _other_root -> {:ok, []}
    end)

    expect(Cinder.Catalog.TMDBMock, :search, fn "Paddington", "en" ->
      {:ok, [movie_result(30, "Paddington", 2014)]}
    end)

    assert [%{profile_id: profile_id, media_profile: :standard} = candidate] = Adoption.scan()
    assert profile_id == profile.id

    expect(Cinder.Catalog.TMDBMock, :get_movie, fn 30 ->
      {:ok,
       movie_result(30, "Paddington", 2014)
       |> Map.merge(%{imdb_id: "tt1109624", localizations: %{}})}
    end)

    assert %{adopted: 1, skipped: 0} = Adoption.adopt([candidate])

    assert %Movie{profile_id: profile_id, media_profile: :standard, file_path: ^path} =
             Catalog.get_movie_by_tmdb_id(30)

    assert profile_id == profile.id
  end

  test "adoption fails closed when its named destination disappears after scanning" do
    root = "/tmp/cinder-stale-adoption"
    path = "#{root}/Dune (2021)/Dune (2021).mkv"

    assert {:ok, profile} =
             Catalog.create_profile(%{
               name: "Temporary adoption",
               kind: :movies,
               handling: :standard,
               library_path: root
             })

    stub(Cinder.Library.FilesystemMock, :find_files, fn
      ^root -> {:ok, [{path, 10}]}
      _other_root -> {:ok, []}
    end)

    expect(Cinder.Catalog.TMDBMock, :search, fn "Dune", "en" ->
      {:ok, [movie_result(31, "Dune", 2021)]}
    end)

    assert [candidate] = Adoption.scan()
    assert {:ok, _deleted} = Catalog.delete_profile(profile)

    assert %{adopted: 0, skipped: 1} = Adoption.adopt([candidate])
    refute Catalog.get_movie_by_tmdb_id(31)
  end

  test "scan adopts a series from an Anime destination with the Anime profile" do
    anime_root = "/tmp/cinder-test-tv-library/anime"
    path = "#{anime_root}/Test Show (2001)/Test.Show.S01E01.mkv"
    saved = Application.get_env(:cinder, :tv_anime_library_path)
    Application.put_env(:cinder, :tv_anime_library_path, anime_root)

    on_exit(fn ->
      if saved,
        do: Application.put_env(:cinder, :tv_anime_library_path, saved),
        else: Application.delete_env(:cinder, :tv_anime_library_path)
    end)

    expect(Cinder.Library.FilesystemMock, :find_files, 3, fn
      "/tmp/cinder-test-library" -> {:ok, []}
      ^anime_root -> {:ok, [{path, 10}]}
      "/tmp/cinder-test-tv-library" -> {:ok, [{path, 10}]}
    end)

    expect(Cinder.Catalog.TMDBMock, :search_tv, fn "Test Show", "en" ->
      {:ok, [series_result(42, "Test Show", 2001)]}
    end)

    stub_series_create(42, 2)

    assert [%{kind: :series, media_profile: :anime} = candidate] = Adoption.scan()
    assert %{adopted: 1, skipped: 0} = Adoption.adopt([candidate])

    assert %Series{media_profile: :anime} = Catalog.get_series_by_tmdb_id(42)
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

  test "a tvdb-tagged series resolves and adopts through find without title search" do
    path =
      "/tmp/cinder-test-tv-library/Test Show (2001) {tvdb-999}/Test.Show.S01E01.mkv"

    stub_roots([], [{path, 10}])

    expect(Cinder.Catalog.TMDBMock, :find_by_external_id, fn 999, :tvdb_id ->
      {:ok, [series_result(42, "Test Show", 2001) |> Map.put(:type, :tv)]}
    end)

    stub_series_create(42, 2)

    assert [%{kind: :series, status: :auto_matched} = candidate] = Adoption.scan()
    assert %{adopted: 1, skipped: 0} = Adoption.adopt([candidate])

    series = Catalog.get_series_by_tmdb_id(42)
    [season] = Catalog.get_series_with_tree(series.id).seasons

    assert Enum.find(season.episodes, &(&1.episode_number == 1)).file_path == path
  end

  test "an imdb-tagged movie resolves and adopts through find without title search" do
    path = "/tmp/cinder-test-library/Dune (2021) {imdb-tt1160419}/Dune.mkv"
    stub_roots([{path, 10}], [])

    expect(Cinder.Catalog.TMDBMock, :find_by_external_id, fn "tt1160419", :imdb_id ->
      {:ok, [movie_result(10, "Dune", 2021) |> Map.put(:type, :movie)]}
    end)

    expect(Cinder.Catalog.TMDBMock, :get_movie, fn 10 ->
      {:ok,
       movie_result(10, "Dune", 2021)
       |> Map.merge(%{imdb_id: "tt1160419", localizations: %{}})}
    end)

    assert [%{kind: :movie, status: :auto_matched} = candidate] = Adoption.scan()
    assert %{adopted: 1, skipped: 0} = Adoption.adopt([candidate])

    assert %Movie{status: :available, file_path: ^path, media_profile: :auto} =
             Catalog.get_movie_by_tmdb_id(10)
  end

  test "unresolved or ambiguous external tags fall back to operator resolution" do
    no_match =
      "/tmp/cinder-test-library/No Match (2001) {imdb-tt0000001}/No.Match.mkv"

    many_matches =
      "/tmp/cinder-test-library/Many Matches (2001) {imdb-tt0000002}/Many.Matches.mkv"

    stub_roots([{no_match, 10}, {many_matches, 10}], [])

    expect(Cinder.Catalog.TMDBMock, :find_by_external_id, 2, fn
      "tt0000001", :imdb_id ->
        {:ok, []}

      "tt0000002", :imdb_id ->
        {:ok,
         [
           movie_result(20, "Many Matches", 2001) |> Map.put(:type, :movie),
           movie_result(21, "Many Matches", 2001) |> Map.put(:type, :movie)
         ]}
    end)

    expect(Cinder.Catalog.TMDBMock, :search, 2, fn
      "No Match", "en" -> {:ok, [movie_result(10, "No Match", 2002)]}
      "Many Matches", "en" -> {:ok, [movie_result(20, "Many Matches", 2002)]}
    end)

    candidates = Adoption.scan()
    assert Enum.all?(candidates, &(&1.status == :ambiguous))
    assert Enum.all?(candidates, &(&1.match == nil))
  end

  test "adopt inserts a movie directly at available, never exposing it to the requested poller query" do
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

    {summary, transitions} =
      Cinder.TelemetryHelpers.capture([:cinder, :transition], fn ->
        Adoption.adopt([candidate])
      end)

    assert %{adopted: 1, skipped: 0, failures: []} = summary

    assert_receive {:movie_created, %Movie{tmdb_id: 10, status: :available, file_path: ^path}}

    refute_receive {:movie_updated, %Movie{tmdb_id: 10}}
    assert transitions == []
    assert Catalog.list_by_status(:requested) == []

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
    assert %Series{monitor_strategy: :none, monitored: false, media_profile: :auto} = series
    assert_receive {:series_updated, series_id} when series_id == series.id

    [season] = Catalog.get_series_with_tree(series.id).seasons
    by_number = Map.new(season.episodes, &{&1.episode_number, &1})
    assert by_number[1].file_path == episode_path
    assert by_number[2].file_path == nil

    assert %{adopted: 0, skipped: 1} = Adoption.adopt([candidate])
    assert Catalog.count_series() == 1
  end

  test "adopting files into an existing series preserves all monitoring choices" do
    series =
      series_fixture(%{
        tmdb_id: 42,
        monitored: true,
        monitor_strategy: :all
      })

    season = season_fixture(series, %{monitored: true})
    monitored = episode_fixture(season, %{episode_number: 1, monitored: true})
    unmonitored = episode_fixture(season, %{episode_number: 2, monitored: false})
    path = "/tmp/cinder-test-tv-library/Test Show (2001)/Test.Show.S01E01.mkv"

    candidate = %{
      kind: :series,
      status: :auto_matched,
      match: %{tmdb_id: 42},
      files: [
        %{
          path: path,
          season_number: 1,
          episode_numbers: [1],
          status: :matched
        }
      ]
    }

    assert %{adopted: 1, skipped: 0, failures: []} = Adoption.adopt([candidate])

    assert %Series{monitored: true, monitor_strategy: :all} = Repo.reload!(series)
    assert Repo.reload!(season).monitored
    assert Repo.reload!(monitored).monitored
    refute Repo.reload!(unmonitored).monitored
    assert Repo.reload!(monitored).file_path == path
  end

  test "a failed episode write rolls back earlier files and is reported separately from skips" do
    series = series_fixture(%{tmdb_id: 42, monitor_strategy: :all})
    season = season_fixture(series)
    first = episode_fixture(season, %{episode_number: 1})
    second = episode_fixture(season, %{episode_number: 2})
    first_path = "/tmp/cinder-test-tv-library/Test Show (2001)/Test.Show.S01E01.mkv"
    failed_path = "/tmp/cinder-test-tv-library/Test Show (2001)/Test.Show.S01E02.part.mkv"

    candidate = %{
      kind: :series,
      status: :auto_matched,
      match: %{tmdb_id: 42},
      files: [
        %{
          path: first_path,
          season_number: 1,
          episode_numbers: [1],
          status: :matched
        },
        %{
          path: failed_path,
          status: :part,
          part_of: %{season_number: 1, episode_number: 2}
        }
      ]
    }

    Catalog.subscribe_series()

    assert %{
             adopted: 0,
             skipped: 0,
             failures: [
               %{
                 episode_code: "S01E02",
                 path: ^failed_path,
                 reason: :primary_file_missing
               }
             ]
           } = Adoption.adopt([candidate])

    assert %Episode{file_path: nil} = Repo.reload!(first)
    assert %Episode{file_path: nil, part_file_paths: []} = Repo.reload!(second)
    refute_receive {:series_updated, _}
  end

  defp stub_roots(movie_files, tv_files) do
    expect(Cinder.Library.FilesystemMock, :find_files, 2, fn
      "/tmp/cinder-test-library" -> {:ok, movie_files}
      "/tmp/cinder-test-tv-library" -> {:ok, tv_files}
    end)
  end

  defp stub_series_create(tmdb_id, calls \\ 1) do
    expect(Cinder.Catalog.TMDBMock, :get_series, calls, fn ^tmdb_id ->
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

    expect(Cinder.Catalog.TMDBMock, :get_season, calls, fn ^tmdb_id, 1, "en" ->
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
