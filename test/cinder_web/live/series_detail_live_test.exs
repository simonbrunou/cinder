defmodule CinderWeb.SeriesDetailLiveTest do
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox
  import Cinder.AccountsFixtures

  alias Cinder.{Catalog, Repo}

  setup :register_and_log_in_admin
  setup :set_mox_global

  # Build a series tree directly via the context (mocked TMDB), at :none so every
  # episode starts un-monitored — the toggles then have something to flip.
  defp create_series(tmdb_id) do
    stub(Cinder.Catalog.TMDBMock, :get_series, fn ^tmdb_id ->
      {:ok,
       %{
         tmdb_id: tmdb_id,
         tvdb_id: nil,
         title: "Test Show",
         year: 2020,
         poster_path: nil,
         seasons: [%{season_number: 1}]
       }}
    end)

    stub(Cinder.Catalog.TMDBMock, :get_season, fn ^tmdb_id, 1 ->
      {:ok,
       %{
         season_number: 1,
         episodes: [
           %{tmdb_episode_id: 1, episode_number: 1, title: "Pilot", air_date: ~D[2020-01-01]},
           %{tmdb_episode_id: 2, episode_number: 2, title: "Two", air_date: ~D[2020-01-08]}
         ]
       }}
    end)

    {:ok, series} = Catalog.add_series_to_watchlist(tmdb_id, monitor_strategy: :none)
    series
  end

  defp first_episode(series_id) do
    Catalog.get_series_with_tree(series_id).seasons |> hd() |> Map.fetch!(:episodes) |> hd()
  end

  defp first_season(series_id) do
    Catalog.get_series_with_tree(series_id).seasons |> hd()
  end

  test "renders the page under the shared header", %{conn: conn} do
    series = create_series(799)
    {:ok, _lv, html} = live(conn, ~p"/series/#{series.id}")
    assert html =~ "Test Show"
    refute html =~ ~s(<h1 class="text-2xl font-semibold">)
  end

  test "renders the season/episode tree", %{conn: conn} do
    series = create_series(700)
    {:ok, _lv, html} = live(conn, ~p"/series/#{series.id}")

    assert html =~ "Test Show"
    assert html =~ "Season 1"
    assert html =~ "Pilot"
    assert html =~ "Two"
  end

  test "toggling an episode flips its monitored flag in the DB", %{conn: conn} do
    series = create_series(701)
    ep = first_episode(series.id)
    refute ep.monitored

    {:ok, lv, _html} = live(conn, ~p"/series/#{series.id}")
    lv |> element(~s|input[phx-value-id="#{ep.id}"]|) |> render_click()

    assert Repo.reload(ep).monitored
  end

  test "the season bulk control monitors every episode", %{conn: conn} do
    series = create_series(702)
    season = first_season(series.id)
    refute season.monitored

    {:ok, lv, _html} = live(conn, ~p"/series/#{series.id}")
    lv |> element(~s|button[phx-value-id="#{season.id}"]|) |> render_click()

    eps = Catalog.get_series_with_tree(series.id).seasons |> hd() |> Map.fetch!(:episodes)
    assert Enum.all?(eps, & &1.monitored)
  end

  test "a missing series redirects to Library (/library)", %{conn: conn} do
    assert {:error, {kind, %{to: "/library"}}} = live(conn, ~p"/series/999999")
    assert kind in [:redirect, :live_redirect]
  end

  test "a non-integer id redirects to Library (/library)", %{conn: conn} do
    assert {:error, {kind, %{to: "/library"}}} = live(conn, ~p"/series/not-a-number")
    assert kind in [:redirect, :live_redirect]
  end

  test "a malformed toggle event does not crash the LiveView", %{conn: conn} do
    series = create_series(703)
    {:ok, lv, _html} = live(conn, ~p"/series/#{series.id}")
    render_hook(lv, "toggle_episode", %{"id" => "not-an-int"})
    assert render(lv) =~ "Test Show"
  end

  test "a series that vanishes out-of-band redirects on the next reload", %{conn: conn} do
    series = create_series(705)
    {:ok, lv, _html} = live(conn, ~p"/series/#{series.id}")

    # Delete the tree (cascades), then a series broadcast forces a reload that finds nothing.
    Repo.delete!(series)
    Phoenix.PubSub.broadcast(Cinder.PubSub, "series", {:series_updated, series.id})

    assert_redirect(lv, "/library")
  end

  test "a non-admin cannot reach the detail page", %{conn: conn} do
    series = create_series(704)
    user = user_fixture()
    conn = log_in_user(conn, user)
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/series/#{series.id}")
    # ponytail: the admin-gate redirect goes to "/" (UserAuth), not "/library"
  end

  test "redirects to Library (/library) when the open series is deleted", %{conn: conn} do
    series = Repo.insert!(%Cinder.Catalog.Series{tmdb_id: 7001, title: "Detail Show"})

    {:ok, lv, _html} = live(conn, ~p"/series/#{series.id}")

    Cinder.Catalog.broadcast_series_deleted(series.id)
    assert_redirect(lv, ~p"/library")
  end

  test "ignores a {:series_deleted, id} for a different series", %{conn: conn} do
    series = Repo.insert!(%Cinder.Catalog.Series{tmdb_id: 7002, title: "Stay Show"})

    {:ok, lv, _html} = live(conn, ~p"/series/#{series.id}")
    Cinder.Catalog.broadcast_series_deleted(series.id + 999)
    assert render(lv) =~ "Stay Show"
  end

  test "admin edits the series title", %{conn: conn} do
    series = create_series(710)
    {:ok, lv, _html} = live(conn, ~p"/series/#{series.id}")

    lv |> element(~s|button[phx-click="edit_series"]|) |> render_click()

    lv
    |> form("#series-form", %{"series" => %{"title" => "Renamed", "year" => "2021"}})
    |> render_submit()

    assert Repo.get!(Cinder.Catalog.Series, series.id).title == "Renamed"
  end

  test "admin cancels the series: grabs reaped, episodes unmonitored", %{conn: conn} do
    series = create_series(711)
    ep = first_episode(series.id)
    # Monitor it + give it an active grab.
    {:ok, _} = Catalog.set_episode_monitored(ep, true)
    {:ok, _grab} = Catalog.create_grab("H-711", :torrent, [ep.id])

    expect(Cinder.Download.ClientMock, :remove, fn "H-711", _opts -> :ok end)

    {:ok, lv, _html} = live(conn, ~p"/series/#{series.id}")
    lv |> element(~s|button[phx-click="ask_cancel_series"]|) |> render_click()
    lv |> element(~s|button[phx-click="confirm_cancel_series"]|) |> render_click()

    assert Repo.all(Cinder.Catalog.Grab) == []
    assert Repo.reload(ep).monitored == false
  end

  test "admin deletes the series and is redirected to Library (/library)", %{conn: conn} do
    series = create_series(712)
    {:ok, lv, _html} = live(conn, ~p"/series/#{series.id}")

    lv |> element(~s|button[phx-click="ask_delete_series"]|) |> render_click()
    lv |> element(~s|button[phx-click="confirm_delete_series"]|) |> render_click()

    assert Repo.get(Cinder.Catalog.Series, series.id) == nil
    assert_redirect(lv, "/library")
  end

  test "deleting an episode file unlinks it and clears file_path (stays monitored)", %{
    conn: conn
  } do
    %{series: series, episode: ep} =
      series_with_episode_file_fixture(
        "/tmp/cinder-test-tv-library/S (2010)/Season 01/S (2010) - S01E01.mkv"
      )

    expect(Cinder.Library.FilesystemMock, :rm, fn _ -> :ok end)
    stub(Cinder.Library.FilesystemMock, :rmdir, fn _ -> {:error, :enotempty} end)

    {:ok, lv, _html} = live(conn, ~p"/series/#{series.id}")

    lv
    |> element("button[phx-click=ask_delete_episode_file][phx-value-id='#{ep.id}']")
    |> render_click()

    lv
    |> element("button[phx-click=confirm_delete_episode_file][phx-value-id='#{ep.id}']")
    |> render_click()

    reloaded = Cinder.Repo.get(Cinder.Catalog.Episode, ep.id)
    assert is_nil(reloaded.file_path)
    assert reloaded.monitored == true
  end

  test "deleting a season's files clears every episode file", %{conn: conn} do
    %{series: series, season: season} =
      season_with_files_fixture([
        "/tmp/cinder-test-tv-library/S (2010)/Season 01/S (2010) - S01E01.mkv"
      ])

    expect(Cinder.Library.FilesystemMock, :rm, fn _ -> :ok end)
    stub(Cinder.Library.FilesystemMock, :rmdir, fn _ -> {:error, :enotempty} end)

    {:ok, lv, _html} = live(conn, ~p"/series/#{series.id}")

    lv
    |> element("button[phx-click=ask_delete_season_files][phx-value-id='#{season.id}']")
    |> render_click()

    lv
    |> element("button[phx-click=confirm_delete_season_files][phx-value-id='#{season.id}']")
    |> render_click()

    assert Cinder.Catalog.get_series_with_tree(series.id).seasons
           |> Enum.flat_map(& &1.episodes)
           |> Enum.all?(&is_nil(&1.file_path))
  end

  # Insert a series→season→episode tree with one episode that has a file_path.
  defp series_with_episode_file_fixture(file_path) do
    series = Repo.insert!(%Cinder.Catalog.Series{tmdb_id: 8001, title: "S", year: 2010})

    season =
      Repo.insert!(%Cinder.Catalog.Season{
        series_id: series.id,
        season_number: 1,
        monitored: true
      })

    episode =
      Repo.insert!(%Cinder.Catalog.Episode{
        season_id: season.id,
        tmdb_episode_id: 8001,
        episode_number: 1,
        title: "Ep1",
        monitored: true,
        file_path: file_path
      })

    %{series: series, season: season, episode: episode}
  end

  # Insert a series→season→episode tree where the given file_paths are assigned across episodes.
  defp season_with_files_fixture(file_paths) do
    series = Repo.insert!(%Cinder.Catalog.Series{tmdb_id: 8002, title: "S", year: 2010})

    season =
      Repo.insert!(%Cinder.Catalog.Season{
        series_id: series.id,
        season_number: 1,
        monitored: true
      })

    file_paths
    |> Enum.with_index(1)
    |> Enum.each(fn {fp, n} ->
      Repo.insert!(%Cinder.Catalog.Episode{
        season_id: season.id,
        tmdb_episode_id: 8100 + n,
        episode_number: n,
        title: "Ep#{n}",
        monitored: true,
        file_path: fp
      })
    end)

    %{series: Repo.reload!(series), season: Repo.reload!(season)}
  end
end
