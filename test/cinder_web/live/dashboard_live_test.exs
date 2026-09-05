defmodule CinderWeb.DashboardLiveTest do
  use CinderWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest
  import Mox

  alias Cinder.{Accounts, Catalog, Requests}
  alias Cinder.Accounts.Scope

  import Cinder.CatalogFixtures

  setup :set_mox_global
  setup :verify_on_exit!

  # Each worker's poll stamps last-run into process-global :persistent_term (PollerSkeleton's
  # `status/0`); erase all four so a run triggered here can't bleed into another test/suite.
  setup do
    on_exit(fn ->
      :persistent_term.erase({Cinder.Download.Poller, :last_run})
      :persistent_term.erase({Cinder.Download.TvPoller, :last_run})
      :persistent_term.erase({Cinder.Catalog.Refresher, :last_run})
      :persistent_term.erase({Cinder.Subtitles.Sweeper, :last_run})
    end)

    :ok
  end

  setup do
    # Dashboard runs Health.check_all/0 in a start_async task (separate process) → global mocks.
    stub(Cinder.Acquisition.IndexerMock, :health, fn -> :ok end)
    stub(Cinder.Books.PrimaryMetadataMock, :health, fn -> :ok end)
    stub(Cinder.Books.SecondaryMetadataMock, :health, fn -> :ok end)
    stub(Cinder.Download.ClientMock, :health, fn -> :ok end)
    stub(Cinder.Download.SabnzbdClientMock, :health, fn -> :ok end)
    stub(Cinder.Library.MediaServerMock, :health, fn -> :ok end)
    stub(Cinder.Library.AudiobookServerMock, :health, fn -> :ok end)
    stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    stub(Cinder.Library.FilesystemMock, :write_exclusive, fn _, _ -> :ok end)
    stub(Cinder.Library.FilesystemMock, :rm, fn _ -> :ok end)

    stub(Cinder.Catalog.TMDBMock, :get_movie, fn id ->
      {:ok,
       %{
         tmdb_id: id,
         imdb_id: nil,
         title: "Dune",
         year: 2021,
         poster_path: nil,
         original_language: "en"
       }}
    end)

    stub(Cinder.Catalog.TMDBMock, :get_movie_alternative_titles, fn _ -> {:ok, []} end)
    :ok
  end

  defp pending_movie_request(requester, attrs \\ %{}) do
    {:ok, req} =
      Requests.create_request(
        requester,
        Map.merge(
          %{
            target_type: "movie",
            target_id: System.unique_integer([:positive]),
            title: "Dune",
            year: 2021
          },
          attrs
        )
      )

    req
  end

  describe "as an admin" do
    setup :register_and_log_in_admin

    test "shows the six maintenance actions with plain-language labels", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/dashboard")

      for id <-
            ~w(movie-pipeline tv-pipeline series-refresh subtitle-backfill scan-movies scan-tv) do
        assert html =~ ~s(id="maintenance-#{id}")
      end

      assert has_element?(lv, "p.font-medium", "Check monitored series for updates")
      assert has_element?(lv, "p", "Check TMDB for changes to monitored series and episodes.")

      assert has_element?(
               lv,
               ~s|#maintenance-series-refresh[aria-label="Run now: Check monitored series for updates"]|
             )

      assert has_element?(lv, "p.font-medium", "Find missing subtitles")
      assert has_element?(lv, "p", "Find missing subtitles for imported movies and episodes.")

      assert has_element?(
               lv,
               ~s|#maintenance-subtitle-backfill[aria-label="Run now: Find missing subtitles"]|
             )

      refute has_element?(lv, "p.font-medium", "Monitored series refresh")
      refute has_element?(lv, "p.font-medium", "Subtitle backfill")
    end

    test "renders an interpolated maintenance aria-label in French", %{
      conn: conn,
      user: admin
    } do
      assert {:ok, _admin} = Accounts.update_user_locale(admin, %{locale: "fr"})
      {:ok, lv, _html} = live(conn, ~p"/dashboard")

      assert has_element?(
               lv,
               ~s|#maintenance-subtitle-backfill[aria-label="Exécuter maintenant : Rechercher les sous-titres manquants"]|
             )
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

    test "a completed maintenance action emits one completion notification", %{conn: conn} do
      Cinder.TestNotifier.subscribe()
      expect(Cinder.Library.MediaServerMock, :scan, fn :movies -> :ok end)
      {:ok, lv, _html} = live(conn, ~p"/dashboard")

      lv |> element("#maintenance-scan-movies") |> render_click()
      render_async(lv)

      assert_receive {:notify, {:maintenance_completed, :scan_movies}}
      refute_receive {:notify, _}
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

      assert has_element?(
               lv,
               ~s(#maintenance-scan-movies[aria-label="Running: Movie library scan"])
             )

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

      log =
        capture_log(fn ->
          lv |> element("#maintenance-scan-movies") |> render_click()
          lv |> element("#maintenance-scan-tv") |> render_click()
          render_async(lv)
        end)

      assert has_element?(lv, "#maintenance-result-scan-movies", "Completed")
      assert has_element?(lv, "#maintenance-result-scan-tv", "Failed")
      assert log =~ "maintenance scan_tv failed: :unavailable"
    end

    test "a forged duplicate event does not start or notify twice", %{conn: conn} do
      parent = self()
      Cinder.TestNotifier.subscribe()

      stub(Cinder.Library.MediaServerMock, :scan, fn :movies ->
        send(parent, {:scan_started, self()})

        receive do
          :finish_scan -> :ok
        end
      end)

      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      lv |> element("#maintenance-scan-movies") |> render_click()
      assert_receive {:scan_started, task}
      refute_receive {:notify, _}

      render_click(lv, "run_maintenance", %{"action" => "scan-movies"})
      refute_receive {:scan_started, _other_task}, 100
      refute_receive {:notify, _}

      send(task, :finish_scan)
      render_async(lv)
      assert_receive {:notify, {:maintenance_completed, :scan_movies}}
      refute_receive {:notify, _}
    end

    test "a returned scan error produces a failure result and logs the reason", %{conn: conn} do
      Cinder.TestNotifier.subscribe()
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
      assert_receive {:notify, {:maintenance_failed, :scan_movies, :unavailable}}
      refute_receive {:notify, _}
    end

    test "a missing worker produces a failure result", %{conn: conn} do
      Cinder.TestNotifier.subscribe()
      {:ok, lv, _html} = live(conn, ~p"/dashboard")

      log =
        capture_log(fn ->
          lv |> element("#maintenance-movie-pipeline") |> render_click()
          render_async(lv)
        end)

      assert has_element?(lv, "#maintenance-result-movie-pipeline", "Failed")
      refute has_element?(lv, "#maintenance-movie-pipeline[disabled]")
      assert log =~ "maintenance movie_pipeline failed:"
      assert log =~ ":noproc"
      assert_receive {:notify, {:maintenance_failed, :movie_pipeline, _reason}}
      refute_receive {:notify, _}
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

    test "shows a reachable SABnzbd configuration warning in amber", %{conn: conn} do
      stub(Cinder.Download.SabnzbdClientMock, :health, fn ->
        {:warning, {:sabnzbd_config, [{:folder_max_length, 60}]}}
      end)

      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      render_async(lv)

      assert has_element?(lv, "#dashboard-health .badge-warning", "Warning")
      assert has_element?(lv, "#dashboard-health p.text-warning", "Folder name limit is 60")
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

    test "a held book target says so on the dashboard too", %{conn: conn} do
      requester = Cinder.AccountsFixtures.user_fixture()
      id = Integer.to_string(System.unique_integer([:positive]))

      {:ok, profile} =
        Catalog.create_profile(%{name: "Ebooks #{id}", kind: :ebook, handling: :standard})

      {:ok, work} =
        Cinder.Books.upsert_work(%{
          title: "Held Book #{id}",
          identifier: %{provider: "openlibrary", kind: "work", foreign_id: id}
        })

      {:ok, req} =
        Cinder.Requests.create_request(requester, %{
          target_type: "book",
          target_id: work.id,
          media_kind: :ebook
        })

      {:ok, target} = Cinder.Books.ensure_target(work, :ebook)

      {:ok, _} =
        Cinder.Books.transition_target(target, %{status: :held, hold_reason: "identity conflict"},
          expect: :unmonitored
        )

      {:ok, lv, _html} = live(conn, ~p"/dashboard")

      lv
      |> form("#dashboard-approval-form-#{req.id}", %{
        "_id" => to_string(req.id),
        "profile_id" => to_string(profile.id)
      })
      |> render_submit()

      render_async(lv)

      assert render(lv) =~ "on hold"
      assert Cinder.Repo.get(Cinder.Requests.Request, req.id).status == :pending
    end

    test "approving from the dashboard behaves identically to /requests", %{conn: conn} do
      requester = Cinder.AccountsFixtures.user_fixture()
      req = pending_movie_request(requester)
      standard = Enum.find(Catalog.list_profiles(:movies), &(&1.handling == :standard))

      {:ok, lv, html} = live(conn, ~p"/dashboard")
      assert html =~ "Dune"

      lv
      |> form("#dashboard-approval-form-#{req.id}", %{
        "_id" => to_string(req.id),
        "profile_id" => to_string(standard.id)
      })
      |> render_submit()

      render_async(lv)

      assert Cinder.Repo.get(Cinder.Requests.Request, req.id).status == :approved
      movie = Catalog.get_movie_by_tmdb_id(req.target_id)
      assert movie.status == :requested
      assert movie.media_profile == :standard
    end

    test "shows an Anime proposal and lets the admin confirm Standard instead", %{conn: conn} do
      requester = Cinder.AccountsFixtures.user_fixture()
      anime = Enum.find(Catalog.list_profiles(:movies), &(&1.handling == :anime))
      standard = Enum.find(Catalog.list_profiles(:movies), &(&1.handling == :standard))

      req =
        pending_movie_request(requester, %{
          proposed_profile_id: anime.id,
          proposed_media_profile: :anime
        })

      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      selector = "#dashboard-approval-profile-#{req.id}"
      form = "#dashboard-approval-form-#{req.id}"
      assert has_element?(lv, "#{selector} option[value='#{anime.id}'][selected]")

      lv
      |> form(form, %{"_id" => to_string(req.id), "profile_id" => to_string(standard.id)})
      |> render_submit()

      render_async(lv)

      assert Catalog.get_movie_by_tmdb_id(req.target_id).media_profile == :standard
    end

    test "explicitly confirms an Anime proposal from the dashboard", %{conn: conn} do
      requester = Cinder.AccountsFixtures.user_fixture()
      anime = Enum.find(Catalog.list_profiles(:movies), &(&1.handling == :anime))

      req =
        pending_movie_request(requester, %{
          proposed_profile_id: anime.id,
          proposed_media_profile: :anime
        })

      {:ok, lv, _html} = live(conn, ~p"/dashboard")

      lv
      |> form("#dashboard-approval-form-#{req.id}", %{
        "_id" => to_string(req.id),
        "profile_id" => to_string(anime.id)
      })
      |> render_submit()

      render_async(lv)

      assert Catalog.get_movie_by_tmdb_id(req.target_id).media_profile == :anime
    end

    test "denying from the dashboard records the reason", %{conn: conn} do
      requester = Cinder.AccountsFixtures.user_fixture()
      req = pending_movie_request(requester)

      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      lv |> element("#pending-#{req.id} button", "Deny") |> render_click()

      lv
      |> form("#pending-#{req.id} form[phx-submit='deny']", %{reason: "Already own it"})
      |> render_submit()

      render(lv)

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

    test "shows the pending accounts count linking to /users", %{conn: conn} do
      Cinder.AccountsFixtures.user_fixture()
      |> Ecto.Changeset.change(active: false)
      |> Cinder.Repo.update!()

      {:ok, lv, _html} = live(conn, ~p"/dashboard")

      assert lv |> element("div.items-baseline", "Pending accounts") |> render() =~
               ~r{tabular-nums">\s*1\s*</span>}

      assert has_element?(lv, ~s|a[href="/users"]|, "Pending accounts")
    end

    test "the pending accounts count live-updates when an admin activates a waiting account", %{
      conn: conn,
      user: admin
    } do
      pending =
        Cinder.AccountsFixtures.user_fixture()
        |> Ecto.Changeset.change(active: false)
        |> Cinder.Repo.update!()

      {:ok, lv, _html} = live(conn, ~p"/dashboard")

      assert lv |> element("div.items-baseline", "Pending accounts") |> render() =~
               ~r{tabular-nums">\s*1\s*</span>}

      {:ok, _} = Cinder.Accounts.activate_user(admin, pending)

      assert lv |> element("div.items-baseline", "Pending accounts") |> render() =~
               ~r{tabular-nums">\s*0\s*</span>}
    end

    test "the pending queue shows a non-default Audio pick, but not the default", %{conn: conn} do
      requester = Cinder.AccountsFixtures.user_fixture()
      pending_movie_request(requester, %{preferred_language: "dual"})
      pending_movie_request(requester, %{preferred_language: "original"})

      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      assert html =~ "Audio: French + original"
      refute html =~ "Audio: Original"
    end
  end

  describe "disk space (as an admin)" do
    setup :register_and_log_in_admin
    setup :reset_cinder_env

    test "shows free/total space for a configured, readable root", %{conn: conn} do
      dir =
        Path.join(
          System.tmp_dir!(),
          "cinder-dashboard-disk-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      Application.put_env(:cinder, :movies_library_path, dir)
      Application.delete_env(:cinder, :tv_library_path)

      {:ok, lv, _html} = live(conn, ~p"/dashboard")

      # Disk stats resolve asynchronously (a slow/hung `df` must not block render).
      assert render_async(lv) =~ "Disk space"
      assert has_element?(lv, "#disk-movies", "free of")
    end

    test "degrades to an Unavailable row for a configured but unreadable root", %{conn: conn} do
      path = "/nonexistent/cinder-dashboard-disk-#{System.unique_integer([:positive])}"
      Application.put_env(:cinder, :movies_library_path, path)
      Application.delete_env(:cinder, :tv_library_path)

      Application.put_env(:cinder, :disk_stats_stub, fn
        ^path -> {:error, :enoent}
        _other -> {:ok, %{free_bytes: 1_000, total_bytes: 2_000}}
      end)

      {:ok, lv, _html} = live(conn, ~p"/dashboard")

      render_async(lv)
      assert has_element?(lv, "#disk-movies", "Unavailable")
      refute has_element?(lv, "#disk-movies", "free of")
    end

    test "shows the no-library-path hint but still the Database row when none configured", %{
      conn: conn
    } do
      Application.delete_env(:cinder, :movies_library_path)
      Application.delete_env(:cinder, :tv_library_path)

      {:ok, lv, _html} = live(conn, ~p"/dashboard")

      assert render_async(lv) =~ "No library paths configured"
      # The database volume is always monitored, so its row shows even with no library paths set.
      assert has_element?(lv, "#disk-database", "Database")
    end

    test "always shows a Database row for the DB volume", %{conn: conn} do
      Application.put_env(:cinder, :movies_library_path, System.tmp_dir!())
      Application.delete_env(:cinder, :tv_library_path)

      {:ok, lv, _html} = live(conn, ~p"/dashboard")

      render_async(lv)
      assert has_element?(lv, "#disk-database", "Database")
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
