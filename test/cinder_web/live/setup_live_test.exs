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

    Req.Test.stub(Cinder.QBittorrentStub, fn conn ->
      case conn.request_path do
        "/api/v2/auth/login" ->
          conn
          |> Plug.Conn.put_resp_header("set-cookie", "SID=testsid; path=/")
          |> Req.Test.text("Ok.")

        "/api/v2/app/webapiVersion" ->
          Req.Test.text(conn, "2.8.5")
      end
    end)

    Req.Test.stub(Cinder.SabnzbdStub, fn conn ->
      case conn.params["mode"] do
        "queue" -> Req.Test.json(conn, %{"queue" => %{"slots" => []}})
        "get_config" -> Req.Test.json(conn, %{"config" => %{"misc" => %{}}})
      end
    end)

    Req.Test.stub(Cinder.JellyfinStub, fn conn -> Req.Test.json(conn, %{}) end)
  end

  # Enables qBittorrent + Jellyfin so the loop can validate green.
  @valid_params %{"torrent_client" => "qbittorrent", "media_server_type" => "jellyfin"}

  test "an admin validates services and finishes setup", %{conn: conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()
    conn = log_in_user(conn, admin)
    stub_all_services_ok()
    Application.put_env(:cinder, :books_library_path, "/tmp/cinder-test-books-library")
    Application.put_env(:cinder, :audiobooks_library_path, "/tmp/cinder-test-audiobooks-library")

    {:ok, lv, _html} = live(conn, ~p"/setup")

    lv |> form("#setup-form", @valid_params) |> render_submit()
    assert has_element?(lv, "#finish-setup:not([disabled])")

    lv |> element("#finish-setup") |> render_click()
    assert Cinder.Settings.setup_complete?()
  end

  test "the first-run wizard excludes settings-only controls", %{conn: conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()
    conn = log_in_user(conn, admin)

    {:ok, lv, html} = live(conn, ~p"/setup")

    # move_on_import is a /settings-only advanced toggle (it deletes a download); a
    # first-run operator hasn't validated their hardlink topology yet, so keep it out.
    refute html =~ ~s(name="move_on_import")
    refute has_element?(lv, "#anime-settings")
    # But the wizard still shows the library paths it needs to validate.
    assert html =~ ~s(name="movies_library_path")
    assert html =~ ~s(name="movies_anime_library_path")
    assert html =~ ~s(name="books_library_path")
    assert html =~ ~s(name="audiobooks_library_path")
    refute html =~ ~s(name="books_anime_library_path")
  end

  test "book and audiobook roots are required to finish setup, like the video ones", %{
    conn: conn
  } do
    admin = Cinder.AccountsFixtures.admin_fixture()
    conn = log_in_user(conn, admin)
    stub_all_services_ok()

    {:ok, lv, _html} = live(conn, ~p"/setup")

    assert has_element?(lv, "button[phx-value-service=ebook_library]", "Test Ebooks library")
    assert has_element?(
             lv,
             "button[phx-value-service=audiobook_library]",
             "Test Audiobooks library"
           )

    # The checklist now lists all four library-path rows, book and video alike.
    assert has_element?(lv, "#setup-checklist", "Movies library path")
    assert has_element?(lv, "#setup-checklist", "TV library path")
    assert has_element?(lv, "#setup-checklist", "Ebooks library path")
    assert has_element?(lv, "#setup-checklist", "Audiobooks library path")

    # Neither book root is configured yet: Finish stays locked exactly like an unset/unwritable
    # video root would, proving the requirement is enforced and not merely displayed.
    lv |> form("#setup-form", @valid_params) |> render_submit()
    assert has_element?(lv, "#finish-setup[disabled]")

    Application.put_env(:cinder, :books_library_path, "/tmp/cinder-test-books-library")
    Application.put_env(:cinder, :audiobooks_library_path, "/tmp/cinder-test-audiobooks-library")

    lv |> form("#setup-form", @valid_params) |> render_submit()
    assert has_element?(lv, "#finish-setup:not([disabled])")
  end

  test "the wizard gives required sections an ordered path from a clear starting point", %{
    conn: conn
  } do
    admin = Cinder.AccountsFixtures.admin_fixture()
    conn = log_in_user(conn, admin)

    {:ok, lv, _html} = live(conn, ~p"/setup")

    assert has_element?(
             lv,
             "#setup-required-steps",
             "Complete these five required steps in order"
           )

    assert has_element?(lv, "#setup-step-1", "Start here")

    for {step, group, label} <- [
          {1, "tmdb", "TMDB"},
          {2, "indexer", "Indexer"},
          {3, "download", "Download clients"},
          {4, "media_server", "Media server"},
          {5, "library", "Library paths"}
        ] do
      assert has_element?(lv, "#setup-step-#{step}", label)
      assert has_element?(lv, "#settings-group-#{group}[data-setup-step=\"#{step}\"]")
    end

    for group <- ~w(migration releases subtitles notifications accounts) do
      assert has_element?(lv, "#settings-group-#{group}[data-setup-optional=true]", "Optional")
    end
  end

  test "every setup section explains its purpose and credential sources are linked", %{conn: conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()
    conn = log_in_user(conn, admin)

    {:ok, lv, _html} = live(conn, ~p"/setup")

    for {group, _label} <- Cinder.Settings.groups() do
      assert has_element?(lv, "#settings-group-#{group} .setup-section-help")
    end

    assert has_element?(lv, "#settings-group-tmdb .setup-section-help", "movie and TV metadata")
    assert has_element?(lv, "#settings-group-indexer .setup-section-help", "finds releases")

    assert has_element?(
             lv,
             "#settings-group-library .setup-section-help",
             "reusing disk space when possible"
           )

    assert has_element?(
             lv,
             "#settings-group-library label[for=import_roots]",
             "Download folders"
           )

    assert has_element?(
             lv,
             "#settings-group-library",
             "Folders where your download clients save completed files"
           )

    assert has_element?(
             lv,
             ~s|#import_roots[aria-describedby="import_roots-help"]|
           )

    assert has_element?(
             lv,
             "#import_roots-help",
             "Folders where your download clients save completed files"
           )

    assert has_element?(
             lv,
             "#settings-group-library label[for=movies_library_path]",
             "Movies library folder"
           )

    assert has_element?(
             lv,
             "#settings-group-library",
             "reuses the download's disk space instead of making another full copy"
           )

    for kind <- ~w(movies tv) do
      assert has_element?(
               lv,
               ~s|##{kind}_library_path[aria-describedby="library-paths-help"]|
             )
    end

    assert has_element?(
             lv,
             "#library-paths-help",
             "reuses the download's disk space instead of making another full copy"
           )

    assert has_element?(
             lv,
             "#settings-group-library label[for=ffprobe_bin]",
             "ffprobe media analysis tool"
           )

    assert has_element?(
             lv,
             "#settings-group-library",
             "Cinder uses ffprobe to check audio and subtitle languages after import"
           )

    assert has_element?(
             lv,
             ~s|#ffprobe_bin[aria-describedby="ffprobe_bin-help"]|
           )

    assert has_element?(
             lv,
             "#ffprobe_bin-help",
             "Cinder uses ffprobe to check audio and subtitle languages after import"
           )

    for jargon <- ["Download import roots", "hardlink", "ffprobe binary", "filesystem root"] do
      refute has_element?(lv, "#settings-group-library", jargon)
    end

    for {group, url} <- [
          {"tmdb", "https://developer.themoviedb.org/docs/authentication-application"},
          {"indexer", "https://wiki.servarr.com/prowlarr/settings"},
          {"download", "https://www.qbittorrent.org/"},
          {"media_server", "https://www.plex.tv/media-server-downloads/"},
          {"subtitles",
           "https://opensubtitles.stoplight.io/docs/opensubtitles-api/e3750fd63a100-getting-started"},
          {"notifications", "https://docs.discord.com/developers/resources/webhook"}
        ] do
      assert has_element?(
               lv,
               "#settings-group-#{group} .setup-section-help a[href=\"#{url}\"][target=_blank][rel=\"noopener noreferrer\"]"
             )
    end

    assert has_element?(
             lv,
             "#settings-group-media_server .setup-section-help a[href=\"https://support.plex.tv/articles/204059436-finding-an-authentication-token-x-plex-token/\"]"
           )
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

  test "a SABnzbd configuration warning remains reachable during setup", %{conn: conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()
    conn = log_in_user(conn, admin)
    stub_all_services_ok()
    Application.put_env(:cinder, :books_library_path, "/tmp/cinder-test-books-library")
    Application.put_env(:cinder, :audiobooks_library_path, "/tmp/cinder-test-audiobooks-library")

    Req.Test.stub(Cinder.SabnzbdStub, fn conn ->
      case conn.params["mode"] do
        "queue" ->
          Req.Test.json(conn, %{"queue" => %{"slots" => []}})

        "get_config" ->
          Req.Test.json(conn, %{
            "config" => %{
              "misc" => %{"folder_max_length" => 60, "no_dupes" => 0, "no_series_dupes" => 0}
            }
          })
      end
    end)

    {:ok, lv, _html} = live(conn, ~p"/setup")

    lv
    |> form("#setup-form", %{"torrent_client" => "disabled", "media_server_type" => "jellyfin"})
    |> render_submit()

    assert has_element?(lv, "#finish-setup:not([disabled])")
  end

  test "a per-service Test button updates that service's badge", %{conn: conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()
    conn = log_in_user(conn, admin)
    stub(Cinder.Catalog.TMDBMock, :health, fn -> :ok end)

    {:ok, lv, _html} = live(conn, ~p"/setup")
    html = lv |> element("button", "Test TMDB") |> render_click()

    assert html =~ "OK"
  end

  test "native disclosures avoid server events and successful validation resets form state", %{
    conn: conn
  } do
    admin = Cinder.AccountsFixtures.admin_fixture()
    conn = log_in_user(conn, admin)
    stub_all_services_ok()

    {:ok, lv, _html} = live(conn, ~p"/setup")
    assert has_element?(lv, ~s|#setup-form[phx-hook="FormState"][data-form-revision="0"]|)
    assert has_element?(lv, "#settings-group-tmdb[phx-hook=DisclosureState]")
    refute has_element?(lv, "#settings-group-tmdb > summary[phx-click]")

    lv |> element("button", "Test TMDB") |> render_click()
    assert has_element?(lv, ~s|#setup-form[data-form-revision="0"]|)

    lv |> form("#setup-form", @valid_params) |> render_submit()
    assert has_element?(lv, ~s|#setup-form[data-form-revision="1"]|)
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

  test "the wizard surfaces optional notifications without gating Finish", %{conn: conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()
    conn = log_in_user(conn, admin)

    {:ok, lv, html} = live(conn, ~p"/setup")

    # The SMTP + Discord fields are reachable in the wizard (reused SettingsComponents markup),
    assert html =~ ~s(name="smtp_host")
    assert html =~ ~s(name="discord_webhook_url")
    # and a signpost makes the optional notifications step discoverable rather than silently off.
    assert has_element?(lv, "#setup-notifications-note")
    # It is not part of the required set — no notification service appears in the checklist.
    refute has_element?(lv, "#setup-checklist", "Discord")
  end

  # `validate` is the other caller of Settings.save_form/1, which reaches into the payload's
  # VALUES — String.trim/1 and String.split/2 both raise on a non-binary, past the point where
  # the clause matched and so past the catch-all. First-run-only, but same admin threat model.
  test "a forged validate payload is ignored rather than crashing the wizard", %{conn: conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()
    conn = log_in_user(conn, admin)

    {:ok, lv, _html} = live(conn, ~p"/setup")
    prowlarr_before = Cinder.Settings.get("prowlarr_url")

    assert render_hook(lv, "validate", ["forged"])

    for forged <- [%{"forged" => true}, ["x"], 7] do
      assert render_hook(lv, "validate", %{"tv_max_size" => forged})
      assert render_hook(lv, "validate", %{"import_roots" => forged})
      assert render_hook(lv, "validate", %{"prowlarr_url" => forged})
    end

    assert Process.alive?(lv.pid)
    assert Cinder.Settings.get("prowlarr_url") == prowlarr_before
  end

  test "non-admins cannot reach /setup", %{conn: conn} do
    user = Cinder.AccountsFixtures.user_fixture()
    conn = log_in_user(conn, user)
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/setup")
  end
end
