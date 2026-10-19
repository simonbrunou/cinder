defmodule Cinder.Settings.Overlay do
  @moduledoc false
  # The env overlay behind `Cinder.Settings.load_into_env/0`: merges the stored rows onto a
  # one-time bootstrap snapshot of the `:cinder` env, one ordered phase at a time.
  #
  # Each definition names its target; @phases names the write order, because the dependencies
  # are between writers, not between definitions. `env_keys/0` folds the same phases, so the set
  # of keys a load writes is never re-listed by hand.

  alias Cinder.Acquisition.AnimePreferences
  alias Cinder.Library.MediaServer.{Jellyfin, Plex}
  alias Cinder.LibraryKind
  alias Cinder.Settings.{Crypto, Registry, Shape}

  @phases [
    # Writes the only fail-OPEN env key (:explicit_import_roots authorizes rm_rf), so it runs
    # first: a partial load failure below can then only leave it in its just-written (correct) or
    # boot-nil (fail-closed) state, never stale-authorized after a revoke.
    :explicit_import_roots,
    :modules,
    # Reads the Cinder.Mailer keyword list :modules just wrote (relay/port/username/password/
    # from), so it must run after.
    :mailer,
    :anime_preferences,
    :media_server,
    :download_clients,
    # One kind at a time, in `LibraryKind` order: its root, then (video kinds) its Anime root and
    # release rules.
    :kinds,
    # Every flat key not named in this list: the download clients' path mappings, and where a new
    # flat setting lands.
    :flat,
    # Its inferred fallback reads the :"#{root_role}_library_path" env keys :kinds just wrote, so
    # it must run after :kinds.
    :import_roots,
    {:env, :move_on_import},
    :upgrade_hunt,
    {:env, :ffprobe_bin},
    {:env, :default_request_quota},
    {:env, :household_timezone}
  ]

  @named_env for {:env, key} <- @phases, do: key

  for %{key: key, target: {:writer, writer}} <- Registry.definitions(), writer not in @phases do
    raise CompileError, description: "#{key} targets unknown overlay writer #{inspect(writer)}"
  end

  for env_key <- @named_env,
      not Enum.any?(Registry.definitions(), &(&1.target == {:env, env_key})) do
    raise CompileError, description: "overlay phase names #{env_key}, which no definition targets"
  end

  @doc "Writes every phase for the stored `rows` (`%{key => %Setting{}}`)."
  def apply(rows), do: Enum.each(@phases, &write(&1, rows))

  @doc "Every `:cinder` env key a load writes, in write order."
  def env_keys, do: @phases |> Enum.flat_map(&keys/1) |> Enum.uniq()

  # --- phase membership ---

  defp keys(:modules), do: Enum.map(module_definitions(), &elem(&1.target, 1))
  defp keys(:mailer), do: [Cinder.Mailer]
  defp keys(:upgrade_hunt), do: [Cinder.Catalog.UpgradeHunter]

  defp keys(phase) when phase in [:kinds, :flat] or is_tuple(phase),
    do: Enum.map(flat_definitions(phase), &elem(&1.target, 1))

  defp keys(phase), do: [phase]

  defp module_definitions,
    do: for(%{target: {:module, _module, _field}} = d <- Registry.definitions(), do: d)

  # Sorted stably by kind, so each kind keeps its definitions' order: root, Anime root, rules.
  defp flat_definitions(:kinds) do
    kinds = LibraryKind.all()

    for(%{target: {:env, _key}, kind: kind} = d <- Registry.definitions(), kind, do: d)
    |> Enum.sort_by(&Enum.find_index(kinds, fn kind -> kind == &1.kind end))
  end

  defp flat_definitions(:flat) do
    for %{target: {:env, env_key}, kind: nil} = definition <- Registry.definitions(),
        env_key not in @named_env,
        do: definition
  end

  defp flat_definitions({:env, env_key}),
    do: for(%{target: {:env, ^env_key}} = d <- Registry.definitions(), do: d)

  defp writer_definitions(writer),
    do: for(%{target: {:writer, ^writer}} = d <- Registry.definitions(), do: d)

  # --- writers ---

  defp write(:explicit_import_roots, rows),
    do: Application.put_env(:cinder, :explicit_import_roots, explicit_roots_from(rows))

  defp write(:modules, rows) do
    module_definitions()
    |> Enum.group_by(&elem(&1.target, 1))
    |> Enum.each(fn {module, definitions} ->
      db_values =
        for %{target: {:module, _module, field}} = definition <- definitions,
            value = Shape.to_env(definition.shape, decoded(rows, definition.key), nil, true),
            not is_nil(value),
            do: {field, value}

      # Always re-apply base ⊕ db (not just when db is non-empty): merging onto the captured
      # bootstrap is what lets a removed/blanked setting revert to the env default instead of
      # stranding the last overlaid value.
      Application.put_env(:cinder, module, Keyword.merge(base(module), db_values))
    end)
  end

  # Layers :adapter and :ssl onto the Cinder.Mailer config :modules just wrote. The adapter only
  # switches to SMTP once a host is actually configured: an unconfigured install keeps whatever
  # the bootstrap shipped (Swoosh.Adapters.Local in dev, .Test in test), so a blank smtp_host can
  # never crash the mailer on a missing :relay. Both Swoosh's SMTP adapter and the Local/Test
  # adapters accept extra unknown keys, so :from (read by Cinder.Mailer.from/0, not the adapter
  # itself) and a temporarily-stale :ssl on a non-SMTP adapter are harmless.
  defp write(:mailer, rows) do
    current = Application.get_env(:cinder, Cinder.Mailer, [])
    host = decoded(rows, "smtp_host")
    smtp? = is_binary(host) and host != ""

    adapter =
      if smtp? do
        Swoosh.Adapters.SMTP
      else
        Keyword.get(base(Cinder.Mailer), :adapter)
      end

    # :ssl must be a real boolean: gen_smtp pattern-matches `true` strictly, so the string "true"
    # would silently disable implicit TLS.
    ssl? = decoded(rows, "smtp_ssl") == "true"

    Application.put_env(
      :cinder,
      Cinder.Mailer,
      Keyword.merge(current, [adapter: adapter, ssl: ssl?] ++ mailer_tls_overlay(rows, host))
    )
  end

  # Rebuilt whole from the four Anime definitions (not merged), each falling back to its own
  # bootstrap field.
  defp write(:anime_preferences, rows) do
    base = base(:anime_preferences)

    config =
      for %{slot: slot} = definition <- writer_definitions(:anime_preferences) do
        fallback = anime_fallback(slot, base)
        {slot, Shape.to_env(definition.shape, decoded(rows, definition.key), fallback, true)}
      end

    Application.put_env(:cinder, :anime_preferences, config)
  end

  # The setting picks the impl; with no setting fall back to the PLEX_URL bootstrap, then to the
  # captured base (config.exs default in prod, the Mox mock in tests). `fallback` is computed
  # every load (so base/1 is captured before any overlay, like the other phases); otherwise an
  # explicit-then-cleared setting would revert to the last impl instead of the bootstrap default.
  defp write(:media_server, rows) do
    fallback =
      if System.get_env("PLEX_URL"),
        do: Plex,
        else: base(:media_server)

    impl =
      case decoded(rows, "media_server_type") do
        "plex" -> Plex
        "jellyfin" -> Jellyfin
        _ -> fallback
      end

    Application.put_env(:cinder, :media_server, impl)
  end

  # A saved choice selects exactly one implementation per protocol. Until a choice is saved,
  # preserve the bootstrap map (including test mocks) and honor the old 1.1 enable row.
  defp write(:download_clients, rows) do
    base_map = base(:download_clients)

    map =
      for choice <- Registry.download_client_choices(),
          module = selected_download_client(rows, choice, base_map),
          not is_nil(module),
          into: %{} do
        {choice.protocol, module}
      end

    Application.put_env(:cinder, :download_clients, map)
  end

  # A DB value overlays the bootstrap; a cleared one reverts to it.
  defp write(phase, rows) when phase in [:kinds, :flat] or is_tuple(phase) do
    for %{target: {:env, env_key}} = definition <- flat_definitions(phase) do
      # Capture the bootstrap EAGERLY, before the row lookup: a lazy capture would first record
      # the env during a *delete*, snapshotting the already-overlaid value instead of the true
      # pre-overlay bootstrap (a cleared setting would then revert to the overlaid value).
      fallback =
        case definition.bootstrap do
          :base -> Shape.from_base(definition.shape, base(env_key))
          :none -> Shape.empty(definition.shape)
        end

      value =
        Shape.to_env(
          definition.shape,
          decoded(rows, definition.key),
          fallback,
          Map.has_key?(rows, definition.key)
        )

      Application.put_env(:cinder, env_key, value)
    end

    :ok
  end

  defp write(:import_roots, rows) do
    Application.put_env(
      :cinder,
      :import_roots,
      explicit_roots_from(rows) || inferred_import_roots()
    )
  end

  # The quality-upgrade sweep's on/off switch overlays `:enabled` onto the captured config.exs
  # block for `Cinder.Catalog.UpgradeHunter`, which is where `UpgradeHunter.enabled?/0` already
  # reads, so any sibling key in that block (interval, batch) survives. An unset/cleared row leaves
  # the bootstrap untouched, so it reverts to the shipped `enabled: false`.
  defp write(:upgrade_hunt, rows) do
    module = Cinder.Catalog.UpgradeHunter
    base = base(module)

    config =
      case decoded(rows, "upgrade_hunt_enabled") do
        nil -> base
        value -> Keyword.put(base, :enabled, value == "true")
      end

    Application.put_env(:cinder, module, config)
  end

  defp anime_fallback(:embedded_subtitle_mode, base), do: base[:embedded_subtitle_mode]

  defp anime_fallback(slot, base) when slot in [:preferred_groups, :blocked_groups],
    do: AnimePreferences.normalize_groups(base[slot] || [])

  defp anime_fallback(:group_fallback_delay, base), do: base[:group_fallback_delay] || 86_400

  # gen_smtp's defaults are `tls: :if_available` (STARTTLS silently downgradable by a MITM
  # stripping the advertisement) with no certificate verification. Credentials must never cross
  # the wire in cleartext: with a password configured STARTTLS is mandatory, and whenever TLS
  # engages the relay certificate is verified against the system store. A password-less LAN relay
  # keeps opportunistic TLS so bare-postfix setups still work.
  defp mailer_tls_overlay(rows, host) when is_binary(host) and host != "" do
    tls = if decoded(rows, "smtp_password") in [nil, ""], do: :if_available, else: :always

    [
      tls: tls,
      tls_options: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        server_name_indication: String.to_charlist(host),
        depth: 3
      ]
    ]
  end

  defp mailer_tls_overlay(_rows, _host), do: []

  defp selected_download_client(rows, choice, base_map) do
    case Shape.choice_option(choice, decoded(rows, choice.key)) do
      %{module: module} ->
        module

      nil ->
        if Shape.enabled?(decoded(rows, choice.legacy_key)), do: base_map[choice.protocol]
    end
  end

  defp explicit_roots_from(rows) do
    case decoded(rows, "import_roots") do
      nil -> nil
      value -> parse_import_roots(value)
    end
  end

  defp parse_import_roots(value) do
    roots = Shape.split_import_roots(value)
    if "/" in roots, do: [], else: roots
  end

  @doc false
  def inferred_import_roots do
    roots =
      Cinder.Library.kinds()
      |> Enum.map(&Application.get_env(:cinder, :"#{LibraryKind.root_role(&1)}_library_path"))
      |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
      |> Enum.map(&Path.expand/1)

    infer_common_root(roots, length(Cinder.Library.kinds()))
  end

  defp infer_common_root(roots, expected_count)
       when length(roots) == expected_count do
    [first | rest] = roots

    common =
      rest
      |> Enum.reduce(Path.split(first), &common_path_parts/2)
      |> Path.join()

    if common == "/" or common in roots, do: [], else: [common]
  end

  defp infer_common_root(_roots, _expected_count), do: []

  defp common_path_parts(path, parts) do
    parts
    |> Enum.zip(Path.split(path))
    |> Enum.take_while(fn {left, right} -> left == right end)
    |> Enum.map(&elem(&1, 0))
  end

  @doc """
  One-time snapshot of the bootstrap config for `key`, so the overlay is always computed from the
  original env, not the already-overlaid (mutated) value. The `:persistent_term` key keeps the
  `Cinder.Settings` name it has always had.
  """
  def base(key) do
    pt_key = {Cinder.Settings, :base, key}

    case :persistent_term.get(pt_key, :__none__) do
      :__none__ ->
        value = Application.get_env(:cinder, key, [])
        :persistent_term.put(pt_key, value)
        value

      value ->
        value
    end
  end

  defp decoded(rows, key) do
    case Map.get(rows, key) do
      nil -> nil
      setting -> Crypto.decode_setting(setting)
    end
  end
end
