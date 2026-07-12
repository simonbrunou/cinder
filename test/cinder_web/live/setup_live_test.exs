defmodule CinderWeb.SetupLiveTest do
  # async: false — the wizard saves config (mutating global env) and tests services.
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox

  setup :set_mox_global
  setup :reset_cinder_env

  # Stubs every service green. Saving media_server_type switches :media_server to the
  # real Jellyfin impl, so its health is stubbed at the Req.Test (HTTP) layer instead.
  defp stub_all_services_ok do
    stub(Cinder.Catalog.TMDBMock, :health, fn -> :ok end)
    stub(Cinder.Acquisition.IndexerMock, :health, fn -> :ok end)
    stub(Cinder.Download.ClientMock, :health, fn -> :ok end)
    stub(Cinder.Download.SabnzbdClientMock, :health, fn -> :ok end)
    stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)

    Req.Test.set_req_test_to_shared()
    on_exit(fn -> Req.Test.set_req_test_to_private() end)
    Req.Test.stub(Cinder.JellyfinStub, fn conn -> Req.Test.json(conn, %{}) end)
  end

  # Enables qBittorrent + Jellyfin so the loop can validate green.
  @valid_params %{"qbittorrent_enabled" => "true", "media_server_type" => "jellyfin"}

  test "an admin validates services and finishes setup", %{conn: conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()
    conn = log_in_user(conn, admin)
    stub_all_services_ok()

    {:ok, lv, _html} = live(conn, ~p"/setup")

    lv |> form("#setup-form", @valid_params) |> render_submit()
    assert has_element?(lv, "#finish-setup:not([disabled])")

    lv |> element("#finish-setup") |> render_click()
    assert Cinder.Settings.setup_complete?()
  end

  test "the first-run wizard does not expose the remove-after-import toggle", %{conn: conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()
    conn = log_in_user(conn, admin)

    {:ok, _lv, html} = live(conn, ~p"/setup")

    # move_on_import is a /settings-only advanced toggle (it deletes a download); a
    # first-run operator hasn't validated their hardlink topology yet, so keep it out.
    refute html =~ ~s(name="move_on_import")
    # But the wizard still shows the library paths it needs to validate.
    assert html =~ ~s(name="movies_library_path")
  end

  test "a service that fails keeps Finish disabled", %{conn: conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()
    conn = log_in_user(conn, admin)
    stub_all_services_ok()
    stub(Cinder.Acquisition.IndexerMock, :health, fn -> {:error, :econnrefused} end)

    {:ok, lv, _html} = live(conn, ~p"/setup")
    lv |> form("#setup-form", @valid_params) |> render_submit()

    assert has_element?(lv, "#finish-setup[disabled]")
    refute Cinder.Settings.setup_complete?()
  end

  test "a per-service Test button updates that service's badge", %{conn: conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()
    conn = log_in_user(conn, admin)
    stub(Cinder.Catalog.TMDBMock, :health, fn -> :ok end)

    {:ok, lv, _html} = live(conn, ~p"/setup")
    html = lv |> element("button", "Test TMDB") |> render_click()

    assert html =~ "OK"
  end

  test "disclosure state survives service tests and validation", %{conn: conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()
    conn = log_in_user(conn, admin)
    stub_all_services_ok()

    {:ok, lv, _html} = live(conn, ~p"/setup")
    lv |> element("#settings-group-tmdb > summary") |> render_click()
    lv |> element("#settings-group-indexer > summary") |> render_click()

    refute has_element?(lv, "#settings-group-tmdb[open]")
    assert has_element?(lv, "#settings-group-indexer[open]")

    lv |> element("button", "Test TMDB") |> render_click()
    refute has_element?(lv, "#settings-group-tmdb[open]")
    assert has_element?(lv, "#settings-group-indexer[open]")

    lv |> form("#setup-form", @valid_params) |> render_submit()
    refute has_element?(lv, "#settings-group-tmdb[open]")
    assert has_element?(lv, "#settings-group-indexer[open]")
  end

  test "invalid setup preserves safe values and opens, describes, and focuses the field", %{
    conn: conn
  } do
    admin = Cinder.AccountsFixtures.admin_fixture()
    conn = log_in_user(conn, admin)

    {:ok, lv, _html} = live(conn, ~p"/setup")

    html =
      lv
      |> form("#setup-form", %{
        "prowlarr_url" => "http://typed:9696",
        "movies_min_size" => "wrong",
        "tmdb_token" => "must-never-echo",
        "media_server_type" => "jellyfin"
      })
      |> render_submit()

    assert has_element?(lv, "#settings-group-releases[open]")
    assert has_element?(lv, ~s|#prowlarr_url[value="http://typed:9696"]|)
    assert has_element?(lv, ~s|#movies_min_size[value="wrong"][aria-invalid="true"]|)
    assert has_element?(lv, "#movies_min_size-error")
    refute html =~ "must-never-echo"
    flash = lv |> element("#flash-error") |> render()
    refute flash =~ "movies_min_size"
    assert flash =~ "Movies: Min size (GB)"
    assert_push_event(lv, "focus-invalid", %{id: "movies_min_size"})
  end

  test "non-admins cannot reach /setup", %{conn: conn} do
    user = Cinder.AccountsFixtures.user_fixture()
    conn = log_in_user(conn, user)
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/setup")
  end
end
