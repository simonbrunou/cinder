defmodule CinderWeb.SettingsLiveTest do
  # async: false — saving mutates global Application env via load_into_env/0, and the
  # LiveView process needs the shared sandbox connection.
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox

  alias Cinder.Catalog.UpgradeHunter
  alias Cinder.Settings

  setup :register_and_log_in_admin

  setup do
    keys = [Cinder.Subtitles.Provider.OpenSubtitles, :anime_preferences]
    original = Map.new(keys, &{&1, Application.get_env(:cinder, &1)})

    on_exit(fn ->
      assert Map.new(keys, &{&1, Application.get_env(:cinder, &1)}) == original
    end)

    :ok
  end

  setup :reset_cinder_env
  setup :set_mox_global

  test "renders the grouped settings form", %{conn: conn} do
    {:ok, lv, html} = live(conn, ~p"/settings")

    assert html =~ "Settings"
    assert html =~ "TMDB"
    assert html =~ "Migration sources"
    assert html =~ "Download clients"
    assert html =~ "Media server"
    assert html =~ "Library"
    assert html =~ ~s(name="movies_library_path")
    assert html =~ ~s(name="movies_anime_library_path")
    assert has_element?(lv, "#movies_anime_library_path-help", "Leave blank")
    assert has_element?(lv, "#books_library_path[name=books_library_path]")
    assert has_element?(lv, "#audiobooks_library_path[name=audiobooks_library_path]")
    assert has_element?(lv, "button[phx-value-service=ebook_library]", "Test Ebooks library")
    # Positive control: Plex section inputs do render here, so the refutes below are live.
    assert has_element?(lv, "#movies_plex_section")

    # Anime root is root-role spelled; the video-policy and Plex fields are media-kind spelled.
    refute has_element?(lv, "#books_anime_library_path")
    refute has_element?(lv, "#audiobooks_anime_library_path")

    for kind <- ~w(ebook audiobook) do
      refute has_element?(lv, "##{kind}_min_size")
      refute has_element?(lv, "##{kind}_max_size")
      refute has_element?(lv, "##{kind}_preferred_resolutions")
      refute has_element?(lv, "##{kind}_preferred_sources")
      refute has_element?(lv, "##{kind}_preferred_terms")
      refute has_element?(lv, "##{kind}_blocked_terms")
      refute has_element?(lv, "##{kind}_upgrade_cutoff")
      refute has_element?(lv, "##{kind}_plex_section")
    end

    assert html =~ ~s(name="import_roots")
    assert html =~ ~s(name="default_request_quota")
    assert has_element?(lv, "#movies_preferred_terms[name=movies_preferred_terms]")
    assert has_element?(lv, "#movies_blocked_terms[name=movies_blocked_terms]")
    assert has_element?(lv, "#movies_upgrade_cutoff[name=movies_upgrade_cutoff]")
    assert has_element?(lv, "#qbittorrent_remote_path_prefix")
    assert has_element?(lv, "#qbittorrent_local_path_prefix")
    assert has_element?(lv, "#sabnzbd_remote_path_prefix")
    assert has_element?(lv, "#radarr_url")
    assert has_element?(lv, "#sonarr_url")
    assert has_element?(lv, "#sabnzbd_local_path_prefix")
    assert has_element?(lv, "#libretranslate_batch_size[name=libretranslate_batch_size]")
    assert has_element?(lv, "#libretranslate_timeout[name=libretranslate_timeout]")
    assert has_element?(lv, "p", "Path prefix as the download client reports it")
    assert has_element?(lv, "p", "The same directory as Cinder sees it")
    # The remove-after-import toggle lives on /settings (Library section).
    assert html =~ ~s(name="move_on_import")
    assert html =~ "Save settings"
    assert has_element?(lv, ~s(a[href="/settings/profiles"]), "Media profiles")
    refute has_element?(lv, ".setup-section-help")
    refute has_element?(lv, "[data-setup-step]")
    refute has_element?(lv, "[data-setup-optional]")
  end

  test "associates the remove-after-import toggle with its help text", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/settings")

    assert has_element?(
             lv,
             ~s|input[name="move_on_import"][aria-describedby="move_on_import-help"]|
           )

    assert has_element?(lv, "#move_on_import-help", "After a Usenet import")
  end

  test "explains how sensitive settings are protected in plain language", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/settings")

    assert has_element?(
             lv,
             "p",
             "External service settings are saved in the database. Passwords and API keys are protected. Save before testing a connection."
           )

    refute has_element?(lv, "p", "encrypted at rest")
  end

  test "warns loudly when a stored secret cannot be decrypted, naming the field", %{conn: conn} do
    # No undecryptable secret yet → no alert.
    {:ok, _lv, html} = live(conn, ~p"/settings")
    refute html =~ "could not be decrypted"

    # A secret encrypted under a different SECRET_KEY_BASE can't be decrypted (here: not even
    # base64, the simplest undecryptable shape).
    Cinder.Repo.insert!(%Cinder.Settings.Setting{
      key: "tmdb_token",
      value: "@@@not-base64@@@",
      is_secret: true
    })

    {:ok, _lv, html} = live(conn, ~p"/settings")
    assert html =~ "undecryptable-secrets-alert"
    assert html =~ "could not be decrypted"
    # Names the affected setting by its label, not the raw key — and never the ciphertext.
    assert html =~ "TMDB API read token (v4 bearer)"
    refute html =~ "@@@not-base64@@@"
  end

  test "saves the default request quota as a non-secret numeric setting", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/settings")

    lv
    |> form("#settings-form", %{
      "default_request_quota" => "7",
      "media_server_type" => "jellyfin"
    })
    |> render_submit()

    assert Settings.get("default_request_quota") == "7"
    assert Settings.default_request_quota() == 7
  end

  test "validates and saves the household timezone", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/settings")

    html =
      lv
      |> form("#settings-form", %{
        "household_timezone" => "Not/A_Zone",
        "media_server_type" => "jellyfin"
      })
      |> render_submit()

    assert html =~ "Enter a valid IANA timezone"
    assert has_element?(lv, "#household_timezone[aria-invalid=true]")

    lv
    |> form("#settings-form", %{
      "household_timezone" => "Europe/Paris",
      "media_server_type" => "jellyfin"
    })
    |> render_submit()

    assert Settings.household_timezone() == "Europe/Paris"
  end

  test "renders stable keyboard-native group disclosures inside one form", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/settings")

    groups = Settings.groups() |> Enum.map(&elem(&1, 0))
    assert has_element?(lv, "form#settings-form")

    for group <- groups do
      assert has_element?(lv, "#settings-group-#{group} > summary")
      assert has_element?(lv, "#settings-group-#{group} [name]")
    end

    assert has_element?(lv, "#settings-group-#{hd(groups)}[open]")
  end

  test "renders Anime defaults in display units and preserves safe values on validation", %{
    conn: conn
  } do
    {:ok, lv, _html} = live(conn, ~p"/settings")

    assert has_element?(lv, "#anime-settings > summary", "Anime releases")
    assert has_element?(lv, "#anime_embedded_subtitle_mode option[value=require]")
    assert has_element?(lv, ~s|#anime_group_fallback_delay[type="number"][min="0"]|)

    html =
      lv
      |> form("#settings-form", %{
        "anime_embedded_subtitle_mode" => "prefer",
        "anime_preferred_groups" => "SubsPlease",
        "anime_blocked_groups" => "BadGroup",
        "anime_group_fallback_delay" => "-1",
        "subtitle_languages" => "en",
        "tmdb_token" => "must-never-echo",
        "media_server_type" => "jellyfin"
      })
      |> render_submit()

    assert has_element?(lv, "#anime_embedded_subtitle_mode option[value=prefer][selected]")

    assert has_element?(
             lv,
             "#anime_group_fallback_delay[value='-1'][aria-invalid=true]"
           )

    refute html =~ "must-never-echo"
  end

  test "saving Anime defaults persists them and flashes success", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/settings")

    html =
      lv
      |> form("#settings-form", %{
        "anime_embedded_subtitle_mode" => "require",
        "anime_preferred_groups" => "SubsPlease, Erai-Raws",
        "anime_blocked_groups" => "BadGroup",
        "anime_group_fallback_delay" => "12",
        "subtitle_languages" => "fr,en",
        "media_server_type" => "jellyfin"
      })
      |> render_submit()

    assert html =~ "Settings saved."
    assert Settings.anime_defaults().group_fallback_delay == 43_200
    assert has_element?(lv, "#anime_group_fallback_delay[value='12']")
  end

  test "disclosures keep native toggles local and force-open only invalid groups", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/settings")

    assert has_element?(
             lv,
             ~s|#settings-group-tmdb[phx-hook="DisclosureState"][data-force-open="false"]|
           )

    refute has_element?(lv, "#settings-group-tmdb > summary[phx-click]")

    lv
    |> form("#settings-form", %{
      "movies_min_size" => "invalid",
      "media_server_type" => "jellyfin"
    })
    |> render_submit()

    assert has_element?(lv, ~s|#settings-group-tmdb[data-force-open="false"]|)
    assert has_element?(lv, ~s|#settings-group-releases[open][data-force-open="true"]|)
  end

  test "service patches preserve the form revision while a successful save resets it", %{
    conn: conn
  } do
    stub(Cinder.Catalog.TMDBMock, :health, fn -> :ok end)
    {:ok, lv, _html} = live(conn, ~p"/settings")

    assert has_element?(lv, ~s|#settings-form[phx-hook="FormState"][data-form-revision="0"]|)
    lv |> element("button", "Test TMDB") |> render_click()
    assert has_element?(lv, ~s|#settings-form[data-form-revision="0"]|)

    lv
    |> form("#settings-form", %{"media_server_type" => "jellyfin"})
    |> render_submit()

    assert has_element?(lv, ~s|#settings-form[data-form-revision="1"]|)
  end

  test "tests both saved migration-source connections", %{conn: conn} do
    stub(Cinder.Library.RadarrMigrationSourceMock, :health, fn -> :ok end)
    stub(Cinder.Library.SonarrMigrationSourceMock, :health, fn -> {:error, :down} end)

    {:ok, lv, _html} = live(conn, ~p"/settings")

    lv |> element("button", "Test Radarr") |> render_click()
    lv |> element("button", "Test Sonarr") |> render_click()

    assert has_element?(lv, "#settings-group-migration", "OK")
    assert has_element?(lv, "#settings-group-migration", "Unreachable")
  end

  test "shows a reachable SABnzbd configuration warning", %{conn: conn} do
    stub(Cinder.Download.SabnzbdClientMock, :health, fn ->
      {:warning, {:sabnzbd_config, [{:duplicate_handling, :series, 2}]}}
    end)

    {:ok, lv, _html} = live(conn, ~p"/settings")
    lv |> element("button", "Test Usenet client") |> render_click()

    assert has_element?(lv, "#settings-group-download .badge-warning", "Warning")

    assert has_element?(
             lv,
             ~s|#settings-group-download [title*="Series duplicate detection is enabled"]|
           )

    refute has_element?(lv, "#settings-group-download", "Unreachable")
  end

  test "opens the group containing invalid fields", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/settings")

    lv
    |> form("#settings-form", %{
      "movies_min_size" => "invalid",
      "media_server_type" => "jellyfin"
    })
    |> render_submit()

    assert has_element?(lv, "#settings-group-releases[open]")
  end

  test "opens the subtitles group for an invalid LibreTranslate tuning value", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/settings")

    lv
    |> form("#settings-form", %{
      "libretranslate_batch_size" => "0",
      "media_server_type" => "jellyfin"
    })
    |> render_submit()

    assert has_element?(lv, "#settings-group-subtitles[open]")
    refute has_element?(lv, "#settings-group-releases[open]")
    assert has_element?(lv, "#libretranslate_batch_size[aria-invalid=true]")

    # Both the group and the message come from the registry `type:`, not the key name, so a future
    # positive-integer field is covered without touching this component.
    assert has_element?(
             lv,
             "#libretranslate_batch_size-error",
             "Enter a positive whole number, or leave blank for the default."
           )
  end

  test "opens the download group for an invalid torrent cleanup limit", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/settings")

    lv
    |> form("#settings-form", %{
      "torrent_cleanup_ratio" => "0",
      "media_server_type" => "jellyfin"
    })
    |> render_submit()

    assert has_element?(lv, "#settings-group-download[open]")
    assert has_element?(lv, "#torrent_cleanup_ratio[aria-invalid=true]")

    assert has_element?(
             lv,
             "#torrent_cleanup_ratio[aria-describedby=torrent_cleanup_ratio-error]"
           )

    assert_push_event(lv, "focus-invalid", %{id: "torrent_cleanup_ratio"})
  end

  test "invalid saves preserve safe values and expose the exact field error", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/settings")

    html =
      lv
      |> form("#settings-form", %{
        "prowlarr_url" => "http://typed:9696",
        "movies_min_size" => "not-a-size",
        "torrent_client" => "qbittorrent",
        "clear_tmdb_token" => "on",
        "tmdb_token" => "must-never-echo",
        "media_server_type" => "jellyfin"
      })
      |> render_submit()

    assert has_element?(lv, ~s|#prowlarr_url[value="http://typed:9696"]|)
    assert has_element?(lv, ~s|#movies_min_size[value="not-a-size"][aria-invalid="true"]|)
    assert has_element?(lv, "#movies_min_size[aria-describedby=movies_min_size-error]")
    assert has_element?(lv, "#movies_min_size-error")
    assert has_element?(lv, ~s(option[value="qbittorrent"][selected]))
    assert has_element?(lv, ~s(input[name="clear_tmdb_token"][checked]))
    refute html =~ "must-never-echo"
    flash = lv |> element("#flash-error") |> render()
    refute flash =~ "movies_min_size"
    assert flash =~ "Movies: Min size (GB)"
    assert_push_event(lv, "focus-invalid", %{id: "movies_min_size"})
  end

  test "an unlisted upgrade cutoff preserves the choice and explains the error", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/settings")

    lv
    |> form("#settings-form", %{
      "movies_preferred_resolutions" => "1080p, 720p",
      "movies_upgrade_cutoff" => "2160p",
      "media_server_type" => "jellyfin"
    })
    |> render_submit()

    assert has_element?(lv, "#movies_upgrade_cutoff[aria-invalid=true]")
    assert has_element?(lv, ~s|#movies_upgrade_cutoff option[value="2160p"][selected]|)
    assert has_element?(lv, "#movies_upgrade_cutoff-error", "Choose a cutoff included")
    assert_push_event(lv, "focus-invalid", %{id: "movies_upgrade_cutoff"})
  end

  test "mobile save and service test actions use full-size targets", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/settings")

    assert has_element?(lv, "#settings-form button[type=submit].min-h-11")
    assert has_element?(lv, "#settings-form button[phx-click=test].min-h-11")
  end

  test "saving import roots persists a non-secret download boundary", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/settings")

    lv
    |> form("#settings-form", %{
      "import_roots" => "/srv/downloads, /srv/usenet",
      "media_server_type" => "jellyfin"
    })
    |> render_submit()

    assert Settings.get("import_roots") == "/srv/downloads, /srv/usenet"
    assert Settings.import_roots() == ["/srv/downloads", "/srv/usenet"]
  end

  test "rejects the top-level folder as an import boundary", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/settings")

    lv
    |> form("#settings-form", %{
      "import_roots" => "/",
      "media_server_type" => "jellyfin"
    })
    |> render_submit()

    assert has_element?(
             lv,
             "#import_roots-error",
             "The top-level folder (/) is not allowed."
           )

    assert has_element?(
             lv,
             ~s|#import_roots[aria-describedby="import_roots-help import_roots-error"]|
           )

    assert Settings.get("import_roots") == nil
  end

  test "saving the movie library path overlays :cinder, :movies_library_path", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/settings")

    lv
    |> form("#settings-form", %{
      "movies_library_path" => "/srv/media",
      "media_server_type" => "jellyfin"
    })
    |> render_submit()

    assert Settings.get("movies_library_path") == "/srv/media"
    assert Application.fetch_env!(:cinder, :movies_library_path) == "/srv/media"
  end

  test "saving an Anime destination overlays it and rejects the filesystem root", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/settings")

    lv
    |> form("#settings-form", %{
      "movies_anime_library_path" => "/srv/anime",
      "media_server_type" => "jellyfin"
    })
    |> render_submit()

    assert Settings.get("movies_anime_library_path") == "/srv/anime"
    assert Application.fetch_env!(:cinder, :movies_anime_library_path) == "/srv/anime"

    lv
    |> form("#settings-form", %{
      "movies_anime_library_path" => "/",
      "media_server_type" => "jellyfin"
    })
    |> render_submit()

    assert has_element?(lv, "#movies_anime_library_path-error", "top-level folder")

    assert has_element?(
             lv,
             ~s|#movies_anime_library_path[aria-describedby="movies_anime_library_path-help movies_anime_library_path-error"]|
           )

    assert Settings.get("movies_anime_library_path") == "/srv/anime"
  end

  test "never echoes a stored secret back to the client", %{conn: conn} do
    Settings.put("tmdb_token", "super-secret-token")

    {:ok, _lv, html} = live(conn, ~p"/settings")

    refute html =~ "super-secret-token"
    # The redacted placeholder signals it's set without revealing the value.
    assert html =~ "saved"
  end

  test "saving applies the config and flashes", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/settings")

    html =
      lv
      |> form("#settings-form", %{
        "prowlarr_url" => "http://saved:9696",
        "media_server_type" => "jellyfin"
      })
      |> render_submit()

    assert html =~ "Settings saved."
    assert Settings.get("prowlarr_url") == "http://saved:9696"

    assert Application.get_env(:cinder, Cinder.Acquisition.Indexer.Prowlarr)[:base_url] ==
             "http://saved:9696"
  end

  test "the Clear toggle removes a stored secret", %{conn: conn} do
    Settings.put("tmdb_token", "tok")

    {:ok, lv, _html} = live(conn, ~p"/settings")

    lv
    |> form("#settings-form", %{
      "clear_tmdb_token" => "on",
      "media_server_type" => "jellyfin"
    })
    |> render_submit()

    assert Settings.get("tmdb_token") == nil
  end

  test "saves SMTP settings and never echoes the password back", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/settings")

    html =
      lv
      |> form("#settings-form", %{
        "smtp_host" => "smtp.example.com",
        "smtp_port" => "587",
        "smtp_username" => "cinder",
        "smtp_password" => "super-secret-password",
        "smtp_from" => "cinder@example.com",
        "smtp_ssl" => "true",
        "media_server_type" => "jellyfin"
      })
      |> render_submit()

    assert html =~ "Settings saved."
    refute html =~ "super-secret-password"

    assert Settings.get("smtp_host") == "smtp.example.com"
    assert Application.get_env(:cinder, Cinder.Mailer)[:relay] == "smtp.example.com"
    assert Application.get_env(:cinder, Cinder.Mailer)[:adapter] == Swoosh.Adapters.SMTP
    assert Application.get_env(:cinder, Cinder.Mailer)[:ssl] == true

    {:ok, _lv, html} = live(conn, ~p"/settings")
    refute html =~ "super-secret-password"
    assert html =~ "saved"
  end

  test "saves the generic webhook and never echoes its auth header back", %{conn: conn} do
    {:ok, lv, html} = live(conn, ~p"/settings")

    assert html =~ ~s(name="webhook_url")
    assert html =~ ~s(name="webhook_auth_header")

    html =
      lv
      |> form("#settings-form", %{
        "webhook_url" => "https://ntfy.example.com/cinder",
        "webhook_auth_header" => "Bearer must-never-echo",
        "media_server_type" => "jellyfin"
      })
      |> render_submit()

    assert html =~ "Settings saved."
    refute html =~ "must-never-echo"

    assert Settings.get("webhook_url") == "https://ntfy.example.com/cinder"

    assert Application.get_env(:cinder, Cinder.Notifier.Webhook)[:url] ==
             "https://ntfy.example.com/cinder"

    assert Application.get_env(:cinder, Cinder.Notifier.Webhook)[:auth_header] ==
             "Bearer must-never-echo"

    {:ok, _lv, html} = live(conn, ~p"/settings")
    refute html =~ "must-never-echo"
  end

  test "toggling auto-approve persists", %{conn: conn} do
    {:ok, lv, _} = live(conn, ~p"/settings")

    lv
    |> element("form[phx-change=toggle_auto_approve]")
    |> render_change(%{"auto_approve_all" => "on"})

    assert Settings.auto_approve_all?() == true
  end

  test "toggling the quality upgrade sweep applies without a restart", %{conn: conn} do
    # Shipped default (config.exs): off.
    refute UpgradeHunter.enabled?()

    {:ok, lv, _} = live(conn, ~p"/settings")

    lv
    |> element("form[phx-change=toggle_upgrade_hunt]")
    |> render_change(%{"upgrade_hunt_enabled" => "on"})

    assert UpgradeHunter.enabled?()

    # Unticking it: the browser sends a change frame with the checkbox absent entirely. Driven
    # off the view rather than the element so the now-checked DOM value isn't merged back in.
    render_change(lv, "toggle_upgrade_hunt", %{})

    refute UpgradeHunter.enabled?()
  end

  test "warns about auto-approval during public registration", %{conn: conn} do
    {:ok, live_view, _html} = live(conn, ~p"/settings")

    assert has_element?(
             live_view,
             "#auto-approve-public-warning[role='alert']",
             "Keep it off while registration enrollment is public."
           )
  end

  test "offers a database snapshot with the restore caveats", %{conn: conn} do
    {:ok, live_view, _html} = live(conn, ~p"/settings")

    assert has_element?(
             live_view,
             ~s|a[href="/settings/database-backup"][download]|,
             "Download database backup"
           )

    assert has_element?(live_view, "p", "Keep your SECRET_KEY_BASE with the backup")
    assert has_element?(live_view, "p", "Media files are not included")

    assert has_element?(
             live_view,
             "#scheduled-database-backups",
             "Automatic verified snapshots run about daily"
           )
  end

  test "generating an API key shows it exactly once and never echoes it back", %{conn: conn} do
    {:ok, lv, html} = live(conn, ~p"/settings")

    assert html =~ "Generate API key"
    refute has_element?(lv, "#new-api-key")

    html = lv |> element("button", "Generate API key") |> render_click()

    assert html =~ "Copy this key now."
    assert [_, key] = Regex.run(~r|<code[^>]*>([A-Za-z0-9_-]{40,})</code>|, html)
    assert Cinder.ApiKey.valid?(key)

    # Re-mounting must not disclose it again: only the hash was persisted.
    {:ok, lv, html} = live(conn, ~p"/settings")
    refute html =~ key
    refute has_element?(lv, "#new-api-key")
    assert html =~ "Regenerate API key"
  end

  test "revoking an API key clears it", %{conn: conn} do
    Cinder.ApiKey.generate()
    {:ok, lv, _html} = live(conn, ~p"/settings")

    lv |> element("button", "Revoke API key") |> render_click()

    refute Cinder.ApiKey.configured?()
    refute has_element?(lv, "button", "Revoke API key")
  end

  # Both handlers took a bare `params` and indexed straight into it — `save_form/1` via `Access`
  # (ArgumentError), `toggle_auto_approve` via `Map.get/2` (BadMapError). A forged frame carrying
  # a list matched the clause, so the module catch-all could not ignore it, and the admin lost the
  # LiveView (and any unsaved form input) to a reconnect.
  test "a forged non-map payload is ignored rather than crashing the view", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/settings")
    auto_approve_before = Settings.auto_approve_all?()

    assert render_hook(lv, "save", ["forged"])
    assert render_hook(lv, "toggle_auto_approve", ["forged"])

    # A map container is not enough: save_form/1 reaches into the VALUES with String.trim/1 and
    # String.split/2, which raise on a non-binary just as Access does on a non-map.
    tv_max_before = Settings.get("tv_max_size")
    qbit_before = Settings.get("qbittorrent_enabled")

    for forged <- [%{"forged" => true}, ["x"], 7] do
      assert render_hook(lv, "save", %{"tv_max_size" => forged})
      assert render_hook(lv, "save", %{"import_roots" => forged})
      assert render_hook(lv, "save", %{"movies_upgrade_cutoff" => forged})
    end

    assert Process.alive?(lv.pid)
    assert Settings.auto_approve_all?() == auto_approve_before
    assert Settings.get("tv_max_size") == tv_max_before
    # The frame is dropped whole, not filtered: plan/1 reads an absent key as an unchecked box,
    # so a filtering implementation would have switched this toggle off instead of crashing.
    assert Settings.get("qbittorrent_enabled") == qbit_before
  end
end
