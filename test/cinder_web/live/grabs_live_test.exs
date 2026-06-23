defmodule CinderWeb.GrabsLiveTest do
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Cinder.AccountsFixtures

  alias Cinder.{Catalog, Repo}
  alias Cinder.Catalog.{Episode, Grab, Season, Series}

  setup :register_and_log_in_admin

  defp grab! do
    series =
      Repo.insert!(%Series{
        tmdb_id: System.unique_integer([:positive]),
        title: "Breaking Bad",
        monitored: true,
        monitor_strategy: :all
      })

    season = Repo.insert!(%Season{series_id: series.id, season_number: 1})

    ep =
      Repo.insert!(%Episode{
        season_id: season.id,
        episode_number: 7,
        title: "Pilot",
        air_date: ~D[2008-01-20]
      })

    {:ok, grab} =
      Catalog.create_grab("HASH-#{System.unique_integer([:positive])}", :torrent, [ep.id])

    {grab, series}
  end

  test "lists grabs with their derived series", %{conn: conn} do
    {_grab, _series} = grab!()
    {:ok, _lv, html} = live(conn, ~p"/grabs")
    assert html =~ "Breaking Bad"
  end

  test "deleting a grab removes it", %{conn: conn} do
    {grab, _series} = grab!()
    {:ok, lv, _html} = live(conn, ~p"/grabs")

    lv |> element(~s|button[phx-click="ask_delete"][phx-value-id="#{grab.id}"]|) |> render_click()

    lv
    |> element(~s|button[phx-click="confirm_delete"][phx-value-id="#{grab.id}"]|)
    |> render_click()

    assert Repo.get(Grab, grab.id) == nil
    refute render(lv) =~ "grab-#{grab.id}"
  end

  test "a non-admin is redirected away from /grabs", %{conn: conn} do
    user = user_fixture()
    conn = log_in_user(build_conn(), user)
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/grabs")
  end
end
