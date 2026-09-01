defmodule CinderWeb.LibraryAdoptionLiveTest do
  use CinderWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest

  alias Cinder.Catalog
  alias Cinder.Catalog.Movie

  setup :register_and_log_in_admin
  setup :set_mox_global
  setup :verify_on_exit!

  test "scan, select, and adopt an existing movie end to end", %{conn: conn} do
    path = "/tmp/cinder-test-library/Dune (2021)/Dune (2021).mkv"

    stub(Cinder.Library.FilesystemMock, :find_files, fn
      "/tmp/cinder-test-library" -> {:ok, [{path, 10}]}
      "/tmp/cinder-test-tv-library" -> {:ok, []}
    end)

    stub(Cinder.Library.FilesystemMock, :lstat, fn ^path ->
      {:ok, %File.Stat{type: :regular, size: 10}}
    end)

    expect(Cinder.Catalog.TMDBMock, :search, fn "Dune", "en" ->
      {:ok,
       [
         %{
           tmdb_id: 10,
           title: "Dune",
           year: 2021,
           poster_path: "/poster.jpg",
           original_language: "en"
         }
       ]}
    end)

    expect(Cinder.Catalog.TMDBMock, :get_movie, fn 10 ->
      {:ok,
       %{
         tmdb_id: 10,
         imdb_id: "tt1160419",
         title: "Dune",
         year: 2021,
         poster_path: "/poster.jpg",
         original_language: "en",
         localizations: %{}
       }}
    end)

    {:ok, view, _html} = live(conn, ~p"/library/adopt")
    view |> element("#scan-library") |> render_click()
    render_async(view)

    assert has_element?(
             view,
             "#adoption-candidate-1 input[type=checkbox][value='1'][checked]"
           )

    view
    |> form("#adoption-form", %{"adoption" => %{"selected" => ["1"]}})
    |> render_submit()

    render_async(view)
    render_async(view)

    assert %Movie{status: :available, file_path: ^path} = Catalog.get_movie_by_tmdb_id(10)
    assert has_element?(view, "#flash-info", "Adopted 1; skipped 0.")
    assert has_element?(view, "#no-unmanaged-files", "No unmanaged files found")
  end

  # Regression: mode flips at click but results arrive async — switching scan modes must not
  # render the new mode's summary/forms over the previous scan's buckets (or leave them stale
  # after a failed preview).
  test "switching to a migration preview clears the previous filesystem scan's buckets", %{
    conn: conn
  } do
    path = "/tmp/cinder-test-library/Dune (2021)/Dune (2021).mkv"

    stub(Cinder.Library.FilesystemMock, :find_files, fn
      "/tmp/cinder-test-library" -> {:ok, [{path, 10}]}
      "/tmp/cinder-test-tv-library" -> {:ok, []}
    end)

    stub(Cinder.Library.FilesystemMock, :lstat, fn ^path ->
      {:ok, %File.Stat{type: :regular, size: 10}}
    end)

    stub(Cinder.Catalog.TMDBMock, :search, fn "Dune", "en" ->
      {:ok,
       [%{tmdb_id: 10, title: "Dune", year: 2021, poster_path: nil, original_language: "en"}]}
    end)

    stub(Cinder.Catalog.TMDBMock, :get_movie, fn 10 ->
      {:ok,
       %{
         tmdb_id: 10,
         imdb_id: "tt1160419",
         title: "Dune",
         year: 2021,
         poster_path: nil,
         original_language: "en",
         localizations: %{}
       }}
    end)

    stub(Cinder.Library.RadarrMigrationSourceMock, :snapshot, fn ->
      {:error, :not_configured}
    end)

    {:ok, view, _html} = live(conn, ~p"/library/adopt")
    view |> element("#scan-library") |> render_click()
    render_async(view)
    assert has_element?(view, "#adoption-candidate-1")

    # The Radarr preview fails (source not configured) — the old filesystem buckets must be
    # gone, not relabeled as a Radarr preview.
    view |> element("#scan-radarr") |> render_click()
    render_async(view)

    refute has_element?(view, "#adoption-candidate-1")
    refute has_element?(view, "#adoption-form")
    assert has_element?(view, "#flash-error")
  end

  # `migration_source_keys` (the "scan_migration" guard) is derived from the FULL registry,
  # which has included :readarr since B6a. B6a-era coverage here asserted that a devtools-crafted
  # event for it failed closed (no `plan/4` clause existed yet); B6b adds
  # `Cinder.Library.MigrationAdoption.Readarr`, so the same event now completes a real, if empty,
  # preview — proving the guard reaches an actually-implemented source, not a still-unwired one.
  # No button exists for it yet regardless (B6c adds the third `<.button>`), so this stays a
  # devtools-crafted event rather than a click.
  test "scan_migration for :readarr completes a real (if empty) preview instead of the old catch-all error",
       %{conn: conn} do
    expect(Cinder.Library.ReadarrMigrationSourceMock, :snapshot, fn ->
      {:ok,
       %{movies: [], series: [], episodes: [], authors: [], works: [], editions: [], files: []}}
    end)

    {:ok, view, _html} = live(conn, ~p"/library/adopt")
    render_click(view, "scan_migration", %{"source" => "readarr"})
    render_async(view)

    assert Process.alive?(view.pid)
    refute has_element?(view, "#flash-error")
    assert has_element?(view, "#migration-summary", "Readarr migration preview")
    assert render(view) =~ "Ready: 0"
  end

  test "operator assigns a TVDB split file as a part of one combined TMDB episode", %{conn: conn} do
    primary =
      "/tmp/cinder-test-tv-library/The Office (2005)/The.Office.S04E15.mkv"

    part =
      "/tmp/cinder-test-tv-library/The Office (2005)/The.Office.S04E16.mkv"

    stub(Cinder.Library.FilesystemMock, :find_files, fn
      "/tmp/cinder-test-library" -> {:ok, []}
      "/tmp/cinder-test-tv-library" -> {:ok, [{primary, 20}, {part, 10}]}
    end)

    stub(Cinder.Library.FilesystemMock, :lstat, fn
      ^primary -> {:ok, %File.Stat{type: :regular, size: 20}}
      ^part -> {:ok, %File.Stat{type: :regular, size: 10}}
    end)

    stub(Cinder.Catalog.TMDBMock, :search_tv, fn "The Office", "en" ->
      {:ok, [series_result()]}
    end)

    stub(Cinder.Catalog.TMDBMock, :get_series, fn 2316 ->
      {:ok, Map.put(series_result(), :seasons, [%{season_number: 4}])}
    end)

    stub(Cinder.Catalog.TMDBMock, :get_season, fn 2316, 4, _locale ->
      {:ok,
       %{
         season_number: 4,
         episodes: [
           %{
             tmdb_episode_id: 40_415,
             episode_number: 15,
             title: "Night Out",
             air_date: ~D[2008-04-24]
           }
         ]
       }}
    end)

    stub(Cinder.Catalog.TMDBMock, :get_series_alternative_titles, fn 2316 -> {:ok, []} end)
    stub(Cinder.Catalog.TMDBMock, :get_episode_groups, fn 2316 -> {:ok, []} end)

    {:ok, view, _html} = live(conn, ~p"/library/adopt")
    view |> element("#scan-library") |> render_click()
    render_async(view)

    assert has_element?(view, "#part-assignment-1-2 option[value='15']")

    view
    |> form("#adoption-form", %{
      "adoption" => %{
        "selected" => ["1"],
        "parts" => %{"1" => %{"2" => "15"}}
      }
    })
    |> render_submit()

    render_async(view)
    render_async(view)

    series = Catalog.get_series_by_tmdb_id(2316)
    [season] = Catalog.get_series_with_tree(series.id).seasons
    [episode] = season.episodes
    assert episode.file_path == primary
    assert episode.part_file_paths == [part]
    assert has_element?(view, "#no-unmanaged-files", "No unmanaged files found")
  end

  test "Radarr migration mode previews and confirms through the existing adoption route", %{
    conn: conn
  } do
    path = "/radarr/Dune (2021)/Dune.mkv"

    expect(Cinder.Library.RadarrMigrationSourceMock, :snapshot, fn ->
      {:ok,
       %{
         movies: [
           %{provider_id: 1, tmdb_id: 10, imdb_id: "tt1160419", file_id: 501}
         ],
         series: [],
         episodes: [],
         files: [%{provider_id: 501, kind: :movie, path: path, size: 10}]
       }}
    end)

    stub(Cinder.Library.FilesystemMock, :lstat, fn ^path -> {:ok, %File.Stat{}} end)

    stub(Cinder.Catalog.TMDBMock, :get_movie, fn 10 ->
      {:ok,
       %{
         tmdb_id: 10,
         imdb_id: "tt1160419",
         title: "Dune",
         year: 2021,
         poster_path: "/poster.jpg",
         original_language: "en",
         localizations: %{}
       }}
    end)

    {:ok, view, _html} = live(conn, ~p"/library/adopt")
    view |> element("#scan-radarr") |> render_click()
    render_async(view)

    assert has_element?(view, "#migration-summary", "Radarr migration preview")
    assert has_element?(view, "#migration-ready-candidates input[type=checkbox][checked]")

    # Ready items are pre-selected server-side; adopting derives the commands from that state.
    view |> element("#adopt-migration-selected") |> render_click()

    render_async(view)

    assert %Movie{status: :available, file_path: ^path} = Catalog.get_movie_by_tmdb_id(10)
  end

  test "select all after deselecting adopts the ready migration candidate", %{conn: conn} do
    path = "/radarr/Dune (2021)/Dune.mkv"

    stub(Cinder.Library.RadarrMigrationSourceMock, :snapshot, fn ->
      {:ok,
       %{
         movies: [%{provider_id: 1, tmdb_id: 10, imdb_id: "tt1160419", file_id: 501}],
         series: [],
         episodes: [],
         files: [%{provider_id: 501, kind: :movie, path: path, size: 10}]
       }}
    end)

    stub(Cinder.Library.FilesystemMock, :lstat, fn ^path -> {:ok, %File.Stat{}} end)

    stub(Cinder.Catalog.TMDBMock, :get_movie, fn 10 ->
      {:ok,
       %{
         tmdb_id: 10,
         imdb_id: "tt1160419",
         title: "Dune",
         year: 2021,
         poster_path: "/poster.jpg",
         original_language: "en",
         localizations: %{}
       }}
    end)

    {:ok, view, _html} = live(conn, ~p"/library/adopt")
    view |> element("#scan-radarr") |> render_click()
    render_async(view)

    assert render(view) =~ "1 of 1 selected"

    view |> element("button", "Deselect all") |> render_click()
    assert render(view) =~ "0 of 1 selected"
    refute has_element?(view, "#migration-ready-candidates input[type=checkbox][checked]")

    view |> element("button", "Select all") |> render_click()
    assert render(view) =~ "1 of 1 selected"
    assert has_element?(view, "#migration-ready-candidates input[type=checkbox][checked]")

    view |> element("#adopt-migration-selected") |> render_click()
    render_async(view)

    assert %Movie{status: :available, file_path: ^path} = Catalog.get_movie_by_tmdb_id(10)
  end

  test "windowing bounds each bucket and ready selection survives a page flip", %{conn: conn} do
    movies =
      for i <- 1..60, do: %{provider_id: i, tmdb_id: 1000 + i, imdb_id: nil, file_id: 5000 + i}

    files =
      for i <- 1..60,
          do: %{provider_id: 5000 + i, kind: :movie, path: "/radarr/M#{i}.mkv", size: 10}

    stub(Cinder.Library.RadarrMigrationSourceMock, :snapshot, fn ->
      {:ok, %{movies: movies, series: [], episodes: [], files: files}}
    end)

    stub(Cinder.Catalog.TMDBMock, :get_movie, fn id ->
      {:ok,
       %{
         tmdb_id: id,
         imdb_id: nil,
         title: "Movie #{id}",
         year: 2020,
         poster_path: nil,
         original_language: "en",
         localizations: %{}
       }}
    end)

    {:ok, view, _html} = live(conn, ~p"/library/adopt")
    view |> element("#scan-radarr") |> render_click()
    render_async(view)

    # Only a bounded page renders even though 60 rows are ready, and every row is pre-selected.
    assert render(view) =~ "60 of 60 selected"
    assert render(view) =~ "Page 1 of 2"
    assert has_element?(view, "#adoption-candidate-1")

    # Deselect one visible row, then page away and back: the selection is held server-side.
    render_click(view, "toggle_ready", %{"id" => "1"})
    assert render(view) =~ "59 of 60 selected"
    refute has_element?(view, "#adoption-candidate-1 input[type=checkbox][checked]")

    render_click(view, "page", %{"bucket" => "ready", "dir" => "next"})
    assert render(view) =~ "Page 2 of 2"
    refute has_element?(view, "#adoption-candidate-1")

    render_click(view, "page", %{"bucket" => "ready", "dir" => "prev"})
    assert render(view) =~ "Page 1 of 2"
    assert render(view) =~ "59 of 60 selected"
    assert has_element?(view, "#adoption-candidate-1")
    refute has_element?(view, "#adoption-candidate-1 input[type=checkbox][checked]")
  end

  test "bulk Apply Fold fills undecided items while a per-candidate override survives", %{
    conn: conn
  } do
    stub_two_group_sonarr_snapshot()

    {:ok, view, _html} = live(conn, ~p"/library/adopt")
    view |> element("#scan-sonarr") |> render_click()
    render_async(view)

    assert render(view) =~ "2 decisions pending"
    refute has_element?(view, "#migration-decision-candidates input[checked]")

    # Bulk apply is explicit: it fills both undecided items with Fold.
    view |> element("button", "Apply Fold to all undecided") |> render_click()
    assert render(view) =~ "0 decisions pending"
    assert has_element?(view, "#adoption-candidate-1 input[value=fold][checked]")
    assert has_element?(view, "#adoption-candidate-2 input[value=fold][checked]")

    # A per-candidate override changes only that item; the other keeps the bulk value.
    render_click(view, "set_decision", %{"id" => "1", "choice" => "part"})
    assert has_element?(view, "#adoption-candidate-1 input[value=part][checked]")
    refute has_element?(view, "#adoption-candidate-1 input[value=fold][checked]")
    assert has_element?(view, "#adoption-candidate-2 input[value=fold][checked]")
    assert render(view) =~ "0 decisions pending"
  end

  test "adopt reports undecided needs-decision items as skipped honestly", %{conn: conn} do
    stub_two_group_sonarr_snapshot()
    stub(Cinder.Library.FilesystemMock, :lstat, fn _ -> {:ok, %File.Stat{}} end)

    # Adopting the decided item creates its series in the catalog; stub that chain so the adopt
    # returns a summary (rather than crashing) and the honest-skip flash is reachable.
    stub(Cinder.Catalog.TMDBMock, :get_series, fn 1100 ->
      {:ok,
       %{
         tmdb_id: 1100,
         tvdb_id: nil,
         title: "Show",
         year: 2020,
         poster_path: nil,
         original_language: "en",
         seasons: [%{season_number: 4}]
       }}
    end)

    stub(Cinder.Catalog.TMDBMock, :get_season, fn 1100, 4, _locale ->
      {:ok,
       %{
         season_number: 4,
         episodes: [
           %{tmdb_episode_id: 2100, episode_number: 15, title: "E15", air_date: ~D[2020-01-01]}
         ]
       }}
    end)

    stub(Cinder.Catalog.TMDBMock, :get_series_alternative_titles, fn 1100 -> {:ok, []} end)
    stub(Cinder.Catalog.TMDBMock, :get_episode_groups, fn 1100 -> {:ok, []} end)

    {:ok, view, _html} = live(conn, ~p"/library/adopt")
    view |> element("#scan-sonarr") |> render_click()
    render_async(view)

    # Decide only one of the two needs-decision items, then adopt: the other is skipped, and that
    # skip is reported instead of being swallowed.
    render_click(view, "set_decision", %{"id" => "1", "choice" => "fold"})
    view |> element("#adopt-migration-selected") |> render_click()
    render_async(view)

    assert has_element?(view, "#flash-info", "needed a decision")
  end

  test "Sonarr migration mode exposes only explicit Fold or Part choices", %{conn: conn} do
    stub(Cinder.Library.SonarrMigrationSourceMock, :snapshot, fn ->
      {:ok,
       %{
         movies: [],
         series: [%{provider_id: 12, tvdb_id: 200}],
         episodes: [
           %{
             provider_id: 22,
             series_id: 12,
             tvdb_id: 2001,
             season_number: 4,
             episode_number: 15,
             file_id: 602
           },
           %{
             provider_id: 23,
             series_id: 12,
             tvdb_id: 2002,
             season_number: 4,
             episode_number: 16,
             file_id: 603
           }
         ],
         files: [
           %{provider_id: 602, kind: :episode, path: "/sonarr/Show.S04E15.mkv", size: 10},
           %{provider_id: 603, kind: :episode, path: "/sonarr/Show.S04E16.mkv", size: 10}
         ]
       }}
    end)

    stub(Cinder.Catalog.TMDBMock, :find_by_external_id, fn
      200, :tvdb_id ->
        {:ok, [%{type: :tv, tmdb_id: 1100, title: "Show"}]}

      id, :tvdb_id when id in [2001, 2002] ->
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

    {:ok, view, _html} = live(conn, ~p"/library/adopt")
    view |> element("#scan-sonarr") |> render_click()
    render_async(view)

    assert has_element?(view, "#migration-decision-candidates input[value=fold]")
    assert has_element?(view, "#migration-decision-candidates input[value=part]")
    refute has_element?(view, "#migration-decision-candidates input[checked]")
  end

  test "an episode adoption failure remains visible with its file after the transaction rolls back",
       %{conn: conn} do
    part =
      "/tmp/cinder-test-tv-library/The Office (2005)/The.Office.S04E16.mkv"

    stub(Cinder.Library.FilesystemMock, :find_files, fn
      "/tmp/cinder-test-library" -> {:ok, []}
      "/tmp/cinder-test-tv-library" -> {:ok, [{part, 10}]}
    end)

    stub(Cinder.Library.FilesystemMock, :lstat, fn ^part ->
      {:ok, %File.Stat{type: :regular, size: 10}}
    end)

    stub(Cinder.Catalog.TMDBMock, :search_tv, fn "The Office", "en" ->
      {:ok, [series_result()]}
    end)

    stub(Cinder.Catalog.TMDBMock, :get_series, fn 2316 ->
      {:ok, Map.put(series_result(), :seasons, [%{season_number: 4}])}
    end)

    stub(Cinder.Catalog.TMDBMock, :get_season, fn 2316, 4, _locale ->
      {:ok,
       %{
         season_number: 4,
         episodes: [
           %{
             tmdb_episode_id: 40_415,
             episode_number: 15,
             title: "Night Out",
             air_date: ~D[2008-04-24]
           }
         ]
       }}
    end)

    stub(Cinder.Catalog.TMDBMock, :get_series_alternative_titles, fn 2316 -> {:ok, []} end)
    stub(Cinder.Catalog.TMDBMock, :get_episode_groups, fn 2316 -> {:ok, []} end)

    {:ok, view, _html} = live(conn, ~p"/library/adopt")
    view |> element("#scan-library") |> render_click()
    render_async(view)

    assert has_element?(view, "#part-assignment-1-1 option[value='15']")

    view
    |> form("#adoption-form", %{
      "adoption" => %{
        "selected" => ["1"],
        "parts" => %{"1" => %{"1" => "15"}}
      }
    })
    |> render_submit()

    render_async(view)

    assert has_element?(view, "#adoption-failures", "S04E15")
    assert has_element?(view, "#adoption-failures", "The.Office.S04E16.mkv")

    series = Catalog.get_series_by_tmdb_id(2316)
    [season] = Catalog.get_series_with_tree(series.id).seasons
    [episode] = season.episodes
    assert episode.file_path == nil
  end

  test "the library page links to adoption", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/library")
    assert has_element?(view, ~s|#adopt-library-link[href="/library/adopt"]|)
  end

  test "malformed selections are ignored safely", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/library/adopt")

    render_click(view, "adopt", %{
      "adoption" => %{"selected" => ["not-a-number"], "chosen" => %{"bad" => "also-bad"}}
    })

    assert has_element?(view, "#flash-error", "Select at least one match to adopt.")
  end

  test "non-admins are redirected away from adoption", %{conn: _conn} do
    conn = build_conn() |> log_in_user(Cinder.AccountsFixtures.user_fixture())
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/library/adopt")
  end

  defp series_result do
    %{
      tmdb_id: 2316,
      tvdb_id: 73_244,
      title: "The Office",
      year: 2005,
      poster_path: "/office.jpg",
      original_language: "en"
    }
  end

  # Two independent TVDB-split groups on one series, each collapsing to a single TMDB episode, so
  # the preview yields exactly two `needs_decision` candidates (ids 1 and 2, sorted by key).
  defp stub_two_group_sonarr_snapshot do
    stub(Cinder.Library.SonarrMigrationSourceMock, :snapshot, fn ->
      {:ok,
       %{
         movies: [],
         series: [%{provider_id: 12, tvdb_id: 200}],
         episodes: [
           %{
             provider_id: 22,
             series_id: 12,
             tvdb_id: 2001,
             season_number: 4,
             episode_number: 15,
             file_id: 602
           },
           %{
             provider_id: 23,
             series_id: 12,
             tvdb_id: 2002,
             season_number: 4,
             episode_number: 16,
             file_id: 603
           },
           %{
             provider_id: 24,
             series_id: 12,
             tvdb_id: 2003,
             season_number: 5,
             episode_number: 10,
             file_id: 604
           },
           %{
             provider_id: 25,
             series_id: 12,
             tvdb_id: 2004,
             season_number: 5,
             episode_number: 11,
             file_id: 605
           }
         ],
         files: [
           %{provider_id: 602, kind: :episode, path: "/sonarr/Show.S04E15.mkv", size: 10},
           %{provider_id: 603, kind: :episode, path: "/sonarr/Show.S04E16.mkv", size: 10},
           %{provider_id: 604, kind: :episode, path: "/sonarr/Show.S05E10.mkv", size: 10},
           %{provider_id: 605, kind: :episode, path: "/sonarr/Show.S05E11.mkv", size: 10}
         ]
       }}
    end)

    stub(Cinder.Catalog.TMDBMock, :find_by_external_id, fn
      200, :tvdb_id ->
        {:ok, [%{type: :tv, tmdb_id: 1100, title: "Show"}]}

      id, :tvdb_id when id in [2001, 2002] ->
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

      id, :tvdb_id when id in [2003, 2004] ->
        {:ok,
         [
           %{
             type: :episode,
             tmdb_episode_id: 2200,
             series_tmdb_id: 1100,
             season_number: 5,
             episode_number: 10
           }
         ]}
    end)
  end
end
