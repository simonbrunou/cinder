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
    :move_on_import
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

  describe "form_state/0 env placeholders" do
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
      :persistent_term.erase({Cinder.Settings, :base, :tv_library_path})
      on_exit(fn -> :persistent_term.erase({Cinder.Settings, :base, :tv_library_path}) end)

      Settings.put("tv_library_path", "/srv/media/tv")
      Settings.delete("tv_library_path")

      assert Application.fetch_env!(:cinder, :tv_library_path) == bootstrap
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
      :persistent_term.erase({Cinder.Settings, :base, :movies_library_path})
      Application.delete_env(:cinder, :movies_library_path)

      on_exit(fn ->
        :persistent_term.erase({Cinder.Settings, :base, :movies_library_path})
        if original, do: Application.put_env(:cinder, :movies_library_path, original)
      end)

      Settings.load_into_env()
      assert Application.get_env(:cinder, :movies_library_path) == nil
    end

    test "with no tv_library_path bootstrap (TV_LIBRARY_PATH unset), the overlay yields nil not []" do
      # The strict TV root must coerce base/1's [] keyword default to nil, or build_episode_dest
      # would Path.join a list. Mirrors the library_path case.
      original = Application.get_env(:cinder, :tv_library_path)
      :persistent_term.erase({Cinder.Settings, :base, :tv_library_path})
      Application.delete_env(:cinder, :tv_library_path)

      on_exit(fn ->
        :persistent_term.erase({Cinder.Settings, :base, :tv_library_path})
        if original, do: Application.put_env(:cinder, :tv_library_path, original)
      end)

      Settings.load_into_env()
      assert Application.get_env(:cinder, :tv_library_path) == nil
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
