defmodule CinderWeb.ActivityLiveTest do
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox

  alias Cinder.Catalog
  alias Cinder.Repo

  import Cinder.CatalogFixtures

  setup :register_and_log_in_admin
  # The panel's async indexer search runs in a spawned Task, and the LiveView in its own
  # process, so the mocks must be visible across processes — global mode (the module is async: false).
  setup :set_mox_global

  defp grab! do
    series =
      Repo.insert!(%Cinder.Catalog.Series{
        tmdb_id: System.unique_integer([:positive]),
        title: "Severance",
        monitor_strategy: :all
      })

    season = Repo.insert!(%Cinder.Catalog.Season{series_id: series.id, season_number: 1})

    episode =
      Repo.insert!(%Cinder.Catalog.Episode{
        season_id: season.id,
        episode_number: 1,
        monitored: true
      })

    {:ok, grab} = Catalog.create_grab("abc123", :torrent, [episode.id])
    grab
  end

  test "renders the movie pipeline and live-updates on transition", %{conn: conn} do
    movie = movie_fixture(%{title: "Dune", year: 2021})

    {:ok, lv, html} = live(conn, ~p"/activity")
    assert html =~ "Dune"
    assert html =~ "Movie pipeline"
    # Management moved to the detail page — the row links there.
    assert has_element?(lv, ~s|#movie-#{movie.id} a[href="/movies/#{movie.id}"]|)

    {:ok, _} = Catalog.transition(movie, %{status: :downloading})
    assert render(lv) =~ "badge-info"
  end

  test "renders grabs and deletes one through the confirm step", %{conn: conn} do
    grab = grab!()

    # Deleting the grab must also remove the tracked client download — a bare row
    # delete leaves it running and colliding with the freed episodes' re-grab.
    expect(Cinder.Download.ClientMock, :remove, fn download_id, _opts ->
      assert download_id == grab.download_id
      :ok
    end)

    {:ok, lv, html} = live(conn, ~p"/activity")
    assert html =~ "Severance"
    assert html =~ "Downloads"

    lv |> element("#grab-#{grab.id} button", "Delete") |> render_click()
    lv |> element("#confirm-delete-grab-#{grab.id} button", "Delete") |> render_click()

    refute has_element?(lv, "#grab-#{grab.id}")
    assert Catalog.list_grabs() == []
  end

  test "non-admins are redirected away from /activity", %{conn: _conn} do
    conn = build_conn() |> log_in_user(Cinder.AccountsFixtures.user_fixture())
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/activity")
  end

  test "/status and /grabs redirect to /activity", %{conn: conn} do
    assert redirected_to(get(conn, ~p"/status")) == "/activity"
    assert redirected_to(get(conn, ~p"/grabs")) == "/activity"
  end
end
