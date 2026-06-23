defmodule CinderWeb.SeriesDiscoveryLiveTest do
  use CinderWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Mox

  setup :set_mox_global

  setup do
    stub(Cinder.Catalog.TMDBMock, :get_series, fn 1399 ->
      {:ok,
       %{
         tmdb_id: 1399,
         tvdb_id: 1,
         title: "GoT",
         year: 2011,
         poster_path: nil,
         seasons: [%{season_number: 1}, %{season_number: 2}]
       }}
    end)

    :ok
  end

  test "lists seasons from TMDB with Request buttons for a not-yet-added show", %{conn: conn} do
    conn = log_in_user(conn, Cinder.AccountsFixtures.user_fixture())
    {:ok, lv, html} = live(conn, ~p"/series/tmdb/1399")
    assert html =~ "GoT"
    assert has_element?(lv, ~s(button[phx-value-season="1"]), "Request")
    assert has_element?(lv, ~s(button[phx-value-season="2"]), "Request")
  end

  test "requesting a season creates a pending request and swaps the button for a badge", %{
    conn: conn
  } do
    user = Cinder.AccountsFixtures.user_fixture()
    conn = log_in_user(conn, user)
    {:ok, lv, _} = live(conn, ~p"/series/tmdb/1399")
    html = lv |> element(~s(button[phx-value-season="2"]), "Request") |> render_click()

    assert [%{target_type: "season", target_id: 1399, season_number: 2, status: :pending}] =
             Cinder.Requests.list_for_user(user)

    assert html =~ "Pending"
  end
end
