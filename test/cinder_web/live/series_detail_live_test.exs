defmodule CinderWeb.SeriesDetailLiveTest do
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox
  import Cinder.AccountsFixtures

  alias Cinder.{Catalog, Repo}

  setup :register_and_log_in_admin
  setup :set_mox_global

  # Baseline so the detail page's lazy metadata backfill (enrich_series) always resolves — for the
  # tests that build a series directly via Repo.insert! (no get_series stub of their own), and even
  # when that fire-once async backfill outlives the test as a detached task. Non-pinned + nil
  # metadata so it never injects unexpected strings; per-test stubs (create_series) override it.
  setup do
    stub(Cinder.Catalog.TMDBMock, :get_series, fn tmdb_id ->
      {:ok, base_series_info(tmdb_id)}
    end)

    :ok
  end

  defp base_series_info(tmdb_id) do
    %{
      tmdb_id: tmdb_id,
      tvdb_id: nil,
      title: "S",
      year: 2020,
      poster_path: nil,
      original_language: "en",
      overview: nil,
      genres: nil,
      vote_average: nil,
      first_air_date: nil,
      seasons: []
    }
  end

  # Build a series tree directly via the context (mocked TMDB), at :none so every
  # episode starts un-monitored — the toggles then have something to flip.
  defp create_series(tmdb_id) do
    # Non-pinned so a detached enrich task from another test can't mismatch this stub.
    stub(Cinder.Catalog.TMDBMock, :get_series, fn _ ->
      {:ok,
       %{
         base_series_info(tmdb_id)
         | title: "Test Show",
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

    # Pre-mark the series enriched (vote_average set) so the detail page's lazy metadata
    # backfill is skipped — no extra TMDB call, no detached async task crossing into the next
    # test. enrich_series's fetch path is covered in catalog_metadata_test; here we just want the
    # metadata block populated and the tree/toggle behaviour isolated from the network.
    series
    |> Ecto.Changeset.change(%{
      overview: "A test show overview.",
      genres: ["Drama"],
      vote_average: 8.2,
      first_air_date: ~D[2020-01-01]
    })
    |> Repo.update!()
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

  test "shows audio + subtitle badges on a filed episode", %{conn: conn} do
    series = Repo.insert!(%Cinder.Catalog.Series{tmdb_id: 8200, title: "S", year: 2010})

    season =
      Repo.insert!(%Cinder.Catalog.Season{
        series_id: series.id,
        season_number: 1,
        monitored: true
      })

    Repo.insert!(%Cinder.Catalog.Episode{
      season_id: season.id,
      tmdb_episode_id: 8201,
      episode_number: 1,
      title: "Ep1",
      monitored: true,
      file_path: "/tmp/cinder-test-tv-library/S (2010)/Season 01/S (2010) - S01E01.mkv",
      imported_audio_languages: ["en", "fr"],
      imported_embedded_subtitles: ["en"],
      imported_sidecar_subtitles: ["fr"]
    })

    {:ok, _lv, html} = live(conn, ~p"/series/#{series.id}")
    assert html =~ "audio en"
    assert html =~ "audio fr"
    assert html =~ "subtitle en"
    assert html =~ "subtitle fr"
  end

  test "shows subtitle badges on a filed episode with empty/untagged audio", %{conn: conn} do
    series = Repo.insert!(%Cinder.Catalog.Series{tmdb_id: 8204, title: "S", year: 2010})

    season =
      Repo.insert!(%Cinder.Catalog.Season{
        series_id: series.id,
        season_number: 1,
        monitored: true
      })

    Repo.insert!(%Cinder.Catalog.Episode{
      season_id: season.id,
      tmdb_episode_id: 8205,
      episode_number: 1,
      title: "Ep1",
      monitored: true,
      file_path: "/tmp/cinder-test-tv-library/S (2010)/Season 01/S (2010) - S01E01.mkv",
      imported_audio_languages: [],
      imported_embedded_subtitles: ["en"]
    })

    {:ok, _lv, html} = live(conn, ~p"/series/#{series.id}")
    refute html =~ ~s(aria-label="audio)
    assert html =~ "subtitle en"
  end

  test "no audio/subtitle badges on a filed episode with no media info", %{conn: conn} do
    series = Repo.insert!(%Cinder.Catalog.Series{tmdb_id: 8202, title: "S", year: 2010})

    season =
      Repo.insert!(%Cinder.Catalog.Season{
        series_id: series.id,
        season_number: 1,
        monitored: true
      })

    Repo.insert!(%Cinder.Catalog.Episode{
      season_id: season.id,
      tmdb_episode_id: 8203,
      episode_number: 1,
      title: "Ep1",
      monitored: true,
      file_path: "/tmp/cinder-test-tv-library/S (2010)/Season 01/S (2010) - S01E01.mkv"
    })

    {:ok, _lv, html} = live(conn, ~p"/series/#{series.id}")
    refute html =~ ~s(aria-label="audio)
    refute html =~ ~s(aria-label="subtitle)
  end

  test "renders the series descriptive metadata block", %{conn: conn} do
    series = create_series(720)
    {:ok, _lv, html} = live(conn, ~p"/series/#{series.id}")

    assert html =~ "A test show overview."
    assert html =~ "Drama"
    assert html =~ "8.2"
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

    lv
    |> element(~s|button[phx-click="toggle_season"][phx-value-id="#{season.id}"]|)
    |> render_click()

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

  test "Search all missing re-queues the season's wanted episodes", %{conn: conn} do
    series = series_with_wanted_episode(search_attempts: 9)

    {:ok, lv, _html} = live(conn, ~p"/series/#{series.id}")
    lv |> element("button", "Search all missing") |> render_click()

    assert [ep] = Catalog.wanted_episodes()
    assert ep.search_attempts == 0
  end

  test "the per-episode Search re-queues a single wanted episode", %{conn: conn} do
    series = series_with_wanted_episode(search_attempts: 7)
    [ep] = Catalog.wanted_episodes()

    {:ok, lv, _html} = live(conn, ~p"/series/#{series.id}")

    lv
    |> element("button[phx-click=search_episode][phx-value-id='#{ep.id}']")
    |> render_click()

    assert [requeued] = Catalog.wanted_episodes()
    assert requeued.search_attempts == 0
  end

  # An unmonitored episode is excluded from wanted_episodes/0, so a Search button on it
  # would be a no-op dressed as a confirmation. Gate it on monitored, like the season control.
  test "the per-episode Search button is gated on monitored", %{conn: conn} do
    series = series_with_wanted_episode(search_attempts: 0)
    [monitored] = Catalog.wanted_episodes()
    season = first_season(series.id)

    unmonitored =
      Repo.insert!(%Cinder.Catalog.Episode{
        season_id: season.id,
        tmdb_episode_id: 9102,
        episode_number: 2,
        title: "Two",
        monitored: false,
        air_date: Date.add(Date.utc_today(), -10)
      })

    {:ok, lv, _html} = live(conn, ~p"/series/#{series.id}")

    assert has_element?(lv, "button[phx-click=search_episode][phx-value-id='#{monitored.id}']")
    refute has_element?(lv, "button[phx-click=search_episode][phx-value-id='#{unmonitored.id}']")
  end

  test "a malformed search_episode event does not crash the LiveView", %{conn: conn} do
    series = series_with_wanted_episode(search_attempts: 0)
    {:ok, lv, _html} = live(conn, ~p"/series/#{series.id}")
    render_hook(lv, "search_episode", %{"id" => "not-an-int"})
    assert render(lv) =~ "Test Show"
  end

  # FIX 2: the Search affordance must mirror Catalog.wanted_episodes_query/0 — a monitored,
  # file-less, grab-less episode the sweep would NOT grab (not yet aired, or undated) must not
  # show a "Search" button that only flashes "Searching…" and never grabs.
  test "the per-episode Search button respects the sweep's air-date gate", %{conn: conn} do
    series = Repo.insert!(%Cinder.Catalog.Series{tmdb_id: 9301, tvdb_id: 93, title: "Test Show"})

    season =
      Repo.insert!(%Cinder.Catalog.Season{
        series_id: series.id,
        season_number: 1,
        monitored: true
      })

    aired = wanted_ep(season, 1, air_date: Date.add(Date.utc_today(), -1))
    future = wanted_ep(season, 2, air_date: Date.add(Date.utc_today(), 7))
    undated = wanted_ep(season, 3, air_date: nil)

    {:ok, lv, _html} = live(conn, ~p"/series/#{series.id}")

    assert has_element?(lv, "button[phx-click=search_episode][phx-value-id='#{aired.id}']")
    refute has_element?(lv, "button[phx-click=search_episode][phx-value-id='#{future.id}']")
    refute has_element?(lv, "button[phx-click=search_episode][phx-value-id='#{undated.id}']")
  end

  # FIX 2: season 0 (specials) is excluded from the sweep, so its episodes get no Search button.
  test "the per-episode Search button is absent for a season-0 special", %{conn: conn} do
    series = Repo.insert!(%Cinder.Catalog.Series{tmdb_id: 9302, tvdb_id: 94, title: "Test Show"})

    specials =
      Repo.insert!(%Cinder.Catalog.Season{
        series_id: series.id,
        season_number: 0,
        monitored: true
      })

    special = wanted_ep(specials, 1, air_date: Date.add(Date.utc_today(), -10))

    {:ok, lv, _html} = live(conn, ~p"/series/#{series.id}")
    refute has_element?(lv, "button[phx-click=search_episode][phx-value-id='#{special.id}']")
  end

  # FIX 1: "Find a better match" is only offered for a season with wanted episodes. An empty
  # indexer result then reads as "No releases found", and a fully-present season (TV replace is
  # deferred) is never offered manual search at all.
  test "Find a better match is offered only for a season with wanted episodes", %{conn: conn} do
    wanted = series_with_wanted_episode(search_attempts: 0)
    {:ok, lv, _html} = live(conn, ~p"/series/#{wanted.id}")
    assert has_element?(lv, "button[phx-click=tv_manual_search]")

    %{series: present} =
      series_with_episode_file_fixture("/tmp/cinder-test-tv-library/S (2010)/S01E01.mkv")

    {:ok, lv2, _html} = live(conn, ~p"/series/#{present.id}")
    refute has_element?(lv2, "button[phx-click=tv_manual_search]")
  end

  test "Find a better match opens the TV panel; grabbing creates a grab over the wanted episode",
       %{conn: conn} do
    series = series_with_wanted_episode(search_attempts: 0)
    season = first_season(series.id)

    stub(Cinder.Acquisition.IndexerMock, :search_tv, fn 99, "Test Show", 1 ->
      {:ok,
       [%{title: "Test Show S01E01 1080p WEB-DL GRP", size: 2_000_000_000, download_url: "u"}]}
    end)

    stub(Cinder.Download.ClientMock, :add, fn _release -> {:ok, "hash-new"} end)

    {:ok, lv, _html} = live(conn, ~p"/series/#{series.id}")

    lv |> element("button", "Find a better match") |> render_click()
    assert render_async(lv) =~ "Test Show S01E01"

    lv |> element("#ms-season-#{season.id} button", "Grab") |> render_click()

    assert render(lv) =~ "Grabbing the selected release"
    assert [grab] = Repo.all(Cinder.Catalog.Grab)
    assert grab.download_id == "hash-new"
  end

  # Insert a series→season→episode tree with one still-wanted episode (monitored, no file,
  # no grab, aired). `search_attempts` seeds the backoff counter the search controls zero.
  defp series_with_wanted_episode(opts) do
    attempts = Keyword.get(opts, :search_attempts, 0)
    series = Repo.insert!(%Cinder.Catalog.Series{tmdb_id: 9001, tvdb_id: 99, title: "Test Show"})

    season =
      Repo.insert!(%Cinder.Catalog.Season{
        series_id: series.id,
        season_number: 1,
        monitored: true
      })

    Repo.insert!(%Cinder.Catalog.Episode{
      season_id: season.id,
      tmdb_episode_id: 9101,
      episode_number: 1,
      title: "Pilot",
      monitored: true,
      air_date: Date.add(Date.utc_today(), -10),
      search_attempts: attempts
    })

    Repo.reload!(series)
  end

  # Insert one wanted-shaped episode (monitored, no file, no grab) with a chosen air_date.
  defp wanted_ep(season, number, opts) do
    Repo.insert!(%Cinder.Catalog.Episode{
      season_id: season.id,
      tmdb_episode_id: season.id * 100 + number,
      episode_number: number,
      title: "Ep#{number}",
      monitored: true,
      air_date: Keyword.fetch!(opts, :air_date)
    })
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
