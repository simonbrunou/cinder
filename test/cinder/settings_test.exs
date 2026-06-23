defmodule Cinder.SettingsTest do
  # async: false — these mutate global Application env via load_into_env/0.
  use Cinder.DataCase, async: false

  import Mox

  alias Cinder.Health
  alias Cinder.Settings
  alias Cinder.Settings.Setting

  setup :verify_on_exit!

  # Every :cinder key load_into_env/0 may write; snapshot and restore so a test can't
  # leak an overlay into the rest of the suite.
  @env_keys [
    Cinder.Catalog.TMDB.HTTP,
    Cinder.Acquisition.Indexer.Prowlarr,
    Cinder.Download.Client.QBittorrent,
    Cinder.Download.Client.Sabnzbd,
    Cinder.Library.MediaServer.Jellyfin,
    Cinder.Library.MediaServer.Plex,
    :media_server,
    :download_clients,
    :library_path,
    :tv_library_path,
    :tv_min_size,
    :tv_max_size,
    :tv_preferred_resolutions
  ]

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

  describe "storage" do
    test "non-secret values are stored as plaintext and round-trip" do
      Settings.put("prowlarr_url", "http://example:9696")

      assert Settings.get("prowlarr_url") == "http://example:9696"

      %{rows: [[stored]]} =
        Repo.query!("SELECT value FROM settings WHERE key = ?", ["prowlarr_url"])

      assert stored == "http://example:9696"
    end

    test "secret values are ciphertext at rest but decrypt on read" do
      Settings.put("tmdb_token", "super-secret-token")

      assert Settings.get("tmdb_token") == "super-secret-token"

      %{rows: [[stored]]} =
        Repo.query!("SELECT value FROM settings WHERE key = ?", ["tmdb_token"])

      refute stored == "super-secret-token"
      refute stored =~ "super-secret-token"
      # is_secret is recorded for redaction/display.
      assert Repo.get_by(Setting, key: "tmdb_token").is_secret
    end

    test "an undecryptable secret is skipped (nil), never crashes load" do
      # A bad ciphertext (e.g. after a SECRET_KEY_BASE change) must not brick anything.
      Repo.insert!(%Setting{key: "tmdb_token", value: "@@@not-base64@@@", is_secret: true})

      assert Settings.get("tmdb_token") == nil
      assert Settings.load_into_env() == :ok
    end

    test "a secret that fails GCM authentication (wrong key) is skipped, not poured into env" do
      # Encrypt under the real vault, then corrupt the ciphertext so the GCM tag fails to
      # authenticate — exactly what a SECRET_KEY_BASE change produces. Cloak returns
      # {:ok, :error} here, so without the is_binary guard :error would land in env.
      Settings.put("tmdb_token", "real-token")
      row = Repo.get_by(Setting, key: "tmdb_token")
      raw = Base.decode64!(row.value)
      n = byte_size(raw) - 1
      <<head::binary-size(^n), last>> = raw
      corrupted = Base.encode64(head <> <<rem(last + 1, 256)>>)
      row |> Ecto.Changeset.change(value: corrupted) |> Repo.update!()

      assert Settings.get("tmdb_token") == nil
      assert Settings.load_into_env() == :ok
      assert Application.get_env(:cinder, Cinder.Catalog.TMDB.HTTP)[:token] != :error
    end
  end

  describe "load_into_env/0 overlay" do
    test "DB overrides the env bootstrap on the boot path" do
      # Insert directly (bypassing put/0's auto-load) to exercise load_into_env standalone.
      Repo.insert!(%Setting{key: "jellyfin_url", value: "http://boot-jellyfin", is_secret: false})

      assert Settings.load_into_env() == :ok

      config = Application.get_env(:cinder, Cinder.Library.MediaServer.Jellyfin)
      assert config[:url] == "http://boot-jellyfin"
      # Merge preserves the other bootstrap keys (api_key, the Req.Test stub).
      assert config[:api_key] == "test-key"
      assert Keyword.has_key?(config, :req_options)
    end

    test "DB overrides the env bootstrap on save" do
      Settings.put("jellyfin_url", "http://saved-jellyfin")

      assert Application.get_env(:cinder, Cinder.Library.MediaServer.Jellyfin)[:url] ==
               "http://saved-jellyfin"
    end

    test "removing a setting reverts to the bootstrap base" do
      original = Application.get_env(:cinder, Cinder.Library.MediaServer.Jellyfin)[:url]

      Settings.put("jellyfin_url", "http://temp")

      assert Application.get_env(:cinder, Cinder.Library.MediaServer.Jellyfin)[:url] ==
               "http://temp"

      Settings.delete("jellyfin_url")
      assert Application.get_env(:cinder, Cinder.Library.MediaServer.Jellyfin)[:url] == original
    end

    test "media_server_type selects the impl; absent leaves the bootstrap untouched" do
      assert Settings.load_into_env() == :ok
      # No setting + no PLEX_URL → the Mox mock from config/test.exs survives.
      assert Application.fetch_env!(:cinder, :media_server) == Cinder.Library.MediaServerMock

      Settings.put("media_server_type", "plex")
      assert Application.fetch_env!(:cinder, :media_server) == Cinder.Library.MediaServer.Plex

      Settings.put("media_server_type", "jellyfin")
      assert Application.fetch_env!(:cinder, :media_server) == Cinder.Library.MediaServer.Jellyfin
    end

    test "download toggles build the client map; absent leaves the bootstrap untouched" do
      assert Settings.load_into_env() == :ok
      # No toggle setting → the two Mox client mocks survive.
      assert Map.keys(Application.fetch_env!(:cinder, :download_clients)) |> Enum.sort() ==
               [:torrent, :usenet]

      Settings.put("sabnzbd_enabled", "false")

      assert Application.fetch_env!(:cinder, :download_clients) == %{
               torrent: Cinder.Download.ClientMock
             }
    end

    test "media_server reverts to the bootstrap base after an explicit set is cleared" do
      # Erase the snapshot to simulate base not yet captured when the first explicit
      # resolution happens (the boot-with-persisted-row case the lazy capture got wrong).
      :persistent_term.erase({Cinder.Settings, :base, :media_server})
      on_exit(fn -> :persistent_term.erase({Cinder.Settings, :base, :media_server}) end)

      Settings.put("media_server_type", "plex")
      assert Application.fetch_env!(:cinder, :media_server) == Cinder.Library.MediaServer.Plex

      Settings.delete("media_server_type")
      assert Application.fetch_env!(:cinder, :media_server) == Cinder.Library.MediaServerMock
    end

    test "a saved library_path overlays :cinder, :library_path; clearing reverts to bootstrap" do
      original = Application.fetch_env!(:cinder, :library_path)

      Settings.put("library_path", "/srv/media/movies")
      assert Application.fetch_env!(:cinder, :library_path) == "/srv/media/movies"

      Settings.delete("library_path")
      assert Application.fetch_env!(:cinder, :library_path) == original
    end

    test "a saved tv_library_path overlays :cinder, :tv_library_path; clearing reverts to bootstrap" do
      original = Application.fetch_env!(:cinder, :tv_library_path)

      Settings.put("tv_library_path", "/srv/media/tv")
      assert Application.fetch_env!(:cinder, :tv_library_path) == "/srv/media/tv"

      Settings.delete("tv_library_path")
      assert Application.fetch_env!(:cinder, :tv_library_path) == original
    end

    test "tv size band: GB strings coerce to bytes; blank/zero/negative clear to unbounded (nil)" do
      Settings.put("tv_max_size", "5")
      assert Application.get_env(:cinder, :tv_max_size) == 5_000_000_000

      Settings.put("tv_min_size", "1.5")
      assert Application.get_env(:cinder, :tv_min_size) == 1_500_000_000

      # A cleared, zero, or negative value degrades to "no limit" rather than rejecting everything.
      Settings.delete("tv_max_size")
      assert Application.get_env(:cinder, :tv_max_size) == nil

      Settings.put("tv_min_size", "0")
      assert Application.get_env(:cinder, :tv_min_size) == nil

      Settings.put("tv_min_size", "-3")
      assert Application.get_env(:cinder, :tv_min_size) == nil
    end

    test "tv_preferred_resolutions: comma list coerces to a downcased list; blank → nil" do
      Settings.put("tv_preferred_resolutions", "1080p, 720P ,")
      assert Application.get_env(:cinder, :tv_preferred_resolutions) == ["1080p", "720p"]

      Settings.delete("tv_preferred_resolutions")
      assert Application.get_env(:cinder, :tv_preferred_resolutions) == nil
    end

    test "with no library_path bootstrap (LIBRARY_PATH unset), the overlay yields nil not []" do
      # Simulate LIBRARY_PATH absent: erase the captured base snapshot + the env, so base/1
      # falls back to its [] keyword-list default. The string key must coerce to nil.
      original = Application.get_env(:cinder, :library_path)
      :persistent_term.erase({Cinder.Settings, :base, :library_path})
      Application.delete_env(:cinder, :library_path)

      on_exit(fn ->
        :persistent_term.erase({Cinder.Settings, :base, :library_path})
        if original, do: Application.put_env(:cinder, :library_path, original)
      end)

      Settings.load_into_env()
      assert Application.get_env(:cinder, :library_path) == nil
    end
  end

  describe "save_form/1" do
    test "non-secret blank clears; secret blank keeps; clear flag deletes" do
      Settings.save_form(%{
        "prowlarr_url" => "http://p",
        "tmdb_token" => "tok",
        "media_server_type" => "jellyfin"
      })

      assert Settings.get("prowlarr_url") == "http://p"
      assert Settings.get("tmdb_token") == "tok"

      # Non-secret blank → cleared.
      Settings.save_form(%{"prowlarr_url" => "", "media_server_type" => "jellyfin"})
      assert Settings.get("prowlarr_url") == nil

      # Secret blank (no clear flag) → kept.
      Settings.save_form(%{"tmdb_token" => "", "media_server_type" => "jellyfin"})
      assert Settings.get("tmdb_token") == "tok"

      # Secret clear flag → deleted.
      Settings.save_form(%{
        "tmdb_token" => "",
        "clear_tmdb_token" => "on",
        "media_server_type" => "jellyfin"
      })

      assert Settings.get("tmdb_token") == nil
    end

    test "leaves non-secret keys absent from params unchanged (no collateral wipe)" do
      Settings.put("prowlarr_url", "http://keep")

      # A partial submit omitting prowlarr_url must not delete it.
      Settings.save_form(%{"jellyfin_url" => "http://j", "media_server_type" => "jellyfin"})

      assert Settings.get("prowlarr_url") == "http://keep"
      assert Settings.get("jellyfin_url") == "http://j"
    end

    test "tolerates a present-but-nil non-secret value (clears, does not crash)" do
      Settings.put("prowlarr_url", "http://x")

      assert Settings.save_form(%{"prowlarr_url" => nil, "media_server_type" => "jellyfin"}) ==
               :ok

      assert Settings.get("prowlarr_url") == nil
    end

    test "form_state never exposes secret values, only whether they are set" do
      Settings.put("tmdb_token", "hidden")

      %{values: values, secrets_set: secrets_set} = Settings.form_state()

      refute Map.has_key?(values, "tmdb_token")
      assert MapSet.member?(secrets_set, "tmdb_token")
    end
  end

  describe "auto_approve_all?/0" do
    test "defaults to false and round-trips" do
      assert Cinder.Settings.auto_approve_all?() == false
      Cinder.Settings.put("auto_approve_all", "true")
      assert Cinder.Settings.auto_approve_all?() == true
      Cinder.Settings.put("auto_approve_all", "false")
      assert Cinder.Settings.auto_approve_all?() == false
    end
  end

  describe "Health.check_service/1" do
    test "probes the configured impl for each service" do
      stub(Cinder.Catalog.TMDBMock, :health, fn -> :ok end)
      stub(Cinder.Acquisition.IndexerMock, :health, fn -> {:error, :down} end)
      stub(Cinder.Library.MediaServerMock, :health, fn -> :ok end)
      stub(Cinder.Download.ClientMock, :health, fn -> :ok end)

      assert Health.check_service(:tmdb) == :ok
      assert Health.check_service(:indexer) == {:error, :down}
      assert Health.check_service(:media_server) == :ok
      assert Health.check_service({:download, :torrent}) == :ok
    end
  end
end
