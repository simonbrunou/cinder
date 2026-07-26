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
end
