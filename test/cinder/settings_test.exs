defmodule Cinder.SettingsTest do
  # async: false — these mutate global Application env via load_into_env/0.
  use Cinder.DataCase, async: false

  import Mox
  import ExUnit.CaptureLog

  alias Cinder.Health
  alias Cinder.Settings
  alias Cinder.Settings.Setting

  setup :verify_on_exit!

  # Every :cinder key load_into_env/0 may write; snapshot and restore so a test can't
  # leak an overlay into the rest of the suite.
  @env_keys [
    Cinder.Catalog.TMDB.HTTP,
    Cinder.Acquisition.Indexer.Prowlarr,
    Cinder.Library.MigrationSource.Radarr,
    Cinder.Library.MigrationSource.Sonarr,
    Cinder.Download.Client.QBittorrent,
    Cinder.Download.Client.Sabnzbd,
    Cinder.Library.MediaServer.Jellyfin,
    Cinder.Library.MediaServer.Plex,
    Cinder.Notifier.Discord,
    Cinder.Notifier.Webhook,
    Cinder.Mailer,
    Cinder.Subtitles.Provider.OpenSubtitles,
    Cinder.Subtitles.Translator.LibreTranslate,
    :media_server,
    :download_clients,
    :qbittorrent_remote_path_prefix,
    :qbittorrent_local_path_prefix,
    :sabnzbd_remote_path_prefix,
    :sabnzbd_local_path_prefix,
    :movies_library_path,
    :movies_min_size,
    :movies_max_size,
    :movies_preferred_resolutions,
    :movies_preferred_sources,
    :tv_library_path,
    :tv_min_size,
    :tv_max_size,
    :tv_preferred_resolutions,
    :tv_preferred_sources,
    :import_roots,
    :explicit_import_roots,
    :move_on_import,
    :ffprobe_bin,
    :anime_preferences,
    :default_request_quota
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

  # `base/1` captures the bootstrap env into :persistent_term on first read
  # (first-capture-wins). Several tests below force the no-prior-snapshot path by erasing
  # that capture; erasing without restoring would leave it absent for the rest of the run,
  # so a later test's `base/1` read could re-capture whatever the env happens to be at that
  # point (already mutated by another test) as the permanent "bootstrap" value. Save the
  # current entry and restore it on exit instead of re-erasing.
  defp erase_base_snapshot(key) do
    pt_key = {Cinder.Settings, :base, key}
    prior = :persistent_term.get(pt_key, :__none__)
    :persistent_term.erase(pt_key)

    on_exit(fn ->
      case prior do
        :__none__ -> :persistent_term.erase(pt_key)
        value -> :persistent_term.put(pt_key, value)
      end
    end)
  end

  describe "storage" do
    test "import_roots parses newline/comma input, expands paths, and removes duplicates" do
      Settings.put("import_roots", " /srv/downloads, /srv/usenet\n/srv/downloads ")

      assert Settings.import_roots() == ["/srv/downloads", "/srv/usenet"]
      refute Repo.get_by!(Setting, key: "import_roots").is_secret
    end

    test "import_roots overlay refreshes on replacement and clear" do
      Settings.put("import_roots", "/srv/one")
      assert Settings.import_roots() == ["/srv/one"]

      Settings.put("import_roots", "/srv/two")
      assert Settings.import_roots() == ["/srv/two"]

      Settings.delete("import_roots")
      assert Settings.import_roots() == inferred_import_roots()
    end

    test "import_roots rejects a filesystem-root entry" do
      Application.delete_env(:cinder, :import_roots)
      Settings.load_into_env()
      expected = Settings.import_roots()

      assert {:error, ["import_roots"]} =
               Settings.save_form(%{
                 "import_roots" => "/, /srv/downloads",
                 "media_server_type" => "jellyfin"
               })

      assert Settings.get("import_roots") == nil
      assert Settings.import_roots() == expected
    end

    test "import_roots conservatively infers only a shared non-root parent" do
      Application.put_env(:cinder, :movies_library_path, "/srv/media/movies")
      Application.put_env(:cinder, :tv_library_path, "/srv/media/tv")
      Application.delete_env(:cinder, :import_roots)
      assert Settings.import_roots() == ["/srv/media"]

      Application.put_env(:cinder, :movies_library_path, "/movies")
      Application.put_env(:cinder, :tv_library_path, "/tv")
      Application.delete_env(:cinder, :import_roots)
      assert Settings.import_roots() == []

      Application.put_env(:cinder, :movies_library_path, "/srv/media")
      Application.put_env(:cinder, :tv_library_path, "/srv/media/tv")
      Application.delete_env(:cinder, :import_roots)
      assert Settings.import_roots() == []
    end

    test "explicit_import_roots is nil for an inferred/absent setting, set once configured" do
      Application.delete_env(:cinder, :import_roots)
      Settings.load_into_env()
      assert Settings.explicit_import_roots() == nil

      Settings.put("import_roots", "/srv/downloads")
      assert Settings.explicit_import_roots() == ["/srv/downloads"]
      # import_roots/0 (the read path) still returns the same explicit value here.
      assert Settings.import_roots() == ["/srv/downloads"]

      Settings.delete("import_roots")
      assert Settings.explicit_import_roots() == nil
    end

    test "import_roots infers the common root from DB-only-configured library paths on boot" do
      # Regression: apply_import_roots's inferred_import_roots/0 fallback reads the
      # :movies_library_path/:tv_library_path env keys that apply_library_config writes, so it
      # must run AFTER apply_library_config in load_into_env/0. Clear the env keys (simulating a
      # boot with no *_LIBRARY_PATH vars set) and insert the library paths directly as DB rows
      # (bypassing put/0's auto-load, like the "DB overrides the env bootstrap on the boot path"
      # test above) so load_into_env/0 has to derive :import_roots from the DB rows in a single
      # pass, not from an already-overlaid env.
      Application.delete_env(:cinder, :movies_library_path)
      Application.delete_env(:cinder, :tv_library_path)
      Application.delete_env(:cinder, :import_roots)
      Application.delete_env(:cinder, :explicit_import_roots)

      Repo.insert!(%Setting{
        key: "movies_library_path",
        value: "/srv/media/movies",
        is_secret: false
      })

      Repo.insert!(%Setting{key: "tv_library_path", value: "/srv/media/tv", is_secret: false})

      assert Settings.load_into_env() == :ok

      assert Settings.import_roots() == ["/srv/media"]
      assert Settings.explicit_import_roots() == nil
    end

    test "non-secret values are stored as plaintext and round-trip" do
      Settings.put("prowlarr_url", "http://example:9696")

      assert Settings.get("prowlarr_url") == "http://example:9696"

      %{rows: [[stored]]} =
        Repo.query!("SELECT value FROM settings WHERE key = ?", ["prowlarr_url"])

      assert stored == "http://example:9696"
    end

    test "download-client path mappings round-trip as flat non-secret settings" do
      mappings = %{
        "qbittorrent_remote_path_prefix" => "/downloads",
        "qbittorrent_local_path_prefix" => "/media/torrents",
        "sabnzbd_remote_path_prefix" => "/data/complete",
        "sabnzbd_local_path_prefix" => "/media/usenet"
      }

      assert :ok =
               Settings.save_form(
                 Map.merge(mappings, %{
                   "media_server_type" => "jellyfin",
                   "qbittorrent_enabled" => "true",
                   "sabnzbd_enabled" => "true"
                 })
               )

      form = Settings.form_state()

      for {key, value} <- mappings do
        assert Settings.get(key) == value
        assert form.values[key] == value
        refute Repo.get_by!(Setting, key: key).is_secret
        assert Application.get_env(:cinder, String.to_existing_atom(key)) == value
      end
    end

    test "migration source settings overlay both clients and encrypt their API keys" do
      assert :ok =
               Settings.save_form(%{
                 "radarr_url" => "http://radarr.internal:7878",
                 "radarr_api_key" => "radarr-secret",
                 "radarr_remote_path_prefix" => "/movies",
                 "radarr_local_path_prefix" => "/media/movies",
                 "sonarr_url" => "http://sonarr.internal:8989",
                 "sonarr_api_key" => "sonarr-secret",
                 "sonarr_remote_path_prefix" => "/tv",
                 "sonarr_local_path_prefix" => "/media/tv",
                 "media_server_type" => "jellyfin"
               })

      assert Application.get_env(:cinder, Cinder.Library.MigrationSource.Radarr)
             |> Keyword.take([:base_url, :api_key, :remote_path_prefix, :local_path_prefix]) ==
               [
                 base_url: "http://radarr.internal:7878",
                 api_key: "radarr-secret",
                 remote_path_prefix: "/movies",
                 local_path_prefix: "/media/movies"
               ]

      assert Application.get_env(:cinder, Cinder.Library.MigrationSource.Sonarr)
             |> Keyword.take([:base_url, :api_key, :remote_path_prefix, :local_path_prefix]) ==
               [
                 base_url: "http://sonarr.internal:8989",
                 api_key: "sonarr-secret",
                 remote_path_prefix: "/tv",
                 local_path_prefix: "/media/tv"
               ]

      for key <- ["radarr_api_key", "sonarr_api_key"] do
        row = Repo.get_by!(Setting, key: key)
        assert row.is_secret
        refute row.value =~ "secret"
      end
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

    test "move_on_import: unset ⇒ false; stored true overlays; cleared reverts to false" do
      Settings.load_into_env()
      assert Application.get_env(:cinder, :move_on_import, false) == false

      Settings.put("move_on_import", "true")
      assert Application.get_env(:cinder, :move_on_import) == true

      Settings.delete("move_on_import")
      assert Application.get_env(:cinder, :move_on_import, false) == false
    end

    test "move_on_import: save_form persists the checkbox and round-trips through form_state" do
      Settings.save_form(%{"move_on_import" => "true"})
      assert Settings.form_state().values["move_on_import"] == true
      assert Application.get_env(:cinder, :move_on_import) == true

      # An unchecked checkbox submits the hidden "false".
      Settings.save_form(%{"move_on_import" => "false"})
      assert Settings.form_state().values["move_on_import"] == false
      assert Application.get_env(:cinder, :move_on_import) == false
    end

    test "ffprobe_bin: unset ⇒ the \"ffprobe\" bootstrap; a saved value overlays; cleared reverts" do
      Settings.load_into_env()
      assert Application.get_env(:cinder, :ffprobe_bin) == "ffprobe"

      Settings.put("ffprobe_bin", "/usr/local/bin/ffprobe")
      assert Application.get_env(:cinder, :ffprobe_bin) == "/usr/local/bin/ffprobe"

      Settings.delete("ffprobe_bin")
      assert Application.get_env(:cinder, :ffprobe_bin) == "ffprobe"
    end

    test "an undecryptable secret is skipped (nil), never crashes load" do
      # A bad ciphertext (e.g. after a SECRET_KEY_BASE change) must not brick anything.
      Repo.insert!(%Setting{key: "tmdb_token", value: "@@@not-base64@@@", is_secret: true})

      log =
        capture_log(fn ->
          assert Settings.get("tmdb_token") == nil
          assert Settings.load_into_env() == :ok
        end)

      assert log =~ "cannot decrypt tmdb_token; re-enter it in /settings"
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

      log =
        capture_log(fn ->
          assert Settings.get("tmdb_token") == nil
          assert Settings.load_into_env() == :ok
        end)

      assert log =~ "cannot decrypt tmdb_token; re-enter it in /settings"
      assert Application.get_env(:cinder, Cinder.Catalog.TMDB.HTTP)[:token] != :error
    end
  end

  describe "undecryptable_secret_keys/0" do
    test "lists secret keys whose ciphertext fails to decrypt, excluding good secrets/plaintext" do
      # A good (decodable) secret and a plaintext non-secret must NOT appear.
      Settings.put("tmdb_token", "good-token")

      Repo.insert!(%Setting{
        key: "prowlarr_url",
        value: "http://localhost:9696",
        is_secret: false
      })

      # A wrong-key secret: encrypt, then corrupt the ciphertext so the GCM tag fails — exactly
      # what a SECRET_KEY_BASE change produces.
      Settings.put("prowlarr_api_key", "real-key")
      corrupt_secret("prowlarr_api_key")

      # A non-base64 secret is undecryptable too.
      Repo.insert!(%Setting{key: "sabnzbd_api_key", value: "@@@not-base64@@@", is_secret: true})

      keys = Settings.undecryptable_secret_keys()
      assert Enum.sort(keys) == ["prowlarr_api_key", "sabnzbd_api_key"]
      refute "tmdb_token" in keys
      refute "prowlarr_url" in keys
    end

    test "is empty when every stored secret decodes" do
      Settings.put("tmdb_token", "good-token")
      assert Settings.undecryptable_secret_keys() == []
    end

    test "a cleared (nil-valued) secret is not undecryptable" do
      Repo.insert!(%Setting{key: "tmdb_token", value: nil, is_secret: true})
      assert Settings.undecryptable_secret_keys() == []
    end

    test "field_label/1 resolves a secret key to its label, else the key itself" do
      assert Settings.field_label("prowlarr_api_key") == "Prowlarr API key"
      assert Settings.field_label("unknown_key") == "unknown_key"
    end

    test "Health.check_all surfaces a failing 'Stored credentials' row naming the count" do
      stub(Cinder.Catalog.TMDBMock, :health, fn -> :ok end)
      stub(Cinder.Acquisition.IndexerMock, :health, fn -> :ok end)
      stub(Cinder.Library.MediaServerMock, :health, fn -> :ok end)
      stub(Cinder.Download.ClientMock, :health, fn -> :ok end)

      Settings.put("tmdb_token", "real-token")
      corrupt_secret("tmdb_token")

      row = Enum.find(Health.check_all(), &(&1.label == "Stored credentials"))
      assert row.status == {:error, {:undecryptable_secrets, 1}}
    end

    test "no 'Stored credentials' row when every secret decodes" do
      stub(Cinder.Catalog.TMDBMock, :health, fn -> :ok end)
      stub(Cinder.Acquisition.IndexerMock, :health, fn -> :ok end)
      stub(Cinder.Library.MediaServerMock, :health, fn -> :ok end)
      stub(Cinder.Download.ClientMock, :health, fn -> :ok end)

      Settings.put("tmdb_token", "good-token")

      refute Enum.any?(Health.check_all(), &(&1.label == "Stored credentials"))
    end
  end

  describe "form_state/0 env placeholders" do
    test "includes the DB-only import roots field" do
      Settings.put("import_roots", "/srv/downloads")

      assert Settings.form_state().values["import_roots"] == "/srv/downloads"
    end

    test "a non-secret value from env (no DB row) is a placeholder, not a value" do
      Application.put_env(:cinder, Cinder.Acquisition.Indexer.Prowlarr,
        base_url: "http://env:9696"
      )

      form = Settings.form_state()

      # The input value stays blank (DB layer is empty → "inherit env"); the effective env
      # value surfaces as the placeholder so the field doesn't read as unconfigured.
      assert form.values["prowlarr_url"] == ""
      assert form.placeholders["prowlarr_url"] == "http://env:9696"
    end

    test "a saved DB value wins: it's the value, not a placeholder" do
      Application.put_env(:cinder, Cinder.Acquisition.Indexer.Prowlarr,
        base_url: "http://env:9696"
      )

      Settings.put("prowlarr_url", "http://db:9696")

      form = Settings.form_state()

      assert form.values["prowlarr_url"] == "http://db:9696"
      refute Map.has_key?(form.placeholders, "prowlarr_url")
    end

    test "showing the env placeholder doesn't promote env into a DB row on save" do
      # The whole point of placeholder-not-value: an untouched env-bootstrapped field stays
      # env-sourced. Submitting the (blank) field must not write a row, so clear-to-revert holds.
      Application.put_env(:cinder, Cinder.Acquisition.Indexer.Prowlarr,
        base_url: "http://env:9696"
      )

      Settings.save_form(%{"prowlarr_url" => ""})

      # No row written → the field still inherits env (clear-to-revert intact). Had the
      # placeholder been rendered as a value, this blank submit would have round-tripped
      # the env value into a DB row instead.
      assert Repo.get_by(Setting, key: "prowlarr_url") == nil
    end

    test "a secret seeded from env is marked set-via-env, never echoed" do
      Application.put_env(:cinder, Cinder.Catalog.TMDB.HTTP, token: "env-token")

      form = Settings.form_state()

      assert MapSet.member?(form.secrets_from_env, "tmdb_token")
      refute MapSet.member?(form.secrets_set, "tmdb_token")
      # The secret value is never in values or placeholders.
      refute Map.has_key?(form.placeholders, "tmdb_token")
      refute Map.has_key?(form.values, "tmdb_token")
    end

    test "submitted state preserves only known safe values and secret clear intent" do
      form =
        Settings.form_state(
          %{
            "prowlarr_url" => "http://typed:9696",
            "movies_min_size" => "wrong",
            "qbittorrent_enabled" => "true",
            "clear_tmdb_token" => "on",
            "tmdb_token" => "never-echo",
            "unknown" => "ignored"
          },
          ["movies_min_size"]
        )

      assert form.values["prowlarr_url"] == "http://typed:9696"
      assert form.values["movies_min_size"] == "wrong"
      assert form.values["qbittorrent_enabled"] == true
      assert MapSet.member?(form.clear_secrets, "tmdb_token")
      assert MapSet.member?(form.invalid_keys, "movies_min_size")
      refute Map.has_key?(form.values, "tmdb_token")
      refute Map.has_key?(form.values, "unknown")
      refute inspect(form) =~ "never-echo"
    end
  end

  describe "load_into_env/0 overlay" do
    test "anime defaults are typed and DB rows overlay then clear to the bootstrap" do
      assert Settings.anime_defaults() == %{
               subtitle_languages: [],
               embedded_subtitle_mode: :prefer,
               preferred_groups: [],
               blocked_groups: [],
               group_fallback_delay: 86_400
             }

      assert :ok =
               Settings.save_form(%{
                 "anime_embedded_subtitle_mode" => "require",
                 "anime_preferred_groups" => " SubsPlease, Erai-Raws, subsplease ",
                 "anime_blocked_groups" => "BadGroup",
                 "anime_group_fallback_delay" => "12",
                 "subtitle_languages" => "fr,en"
               })

      assert Settings.anime_defaults() == %{
               subtitle_languages: ["fr", "en"],
               embedded_subtitle_mode: :require,
               preferred_groups: ["subsplease", "erai-raws"],
               blocked_groups: ["badgroup"],
               group_fallback_delay: 43_200
             }

      for field <- Settings.anime_fields() do
        refute Repo.get_by!(Setting, key: field.key).is_secret
      end

      assert :ok =
               Settings.save_form(%{
                 "anime_embedded_subtitle_mode" => "",
                 "anime_preferred_groups" => "",
                 "anime_blocked_groups" => "",
                 "anime_group_fallback_delay" => "",
                 "subtitle_languages" => ""
               })

      assert Settings.anime_defaults() == %{
               subtitle_languages: [],
               embedded_subtitle_mode: :prefer,
               preferred_groups: [],
               blocked_groups: [],
               group_fallback_delay: 86_400
             }
    end

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

    test "a saved LibreTranslate URL overlays its module config; clearing restores the bootstrap" do
      original =
        Application.get_env(:cinder, Cinder.Subtitles.Translator.LibreTranslate)[:base_url]

      Settings.put("libretranslate_url", "https://translate.example")

      assert Application.get_env(:cinder, Cinder.Subtitles.Translator.LibreTranslate)[:base_url] ==
               "https://translate.example"

      Settings.delete("libretranslate_url")

      assert Application.get_env(:cinder, Cinder.Subtitles.Translator.LibreTranslate)[:base_url] ==
               original
    end

    test "a saved LibreTranslate API key overlays its module config; clearing restores the bootstrap" do
      original =
        Application.get_env(:cinder, Cinder.Subtitles.Translator.LibreTranslate)[:api_key]

      Settings.put("libretranslate_api_key", "test-api-key")

      assert Application.get_env(:cinder, Cinder.Subtitles.Translator.LibreTranslate)[:api_key] ==
               "test-api-key"

      Settings.delete("libretranslate_api_key")

      assert Application.get_env(:cinder, Cinder.Subtitles.Translator.LibreTranslate)[:api_key] ==
               original
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
      erase_base_snapshot(:media_server)

      Settings.put("media_server_type", "plex")
      assert Application.fetch_env!(:cinder, :media_server) == Cinder.Library.MediaServer.Plex

      Settings.delete("media_server_type")
      assert Application.fetch_env!(:cinder, :media_server) == Cinder.Library.MediaServerMock
    end

    test "a saved movies_library_path overlays :cinder, :movies_library_path; clearing reverts" do
      original = Application.fetch_env!(:cinder, :movies_library_path)

      Settings.put("movies_library_path", "/srv/media/movies")
      assert Application.fetch_env!(:cinder, :movies_library_path) == "/srv/media/movies"

      Settings.delete("movies_library_path")
      assert Application.fetch_env!(:cinder, :movies_library_path) == original
    end

    test "a saved tv_library_path overlays :cinder, :tv_library_path; clearing reverts to bootstrap" do
      original = Application.fetch_env!(:cinder, :tv_library_path)

      Settings.put("tv_library_path", "/srv/media/tv")
      assert Application.fetch_env!(:cinder, :tv_library_path) == "/srv/media/tv"

      Settings.delete("tv_library_path")
      assert Application.fetch_env!(:cinder, :tv_library_path) == original
    end

    test "library-root base snapshot is captured eagerly (clearing reverts even with no prior capture)" do
      # Regression: apply_kind_config must capture base/1 BEFORE the `decoded || fallback` so the
      # `||` can't short-circuit past it. Force the no-prior-snapshot path by erasing the
      # persistent_term, then put-then-delete: a lazy capture would snapshot the overlaid value
      # (during the delete) and revert there; eager capture snapshots the true bootstrap.
      bootstrap = Application.fetch_env!(:cinder, :tv_library_path)
      erase_base_snapshot(:tv_library_path)

      Settings.put("tv_library_path", "/srv/media/tv")
      Settings.delete("tv_library_path")

      assert Application.fetch_env!(:cinder, :tv_library_path) == bootstrap
    end

    test "tv size band: GB strings coerce to bytes; zero/negative opt out; clearing reverts" do
      Settings.put("tv_max_size", "5")
      assert Application.get_env(:cinder, :tv_max_size) == 5_000_000_000

      Settings.put("tv_min_size", "1.5")
      assert Application.get_env(:cinder, :tv_min_size) == 1_500_000_000

      # A delete reverts to the bootstrap default (config/test.exs neutralizes the shipped
      # bands to nil); a zero or negative value degrades to "no limit" rather than rejecting
      # everything.
      Settings.delete("tv_max_size")
      assert Application.get_env(:cinder, :tv_max_size) == nil

      Settings.put("tv_min_size", "0")
      assert Application.get_env(:cinder, :tv_min_size) == nil

      Settings.put("tv_min_size", "-3")
      assert Application.get_env(:cinder, :tv_min_size) == nil
    end

    test "default request quota coerces positive integers and degrades unusable values to nil" do
      Settings.put("default_request_quota", "6")
      assert Settings.default_request_quota() == 6
      refute Repo.get_by!(Setting, key: "default_request_quota").is_secret

      for value <- ["", "invalid", "0", "-2"] do
        Settings.put("default_request_quota", value)
        assert Settings.default_request_quota() == nil
      end

      Settings.delete("default_request_quota")
      assert Settings.default_request_quota() == 10
    end

    test "size bands fall back to the config bootstrap defaults when no DB row exists" do
      # Simulate the shipped config.exs defaults (config/test.exs neutralizes them so the
      # suite's fixtures stay unbounded); module setup restores the env keys afterwards.
      Enum.each([:tv_min_size, :tv_max_size], &erase_base_snapshot/1)

      Application.put_env(:cinder, :tv_min_size, 50_000_000)
      Application.put_env(:cinder, :tv_max_size, 4_000_000_000)

      Settings.load_into_env()

      assert Application.get_env(:cinder, :tv_min_size) == 50_000_000
      assert Application.get_env(:cinder, :tv_max_size) == 4_000_000_000
    end

    test "a saved band overrides the default, an explicit 0 opts out, clearing reverts to it" do
      erase_base_snapshot(:movies_max_size)
      Application.put_env(:cinder, :movies_max_size, 15_000_000_000)

      # The DB row wins over the bootstrap default (base captured eagerly on this first load,
      # even though the row short-circuits the fallback — the same regression as the roots).
      Settings.put("movies_max_size", "20")
      assert Application.get_env(:cinder, :movies_max_size) == 20_000_000_000

      # An explicit 0 row is unbounded — it must NOT fall back to the default.
      Settings.put("movies_max_size", "0")
      assert Application.get_env(:cinder, :movies_max_size) == nil

      # Clearing the row reverts to the bootstrap default, not to unbounded.
      Settings.delete("movies_max_size")
      assert Application.get_env(:cinder, :movies_max_size) == 15_000_000_000
    end

    test "tv_preferred_resolutions: comma list coerces to a downcased list; blank → nil" do
      Settings.put("tv_preferred_resolutions", "1080p, 720P ,")
      assert Application.get_env(:cinder, :tv_preferred_resolutions) == ["1080p", "720p"]

      Settings.delete("tv_preferred_resolutions")
      assert Application.get_env(:cinder, :tv_preferred_resolutions) == nil
    end

    test "a saved movies_preferred_sources overlays the env as a downcased list; clearing reverts to nil" do
      Settings.put("movies_preferred_sources", "BluRay, WEBDL")
      assert Application.get_env(:cinder, :movies_preferred_sources) == ["bluray", "webdl"]

      Settings.delete("movies_preferred_sources")
      assert Application.get_env(:cinder, :movies_preferred_sources) == nil
    end

    test "movie size band is editable too (same coercion as TV) and reaches band_opts/1" do
      Settings.put("movies_max_size", "20")
      Settings.put("movies_preferred_resolutions", "2160p, 1080P")

      assert Application.get_env(:cinder, :movies_max_size) == 20_000_000_000
      assert Application.get_env(:cinder, :movies_preferred_resolutions) == ["2160p", "1080p"]

      # The band reaches the scorer the same way TV's does; nil (min_size unset) is dropped.
      opts = Cinder.Acquisition.band_opts(:movies)
      assert opts[:max_size] == 20_000_000_000
      assert opts[:preferred_resolutions] == ["2160p", "1080p"]
      refute Keyword.has_key?(opts, :min_size)

      Settings.delete("movies_max_size")
      assert Application.get_env(:cinder, :movies_max_size) == nil
    end

    test "with no movies_library_path bootstrap (MOVIES_LIBRARY_PATH unset), overlay yields nil not []" do
      # Simulate MOVIES_LIBRARY_PATH absent: erase the captured base snapshot + the env, so base/1
      # falls back to its [] keyword-list default. The string key must coerce to nil.
      original = Application.get_env(:cinder, :movies_library_path)
      erase_base_snapshot(:movies_library_path)
      Application.delete_env(:cinder, :movies_library_path)

      on_exit(fn ->
        if original, do: Application.put_env(:cinder, :movies_library_path, original)
      end)

      Settings.load_into_env()
      assert Application.get_env(:cinder, :movies_library_path) == nil
    end

    test "with no tv_library_path bootstrap (TV_LIBRARY_PATH unset), the overlay yields nil not []" do
      # The strict TV root must coerce base/1's [] keyword default to nil, or build_episode_dest
      # would Path.join a list. Mirrors the library_path case.
      original = Application.get_env(:cinder, :tv_library_path)
      erase_base_snapshot(:tv_library_path)
      Application.delete_env(:cinder, :tv_library_path)

      on_exit(fn ->
        if original, do: Application.put_env(:cinder, :tv_library_path, original)
      end)

      Settings.load_into_env()
      assert Application.get_env(:cinder, :tv_library_path) == nil
    end

    test "a stored discord_webhook_url overlays :cinder Discord config and is encrypted at rest" do
      original = Application.get_env(:cinder, Cinder.Notifier.Discord)
      on_exit(fn -> Application.put_env(:cinder, Cinder.Notifier.Discord, original) end)

      :ok = Cinder.Settings.put("discord_webhook_url", "https://discord.com/api/webhooks/1/abc")

      assert Application.get_env(:cinder, Cinder.Notifier.Discord)[:webhook_url] ==
               "https://discord.com/api/webhooks/1/abc"

      # Stored ciphertext is not the plaintext (secret: true → Cloak-encrypted).
      row = Cinder.Repo.get_by(Cinder.Settings.Setting, key: "discord_webhook_url")
      assert row.is_secret
      refute row.value == "https://discord.com/api/webhooks/1/abc"
    end

    test "the generic webhook overlays :cinder Webhook config; only the header is encrypted" do
      :ok = Settings.put("webhook_url", "https://ntfy.example.com/cinder")
      :ok = Settings.put("webhook_auth_header", "Bearer tk_abc")

      config = Application.get_env(:cinder, Cinder.Notifier.Webhook)
      assert config[:url] == "https://ntfy.example.com/cinder"
      assert config[:auth_header] == "Bearer tk_abc"

      # The URL is operator-visible config; the header value carries the endpoint's token.
      refute Cinder.Repo.get_by(Setting, key: "webhook_url").is_secret
      header_row = Cinder.Repo.get_by(Setting, key: "webhook_auth_header")
      assert header_row.is_secret
      refute header_row.value == "Bearer tk_abc"
    end

    test "SMTP fields overlay Cinder.Mailer; the password is encrypted at rest" do
      :ok =
        Settings.save_form(%{
          "smtp_host" => "smtp.example.com",
          "smtp_port" => "587",
          "smtp_username" => "cinder",
          "smtp_password" => "hunter2",
          "smtp_from" => "cinder@example.com",
          "media_server_type" => "jellyfin"
        })

      config = Application.get_env(:cinder, Cinder.Mailer)
      assert config[:relay] == "smtp.example.com"
      assert config[:port] == "587"
      assert config[:username] == "cinder"
      assert config[:password] == "hunter2"
      assert config[:from] == "cinder@example.com"

      row = Repo.get_by(Setting, key: "smtp_password")
      assert row.is_secret
      refute row.value == "hunter2"
    end

    test "the adapter switches to SMTP only once a host is saved; clearing it reverts" do
      original = Application.get_env(:cinder, Cinder.Mailer)
      bootstrap_adapter = original[:adapter]

      Settings.put("smtp_host", "smtp.example.com")
      assert Application.get_env(:cinder, Cinder.Mailer)[:adapter] == Swoosh.Adapters.SMTP

      Settings.delete("smtp_host")
      assert Application.get_env(:cinder, Cinder.Mailer)[:adapter] == bootstrap_adapter
    end

    test "smtp_ssl: unset ⇒ false; stored true overlays; cleared reverts to false" do
      Settings.load_into_env()
      assert Application.get_env(:cinder, Cinder.Mailer)[:ssl] == false

      Settings.save_form(%{"smtp_ssl" => "true", "media_server_type" => "jellyfin"})
      assert Application.get_env(:cinder, Cinder.Mailer)[:ssl] == true
      assert Settings.form_state().values["smtp_ssl"] == true

      Settings.save_form(%{"smtp_ssl" => "false", "media_server_type" => "jellyfin"})
      assert Application.get_env(:cinder, Cinder.Mailer)[:ssl] == false
      assert Settings.form_state().values["smtp_ssl"] == false
    end
  end

  describe "save_form/1" do
    test "invalid anime enums, delay, and required subtitles save nothing" do
      for params <- [
            valid_anime_params(%{"anime_embedded_subtitle_mode" => "surround"}),
            valid_anime_params(%{"anime_group_fallback_delay" => "-1"}),
            valid_anime_params(%{
              "anime_embedded_subtitle_mode" => "require",
              "subtitle_languages" => ""
            })
          ] do
        assert {:error, [_ | _]} = Settings.save_form(params)

        for field <- Settings.anime_fields() do
          assert Settings.get(field.key) == nil
        end
      end
    end

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

    test "a typed secret replacement wins over a ticked Clear box" do
      Settings.save_form(%{"tmdb_token" => "old", "media_server_type" => "jellyfin"})

      # Admin replaces the key AND ticks Clear in the same submit: the new value must
      # win — deleting the old and dropping the new would leave the service silently
      # unauthenticated behind a "Settings saved." flash.
      Settings.save_form(%{
        "tmdb_token" => "new-key",
        "clear_tmdb_token" => "on",
        "media_server_type" => "jellyfin"
      })

      assert Settings.get("tmdb_token") == "new-key"
    end

    test "rejects an unusable size-band value instead of persisting it" do
      assert {:error, ["movies_max_size"]} =
               Settings.save_form(%{
                 "movies_max_size" => "abc",
                 "media_server_type" => "jellyfin"
               })

      assert Settings.get("movies_max_size") == nil

      # An explicit 0 is the documented unbounded opt-out, so it saves; negatives still reject.
      assert :ok =
               Settings.save_form(%{"tv_min_size" => "0", "media_server_type" => "jellyfin"})

      assert Settings.get("tv_min_size") == "0"
      assert Application.get_env(:cinder, :tv_min_size) == nil

      assert {:error, ["tv_min_size"]} =
               Settings.save_form(%{"tv_min_size" => "-2", "media_server_type" => "jellyfin"})

      # A valid decimal still saves.
      assert :ok =
               Settings.save_form(%{"tv_min_size" => "1.5", "media_server_type" => "jellyfin"})

      assert Settings.get("tv_min_size") == "1.5"
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

  # Encrypt-then-corrupt a stored secret so its GCM tag fails to authenticate — exactly what a
  # SECRET_KEY_BASE change (or a restore under a different key) produces.
  defp corrupt_secret(key) do
    row = Repo.get_by!(Setting, key: key)
    raw = Base.decode64!(row.value)
    n = byte_size(raw) - 1
    <<head::binary-size(^n), last>> = raw
    corrupted = Base.encode64(head <> <<rem(last + 1, 256)>>)
    row |> Ecto.Changeset.change(value: corrupted) |> Repo.update!()
  end

  defp inferred_import_roots do
    movie = Application.fetch_env!(:cinder, :movies_library_path)
    tv = Application.fetch_env!(:cinder, :tv_library_path)

    case {Path.dirname(movie), Path.dirname(tv)} do
      {same, same} when same != "/" -> [same]
      _ -> []
    end
  end

  defp valid_anime_params(overrides) do
    Map.merge(
      %{
        "anime_embedded_subtitle_mode" => "prefer",
        "anime_preferred_groups" => "SubsPlease",
        "anime_blocked_groups" => "BadGroup",
        "anime_group_fallback_delay" => "24",
        "subtitle_languages" => "en"
      },
      overrides
    )
  end

  describe "subscribe/0" do
    # Open pages re-read config on this message; without it a settings change is invisible
    # until the page happens to re-render for some other reason.
    test "a write broadcasts once the env overlay has been applied" do
      Settings.subscribe()
      Settings.put("plex_web_url", "https://plex.broadcast")

      assert_receive :settings_updated

      # Applied before the broadcast, so a subscriber that re-reads sees the new value.
      assert Application.get_env(:cinder, Cinder.Library.MediaServer.Plex)[:web_url] ==
               "https://plex.broadcast"
    end

    test "a delete broadcasts too" do
      Settings.put("plex_web_url", "https://plex.broadcast")
      Settings.subscribe()
      Settings.delete("plex_web_url")

      assert_receive :settings_updated
    end
  end

  describe "media_server_web_link/0" do
    # Writes the type row directly rather than via Settings.put/2: put triggers
    # load_into_env/0, which flips the global :media_server impl away from the Mox mock and
    # leaks into every later test in the run. media_server_web_link/0 reads the row, not the
    # impl, so the row alone is what this needs.
    defp set_media_server_type(type) do
      Repo.insert!(%Setting{key: "media_server_type", value: type, is_secret: false})
    end

    defp set_web_url(server, url) do
      module =
        case server do
          :plex -> Cinder.Library.MediaServer.Plex
          :jellyfin -> Cinder.Library.MediaServer.Jellyfin
        end

      config = Application.get_env(:cinder, module, [])
      Application.put_env(:cinder, module, Keyword.put(config, :web_url, url))
    end

    setup do
      # A leftover value on either module would mask the case under test.
      set_web_url(:plex, nil)
      set_web_url(:jellyfin, nil)
      :ok
    end

    test "is nil when neither media server has one configured" do
      refute Settings.media_server_web_link()
    end

    test "follows the configured media server type" do
      set_web_url(:plex, "https://plex.test")
      set_web_url(:jellyfin, "https://jellyfin.test")
      set_media_server_type("plex")

      assert Settings.media_server_web_link() == {:plex, "https://plex.test"}
    end

    test "follows the configured type when that type is Jellyfin" do
      set_web_url(:plex, "https://plex.test")
      set_web_url(:jellyfin, "https://jellyfin.test")
      set_media_server_type("jellyfin")

      assert Settings.media_server_web_link() == {:jellyfin, "https://jellyfin.test"}
    end

    # The whole point of reading the type: a Plex household with a stale Jellyfin URL still
    # configured must not send people to a server that does not have the file.
    test "never falls back to the other server's URL once a type is set" do
      set_media_server_type("plex")
      set_web_url(:jellyfin, "https://jellyfin.test")

      refute Settings.media_server_web_link()
    end

    test "with no type saved, uses a uniquely configured URL" do
      set_web_url(:jellyfin, "https://jellyfin.test")

      assert Settings.media_server_web_link() == {:jellyfin, "https://jellyfin.test"}
    end

    # Either answer would be a guess, and the wrong one is worse than none.
    test "with no type saved and both configured, refuses to guess" do
      set_web_url(:plex, "https://plex.test")
      set_web_url(:jellyfin, "https://jellyfin.test")

      refute Settings.media_server_web_link()
    end

    # A scheme-less host would render as a RELATIVE href (resolving against the current page),
    # and "javascript:" makes Phoenix's <.link> raise. Both are operator typos; no link beats a
    # broken link or a crashed page.
    test "ignores a value that is not an absolute http(s) URL" do
      set_media_server_type("plex")

      for bad <- [
            "plex.example.com",
            "javascript:alert(1)",
            "/relative",
            "ftp://x.test",
            "http://",
            ""
          ] do
        set_web_url(:plex, bad)

        refute Settings.media_server_web_link(), "expected #{inspect(bad)} to be rejected"
      end
    end

    # media_server_type is submitted with the form (plan/1 force-writes it, falling back to the
    # default when absent), so a realistic save carries both fields.
    test "a saved plex_web_url setting overlays onto Application env" do
      Settings.save_form(%{
        "media_server_type" => "plex",
        "plex_web_url" => "https://plex.saved"
      })

      assert Settings.media_server_web_link() == {:plex, "https://plex.saved"}
    end
  end
end
