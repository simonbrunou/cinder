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

  alias Cinder.Acquisition.{AnimePreferences, Parser, Scorer}
  alias Cinder.Catalog.Profile
  alias Cinder.LibraryKind
  alias Cinder.Repo
  alias Cinder.Settings.{Crypto, Definition, Overlay, Registry, Setting, Shape}
  alias Cinder.Util

  # Found at compile time, like the overlay's writers: the media server web link reads the stored
  # type through this definition, and names and links each server through its options.
  @media_server Registry.one!(target: {:writer, :media_server})
  @media_servers Registry.media_servers()

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

  # --- setting definitions: one `Cinder.Settings.Definition` per key, catalogued in
  # `Cinder.Settings.Registry` ---

  @doc "Every setting definition, in `/settings` render order, optionally filtered by field."
  defdelegate definitions(filter \\ []), to: Registry
  defdelegate groups(), to: Registry
  defdelegate migration_sources(), to: Registry
  defdelegate download_client_choices(), to: Registry
  defdelegate library_kinds(), to: Registry
  defdelegate media_server_options(), to: Registry

  @doc "The settings key of a per-kind definition, e.g. `kind_key(:tv, :min_size)`."
  defdelegate kind_key(kind, slot), to: Definition

  @doc """
  How `key` reads to the operator: the group its disclosure is, its self-describing label (an
  English msgid or `{template, bindings}`, translated by `CinderWeb.SettingsLabels.t/1`) and the
  message a rejected value shows. An unregistered key describes as itself, with no group.
  """
  @spec describe(String.t()) :: %{
          key: String.t(),
          group: atom() | nil,
          label: Definition.label(),
          message: String.t() | nil
        }
  def describe(key) do
    case Registry.definition(key) do
      %Definition{} = definition ->
        %{
          key: key,
          group: definition.group,
          label: definition.label || key,
          message: Definition.message(definition)
        }

      nil ->
        %{key: key, group: nil, label: key, message: nil}
    end
  end

  @doc "Every `:cinder` env key `load_into_env/0` writes, in write order."
  @spec env_keys() :: [atom()]
  defdelegate env_keys(), to: Overlay

  @doc "The resolutions an upgrade cutoff may name."
  def release_resolutions, do: Parser.resolutions()

  @doc "Positive default quota for new users, or nil when the configured value is unusable."
  def default_request_quota do
    :cinder
    |> Application.get_env(:default_request_quota)
    |> Shape.positive_integer()
  end

  @doc "Validated IANA timezone used for household calendar-day decisions."
  def household_timezone do
    case Application.get_env(:cinder, :household_timezone, "Etc/UTC") do
      zone when is_binary(zone) ->
        zone = String.trim(zone)
        if valid_timezone?(zone), do: zone, else: "Etc/UTC"

      _ ->
        "Etc/UTC"
    end
  end

  @doc "The household-local date at a UTC instant."
  def household_date(at \\ DateTime.utc_now()) do
    case DateTime.shift_zone(at, household_timezone()) do
      {:ok, local} -> DateTime.to_date(local)
      {:error, _reason} -> DateTime.to_date(at)
    end
  end

  defp valid_timezone?(zone), do: Shape.valid_timezone?(zone)

  # --- reads ---

  @doc "All raw settings rows."
  def all, do: Repo.all(Setting)

  @doc """
  Keys of stored secret settings whose ciphertext cannot be decrypted under the current
  `SECRET_KEY_BASE` — typically after a key rotation or a restore under a different key. Each names
  a credential that is silently lost (skipped at load, so the app boots "healthy" while the
  pipeline can't reach the service) until re-entered. `[]` when every secret decodes, or none are
  stored. Never returns or logs the ciphertext itself.
  """
  @spec undecryptable_secret_keys() :: [String.t()]
  def undecryptable_secret_keys do
    for %Setting{is_secret: true} = row <- all(), not Crypto.decryptable?(row), do: row.key
  end

  @doc "Returns true if the auto-approve-all setting is explicitly enabled."
  def auto_approve_all?, do: get("auto_approve_all") == "true"

  @doc "True once the first-run wizard has been completed."
  def setup_complete?, do: get("setup_complete") == "true"

  @doc """
  The browser-reachable media-server URL a household member should open, or `nil` when the
  operator has not set one.

  Resolved from the stored `media_server_type`, else the option whose `os_env` variable is set
  (`PLEX_URL` picks Plex): the same choice that picks the impl in the env overlay, so a Plex
  instance never links at a leftover Jellyfin URL. The server atom and its module come from that
  definition's options. When neither applies, this falls back to a *uniquely* configured web URL
  and otherwise returns `nil`: with both set and no choice, either answer is a guess, and sending
  someone to the wrong server is worse than showing no link.

  When the background media-server inventory has reconciled a title, pass its opaque item id to
  `media_server_web_link/1` for a title deep link. A missing or stale id retains this front-door
  fallback.
  """
  @spec media_server_web_link() :: {:plex | :jellyfin, String.t()} | nil
  def media_server_web_link do
    case running_media_server() do
      %{} = option -> web_link_for(option)
      nil -> sole_configured_web_link()
    end
  end

  @doc """
  The media server type Cinder runs against, picked as the env overlay picks its impl: the stored
  `media_server_type`, else the option whose `os_env` variable is set (`PLEX_URL` picks Plex),
  else the option whose module is the bootstrap impl (config.exs's Jellyfin). `nil` only when the
  bootstrap is no listed server, as in tests, where it is the Mox mock.

  Data a server wrote carries its type, so a reader uses this to ignore what the other type left
  behind after a switch, as `Cinder.Catalog.MediaServerSeasons` does. It reads the bootstrap
  snapshot, never the running impl (`Cinder.Library.MediaServer.impl/0`), which tests point at
  the same Mox mock for both types. `media_server_web_link/0` keeps its own fallback when no type
  is stored and no `os_env` is set.
  """
  @spec media_server_type() :: :plex | :jellyfin | nil
  def media_server_type do
    case running_media_server() || bootstrap_media_server() do
      %{server: server} -> server
      nil -> nil
    end
  end

  defp running_media_server,
    do: Shape.running_media_server(@media_servers, get(@media_server.key))

  defp bootstrap_media_server do
    bootstrap = Overlay.base(:media_server)
    Enum.find(@media_servers, &(&1.module == bootstrap))
  end

  @doc """
  Returns a title deep link for a reconciled item id, or the server front door. The id starts
  with the server that wrote it (`"plex:"`, `"jellyfin:"`), so the other server's id gets the
  front door.
  """
  @spec media_server_web_link(String.t() | nil) :: {:plex | :jellyfin, String.t()} | nil
  def media_server_web_link(item_id), do: media_server_web_link(media_server_web_link(), item_id)

  @doc false
  def media_server_web_link(link, item_id) do
    case link do
      {server, fallback} ->
        %{module: module} = Enum.find(@media_servers, &(&1.server == server))
        {server, module.deep_link(item_id) || fallback}

      nil ->
        nil
    end
  end

  defp web_link_for(%{server: server, module: module}) do
    url =
      :cinder
      |> Application.get_env(module, [])
      |> Keyword.get(:web_url)
      |> Util.blank_to_nil()
      |> absolute_http_url()

    url && {server, url}
  end

  defp sole_configured_web_link do
    case Enum.flat_map(@media_servers, &List.wrap(web_link_for(&1))) do
      [only] -> only
      _ -> nil
    end
  end

  # Rendering this straight into an href has two failure modes worth closing here rather than at
  # the call site: a scheme-less "plex.example.com" is a *relative* link (it would resolve against
  # the current page), and a "javascript:" value makes Phoenix's <.link> raise, taking the whole
  # page down. Both are operator typos, so degrade to "no link" instead.
  defp absolute_http_url("http://" <> rest) when rest != "", do: "http://" <> rest
  defp absolute_http_url("https://" <> rest) when rest != "", do: "https://" <> rest
  defp absolute_http_url(_), do: nil

  @doc "Expanded download roots permitted as import sources."
  @spec import_roots() :: [String.t()]
  def import_roots do
    case Application.get_env(:cinder, :import_roots) do
      roots when is_list(roots) -> roots
      _ -> Overlay.inferred_import_roots()
    end
  end

  @doc """
  The `import_roots` setting exactly as configured, or `nil` when unset — never the
  common-ancestor guess `import_roots/0` falls back to for reads. `import_roots/0`'s inference
  bakes the guessed root into the same `:cinder, :import_roots` env key it returns, so a reader
  can't tell "an operator typed this" from "we guessed it." Deletion needs that distinction:
  authorizing `rm_rf` against an inferred root (which can be a whole downloads-category
  directory, e.g. `/data` for `/data/movies` + `/data/tv`) on a misreported `content_path` is
  unsafe, so `Library.delete_download_source/1` requires an explicit root and never falls back.
  """
  @spec explicit_import_roots() :: [String.t()] | nil
  def explicit_import_roots, do: Application.get_env(:cinder, :explicit_import_roots)

  @doc "Configured named and legacy destinations, without duplicate roots for a kind."
  @spec library_destinations() :: [map()]
  def library_destinations do
    (named_destinations() ++ legacy_library_destinations())
    |> Enum.reject(&is_nil(&1.path))
    |> Enum.uniq_by(fn destination ->
      {destination.kind, Path.expand(destination.path)}
    end)
  end

  @doc "The destination for a title, with blank named roots using their legacy handling fallback."
  @spec library_root(atom(), term()) :: {:ok, String.t()} | {:error, :library_not_configured}
  def library_root(kind, media) do
    path =
      case named_profile(media) do
        %Profile{kind: ^kind} = profile ->
          Util.blank_to_nil(profile.library_path) || fallback_library_path(kind, profile.handling)

        _missing_or_wrong_kind ->
          fallback_library_path(kind, routing_profile(media))
      end

    if path, do: {:ok, path}, else: {:error, :library_not_configured}
  end

  @doc "Returns the most-specific configured library root containing `path`."
  @spec library_root_for_path(String.t()) :: {:ok, String.t()} | {:error, :outside_library}
  def library_root_for_path(path) when is_binary(path) do
    case library_destination_for_path(path) do
      {:ok, destination} -> {:ok, Path.expand(destination.path)}
      {:error, :outside_library} = error -> error
    end
  end

  @doc "Returns the most-specific configured destination containing `path`."
  @spec library_destination_for_path(String.t()) :: {:ok, map()} | {:error, :outside_library}
  def library_destination_for_path(path) when is_binary(path),
    do: library_destination_for_path(nil, path)

  @doc "Returns the most-specific destination of `kind` containing `path`."
  @spec library_destination_for_path(atom(), String.t()) ::
          {:ok, map()} | {:error, :outside_library}
  def library_destination_for_path(kind, path) when is_atom(kind) and is_binary(path),
    do: find_library_destination(kind, path)

  defp find_library_destination(kind, path) do
    expanded = Path.expand(path)

    library_destinations()
    |> Enum.filter(&(is_nil(kind) or &1.kind == kind))
    |> Enum.sort_by(&byte_size(Path.expand(&1.path)), :desc)
    |> Enum.find(fn destination ->
      root = Path.expand(destination.path)
      expanded == root or String.starts_with?(expanded, root <> "/")
    end)
    |> case do
      nil -> {:error, :outside_library}
      destination -> {:ok, destination}
    end
  end

  @doc "Expanded library roots permitted as managed destinations."
  @spec library_roots() :: [String.t()]
  def library_roots do
    library_destinations()
    |> Enum.map(&Path.expand(&1.path))
    |> Enum.uniq()
  end

  @doc "Expanded video library roots permitted as managed destinations."
  @spec video_library_roots() :: [String.t()]
  def video_library_roots do
    library_destinations()
    |> Enum.filter(&LibraryKind.video?(&1.kind))
    |> Enum.map(&Path.expand(&1.path))
    |> Enum.uniq()
  end

  @doc """
  The library root configured for `kind` and `handling` (`:standard` or `:anime`), read from the
  env key its root definition targets: `nil` when the root is blank or `kind` has no root for
  `handling` (books have no Anime root). Raises `KeyError` for an unknown kind.
  """
  @spec configured_library_path(atom(), :standard | :anime) :: String.t() | nil
  defdelegate configured_library_path(kind, handling \\ :standard), to: Overlay

  defp fallback_library_path(kind, profile),
    do: configured_library_path(kind, profile) || configured_library_path(kind, :standard)

  defp named_destinations do
    for %Profile{} = profile <- Cinder.Catalog.list_profiles(),
        path = Util.blank_to_nil(profile.library_path),
        path do
      %{
        kind: profile.kind,
        profile: profile.handling,
        profile_id: profile.id,
        profile_name: profile.name,
        path: path
      }
    end
  end

  @doc "Boot-configured Standard and Anime destinations, without profile-store reads."
  @spec legacy_library_destinations() :: [map()]
  def legacy_library_destinations do
    Enum.flat_map(LibraryKind.all(), fn kind ->
      standard = configured_library_path(kind, :standard)
      anime = configured_library_path(kind, :anime)

      [%{kind: kind, profile: :standard, profile_id: nil, path: standard}] ++
        if(anime in [nil, standard],
          do: [],
          else: [%{kind: kind, profile: :anime, profile_id: nil, path: anime}]
        )
    end)
    |> Enum.reject(&is_nil(&1.path))
    |> Enum.uniq_by(&{&1.kind, Path.expand(&1.path)})
  end

  defp named_profile([media | _rest]), do: named_profile(media)
  defp named_profile(%{season: %{series: series}}), do: named_profile(series)
  defp named_profile(%{profile: %Profile{} = profile}), do: profile

  defp named_profile(%{profile_id: id}) when is_integer(id),
    do: Cinder.Catalog.get_profile(id)

  defp named_profile(_media), do: nil

  defp routing_profile(:anime), do: :anime
  defp routing_profile([media | _rest]), do: routing_profile(media)
  defp routing_profile(%{media_profile: :anime}), do: :anime
  defp routing_profile(%{season: %{series: %{media_profile: :anime}}}), do: :anime
  defp routing_profile(_media), do: :standard

  @doc "Typed global Anime release defaults with normalized language and group lists."
  def anime_defaults do
    anime = Application.fetch_env!(:cinder, :anime_preferences)
    subtitle = Application.get_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, [])

    anime
    |> Map.new()
    |> Map.put(
      :subtitle_languages,
      subtitle |> Keyword.get(:languages, "") |> normalize_anime_languages()
    )
  end

  @doc "Marks the first-run wizard complete."
  def mark_setup_complete, do: put("setup_complete", "true")

  @doc "Decoded value for `key` (decrypting secrets), or `nil` if unset/undecryptable."
  def get(key) do
    case Repo.get_by(Setting, key: key) do
      nil -> nil
      setting -> decode_setting(setting)
    end
  end

  @doc """
  Form state for the LiveView. `form_state/2` safely overlays submitted, non-secret
  values after validation errors so the operator can correct them without retyping.

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
    lookup = &decoded_for(rows, &1)

    values =
      for %Definition{} = definition <- form_definitions(),
          not Definition.secret?(definition),
          into: %{} do
        value = Shape.form_value(definition.shape, lookup.(definition.key), lookup)
        {definition.key, value}
      end

    secrets_set =
      for %Definition{key: key} = definition <- form_definitions(),
          Definition.secret?(definition),
          not is_nil(lookup.(key)),
          into: MapSet.new(),
          do: key

    %{
      values: values,
      secrets_set: secrets_set,
      placeholders: placeholders(lookup),
      secrets_from_env: secrets_from_env(lookup),
      clear_secrets: MapSet.new(),
      invalid_keys: MapSet.new()
    }
  end

  def form_state(params, invalid_keys \\ []) when is_map(params) do
    state = form_state()

    values =
      for %Definition{key: key} = definition <- form_definitions(),
          not Definition.secret?(definition),
          {:ok, value} <- [Shape.resubmitted(definition.shape, key, params)],
          reduce: state.values do
        values -> Map.put(values, key, value)
      end

    clear_secrets =
      for %Definition{key: key} = definition <- form_definitions(),
          Definition.secret?(definition),
          Shape.truthy?(params["clear_" <> key]),
          into: MapSet.new(),
          do: key

    %{
      state
      | values: values,
        clear_secrets: clear_secrets,
        invalid_keys: MapSet.new(invalid_keys)
    }
  end

  # The definitions the main settings form shows: everything but the keys edited elsewhere.
  defp form_definitions, do: Enum.reject(definitions(), &(&1.save == :direct))

  # Effective env value shown as a placeholder for each non-secret definition that asks for one
  # and has no DB row (the service creds, the library roots and ffprobe_bin; the band defaults
  # are raw bytes, stated in the group's help text instead of echoed as a placeholder).
  defp placeholders(lookup) do
    for %Definition{env_placeholder: true, key: key} = definition <- definitions(),
        is_nil(lookup.(key)),
        value = effective_value(definition),
        not is_nil(value),
        into: %{},
        do: {key, value}
  end

  # Secret definitions with no DB row but a value seeded from env, marked "set via environment"
  # in the UI (the value itself is never echoed).
  defp secrets_from_env(lookup) do
    for %Definition{key: key} = definition <- definitions(),
        Definition.secret?(definition),
        is_nil(lookup.(key)),
        not is_nil(effective_value(definition)),
        into: MapSet.new(),
        do: key
  end

  defp effective_value(%Definition{target: {:module, module, field}}),
    do: :cinder |> Application.get_env(module, []) |> Keyword.get(field) |> Util.blank_to_nil()

  defp effective_value(%Definition{target: {:env, env_key}}),
    do: :cinder |> Application.get_env(env_key) |> Util.blank_to_nil()

  @topic "settings"

  @doc """
  Subscribes to `:settings_updated`, broadcast once after any settings write has been committed
  and applied to the env.

  Deliberately payload-free: subscribers re-read what they care about, so this never has to know
  which keys any given page depends on.
  """
  def subscribe, do: Phoenix.PubSub.subscribe(Cinder.PubSub, @topic)

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
    # `commit -> load_into_env/0` is not atomic: each loader captures its own DB snapshot
    # (`rows_by_key/0`) before writing individual Application env keys. Without serialization,
    # an older writer's commit-then-reload can interleave around a newer one — e.g. this save
    # deletes `import_roots` and finishes its overlay, then a slower, already-committed earlier
    # save's overlay lands afterwards and resurrects the deleted value in the env, even though
    # the DB agrees with the newer state. `:global.trans/2` (the same lock primitive
    # `Download.with_intent_lock/2` and `Library.with_lock/2` use) makes the whole
    # commit-then-overlay sequence one atomic unit per writer, so an older snapshot can never
    # apply after a newer commit.
    :global.trans({{__MODULE__, :write}, self()}, fn -> commit_and_reload(puts, deletes) end)

    # After the commit AND after the env overlay, so a subscriber that re-reads on this message
    # sees the new values rather than racing the apply.
    Phoenix.PubSub.broadcast(Cinder.PubSub, @topic, :settings_updated)
    :ok
  end

  # Asserted: upsert/delete_row are bang functions today, so a failure raises out of the
  # transaction — but the result must never be silently discarded, or a future non-bang refactor
  # would flash "Settings saved." over an unapplied rollback.
  defp commit_and_reload(puts, deletes) do
    {:ok, _} =
      Repo.transaction(fn ->
        Enum.each(puts, fn {k, v} -> upsert(k, v) end)
        Enum.each(deletes, &delete_row/1)
      end)

    load_into_env()
  end

  @doc """
  Applies submitted form `params` (string-keyed): non-secret blanks clear, secret
  blanks keep the existing value, a `clear_<key>` flag deletes a secret.

  Values are validated first: a non-blank size the GB coercion would
  silently degrade to nil ("abc", "-2") is rejected — persisting it would echo
  back as if accepted while the scorer runs unbounded — except an explicit 0,
  the documented unbounded opt-out (blank reverts to the shipped default band).
  `/` is never accepted as an import root. Returns `:ok`, or
  `{:error, invalid_keys}` with nothing saved, the keys in `/settings` render order.
  """
  def save_form(params) do
    case invalid_values(params) do
      [] ->
        {puts, deletes} =
          Enum.reduce(definitions(), {%{}, []}, &Shape.plan(&1, params, &2))

        save(puts, deletes)

      invalid ->
        {:error, invalid}
    end
  end

  # Only a validated definition can reject a value, so every rejected key has the group, label and
  # message `describe/1` promises (the cross-product test in definition_test fences this).
  defp invalid_values(params) do
    for %Definition{key: key} = definition <- definitions(),
        Definition.validated?(definition),
        Shape.invalid?(definition.shape, params[key]) or
          fails_check?(definition.check, definition, params),
        do: key
  end

  defp fails_check?(nil, _definition, _params), do: false

  defp fails_check?(:cutoff_in_preferred, %Definition{key: key, kind: kind}, params) do
    with {:ok, value} <- Map.fetch(params, key),
         cutoff when cutoff != "" <- (value || "") |> String.trim() |> String.downcase() do
      cutoff not in effective_preferred_resolutions(params, kind)
    else
      _absent_or_blank -> false
    end
  end

  defp fails_check?(:languages_for_require, _definition, params) do
    effective_embedded_subtitle_mode(params) == :require and
      effective_subtitle_languages(params) == []
  end

  defp effective_preferred_resolutions(params, kind) do
    case Map.fetch(params, kind_key(kind, :preferred_resolutions)) do
      {:ok, value} ->
        Shape.parse_csv_list(value) || Scorer.default_preferred()

      :error ->
        Application.get_env(:cinder, :"#{kind}_preferred_resolutions") ||
          Scorer.default_preferred()
    end
  end

  defp effective_embedded_subtitle_mode(params) do
    case Map.fetch(params, "anime_embedded_subtitle_mode") do
      {:ok, value} ->
        case String.trim(value || "") do
          "require" -> :require
          "" -> Overlay.base(:anime_preferences)[:embedded_subtitle_mode]
          _value -> :other
        end

      :error ->
        anime_defaults().embedded_subtitle_mode
    end
  end

  defp effective_subtitle_languages(params) do
    languages =
      case Map.fetch(params, "subtitle_languages") do
        {:ok, value} when is_binary(value) and byte_size(value) > 0 ->
          if String.trim(value) == "",
            do: Overlay.base(Cinder.Subtitles.Provider.OpenSubtitles)[:languages] || "",
            else: value

        {:ok, value} when is_list(value) ->
          value

        {:ok, _blank} ->
          Overlay.base(Cinder.Subtitles.Provider.OpenSubtitles)[:languages] || ""

        :error ->
          :cinder
          |> Application.get_env(Cinder.Subtitles.Provider.OpenSubtitles, [])
          |> Keyword.get(:languages, "")
      end

    normalize_anime_languages(languages)
  end

  defp normalize_anime_languages(languages) when is_binary(languages) do
    languages |> String.split(",") |> AnimePreferences.normalize_languages()
  end

  defp normalize_anime_languages(languages), do: AnimePreferences.normalize_languages(languages)

  # --- env overlay ---

  @doc """
  Overlays stored settings onto the `:cinder` Application env. Never raises — a
  decode/DB failure degrades to the env bootstrap and is logged. The write order lives in
  `Cinder.Settings.Overlay`; `env_keys/0` lists every key it writes.
  """
  def load_into_env do
    Overlay.apply(rows_by_key())
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

  # --- helpers ---

  defp rows_by_key, do: all() |> Map.new(&{&1.key, &1})

  defp decoded_for(rows, key) do
    case Map.get(rows, key) do
      nil -> nil
      setting -> decode_setting(setting)
    end
  end

  # Secret encode/decode lives in Cinder.Settings.Crypto (code motion, 1500-line cap).
  defp decode_setting(setting), do: Crypto.decode_setting(setting)

  defp secret?(key) do
    case Registry.definition(key) do
      %Definition{} = definition -> Definition.secret?(definition)
      nil -> false
    end
  end

  defp upsert(key, value) do
    stored = Crypto.store_value(secret?(key), value)

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
end
