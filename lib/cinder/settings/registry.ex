defmodule Cinder.Settings.Registry do
  @moduledoc """
  The catalogue of setting definitions: one `Cinder.Settings.Definition` per settings key, in
  `/settings` render order, built at compile time from the static service fields and
  `Cinder.LibraryKind`.

  A plain new setting is one entry here plus its French msgstr. `msgids/0` hands every English
  string the definitions can emit to `CinderWeb.SettingsLabels`, which registers them for
  extraction, so nothing else needs editing.
  """

  import Cinder.Settings.Definition, only: [field: 3, new: 3, kind_key: 2, root_slot: 1]

  alias Cinder.Download.Client
  alias Cinder.Library.MediaServer.{Jellyfin, Plex}
  alias Cinder.LibraryKind

  @migration_sources [
    %{
      key: "radarr",
      name: "Radarr",
      module: Cinder.Library.MigrationSource.Radarr,
      port: 7878,
      remote: "/movies",
      local: "/media/movies"
    },
    %{
      key: "sonarr",
      name: "Sonarr",
      module: Cinder.Library.MigrationSource.Sonarr,
      port: 8989,
      remote: "/tv",
      local: "/media/tv"
    },
    %{
      key: "readarr",
      name: "Readarr",
      module: Cinder.Library.MigrationSource.Readarr,
      port: 8787,
      remote: "/library/ebooks",
      local: "/media/books"
    }
  ]

  @remote_help "Path prefix as the download client reports it"
  @local_help "The same directory as Cinder sees it"

  @download_client_choices [
    %{
      key: "torrent_client",
      protocol: :torrent,
      label: "Torrent client",
      default: "qbittorrent",
      legacy_key: "qbittorrent_enabled",
      options: [
        %{value: "disabled", label: "Disabled", module: nil},
        %{value: "qbittorrent", label: "qBittorrent", module: Client.QBittorrent},
        %{value: "transmission", label: "Transmission", module: Client.Transmission}
      ]
    },
    %{
      key: "usenet_client",
      protocol: :usenet,
      label: "Usenet client",
      default: "sabnzbd",
      legacy_key: "sabnzbd_enabled",
      options: [
        %{value: "disabled", label: "Disabled", module: nil},
        %{value: "sabnzbd", label: "SABnzbd", module: Client.Sabnzbd},
        %{value: "nzbget", label: "NZBGet", module: Client.Nzbget}
      ]
    }
  ]

  @groups [
    tmdb: "TMDB",
    indexer: "Indexer",
    migration: "Migration sources",
    download: "Download clients",
    media_server: "Media server",
    audiobook_server: "Audiobookshelf",
    library: "Library paths",
    releases: "Release size bands",
    subtitles: "Subtitles",
    books: "Books metadata",
    notifications: "Notifications",
    accounts: "Accounts"
  ]

  @migration (for source <- @migration_sources,
                  {suffix, attr, label, opts} <- [
                    {"url", :base_url, "URL", placeholder: "http://localhost:#{source.port}"},
                    {"api_key", :api_key, "API key", shape: :secret},
                    {"remote_path_prefix", :remote_path_prefix, "remote path prefix",
                     placeholder: source.remote, help: @remote_help},
                    {"local_path_prefix", :local_path_prefix, "local path prefix",
                     placeholder: source.local, help: @local_help}
                  ] do
                field(
                  "#{source.key}_#{suffix}",
                  {source.module, attr},
                  [group: :migration, label: "#{source.name} #{label}"] ++ opts
                )
              end)

  # A client's credentials, then where it saves files as the client and as Cinder see them.
  @download (for {prefix, name, module, creds} <- [
                   {"qbittorrent", "qBittorrent", Client.QBittorrent,
                    [
                      {"url", :base_url, "qBittorrent URL", placeholder: "http://localhost:8080"},
                      {"username", :username, "qBittorrent username", []},
                      {"password", :password, "qBittorrent password", shape: :secret}
                    ]},
                   {"transmission", "Transmission", Client.Transmission,
                    [
                      {"url", :base_url, "Transmission RPC URL",
                       placeholder: "http://localhost:9091/transmission/rpc"},
                      {"username", :username, "Transmission username", []},
                      {"password", :password, "Transmission password", shape: :secret}
                    ]},
                   {"sabnzbd", "SABnzbd", Client.Sabnzbd,
                    [
                      {"url", :base_url, "SABnzbd URL", placeholder: "http://localhost:8080"},
                      {"api_key", :api_key, "SABnzbd API key", shape: :secret}
                    ]},
                   {"nzbget", "NZBGet", Client.Nzbget,
                    [
                      {"url", :base_url, "NZBGet JSON-RPC URL",
                       placeholder: "http://localhost:6789/jsonrpc"},
                      {"username", :username, "NZBGet username", placeholder: "nzbget"},
                      {"password", :password, "NZBGet password", shape: :secret}
                    ]}
                 ],
                 definition <-
                   Enum.map(creds, fn {suffix, attr, label, opts} ->
                     field("#{prefix}_#{suffix}", {module, attr},
                       group: :download,
                       label: label,
                       placeholder: Keyword.get(opts, :placeholder, ""),
                       shape: Keyword.get(opts, :shape, :text)
                     )
                   end) ++
                     [
                       field(
                         "#{prefix}_remote_path_prefix",
                         :"#{prefix}_remote_path_prefix",
                         group: :download,
                         label: "#{name} remote path prefix",
                         placeholder: "/downloads",
                         help: @remote_help
                       ),
                       field(
                         "#{prefix}_local_path_prefix",
                         :"#{prefix}_local_path_prefix",
                         group: :download,
                         label: "#{name} local path prefix",
                         placeholder: "/media/downloads",
                         help: @local_help
                       )
                     ] do
               definition
             end)

  @download_choices (for choice <- @download_client_choices do
                       new(choice.key, {:download_client, choice},
                         group: :download,
                         label: choice.label,
                         target: {:writer, :download_clients}
                       )
                     end)

  # Legacy 1.1 rows remain readable so an upgrade doesn't silently re-enable a disabled protocol.
  @legacy_toggles [
    new("qbittorrent_enabled", :legacy_toggle,
      group: :download,
      label: "Enable qBittorrent (torrent)",
      target: {:writer, :download_clients},
      save: :read_only,
      render: :none
    ),
    new("sabnzbd_enabled", :legacy_toggle,
      group: :download,
      label: "Enable SABnzbd (usenet)",
      target: {:writer, :download_clients},
      save: :read_only,
      render: :none
    )
  ]

  @torrent_cleanup [
    field("torrent_cleanup_ratio", {Cinder.Download.Cleaner, :ratio_limit},
      shape: :positive_number,
      group: :download,
      label: "Remove completed torrents at ratio",
      placeholder: "Disabled"
    ),
    field("torrent_cleanup_seed_hours", {Cinder.Download.Cleaner, :seed_time_limit_hours},
      shape: :positive_number,
      group: :download,
      label: "Remove completed torrents after seed hours",
      placeholder: "Disabled"
    )
  ]

  # The *_url fields are how the Cinder server reaches the media server, which in the documented
  # compose deployment is a docker-internal address (see .env.example). The *_web_url fields are
  # what a household member's browser should open instead, so they are a separate,
  # operator-supplied value rather than something derivable from the server URL. One Plex section
  # per video kind, so a server with separate Movies/Shows libraries refreshes the right one.
  #
  # Each option's `server` is the atom `Cinder.Settings.media_server_web_link/0` names it by. With
  # no listed type stored, the option whose `os_env` variable is set is the bootstrap choice for
  # the overlay, the form and the web link; with none set, the form shows the first option, the
  # overlay keeps the captured impl and the web link takes a uniquely configured web URL.
  @media_server [
                  new(
                    "media_server_type",
                    {:media_server,
                     [
                       %{value: "jellyfin", server: :jellyfin, module: Jellyfin, os_env: nil},
                       %{value: "plex", server: :plex, module: Plex, os_env: "PLEX_URL"}
                     ]},
                    group: :media_server,
                    label: "Media server type",
                    target: {:writer, :media_server},
                    save: :always
                  ),
                  field("jellyfin_url", {Jellyfin, :url},
                    group: :media_server,
                    label: "Jellyfin URL",
                    placeholder: "http://localhost:8096"
                  ),
                  field("jellyfin_api_key", {Jellyfin, :api_key},
                    shape: :secret,
                    group: :media_server,
                    label: "Jellyfin API key"
                  ),
                  field("plex_url", {Plex, :url},
                    group: :media_server,
                    label: "Plex URL",
                    placeholder: "http://localhost:32400"
                  ),
                  field("plex_token", {Plex, :token},
                    shape: :secret,
                    group: :media_server,
                    label: "Plex token"
                  ),
                  field("jellyfin_web_url", {Jellyfin, :web_url},
                    group: :media_server,
                    label: "Jellyfin web URL",
                    placeholder: "https://jellyfin.example.com"
                  ),
                  field("plex_web_url", {Plex, :web_url},
                    group: :media_server,
                    label: "Plex web URL",
                    placeholder: "https://app.plex.tv"
                  )
                ] ++
                  for(
                    kind <- LibraryKind.video(),
                    do:
                      field("#{kind}_plex_section", {Plex, :"#{kind}_section"},
                        group: :media_server,
                        label: "Plex #{LibraryKind.label(kind)} library section (numeric id)"
                      )
                  )

  # One root per handling a kind supports: every kind has a Standard root, and only kinds with
  # Anime handling get an Anime root. Both show the effective env root as their placeholder.
  @root_handlings [
    standard: {"%{kind} library folder", :base},
    anime: {"Anime %{kind} library folder", :none}
  ]

  @library [
             new("import_roots", :root_list,
               group: :library,
               label: "Download folders",
               target: {:writer, :import_roots}
             )
           ] ++
             (for kind <- LibraryKind.all(),
                  binding = [kind: LibraryKind.label(kind)],
                  handling <- LibraryKind.handlings(kind),
                  {template, bootstrap} = Keyword.fetch!(@root_handlings, handling) do
                slot = root_slot(handling)
                key = kind_key(kind, slot)

                new(key, :path_root,
                  group: :library,
                  label: {template, binding},
                  target: {:env, String.to_atom(key)},
                  bootstrap: bootstrap,
                  env_placeholder: true,
                  kind: kind,
                  slot: slot
                )
              end) ++
             [
               new("move_on_import", :boolean,
                 group: :library,
                 label: "Remove download after a Usenet import",
                 target: {:env, :move_on_import},
                 save: :always
               ),
               new("ffprobe_bin", :text,
                 group: :library,
                 label: "ffprobe media analysis tool",
                 target: {:env, :ffprobe_bin},
                 bootstrap: :base,
                 env_placeholder: true
               )
             ]

  # min/max_size have a config.exs bootstrap (the shipped default bands; a stored 0 opts out to
  # unbounded); the release lists and the cutoff stay DB-only (unset means the scorer/hunter
  # default).
  @releases (for kind <- LibraryKind.video(),
                 binding = [kind: LibraryKind.label(kind)],
                 {slot, shape, template, opts} <- [
                   {:min_size, :size_band, "%{kind}: Min size (GB)", bootstrap: :base},
                   {:max_size, :size_band, "%{kind}: Max size (GB)", bootstrap: :base},
                   {:preferred_resolutions, {:list, :downcase}, "%{kind}: Preferred resolutions",
                    []},
                   {:preferred_sources, {:list, :downcase}, "%{kind}: Preferred sources", []},
                   {:preferred_terms, {:list, :downcase}, "%{kind}: Preferred terms", []},
                   {:blocked_terms, {:list, :downcase}, "%{kind}: Blocked terms", []},
                   {:upgrade_cutoff, :resolution, "%{kind}: Automatic upgrade cutoff",
                    check: :cutoff_in_preferred}
                 ] do
               key = kind_key(kind, slot)

               new(
                 key,
                 shape,
                 [
                   group: :releases,
                   label: {template, binding},
                   target: {:env, String.to_atom(key)},
                   kind: kind,
                   slot: slot
                 ] ++ opts
               )
             end)

  @subtitles [
    field("opensubtitles_api_key", {Cinder.Subtitles.Provider.OpenSubtitles, :api_key},
      shape: :secret,
      group: :subtitles,
      label: "OpenSubtitles API key"
    ),
    field("opensubtitles_username", {Cinder.Subtitles.Provider.OpenSubtitles, :username},
      shape: :secret,
      group: :subtitles,
      label: "OpenSubtitles username"
    ),
    field("opensubtitles_password", {Cinder.Subtitles.Provider.OpenSubtitles, :password},
      shape: :secret,
      group: :subtitles,
      label: "OpenSubtitles password"
    ),
    field("subtitle_languages", {Cinder.Subtitles.Provider.OpenSubtitles, :languages},
      group: :subtitles,
      label: "Subtitle languages (comma-separated, e.g. en,fr)",
      placeholder: "en,fr"
    ),
    field("libretranslate_url", {Cinder.Subtitles.Translator.LibreTranslate, :base_url},
      group: :subtitles,
      label: "LibreTranslate URL",
      placeholder: "http://localhost:5000"
    ),
    field("libretranslate_api_key", {Cinder.Subtitles.Translator.LibreTranslate, :api_key},
      shape: :secret,
      group: :subtitles,
      label: "LibreTranslate API key"
    ),
    field("libretranslate_batch_size", {Cinder.Subtitles.Translator.LibreTranslate, :batch_size},
      shape: :positive_integer,
      group: :subtitles,
      label: "LibreTranslate batch size (cues)",
      placeholder: "50",
      inputmode: "numeric"
    ),
    field(
      "libretranslate_timeout",
      {Cinder.Subtitles.Translator.LibreTranslate, :receive_timeout},
      shape: :positive_integer,
      group: :subtitles,
      label: "LibreTranslate timeout (milliseconds)",
      placeholder: "60000",
      inputmode: "numeric"
    )
  ]

  @services [
    field("audiobookshelf_url", {Cinder.Library.AudiobookServer.Audiobookshelf, :url},
      group: :audiobook_server,
      label: "Audiobookshelf URL",
      placeholder: "http://localhost:13378"
    ),
    field("audiobookshelf_api_key", {Cinder.Library.AudiobookServer.Audiobookshelf, :api_key},
      shape: :secret,
      group: :audiobook_server,
      label: "Audiobookshelf API key"
    ),
    field(
      "audiobookshelf_library_id",
      {Cinder.Library.AudiobookServer.Audiobookshelf, :library_id},
      group: :audiobook_server,
      label: "Audiobookshelf library id"
    )
  ]

  @books [
    field("openlibrary_url", {Cinder.Books.Metadata.OpenLibrary, :base_url},
      group: :books,
      label: "Open Library URL",
      placeholder: "https://openlibrary.org"
    ),
    field("hardcover_url", {Cinder.Books.Metadata.Hardcover, :base_url},
      group: :books,
      label: "Hardcover metadata proxy URL",
      placeholder: "https://api.bookinfo.pro"
    ),
    field("hardcover_api_key", {Cinder.Books.Metadata.Hardcover, :api_key},
      shape: :secret,
      group: :books,
      label: "Hardcover metadata proxy API key"
    )
  ]

  # The generic JSON webhook (ntfy/Gotify/Apprise/n8n/...) URL is not secret; its optional header
  # value carries the endpoint's token, so it is. smtp_ssl is read by the mailer writer, together
  # with smtp_host and smtp_password.
  @notifications [
    new("smtp_ssl", :boolean,
      group: :notifications,
      label: "SMTP: use implicit TLS/SSL (usually port 465; leave off for STARTTLS on 587)",
      target: {:writer, :mailer},
      slot: :ssl,
      save: :always
    ),
    field("discord_webhook_url", {Cinder.Notifier.Discord, :webhook_url},
      shape: :secret,
      group: :notifications,
      label: "Discord webhook URL",
      placeholder: "https://discord.com/api/webhooks/..."
    ),
    field("webhook_url", {Cinder.Notifier.Webhook, :url},
      group: :notifications,
      label: "Webhook URL",
      placeholder: "https://ntfy.example.com/cinder"
    ),
    field("webhook_auth_header", {Cinder.Notifier.Webhook, :auth_header},
      shape: :secret,
      group: :notifications,
      label: "Webhook Authorization header"
    ),
    field("smtp_host", {Cinder.Mailer, :relay},
      group: :notifications,
      label: "SMTP host",
      placeholder: "smtp.example.com"
    ),
    field("smtp_port", {Cinder.Mailer, :port},
      group: :notifications,
      label: "SMTP port",
      placeholder: "587"
    ),
    field("smtp_username", {Cinder.Mailer, :username},
      group: :notifications,
      label: "SMTP username"
    ),
    field("smtp_password", {Cinder.Mailer, :password},
      shape: :secret,
      group: :notifications,
      label: "SMTP password"
    ),
    field("smtp_from", {Cinder.Mailer, :from},
      group: :notifications,
      label: "SMTP from address",
      placeholder: "cinder@example.com"
    )
  ]

  # The quota never rejects a value: 0 or an unusable one means unlimited, as its help text says.
  @accounts [
    field("oidc_issuer_url", {Cinder.Accounts.OIDC, :issuer_url},
      group: :accounts,
      label: "OpenID Connect issuer URL",
      placeholder: "https://login.example.com/application/o/cinder"
    ),
    field("oidc_client_id", {Cinder.Accounts.OIDC, :client_id},
      group: :accounts,
      label: "OpenID Connect client ID",
      placeholder: "cinder"
    ),
    field("oidc_client_secret", {Cinder.Accounts.OIDC, :client_secret},
      shape: :secret,
      group: :accounts,
      label: "OpenID Connect client secret"
    ),
    field("household_timezone", :household_timezone,
      shape: :timezone,
      group: :accounts,
      label: "Household timezone",
      placeholder: "Europe/Paris",
      help: "IANA name used to decide when an episode's local air date has arrived",
      bootstrap: :base
    ),
    field("default_request_quota", :default_request_quota,
      shape: :lenient_integer,
      group: :accounts,
      label: "Default request quota",
      placeholder: "10",
      inputmode: "numeric",
      bootstrap: :base
    )
  ]

  @anime [
    new("anime_embedded_subtitle_mode", {:choice, ~w(allow prefer require)},
      group: :anime,
      label: "Anime: Embedded subtitles",
      message: "Choose a valid mode and at least one subtitle language when required.",
      target: {:writer, :anime_preferences},
      slot: :embedded_subtitle_mode,
      bootstrap: :base,
      check: :languages_for_require
    ),
    new("anime_preferred_groups", {:list, :groups},
      group: :anime,
      label: "Anime: Preferred groups",
      target: {:writer, :anime_preferences},
      slot: :preferred_groups,
      bootstrap: :base
    ),
    new("anime_blocked_groups", {:list, :groups},
      group: :anime,
      label: "Anime: Blocked groups",
      target: {:writer, :anime_preferences},
      slot: :blocked_groups,
      bootstrap: :base
    ),
    new("anime_group_fallback_delay", :hours,
      group: :anime,
      label: "Anime: Preferred-group fallback delay",
      target: {:writer, :anime_preferences},
      slot: :group_fallback_delay,
      bootstrap: {:base, 24 * 60 * 60}
    )
  ]

  # Edited outside the main form (their own toggles, or the first-run wizard), so a form save
  # never plans them: a missing checkbox must not switch them off.
  @standalone [
    new("auto_approve_all", :boolean,
      label: "Auto-approve all requests (skip the approval queue)",
      save: :direct
    ),
    new("upgrade_hunt_enabled", :boolean,
      label: "Look for better releases of titles already in the library",
      target: {:writer, :upgrade_hunt},
      slot: :enabled,
      save: :direct
    ),
    new("setup_complete", :boolean, save: :direct, render: :none)
  ]

  @definitions [
                 field("tmdb_token", {Cinder.Catalog.TMDB.HTTP, :token},
                   shape: :secret,
                   group: :tmdb,
                   label: "TMDB API read token (v4 bearer)"
                 ),
                 field("prowlarr_url", {Cinder.Acquisition.Indexer.Prowlarr, :base_url},
                   group: :indexer,
                   label: "Prowlarr URL",
                   placeholder: "http://localhost:9696"
                 ),
                 field("prowlarr_api_key", {Cinder.Acquisition.Indexer.Prowlarr, :api_key},
                   shape: :secret,
                   group: :indexer,
                   label: "Prowlarr API key"
                 )
               ] ++
                 @migration ++
                 @download_choices ++
                 @download ++
                 @torrent_cleanup ++
                 @legacy_toggles ++
                 @media_server ++
                 @services ++
                 @library ++
                 @releases ++
                 @subtitles ++
                 @books ++ @notifications ++ @accounts ++ @anime ++ @standalone

  @by_key Map.new(@definitions, &{&1.key, &1})

  [media_servers] = for %{shape: {:media_server, options}} <- @definitions, do: options
  @media_servers media_servers

  @library_kinds Enum.map(
                   LibraryKind.all(),
                   &%{kind: &1, label: LibraryKind.label(&1), video?: LibraryKind.video?(&1)}
                 )

  @msgids (Enum.map(@groups, &elem(&1, 1)) ++
             Enum.flat_map(@definitions, fn definition ->
               [definition.label, Cinder.Settings.Definition.message(definition), definition.help]
             end) ++
             Enum.flat_map(@download_client_choices, fn choice ->
               Enum.map(choice.options, & &1.label)
             end) ++
             Enum.map(@library_kinds, & &1.label))
          |> Enum.flat_map(fn
            nil -> []
            {template, bindings} -> [template | Keyword.values(bindings)]
            string -> [string]
          end)
          |> Enum.uniq()

  @doc "Every setting definition, in `/settings` render order, optionally filtered by field."
  @spec definitions(keyword()) :: [Cinder.Settings.Definition.t()]
  def definitions(filter \\ [])
  def definitions([]), do: @definitions

  def definitions(filter) do
    Enum.filter(@definitions, fn definition ->
      Enum.all?(filter, fn {field, value} -> Map.fetch!(definition, field) == value end)
    end)
  end

  @doc """
  The single definition `filter` names, as in `definitions/1`; raises unless exactly one matches.
  `Cinder.Settings.Overlay` calls it at compile time, in module attributes, so a renamed key still
  reaches its writers and a removed or doubled one fails the build.
  """
  @spec one!(keyword()) :: Cinder.Settings.Definition.t()
  def one!(filter) do
    case definitions(filter) do
      [definition] ->
        definition

      [] ->
        raise ArgumentError, "no setting definition matches #{inspect(filter)}"

      matches ->
        raise ArgumentError,
              "#{length(matches)} setting definitions match #{inspect(filter)}, expected one"
    end
  end

  @doc "The definition for `key`, or `nil` when the key is not a setting."
  @spec definition(String.t()) :: Cinder.Settings.Definition.t() | nil
  def definition(key), do: Map.get(@by_key, key)

  @doc "Display groups in render order, as `{group_atom, label}`."
  def groups, do: @groups

  @doc """
  Every English string the definitions, groups, client options and library kinds can hand the
  view. `CinderWeb.SettingsLabels.known/0` expands one `gettext_noop/1` per entry.
  """
  def msgids, do: @msgids

  @doc "The configured migration sources: key, display name, adapter module, and default path prefixes."
  def migration_sources, do: @migration_sources

  @doc "The exclusive client selection for each release protocol."
  def download_client_choices, do: @download_client_choices

  @doc "Every media kind with its display label and video capability, for the settings/setup UI."
  def library_kinds, do: @library_kinds

  @doc """
  The media server choices, in form order: each one's stored `value`, `server` atom, `module` and
  the `os_env` variable that makes it the bootstrap choice (or nil).
  """
  def media_servers, do: @media_servers

  @doc "The media server types the form offers."
  def media_server_options, do: Enum.map(@media_servers, & &1.value)
end
