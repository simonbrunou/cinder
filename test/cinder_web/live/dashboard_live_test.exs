defmodule CinderWeb.DashboardLiveTest do
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox

  alias Cinder.Accounts.Scope
  alias Cinder.{Catalog, Requests}

  import Cinder.CatalogFixtures

  setup :set_mox_global

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
