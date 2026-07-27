defmodule Cinder.Settings.Registry do
  @moduledoc """
  The declarative settings registry: the field / group / toggle definitions that map each
  `/settings` key to its `:cinder` env target, plus the pure accessors over them.

  Carved out of `Cinder.Settings` as plain code motion (mirrors the `Cinder.Settings.Crypto`
  split) so the overlay engine in `Cinder.Settings` stops coupling to a wall of module
  attributes and consumes these functions instead. Every function here is pure — a read over the
  compile-time registry (or `Cinder.Library.kinds/0`) — and the same values are re-exported
  unchanged through `Cinder.Settings` via `defdelegate`, so `CinderWeb.SettingsLabels`,
  `settings_test`, and the LiveView see byte-for-byte identical shapes.
  """

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
    }
  ]

  @migration_config_fields (for source <- @migration_sources,
                                {suffix, field, label, secret, placeholder, help} <- [
                                  {"url", :base_url, "URL", false,
                                   "http://localhost:#{source.port}", nil},
                                  {"api_key", :api_key, "API key", true, "", nil},
                                  {"remote_path_prefix", :remote_path_prefix,
                                   "remote path prefix", false, source.remote, :remote},
                                  {"local_path_prefix", :local_path_prefix, "local path prefix",
                                   false, source.local, :local}
                                ] do
                              config = %{
                                key: "#{source.key}_#{suffix}",
                                module: source.module,
                                field: field,
                                secret: secret,
                                group: :migration,
                                label: "#{source.name} #{label}",
                                placeholder: placeholder
                              }

                              if help, do: Map.put(config, :help, help), else: config
                            end)

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
    },
    # The *_url fields above are how the Cinder server reaches the media server, which in the
    # documented compose deployment is a docker-internal address (see .env.example). These two
    # are what a household member's browser should open instead, so they are a separate,
    # operator-supplied value rather than something derivable from the ones above.
    %{
      key: "jellyfin_web_url",
      module: Cinder.Library.MediaServer.Jellyfin,
      field: :web_url,
      secret: false,
      group: :media_server,
      label: "Jellyfin web URL",
      placeholder: "https://jellyfin.example.com"
    },
    %{
      key: "plex_web_url",
      module: Cinder.Library.MediaServer.Plex,
      field: :web_url,
      secret: false,
      group: :media_server,
      label: "Plex web URL",
      placeholder: "https://app.plex.tv"
    },
    %{
      key: "discord_webhook_url",
      module: Cinder.Notifier.Discord,
      field: :webhook_url,
      secret: true,
      group: :notifications,
      label: "Discord webhook URL",
      placeholder: "https://discord.com/api/webhooks/..."
    },
    %{
      key: "smtp_host",
      module: Cinder.Mailer,
      field: :relay,
      secret: false,
      group: :notifications,
      label: "SMTP host",
      placeholder: "smtp.example.com"
    },
    %{
      key: "smtp_port",
      module: Cinder.Mailer,
      field: :port,
      secret: false,
      group: :notifications,
      label: "SMTP port",
      placeholder: "587"
    },
    %{
      key: "smtp_username",
      module: Cinder.Mailer,
      field: :username,
      secret: false,
      group: :notifications,
      label: "SMTP username",
      placeholder: ""
    },
    %{
      key: "smtp_password",
      module: Cinder.Mailer,
      field: :password,
      secret: true,
      group: :notifications,
      label: "SMTP password",
      placeholder: ""
    },
    %{
      key: "smtp_from",
      module: Cinder.Mailer,
      field: :from,
      secret: false,
      group: :notifications,
      label: "SMTP from address",
      placeholder: "cinder@example.com"
    },
    %{
      key: "opensubtitles_api_key",
      module: Cinder.Subtitles.Provider.OpenSubtitles,
      field: :api_key,
      secret: true,
      group: :subtitles,
      label: "OpenSubtitles API key",
      placeholder: ""
    },
    %{
      key: "opensubtitles_username",
      module: Cinder.Subtitles.Provider.OpenSubtitles,
      field: :username,
      secret: true,
      group: :subtitles,
      label: "OpenSubtitles username",
      placeholder: ""
    },
    %{
      key: "opensubtitles_password",
      module: Cinder.Subtitles.Provider.OpenSubtitles,
      field: :password,
      secret: true,
      group: :subtitles,
      label: "OpenSubtitles password",
      placeholder: ""
    },
    %{
      key: "subtitle_languages",
      module: Cinder.Subtitles.Provider.OpenSubtitles,
      field: :languages,
      secret: false,
      group: :subtitles,
      label: "Subtitle languages (comma-separated, e.g. en,fr)",
      placeholder: "en,fr"
    },
    %{
      key: "libretranslate_url",
      module: Cinder.Subtitles.Translator.LibreTranslate,
      field: :base_url,
      secret: false,
      group: :subtitles,
      label: "LibreTranslate URL",
      placeholder: "http://localhost:5000"
    },
    %{
      key: "libretranslate_api_key",
      module: Cinder.Subtitles.Translator.LibreTranslate,
      field: :api_key,
      secret: true,
      group: :subtitles,
      label: "LibreTranslate API key",
      placeholder: ""
    }
  ]

  @path_mapping_fields [
    %{
      key: "qbittorrent_remote_path_prefix",
      env_key: :qbittorrent_remote_path_prefix,
      secret: false,
      label: "qBittorrent remote path prefix",
      placeholder: "/downloads",
      help: :remote
    },
    %{
      key: "qbittorrent_local_path_prefix",
      env_key: :qbittorrent_local_path_prefix,
      secret: false,
      label: "qBittorrent local path prefix",
      placeholder: "/media/downloads",
      help: :local
    },
    %{
      key: "sabnzbd_remote_path_prefix",
      env_key: :sabnzbd_remote_path_prefix,
      secret: false,
      label: "SABnzbd remote path prefix",
      placeholder: "/downloads",
      help: :remote
    },
    %{
      key: "sabnzbd_local_path_prefix",
      env_key: :sabnzbd_local_path_prefix,
      secret: false,
      label: "SABnzbd local path prefix",
      placeholder: "/media/downloads",
      help: :local
    }
  ]

  # Download-client enable toggles → the :cinder, :download_clients %{protocol => module} map.
  @toggles [
    %{key: "qbittorrent_enabled", protocol: :torrent, label: "Enable qBittorrent (torrent)"},
    %{key: "sabnzbd_enabled", protocol: :usenet, label: "Enable SABnzbd (usenet)"}
  ]

  @default_request_quota_key "default_request_quota"

  @global_fields [
    %{
      key: @default_request_quota_key,
      secret: false,
      group: :accounts,
      label: "Default request quota",
      placeholder: "10",
      inputmode: "numeric"
    }
  ]

  @anime_fields [
    %{
      key: "anime_embedded_subtitle_mode",
      type: :select,
      options: ~w(allow prefer require)
    },
    %{key: "anime_preferred_groups", type: :csv},
    %{key: "anime_blocked_groups", type: :csv},
    %{key: "anime_group_fallback_delay", type: :hours}
  ]

  # Display labels for the library kinds. `Cinder.Library.kinds/0` stays a pure context list;
  # the UI labels live here alongside the other settings-group labels.
  @kind_labels %{movies: "Movies", tv: "TV"}

  # The band suffixes each kind owns. min/max_size have a config.exs bootstrap (the shipped
  # default bands; a stored 0 opts out to unbounded); the resolution/source lists stay DB-only
  # (unset ⇒ scorer default). The root path (`#{kind}_library_path`) is the fourth flat key and
  # DOES have an env bootstrap.
  @band_suffixes ["min_size", "max_size", "preferred_resolutions", "preferred_sources"]

  @groups [
    tmdb: "TMDB",
    indexer: "Indexer",
    migration: "Migration sources",
    download: "Download clients",
    media_server: "Media server",
    library: "Library paths",
    releases: "Release size bands",
    subtitles: "Subtitles",
    notifications: "Notifications",
    accounts: "Accounts"
  ]

  # Only static fields can be secret (the generated Plex-section fields are not), so this stays
  # a compile-time set over @base_config_fields — no need to call config_fields/0 at module load.
  @secret_keys for(
                 f <- @base_config_fields ++ @migration_config_fields,
                 f.secret,
                 into: MapSet.new(),
                 do: f.key
               )

  @doc "Display groups in render order, as `{group_atom, label}`."
  def groups, do: @groups

  @doc "All config fields: the static service creds plus the per-kind Plex section fields."
  def config_fields, do: @base_config_fields ++ @migration_config_fields ++ plex_section_fields()

  @doc "Config fields in a given group."
  def config_fields(group), do: Enum.filter(config_fields(), &(&1.group == group))

  @doc "DB-only flat path mappings, applied to top-level `:cinder` env keys."
  def path_mapping_fields, do: @path_mapping_fields

  @doc "Download fields ordered client-by-client for the settings UI."
  def download_fields do
    fields = config_fields(:download) ++ path_mapping_fields()

    for prefix <- ["qbittorrent", "sabnzbd"],
        field <- fields,
        String.starts_with?(field.key, prefix),
        do: field
  end

  @doc "Flat global settings fields."
  def global_fields, do: @global_fields

  @doc "Flat global settings fields in a given group."
  def global_fields(group), do: Enum.filter(@global_fields, &(&1.group == group))

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

  def anime_fields, do: @anime_fields

  @doc "The library kinds with display labels, for the settings/setup UI (`[%{kind:, label:}]`)."
  def library_kinds, do: Enum.map(Cinder.Library.kinds(), &%{kind: &1, label: kind_label(&1)})

  @doc "Every flat `:cinder` env key overlaid from the settings store."
  def flat_keys do
    library_keys =
      for kind <- Cinder.Library.kinds(), suffix <- ["library_path" | @band_suffixes] do
        "#{kind}_#{suffix}"
      end

    library_keys ++ Enum.map(@path_mapping_fields, & &1.key)
  end

  # Per-kind settings-key derivations for the UI (the form field `name`s).
  def library_path_key(kind), do: "#{kind}_library_path"
  def min_size_key(kind), do: "#{kind}_min_size"
  def max_size_key(kind), do: "#{kind}_max_size"
  def preferred_resolutions_key(kind), do: "#{kind}_preferred_resolutions"
  def preferred_sources_key(kind), do: "#{kind}_preferred_sources"

  @doc "Keys of registry fields the store encrypts at rest (secret rows only)."
  def secret_keys, do: @secret_keys

  @doc "The settings key backing the default request quota."
  def default_request_quota_key, do: @default_request_quota_key
end
