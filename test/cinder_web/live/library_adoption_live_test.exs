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

    assert %Movie{status: :available, file_path: ^path} = Catalog.get_movie_by_tmdb_id(10)
    assert has_element?(view, "#flash-info", "Adopted 1; skipped 0.")
    assert has_element?(view, "#no-unmanaged-files", "No unmanaged files found")
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

    series = Catalog.get_series_by_tmdb_id(2316)
    [season] = Catalog.get_series_with_tree(series.id).seasons
    [episode] = season.episodes
    assert episode.file_path == primary
    assert episode.part_file_paths == [part]
    assert has_element?(view, "#no-unmanaged-files", "No unmanaged files found")
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
end
