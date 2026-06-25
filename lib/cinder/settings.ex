defmodule Cinder.Settings do
  @moduledoc """
  DB-backed in-app configuration, overlaid onto the `Application` env the contexts
  already read — so external-service config is editable in `/settings` with **zero
  context changes**.

  A declarative registry maps each settings key to its `:cinder` env target. On boot
  (a one-shot supervised child) and on every save, `load_into_env/0` merges the stored
  values **onto a one-time bootstrap snapshot** (`:persistent_term`) of the env config,
  so DB overrides env, a removed setting reverts to the env/default, and repeated saves
  don't drift. Secret values are encrypted at rest via `Cinder.Vault`; a value that
  can't be decrypted (e.g. after a `SECRET_KEY_BASE` change) is skipped with a warning
  rather than crashing boot.
  """
  require Logger

  alias Cinder.Repo
  alias Cinder.Settings.Setting

  # Static per-module config fields (service creds): {settings key, env target module + field,
  # secret?, group}. The complete set is `config_fields/0` = these ++ the per-kind Plex section
  # fields generated from `Cinder.Library.kinds/0`.
  @base_config_fields [
    %{
      key: "tmdb_token",
      module: Cinder.Catalog.TMDB.HTTP,
      field: :token,
      secret: true,
      group: :tmdb,
      label: "TMDB API read token (v4 bearer)",
      placeholder: ""
    },
    %{
      key: "prowlarr_url",
      module: Cinder.Acquisition.Indexer.Prowlarr,
      field: :base_url,
      secret: false,
      group: :indexer,
      label: "Prowlarr URL",
      placeholder: "http://localhost:9696"
    },
    %{
      key: "prowlarr_api_key",
      module: Cinder.Acquisition.Indexer.Prowlarr,
      field: :api_key,
      secret: true,
      group: :indexer,
      label: "Prowlarr API key",
      placeholder: ""
    },
    %{
      key: "qbittorrent_url",
      module: Cinder.Download.Client.QBittorrent,
      field: :base_url,
      secret: false,
      group: :download,
      label: "qBittorrent URL",
      placeholder: "http://localhost:8080"
    },
    %{
      key: "qbittorrent_username",
      module: Cinder.Download.Client.QBittorrent,
      field: :username,
      secret: false,
      group: :download,
      label: "qBittorrent username",
      placeholder: ""
    },
    %{
      key: "qbittorrent_password",
      module: Cinder.Download.Client.QBittorrent,
      field: :password,
      secret: true,
      group: :download,
      label: "qBittorrent password",
      placeholder: ""
    },
    %{
      key: "sabnzbd_url",
      module: Cinder.Download.Client.Sabnzbd,
      field: :base_url,
      secret: false,
      group: :download,
      label: "SABnzbd URL",
      placeholder: "http://localhost:8080"
    },
    %{
      key: "sabnzbd_api_key",
      module: Cinder.Download.Client.Sabnzbd,
      field: :api_key,
      secret: true,
      group: :download,
      label: "SABnzbd API key",
      placeholder: ""
    },
    %{
      key: "jellyfin_url",
      module: Cinder.Library.MediaServer.Jellyfin,
      field: :url,
      secret: false,
      group: :media_server,
      label: "Jellyfin URL",
      placeholder: "http://localhost:8096"
    },
    %{
      key: "jellyfin_api_key",
      module: Cinder.Library.MediaServer.Jellyfin,
      field: :api_key,
      secret: true,
      group: :media_server,
      label: "Jellyfin API key",
      placeholder: ""
    },
    %{
      key: "plex_url",
      module: Cinder.Library.MediaServer.Plex,
      field: :url,
      secret: false,
      group: :media_server,
      label: "Plex URL",
      placeholder: "http://localhost:32400"
    },
    %{
      key: "plex_token",
      module: Cinder.Library.MediaServer.Plex,
      field: :token,
      secret: true,
      group: :media_server,
      label: "Plex token",
      placeholder: ""
    }
  ]

  # Download-client enable toggles → the :cinder, :download_clients %{protocol => module} map.
  @toggles [
    %{key: "qbittorrent_enabled", protocol: :torrent, label: "Enable qBittorrent (torrent)"},
    %{key: "sabnzbd_enabled", protocol: :usenet, label: "Enable SABnzbd (usenet)"}
  ]

  @media_server_key "media_server_type"
  @media_server_options ["jellyfin", "plex"]

  # Display labels for the library kinds. `Cinder.Library.kinds/0` stays a pure context list;
  # the UI labels live here alongside the other settings-group labels.
  @kind_labels %{movies: "Movies", tv: "TV"}

  # The DB-only band suffixes each kind owns (no env bootstrap — unset ⇒ unbounded/default).
  # The root path (`#{kind}_library_path`) is the fourth flat key and DOES have an env bootstrap.
  @band_suffixes ["min_size", "max_size", "preferred_resolutions"]

  @bytes_per_gb 1_000_000_000

  @groups [
    tmdb: "TMDB",
    indexer: "Indexer",
    download: "Download clients",
    media_server: "Media server",
    library: "Library paths",
    releases: "Release size bands"
  ]

  # Only static fields can be secret (the generated Plex-section fields are not), so this stays
  # a compile-time set over @base_config_fields — no need to call config_fields/0 at module load.
  @secret_keys for(f <- @base_config_fields, f.secret, into: MapSet.new(), do: f.key)

  # --- boot loader: one-shot supervised child, runs synchronously before the poller ---

  @doc false
  def child_spec(_opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [[]]}, restart: :temporary}
  end

  @doc false
  def start_link(_opts) do
    load_into_env()
    :ignore
  end

  # --- registry accessors (for the LiveView) ---

  @doc "Display groups in render order, as `{group_atom, label}`."
  def groups, do: @groups

  @doc "All config fields: the static service creds plus the per-kind Plex section fields."
  def config_fields, do: @base_config_fields ++ plex_section_fields()

  @doc "Config fields in a given group."
  def config_fields(group), do: Enum.filter(config_fields(), &(&1.group == group))

  # One Plex section field per library kind (`movies_plex_section` → Plex `:movies_section`, …),
  # so a server with separate Movies/Shows libraries refreshes the right one. Generated from
  # `Cinder.Library.kinds/0` so a new kind needs no entry here.
  defp plex_section_fields do
    for kind <- Cinder.Library.kinds() do
      %{
        key: "#{kind}_plex_section",
        module: Cinder.Library.MediaServer.Plex,
        field: :"#{kind}_section",
        secret: false,
        group: :media_server,
        label: "Plex #{kind_label(kind)} library section (numeric id)",
        placeholder: ""
      }
    end
  end

  defp kind_label(kind),
    do: Map.get(@kind_labels, kind, kind |> to_string() |> String.capitalize())

  @doc "The download-client enable toggles."
  def toggles, do: @toggles

  def media_server_key, do: @media_server_key
  def media_server_options, do: @media_server_options

  @doc "The library kinds with display labels, for the settings/setup UI (`[%{kind:, label:}]`)."
  def library_kinds, do: Enum.map(Cinder.Library.kinds(), &%{kind: &1, label: kind_label(&1)})

  @doc "Every flat `:cinder` env key overlaid per kind: the root path + the three band keys."
  def flat_keys do
    for kind <- Cinder.Library.kinds(), suffix <- ["library_path" | @band_suffixes] do
      "#{kind}_#{suffix}"
    end
  end

  # Per-kind settings-key derivations for the UI (the form field `name`s).
  def library_path_key(kind), do: "#{kind}_library_path"
  def min_size_key(kind), do: "#{kind}_min_size"
  def max_size_key(kind), do: "#{kind}_max_size"
  def preferred_resolutions_key(kind), do: "#{kind}_preferred_resolutions"

  # --- reads ---

  @doc "All raw settings rows."
  def all, do: Repo.all(Setting)

  @doc "Returns true if the auto-approve-all setting is explicitly enabled."
  def auto_approve_all?, do: get("auto_approve_all") == "true"

  @doc "True once the first-run wizard has been completed."
  def setup_complete?, do: get("setup_complete") == "true"

  @doc "Marks the first-run wizard complete."
  def mark_setup_complete, do: put("setup_complete", "true")

  @doc "Decoded value for `key` (decrypting secrets), or `nil` if unset/undecryptable."
  def get(key) do
    case Repo.get_by(Setting, key: key) do
      nil -> nil
      setting -> setting |> decoded() |> unwrap() |> blank_to_nil()
    end
  end

  @doc """
  Form state for the LiveView: `%{values:, secrets_set:, placeholders:, secrets_from_env:}`.

  `values` drives the input `value=` and reflects the **DB layer only** (so a blank field
  still means "no override, inherit env"). `placeholders` carries the **effective env value**
  for a non-secret field with no DB row, so an env-bootstrapped install reads as configured
  rather than empty — shown as greyed placeholder text, never as a value (echoing it back
  would promote env into a DB row on the next save and break clear-to-revert). Secret
  *values* are never returned (only whether each is set, and whether it comes from env) so
  they can't be echoed back to the client.
  """
  def form_state do
    rows = rows_by_key()

    values =
      for f <- config_fields(), not f.secret, into: %{} do
        {f.key, decoded_for(rows, f.key) || ""}
      end

    values =
      values
      |> Map.put(
        @media_server_key,
        decoded_for(rows, @media_server_key) || default_media_server_type()
      )
      |> then(fn v ->
        Enum.reduce(flat_keys(), v, fn key, acc ->
          Map.put(acc, key, decoded_for(rows, key) || "")
        end)
      end)
      |> Map.merge(toggle_values(rows))
      |> Map.put("move_on_import", decoded_for(rows, "move_on_import") == "true")

    secrets_set =
      for f <- config_fields(),
          f.secret,
          not is_nil(decoded_for(rows, f.key)),
          into: MapSet.new() do
        f.key
      end

    %{
      values: values,
      secrets_set: secrets_set,
      placeholders: placeholders(rows),
      secrets_from_env: secrets_from_env(rows)
    }
  end

  # Effective env value to show as a placeholder for each non-secret field with no DB row
  # (config creds + the env-backed library_path roots; bands are DB-only, no env to show).
  defp placeholders(rows) do
    field_pairs = for f <- config_fields(), not f.secret, do: {f.key, effective_field_value(f)}
    path_pairs = for k <- library_path_keys(), do: {k, effective_flat_value(k)}

    (field_pairs ++ path_pairs)
    |> Enum.reject(fn {key, value} -> is_nil(value) or not is_nil(decoded_for(rows, key)) end)
    |> Map.new()
  end

  # Secret fields with no DB row but a value seeded from env — marked "set via environment"
  # in the UI (the value itself is never echoed).
  defp secrets_from_env(rows) do
    for f <- config_fields(),
        f.secret,
        is_nil(decoded_for(rows, f.key)),
        not is_nil(effective_field_value(f)),
        into: MapSet.new() do
      f.key
    end
  end

  defp library_path_keys, do: Enum.map(Cinder.Library.kinds(), &library_path_key/1)

  defp effective_field_value(%{module: module, field: field}) do
    :cinder |> Application.get_env(module, []) |> Keyword.get(field) |> blank_to_nil()
  end

  defp effective_flat_value(key) do
    :cinder |> Application.get_env(:"#{key}") |> blank_to_nil()
  end

  # --- writes ---

  @doc "Upserts one setting (encrypting if the registry marks it secret) and re-applies env."
  def put(key, value), do: save(%{key => value}, [])

  @doc "Deletes one setting and re-applies env (reverting it to the env/default bootstrap)."
  def delete(key), do: save(%{}, [key])

  @doc """
  Persists a batch of `puts` (`%{key => value}`) and `deletes` (`[key]`) in one
  transaction, then re-applies the env overlay once.
  """
  def save(puts, deletes \\ []) do
    Repo.transaction(fn ->
      Enum.each(puts, fn {k, v} -> upsert(k, v) end)
      Enum.each(deletes, &delete_row/1)
    end)

    load_into_env()
    :ok
  end

  @doc """
  Applies submitted form `params` (string-keyed): non-secret blanks clear, secret
  blanks keep the existing value, a `clear_<key>` flag deletes a secret.
  """
  def save_form(params) do
    {puts, deletes} = plan(params)
    save(puts, deletes)
  end

  # --- env overlay ---

  @doc """
  Overlays stored settings onto the `:cinder` Application env. Never raises — a
  decode/DB failure degrades to the env bootstrap and is logged.
  """
  def load_into_env do
    rows = rows_by_key()
    apply_config_fields(rows)
    apply_media_server(rows)
    apply_download_clients(rows)
    apply_library_config(rows)
    apply_move_on_import(rows)
    :ok
  rescue
    e ->
      Logger.error("Cinder.Settings.load_into_env failed; using env bootstrap: #{inspect(e)}")
      :ok
  catch
    # An exit/throw (e.g. a DB pool-checkout timeout deep in Repo.all) would otherwise
    # escape start_link and abort boot — the "never bricks boot" contract covers these too.
    kind, value ->
      Logger.error(
        "Cinder.Settings.load_into_env #{kind}; using env bootstrap: #{inspect(value)}"
      )

      :ok
  end

  defp apply_config_fields(rows) do
    config_fields()
    |> Enum.group_by(& &1.module)
    |> Enum.each(fn {module, fields} ->
      db_values =
        fields
        |> Enum.map(fn f -> {f.field, field_value(rows, f)} end)
        |> Enum.reject(fn {_field, value} -> is_nil(value) end)

      # Always re-apply base ⊕ db (not just when db is non-empty): merging onto the
      # captured bootstrap is what lets a removed/blanked setting revert to the env
      # default instead of stranding the last overlaid value.
      Application.put_env(:cinder, module, Keyword.merge(base(module), db_values))
    end)
  end

  # The setting picks the impl; with no setting fall back to the PLEX_URL bootstrap, then
  # to the captured base (config.exs default in prod, the Mox mock in tests). `fallback`
  # is computed every load (so base/1 is captured before any overlay, like the other
  # apply_* paths) — otherwise an explicit-then-cleared setting would revert to the last
  # impl instead of the bootstrap default.
  defp apply_media_server(rows) do
    fallback =
      if System.get_env("PLEX_URL"),
        do: Cinder.Library.MediaServer.Plex,
        else: base(:media_server)

    impl =
      case decoded_for(rows, @media_server_key) do
        "plex" -> Cinder.Library.MediaServer.Plex
        "jellyfin" -> Cinder.Library.MediaServer.Jellyfin
        _ -> fallback
      end

    Application.put_env(:cinder, :media_server, impl)
  end

  # Per-kind library config, applied uniformly for every Cinder.Library kind: the import root
  # (a flat :cinder env key WITH an env bootstrap) plus the DB-only size band. A DB value overlays
  # the bootstrap; a cleared setting reverts to it (base/1 snapshots the pre-overlay env once).
  # One loop — a new kind needs no new apply_* function.
  defp apply_library_config(rows) do
    for kind <- Cinder.Library.kinds(), do: apply_kind_config(rows, kind)
    :ok
  end

  defp apply_kind_config(rows, kind) do
    root_env = :"#{kind}_library_path"

    # Capture the bootstrap snapshot EAGERLY, before the `||` — otherwise the `||` short-circuits
    # past base_path/1 whenever a value is set, so base/1 first records the env lazily during a
    # *delete*, snapshotting the already-overlaid value instead of the true pre-overlay bootstrap
    # (a cleared setting would then revert to the overlaid value, not the env default).
    fallback = base_path(root_env)
    root = decoded_for(rows, "#{kind}_library_path") || fallback
    min_size = parse_gb(decoded_for(rows, "#{kind}_min_size"))
    max_size = parse_gb(decoded_for(rows, "#{kind}_max_size"))
    preferred = parse_resolutions(decoded_for(rows, "#{kind}_preferred_resolutions"))

    Application.put_env(:cinder, root_env, root)
    Application.put_env(:cinder, :"#{kind}_min_size", min_size)
    Application.put_env(:cinder, :"#{kind}_max_size", max_size)
    Application.put_env(:cinder, :"#{kind}_preferred_resolutions", preferred)
  end

  # Standalone global boolean — not a config field, toggle, or flat key, so it gets its own
  # tiny overlay. No base/1 snapshot: an unset/cleared row reverts via the inline `false` default
  # everywhere it's read (Application.get_env(:cinder, :move_on_import, false)).
  defp apply_move_on_import(rows) do
    Application.put_env(:cinder, :move_on_import, decoded_for(rows, "move_on_import") == "true")
  end

  # base/1 defaults to [] for unset keys; a library path is a flat string, so coerce an unset
  # bootstrap (e.g. MOVIES_LIBRARY_PATH absent → []) to nil. Health then reports :not_configured
  # rather than crashing on a list-typed path.
  defp base_path(env_key) do
    case base(env_key) do
      path when is_binary(path) -> path
      _ -> nil
    end
  end

  # A GB string → bytes. Blank/non-numeric/≤0 ⇒ nil (unbounded): a 0 or negative band would
  # silently reject every release, so it degrades to "no limit" rather than "grab nothing".
  defp parse_gb(nil), do: nil

  defp parse_gb(value) do
    case Float.parse(String.trim(value)) do
      {gb, _rest} when gb > 0 -> round(gb * @bytes_per_gb)
      _ -> nil
    end
  end

  # "1080p, 720P" → ["1080p", "720p"]. Downcased to match the parser's lower-case resolutions;
  # blank/empty ⇒ nil so the scorer's @default_preferred applies.
  defp parse_resolutions(nil), do: nil

  defp parse_resolutions(value) do
    case value
         |> String.split(",")
         |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
         |> Enum.reject(&(&1 == "")) do
      [] -> nil
      list -> list
    end
  end

  # Toggles build the client map from the captured base map (so a protocol with no toggle
  # row defaults to enabled and the test mock modules survive); with no toggle setting at
  # all, fall back to the base map. A protocol is included only when enabled.
  defp apply_download_clients(rows) do
    base_map = base(:download_clients)

    map =
      if Enum.any?(@toggles, fn t -> Map.has_key?(rows, t.key) end) do
        for t <- @toggles,
            enabled?(decoded_for(rows, t.key)),
            Map.has_key?(base_map, t.protocol),
            into: %{} do
          {t.protocol, Map.fetch!(base_map, t.protocol)}
        end
      else
        base_map
      end

    Application.put_env(:cinder, :download_clients, map)
  end

  # One-time snapshot of the bootstrap config for `key`, so the overlay is always
  # computed from the original env, not the already-overlaid (mutated) value.
  defp base(key) do
    pt_key = {__MODULE__, :base, key}

    case :persistent_term.get(pt_key, :__none__) do
      :__none__ ->
        value = Application.get_env(:cinder, key, [])
        :persistent_term.put(pt_key, value)
        value

      value ->
        value
    end
  end

  # --- helpers ---

  defp rows_by_key, do: all() |> Map.new(&{&1.key, &1})

  defp field_value(rows, field), do: decoded_for(rows, field.key)

  defp decoded_for(rows, key) do
    case Map.get(rows, key) do
      nil -> nil
      setting -> setting |> decoded() |> unwrap() |> blank_to_nil()
    end
  end

  defp unwrap({:ok, value}), do: value
  defp unwrap(:error), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp blank_to_nil(value), do: value

  defp decoded(%Setting{is_secret: false, value: value}), do: {:ok, value}
  defp decoded(%Setting{is_secret: true, value: nil}), do: {:ok, nil}

  defp decoded(%Setting{is_secret: true, value: value, key: key}) do
    # The is_binary guard matters: Cloak's AES-GCM decrypt returns {:ok, :error} (not an
    # error tuple, not a raise) when the GCM tag fails to authenticate — i.e. the value was
    # encrypted under a different SECRET_KEY_BASE. Without the guard, :error would be poured
    # into Application env as a credential. Here it falls to the skip-and-warn branch instead.
    with {:ok, ciphertext} <- Base.decode64(value),
         {:ok, plaintext} when is_binary(plaintext) <- Cinder.Vault.decrypt(ciphertext) do
      {:ok, plaintext}
    else
      _ ->
        Logger.warning("Cinder.Settings: cannot decrypt #{key}; re-enter it in /settings")
        :error
    end
  rescue
    _ ->
      Logger.warning("Cinder.Settings: cannot decrypt #{key}; re-enter it in /settings")
      :error
  end

  defp toggle_values(rows) do
    for t <- @toggles, into: %{} do
      {t.key, enabled?(decoded_for(rows, t.key))}
    end
  end

  defp enabled?(nil), do: true
  defp enabled?(value), do: value in ["true", "1", "on"]

  defp default_media_server_type do
    if System.get_env("PLEX_URL"), do: "plex", else: "jellyfin"
  end

  defp secret?(key), do: MapSet.member?(@secret_keys, key)

  defp upsert(key, value) do
    stored = if secret?(key), do: Base.encode64(Cinder.Vault.encrypt!(value)), else: value

    (Repo.get_by(Setting, key: key) || %Setting{})
    |> Setting.changeset(%{key: key, value: stored, is_secret: secret?(key)})
    |> Repo.insert_or_update!()
  end

  defp delete_row(key) do
    case Repo.get_by(Setting, key: key) do
      nil -> :ok
      setting -> Repo.delete!(setting)
    end
  end

  defp plan(params) do
    config_plan = Enum.reduce(config_fields(), {%{}, []}, &plan_config(&1, params, &2))
    {puts, deletes} = Enum.reduce(flat_keys(), config_plan, &plan_flat(&1, params, &2))

    puts =
      puts
      |> Map.put(@media_server_key, media_server_choice(params))
      |> Map.put("move_on_import", params["move_on_import"] || "false")
      |> then(fn p ->
        Enum.reduce(@toggles, p, fn t, acc -> Map.put(acc, t.key, params[t.key] || "false") end)
      end)

    {puts, deletes}
  end

  # Validate against the whitelist so a crafted/buggy submit can't persist a junk impl
  # string (which apply_media_server would silently ignore, leaving the dropdown unselected).
  defp media_server_choice(params) do
    case params[@media_server_key] do
      choice when choice in @media_server_options -> choice
      _ -> default_media_server_type()
    end
  end

  # A flat key (not a @config_fields entry) is planned like a non-secret field: present-but-blank
  # clears (reverts to env bootstrap / unbounded), absent leaves it untouched.
  defp plan_flat(key, params, {puts, deletes}) do
    if Map.has_key?(params, key) do
      case String.trim(params[key] || "") do
        "" -> {puts, [key | deletes]}
        value -> {Map.put(puts, key, value), deletes}
      end
    else
      {puts, deletes}
    end
  end

  # A field absent from params is left unchanged; only a present-but-blank value clears it
  # (so a partial/programmatic save can't silently wipe unrelated non-secret settings).
  defp plan_config(%{secret: false, key: key}, params, {puts, deletes}) do
    if Map.has_key?(params, key) do
      # `|| ""` keeps a present-but-nil value (a programmatic caller) safe — String.trim/1
      # would raise on nil; this matches the secret clause's handling.
      case String.trim(params[key] || "") do
        "" -> {puts, [key | deletes]}
        value -> {Map.put(puts, key, value), deletes}
      end
    else
      {puts, deletes}
    end
  end

  defp plan_config(%{secret: true, key: key}, params, {puts, deletes}) do
    cond do
      params["clear_" <> key] -> {puts, [key | deletes]}
      String.trim(params[key] || "") == "" -> {puts, deletes}
      true -> {Map.put(puts, key, String.trim(params[key])), deletes}
    end
  end
end
