defmodule CinderWeb.SettingsLiveTest do
  # async: false — saving mutates global Application env via load_into_env/0, and the
  # LiveView process needs the shared sandbox connection.
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox

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
    {:ok, _lv, html} = live(conn, ~p"/settings")

    assert html =~ "Settings"
    assert html =~ "TMDB"
    assert html =~ "Download clients"
    assert html =~ "Media server"
    assert html =~ "Library"
    assert html =~ ~s(name="movies_library_path")
    assert html =~ ~s(name="import_roots")
    # The remove-after-import toggle lives on /settings (Library section).
    assert html =~ ~s(name="move_on_import")
    assert html =~ "Save settings"
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
    assert has_element?(lv, "#anime_audio_mode option[value=original]")
    assert has_element?(lv, "#anime_embedded_subtitle_mode option[value=require]")
    assert has_element?(lv, ~s|#anime_group_fallback_delay[type="number"][min="0"]|)

    html =
      lv
      |> form("#settings-form", %{
        "anime_audio_mode" => "dual",
        "anime_embedded_subtitle_mode" => "prefer",
        "anime_preferred_groups" => "SubsPlease",
        "anime_blocked_groups" => "BadGroup",
        "anime_group_fallback_delay" => "-1",
        "subtitle_languages" => "en",
        "tmdb_token" => "must-never-echo",
        "media_server_type" => "jellyfin"
      })
      |> render_submit()

    assert has_element?(lv, "#anime_audio_mode option[value=dual][selected]")
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
        "anime_audio_mode" => "dual",
        "anime_embedded_subtitle_mode" => "require",
        "anime_preferred_groups" => "SubsPlease, Erai-Raws",
        "anime_blocked_groups" => "BadGroup",
        "anime_group_fallback_delay" => "12",
        "subtitle_languages" => "fr,en",
        "media_server_type" => "jellyfin"
      })
      |> render_submit()

    assert html =~ "Settings saved."
    assert Settings.anime_defaults().audio_mode == :dual
    assert Settings.anime_defaults().group_fallback_delay == 43_200
    assert has_element?(lv, "#anime_audio_mode option[value=dual][selected]")
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

  test "invalid saves preserve safe values and expose the exact field error", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/settings")

    html =
      lv
      |> form("#settings-form", %{
        "prowlarr_url" => "http://typed:9696",
        "movies_min_size" => "not-a-size",
        "qbittorrent_enabled" => "true",
        "clear_tmdb_token" => "on",
        "tmdb_token" => "must-never-echo",
        "media_server_type" => "jellyfin"
      })
      |> render_submit()

    assert has_element?(lv, ~s|#prowlarr_url[value="http://typed:9696"]|)
    assert has_element?(lv, ~s|#movies_min_size[value="not-a-size"][aria-invalid="true"]|)
    assert has_element?(lv, "#movies_min_size[aria-describedby=movies_min_size-error]")
    assert has_element?(lv, "#movies_min_size-error")
    assert has_element?(lv, ~s(input[name="qbittorrent_enabled"][checked]))
    assert has_element?(lv, ~s(input[name="clear_tmdb_token"][checked]))
    refute html =~ "must-never-echo"
    flash = lv |> element("#flash-error") |> render()
    refute flash =~ "movies_min_size"
    assert flash =~ "Movies: Min size (GB)"
    assert_push_event(lv, "focus-invalid", %{id: "movies_min_size"})
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

  test "rejects a filesystem-root import boundary", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/settings")

    html =
      lv
      |> form("#settings-form", %{
        "import_roots" => "/",
        "media_server_type" => "jellyfin"
      })
      |> render_submit()

    assert html =~ "The filesystem root (/) is not allowed."
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

  test "toggling auto-approve persists", %{conn: conn} do
    {:ok, lv, _} = live(conn, ~p"/settings")

    lv
    |> element("form[phx-change=toggle_auto_approve]")
    |> render_change(%{"auto_approve_all" => "on"})

    assert Settings.auto_approve_all?() == true
  end
end
