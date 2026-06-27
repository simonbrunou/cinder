defmodule CinderWeb.ActivityLiveTest do
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Cinder.Catalog
  alias Cinder.Repo

  import Cinder.CatalogFixtures

  setup :register_and_log_in_admin

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

    {:ok, _} = Catalog.transition(movie, %{status: :downloading})
    assert render(lv) =~ "badge-info"
  end

  test "a parked movie shows Retry that re-queues it to :requested", %{conn: conn} do
    movie = movie_fixture(%{title: "Tenet"})
    {:ok, _} = Catalog.transition(movie, %{status: :no_match})

    {:ok, lv, _html} = live(conn, ~p"/activity")
    lv |> element("#movie-#{movie.id} button", "Retry") |> render_click()

    assert Catalog.get_movie_by_id(movie.id).status == :requested
  end

  test "retry with a forged non-numeric id is a no-op (no crash)", %{conn: conn} do
    movie = movie_fixture(%{title: "Tenet"})
    {:ok, _} = Catalog.transition(movie, %{status: :no_match})

    {:ok, lv, _html} = live(conn, ~p"/activity")
    # A forged phx-value reaching the old get_movie_by_id/Repo.get would CastError-crash the LV.
    render_click(lv, "retry", %{"id" => "not-a-number"})

    assert render(lv) =~ "Movie pipeline"
    assert Catalog.get_movie_by_id(movie.id).status == :no_match
  end

  test "an in-flight movie shows no Retry button", %{conn: conn} do
    movie = movie_fixture(%{title: "Sicario"})
    {:ok, _} = Catalog.transition(movie, %{status: :downloading, download_id: "h"})

    {:ok, lv, _html} = live(conn, ~p"/activity")
    refute has_element?(lv, "#movie-#{movie.id} button", "Retry")
  end

  test "renders grabs and deletes one through the confirm step", %{conn: conn} do
    grab = grab!()

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
