defmodule CinderWeb.DashboardLiveTest do
  use CinderWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest
  import Mox

  alias Cinder.Accounts.Scope
  alias Cinder.{Catalog, Requests}

  import Cinder.CatalogFixtures

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    # Dashboard runs Health.check_all/0 in a start_async task (separate process) → global mocks.
    stub(Cinder.Acquisition.IndexerMock, :health, fn -> :ok end)
    stub(Cinder.Download.ClientMock, :health, fn -> :ok end)
    stub(Cinder.Download.SabnzbdClientMock, :health, fn -> :ok end)
    stub(Cinder.Library.MediaServerMock, :health, fn -> :ok end)
    stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    :ok
  end

  defp pending_movie_request(requester) do
    {:ok, req} =
      Requests.create_request(requester, %{
        target_type: "movie",
        target_id: System.unique_integer([:positive]),
        title: "Dune",
        year: 2021
      })

    req
  end

  describe "as an admin" do
    setup :register_and_log_in_admin

    test "shows the six maintenance actions", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      for id <-
            ~w(movie-pipeline tv-pipeline series-refresh subtitle-backfill scan-movies scan-tv) do
        assert html =~ ~s(id="maintenance-#{id}")
      end
    end

    for {id, worker} <- [
          {"movie-pipeline", Cinder.Download.Poller},
          {"tv-pipeline", Cinder.Download.TvPoller},
          {"series-refresh", Cinder.Catalog.Refresher},
          {"subtitle-backfill", Cinder.Subtitles.Sweeper}
        ] do
      @tag worker: worker
      test "#{id} runs its supervised worker once", %{conn: conn, worker: worker} do
        start_supervised!({worker, interval: 60_000})
        {:ok, lv, _html} = live(conn, ~p"/dashboard")

        lv |> element("#maintenance-#{unquote(id)}") |> render_click()

        render_async(lv)
        assert has_element?(lv, "#maintenance-result-#{unquote(id)}", "Completed")
      end
    end

    test "movie and TV scan actions pass the intended library kind", %{conn: conn} do
      expect(Cinder.Library.MediaServerMock, :scan, fn :movies -> :ok end)
      expect(Cinder.Library.MediaServerMock, :scan, fn :tv -> :ok end)
      {:ok, lv, _html} = live(conn, ~p"/dashboard")

      lv |> element("#maintenance-scan-movies") |> render_click()
      render_async(lv)
      assert has_element?(lv, "#maintenance-result-scan-movies", "Completed")

      lv |> element("#maintenance-scan-tv") |> render_click()
      render_async(lv)
      assert has_element?(lv, "#maintenance-result-scan-tv", "Completed")
    end

    test "only the running action is disabled", %{conn: conn} do
      parent = self()

      expect(Cinder.Library.MediaServerMock, :scan, fn :movies ->
        send(parent, {:scan_started, self()})

        receive do
          :finish_scan -> :ok
        end
      end)

      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      lv |> element("#maintenance-scan-movies") |> render_click()
      assert_receive {:scan_started, task}

      assert has_element?(lv, "#maintenance-scan-movies[disabled]")
      refute has_element?(lv, "#maintenance-scan-tv[disabled]")

      send(task, :finish_scan)
      render_async(lv)
      assert has_element?(lv, "#maintenance-result-scan-movies", "Completed")
    end

    test "concurrent actions retain independent results", %{conn: conn} do
      stub(Cinder.Library.MediaServerMock, :scan, fn
        :movies -> :ok
        :tv -> {:error, :unavailable}
      end)

      {:ok, lv, _html} = live(conn, ~p"/dashboard")

      lv |> element("#maintenance-scan-movies") |> render_click()
      lv |> element("#maintenance-scan-tv") |> render_click()
      render_async(lv)

      assert has_element?(lv, "#maintenance-result-scan-movies", "Completed")
      assert has_element?(lv, "#maintenance-result-scan-tv", "Failed")
    end

    test "a forged duplicate event does not start an already-running action twice", %{conn: conn} do
      parent = self()

      stub(Cinder.Library.MediaServerMock, :scan, fn :movies ->
        send(parent, {:scan_started, self()})

        receive do
          :finish_scan -> :ok
        end
      end)

      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      lv |> element("#maintenance-scan-movies") |> render_click()
      assert_receive {:scan_started, task}

      render_click(lv, "run_maintenance", %{"action" => "scan-movies"})
      refute_receive {:scan_started, _other_task}, 100

      send(task, :finish_scan)
      render_async(lv)
    end

    test "a returned scan error produces a failure result and logs the reason", %{conn: conn} do
      expect(Cinder.Library.MediaServerMock, :scan, fn :movies -> {:error, :unavailable} end)
      {:ok, lv, _html} = live(conn, ~p"/dashboard")

      log =
        capture_log(fn ->
          lv |> element("#maintenance-scan-movies") |> render_click()
          render_async(lv)
        end)

      assert has_element?(lv, "#maintenance-result-scan-movies", "Failed")
      refute has_element?(lv, "#maintenance-scan-movies[disabled]")
      assert log =~ "maintenance scan_movies failed: :unavailable"
    end

    test "a missing worker produces a failure result", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")

      lv |> element("#maintenance-movie-pipeline") |> render_click()

      render_async(lv)
      assert has_element?(lv, "#maintenance-result-movie-pipeline", "Failed")
      refute has_element?(lv, "#maintenance-movie-pipeline[disabled]")
    end

    test "shows stats, the health panel, and recent activity", %{conn: conn} do
      {:ok, _} = Catalog.add_movie(%{tmdb_id: 1, title: "Arrival", year: 2016})

      {:ok, lv, html} = live(conn, ~p"/dashboard")
      assert html =~ "Dashboard"
      assert html =~ "Recent activity"
      assert html =~ "Arrival"
      # health resolves asynchronously
      assert render_async(lv) =~ "OK"
    end

    test "renders recent movie download progress", %{conn: conn} do
      movie = movie_fixture(%{status: :downloading})

      {:ok, _} =
        Catalog.update_movie_download_metrics(movie, %{
          download_progress: 0.42,
          download_speed: 1_500_000,
          download_eta: 90
        })

      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      assert render(lv) =~ "42%"
    end

    test "approving from the dashboard behaves identically to /requests", %{conn: conn} do
      requester = Cinder.AccountsFixtures.user_fixture()
      req = pending_movie_request(requester)

      {:ok, lv, html} = live(conn, ~p"/dashboard")
      assert html =~ "Dune"

      lv |> element("#pending-#{req.id} button", "Approve") |> render_click()

      assert Cinder.Repo.get(Cinder.Requests.Request, req.id).status == :approved
      assert Catalog.get_movie_by_tmdb_id(req.target_id).status == :requested
    end

    test "denying from the dashboard records the reason", %{conn: conn} do
      requester = Cinder.AccountsFixtures.user_fixture()
      req = pending_movie_request(requester)

      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      lv |> element("#pending-#{req.id} button", "Deny") |> render_click()

      lv
      |> form("#pending-#{req.id} form", %{reason: "Already own it"})
      |> render_submit()

      reloaded = Cinder.Repo.get(Cinder.Requests.Request, req.id)
      assert reloaded.status == :denied
      assert reloaded.denial_reason == "Already own it"
    end

    test "an :upgrading movie counts as in-pipeline", %{conn: conn} do
      {:ok, movie} =
        Catalog.add_movie(%{
          tmdb_id: System.unique_integer([:positive]),
          title: "Blade Runner"
        })

      {:ok, _} = Catalog.transition(movie, %{status: :upgrading})
      {:ok, lv, _html} = live(conn, ~p"/dashboard")

      # With exactly one movie — the :upgrading one — the in-pipeline stat must read 1.
      # Assert the count on the "In pipeline" stat card, not the static label (which is
      # always present): if :upgrading weren't in @pipeline this would render 0.
      assert lv |> element("div.items-baseline", "In pipeline") |> render() =~
               ~r{tabular-nums">\s*1\s*</span>}
    end

    test "shows an empty pending state when there is nothing to approve", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")
      assert html =~ "Nothing to approve"
    end
  end

  test "non-admins are redirected away from /dashboard", %{conn: _conn} do
    conn = build_conn() |> log_in_user(Cinder.AccountsFixtures.user_fixture())
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/dashboard")
  end

  test "signed_in_path is /dashboard for admins, / for users" do
    admin = Scope.for_user(Cinder.AccountsFixtures.admin_fixture())
    user = Scope.for_user(Cinder.AccountsFixtures.user_fixture())

    assert CinderWeb.UserAuth.signed_in_path(%{assigns: %{current_scope: admin}}) == "/dashboard"
    assert CinderWeb.UserAuth.signed_in_path(%{assigns: %{current_scope: user}}) == "/"
    assert CinderWeb.UserAuth.signed_in_path(%{assigns: %{}}) == "/"
  end
end
