defmodule CinderWeb.SeriesLiveTest do
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox
  import Cinder.AccountsFixtures

  # The LiveView (and the start_async add Task) run in their own processes, so the
  # mock must be global (requires async: false).
  setup :register_and_log_in_admin
  setup :set_mox_global

  @show %{tmdb_id: 1399, title: "Game of Thrones", year: 2011, poster_path: "/got.jpg"}

  defp stub_search(results) do
    stub(Cinder.Catalog.TMDBMock, :search_tv, fn _query -> {:ok, results} end)
  end

  test "first load shows the empty state and an accessible search field", %{conn: conn} do
    {:ok, lv, html} = live(conn, ~p"/series")
    assert html =~ "No series added yet."
    assert has_element?(lv, "input#tv-query[aria-label='Search TV series']")
  end

  test "searching renders TMDB TV results", %{conn: conn} do
    stub_search([@show])
    {:ok, lv, _html} = live(conn, ~p"/series")

    html = lv |> form("#tv-search-form", %{"query" => "thrones"}) |> render_change()

    assert html =~ "Game of Thrones"
    assert html =~ "2011"
  end

  test "search results link to the discovery detail page (by tmdb_id)", %{conn: conn} do
    stub_search([@show])
    {:ok, lv, _html} = live(conn, ~p"/series")

    html = lv |> form("#tv-search-form", %{"query" => "thrones"}) |> render_change()

    assert has_element?(lv, ~s(a[href="/series/tmdb/1399"]))
    assert html =~ ~s(href="/series/tmdb/1399")
  end

  test "an unknown event does not crash the LiveView", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/series")
    render_hook(lv, "bogus", %{})
    assert render(lv) =~ "TV series"
  end

  test "a non-admin can load /series but NOT the admin local detail /series/:id", %{conn: conn} do
    user = user_fixture()
    conn = log_in_user(conn, user)
    {:ok, _lv, _html} = live(conn, ~p"/series")
    assert {:error, {:redirect, _}} = live(conn, ~p"/series/1")
  end

  defp stub_tmdb_series(tmdb_id) do
    stub(Cinder.Catalog.TMDBMock, :get_series, fn ^tmdb_id ->
      {:ok,
       %{
         tmdb_id: tmdb_id,
         tvdb_id: 1,
         title: "Game of Thrones",
         year: 2011,
         poster_path: "/got.jpg",
         seasons: [%{season_number: 1}]
       }}
    end)

    stub(Cinder.Catalog.TMDBMock, :get_season, fn ^tmdb_id, 1 ->
      {:ok,
       %{
         season_number: 1,
         episodes: [
           %{
             tmdb_episode_id: 1,
             episode_number: 1,
             title: "Winter Is Coming",
             air_date: ~D[2011-04-17]
           }
         ]
       }}
    end)
  end

  test "non-admin does NOT see the admin 'Added series' management section", %{conn: conn} do
    stub_search([])
    stub_tmdb_series(1399)

    # Add a series so the admin section would render if ungated
    {:ok, _} = Cinder.Catalog.add_series_to_watchlist(1399, monitor_strategy: :all)

    user = user_fixture()
    conn = log_in_user(conn, user)
    {:ok, _lv, html} = live(conn, ~p"/series")

    refute html =~ "Configure monitoring"
    refute html =~ ~s(href="/series/)
  end

  test "admin sees the 'Added series' management section with configure-monitoring links",
       %{conn: conn} do
    stub_search([])
    stub_tmdb_series(1399)

    {:ok, series} = Cinder.Catalog.add_series_to_watchlist(1399, monitor_strategy: :all)

    {:ok, _lv, html} = live(conn, ~p"/series")

    assert html =~ "Configure monitoring"
    assert html =~ ~s(href="/series/#{series.id}")
  end

  test "admin deletes an added series from the list", %{conn: conn} do
    series =
      Cinder.Repo.insert!(%Cinder.Catalog.Series{
        tmdb_id: System.unique_integer([:positive]),
        title: "Deletable",
        monitored: true,
        monitor_strategy: :all
      })

    {:ok, lv, _html} = live(conn, ~p"/series")

    lv
    |> element(~s|button[phx-click="ask_delete_series"][phx-value-id="#{series.id}"]|)
    |> render_click()

    lv
    |> element(~s|button[phx-click="confirm_delete_series"][phx-value-id="#{series.id}"]|)
    |> render_click()

    assert Cinder.Repo.get(Cinder.Catalog.Series, series.id) == nil
    refute render(lv) =~ "series-row-#{series.id}"
  end

  test "a non-admin does not see the admin series controls", %{conn: _conn} do
    Cinder.Repo.insert!(%Cinder.Catalog.Series{
      tmdb_id: System.unique_integer([:positive]),
      title: "Hidden",
      monitored: true,
      monitor_strategy: :all
    })

    user = Cinder.AccountsFixtures.user_fixture()
    conn = log_in_user(build_conn(), user)
    {:ok, _lv, html} = live(conn, ~p"/series")
    refute html =~ "ask_delete_series"
    refute html =~ "Added series"
  end

  test "forged confirm_delete_series from a non-admin does NOT delete the series", %{conn: _conn} do
    series =
      Cinder.Repo.insert!(%Cinder.Catalog.Series{
        tmdb_id: System.unique_integer([:positive]),
        title: "Forge Target",
        monitored: true,
        monitor_strategy: :all
      })

    user = Cinder.AccountsFixtures.user_fixture()
    conn = log_in_user(build_conn(), user)
    {:ok, lv, _html} = live(conn, ~p"/series")

    # Non-admin has no button in the DOM — push the destructive event directly
    render_hook(lv, "confirm_delete_series", %{"id" => to_string(series.id)})

    # The series must still exist in the DB
    assert Cinder.Repo.get(Cinder.Catalog.Series, series.id) != nil
    # The LiveView must still be alive
    assert render(lv) =~ "TV series"
  end
end
