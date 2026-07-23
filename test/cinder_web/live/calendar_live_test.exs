defmodule CinderWeb.CalendarLiveTest do
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Cinder.AccountsFixtures

  alias Cinder.Catalog.{Episode, Season, Series}
  alias Cinder.Repo

  setup :register_and_log_in_admin

  defp tree do
    series =
      Repo.insert!(%Series{
        tmdb_id: System.unique_integer([:positive]),
        title: "Calendar Show",
        year: 2020,
        monitored: true,
        monitor_strategy: :all
      })

    season = Repo.insert!(%Season{series_id: series.id, season_number: 1, monitored: true})
    {series, season}
  end

  test "renders monitored upcoming episodes with state badges", %{conn: conn} do
    {_series, season} = tree()
    today = Date.utc_today()

    Repo.insert!(%Episode{
      season_id: season.id,
      episode_number: 1,
      title: "Coming Soon",
      monitored: true,
      air_date: Date.add(today, 5)
    })

    Repo.insert!(%Episode{
      season_id: season.id,
      episode_number: 2,
      title: "Just Aired",
      monitored: true,
      air_date: Date.add(today, -1)
    })

    {:ok, lv, html} = live(conn, ~p"/calendar")

    assert html =~ "Calendar Show"
    assert html =~ "S01E01"
    assert html =~ "Coming Soon"
    assert html =~ "Upcoming"
    assert html =~ "S01E02"
    assert html =~ "Wanted"
    assert has_element?(lv, "#calendar-list")
    refute html =~ "<table"
  end

  test "renders upcoming episodes as cards (no overflow-prone table)", %{conn: conn} do
    {_series, season} = tree()
    today = Date.utc_today()

    Repo.insert!(%Episode{
      season_id: season.id,
      episode_number: 3,
      title: "Card Test Ep",
      monitored: true,
      air_date: Date.add(today, 10)
    })

    {:ok, lv, html} = live(conn, ~p"/calendar")
    assert has_element?(lv, "#calendar-list")
    refute html =~ "<table"
  end

  test "shows an empty state when nothing is scheduled", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/calendar")
    assert html =~ "Nothing upcoming"
  end

  test "a non-admin cannot reach the calendar", %{conn: conn} do
    user = user_fixture()
    conn = log_in_user(conn, user)
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/calendar")
  end

  test "renders the page under the shared header", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/calendar")
    assert html =~ "Upcoming"
    refute html =~ ~s(<h1 class="mb-6 text-2xl font-semibold">)
  end

  test "survives a {:series_deleted, id} broadcast (re-derives, no crash)", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/calendar")
    Cinder.Catalog.broadcast_series_deleted(123)
    # still alive
    assert render(lv)
  end

  test "FR session renders a localized episode and series title", %{conn: conn} do
    {series, season} = tree()

    series
    |> Ecto.Changeset.change(localizations: %{"fr" => %{"title" => "Émission Calendrier"}})
    |> Repo.update!()

    Repo.insert!(%Episode{
      season_id: season.id,
      episode_number: 1,
      title: "Coming Soon",
      localizations: %{"fr" => %{"title" => "Bientôt Disponible"}},
      monitored: true,
      air_date: Date.add(Date.utc_today(), 5)
    })

    {:ok, _lv, fr_html} =
      conn
      |> Plug.Test.init_test_session(%{"locale" => "fr"})
      |> live(~p"/calendar")

    assert fr_html =~ "Émission Calendrier"
    assert fr_html =~ "Bientôt Disponible"
    refute fr_html =~ "Calendar Show"
    refute fr_html =~ "Coming Soon"

    {:ok, _lv, en_html} = live(conn, ~p"/calendar")
    assert en_html =~ "Calendar Show"
    assert en_html =~ "Coming Soon"
  end
end
