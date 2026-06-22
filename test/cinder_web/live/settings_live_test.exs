defmodule CinderWeb.SettingsLiveTest do
  # async: false — saving mutates global Application env via load_into_env/0, and the
  # LiveView process needs the shared sandbox connection.
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Cinder.Settings

  @env_keys [
    Cinder.Catalog.TMDB.HTTP,
    Cinder.Acquisition.Indexer.Prowlarr,
    Cinder.Download.Client.QBittorrent,
    Cinder.Download.Client.Sabnzbd,
    Cinder.Library.MediaServer.Jellyfin,
    Cinder.Library.MediaServer.Plex,
    :media_server,
    :download_clients,
    :library_path
  ]

  setup :register_and_log_in_admin

  setup do
    saved = Map.new(@env_keys, fn k -> {k, Application.get_env(:cinder, k)} end)

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> Application.delete_env(:cinder, k)
        {k, v} -> Application.put_env(:cinder, k, v)
      end)
    end)

    :ok
  end

  test "renders the grouped settings form", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/settings")

    assert html =~ "Settings"
    assert html =~ "TMDB"
    assert html =~ "Download clients"
    assert html =~ "Media server"
    assert html =~ "Library"
    assert html =~ ~s(name="library_path")
    assert html =~ "Save settings"
  end

  test "saving the library path overlays :cinder, :library_path", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/settings")

    lv
    |> form("#settings-form", %{"library_path" => "/srv/media", "media_server_type" => "jellyfin"})
    |> render_submit()

    assert Settings.get("library_path") == "/srv/media"
    assert Application.fetch_env!(:cinder, :library_path) == "/srv/media"
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
