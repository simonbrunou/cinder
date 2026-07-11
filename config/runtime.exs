import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/cinder start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :cinder, CinderWeb.Endpoint, server: true
end

# Real TMDB client bearer token, read in every environment. Normally unset in
# test/CI; the suite stubs Req regardless, so it has no effect there.
if token = System.get_env("TMDB_API_TOKEN") do
  config :cinder, Cinder.Catalog.TMDB.HTTP, token: token
end

# Real qBittorrent connection, read in every environment. Unset in test/CI, where
# the suite stubs Req regardless, so it has no effect there.
if base_url = System.get_env("QBITTORRENT_URL") do
  config :cinder, Cinder.Download.Client.QBittorrent,
    base_url: base_url,
    username: System.get_env("QBITTORRENT_USERNAME"),
    password: System.get_env("QBITTORRENT_PASSWORD")
end

# Real SABnzbd connection, read in every environment. Unset in test/CI, where
# the suite stubs Req regardless, so it has no effect there. NOTE: SABnzbd must
# have "Pause on Duplicates" disabled — that mode re-keys the nzo_id after an
# addurl, so the stored download_id would never reappear in the queue/history.
if url = System.get_env("SABNZBD_URL") do
  config :cinder, Cinder.Download.Client.Sabnzbd,
    base_url: url,
    api_key: System.get_env("SABNZBD_API_KEY")
end

# Real Prowlarr indexer connection, read in every environment. Unset in
# test/CI, where the suite stubs Req regardless, so it has no effect there.
if base_url = System.get_env("PROWLARR_URL") do
  config :cinder, Cinder.Acquisition.Indexer.Prowlarr,
    base_url: base_url,
    api_key: System.get_env("PROWLARR_API_KEY")
end

# Real OpenSubtitles connection, read in every environment. Unset in test/CI, where the
# suite stubs Req regardless, so it has no effect there.
if api_key = System.get_env("OPENSUBTITLES_API_KEY") do
  config :cinder, Cinder.Subtitles.Provider.OpenSubtitles,
    api_key: api_key,
    username: System.get_env("OPENSUBTITLES_USERNAME"),
    password: System.get_env("OPENSUBTITLES_PASSWORD"),
    languages: System.get_env("SUBTITLE_LANGUAGES")
end

if url = System.get_env("LIBRETRANSLATE_URL") do
  # Optional tuning knobs (nil → module defaults: 50 cues/batch, 60_000 ms).
  # CPU LibreTranslate throughput varies per box, so batch size is worth tuning
  # empirically without a code change.
  parse_pos_int = fn name ->
    with value when is_binary(value) <- System.get_env(name),
         {n, ""} when n > 0 <- Integer.parse(value) do
      n
    else
      _ -> nil
    end
  end

  config :cinder, Cinder.Subtitles.Translator.LibreTranslate,
    base_url: url,
    api_key: System.get_env("LIBRETRANSLATE_API_KEY"),
    batch_size: parse_pos_int.("LIBRETRANSLATE_BATCH_SIZE"),
    receive_timeout: parse_pos_int.("LIBRETRANSLATE_TIMEOUT")
end

# Real Jellyfin connection, read in every environment. Unset in test/CI, where
# the suite either mocks media_server or stubs Req, so it has no effect there.
if url = System.get_env("JELLYFIN_URL") do
  config :cinder, Cinder.Library.MediaServer.Jellyfin,
    url: url,
    api_key: System.get_env("JELLYFIN_API_KEY")
end

# Real Plex connection, read in every environment. Unset in test/CI, where the suite stubs Req
# regardless. Plex has no refresh-all endpoint, so each library kind carries its OWN numeric
# section id: MOVIES_PLEX_SECTION, TV_PLEX_SECTION, … → Plex `:movies_section`/`:tv_section`, so
# a TV import refreshes the Shows library, not the Movies one. The media-server impl is no longer
# flipped here (M1): Cinder.Settings picks Jellyfin/Plex, defaulting to Plex when PLEX_URL is set.
# These creds remain the env bootstrap. Per-kind keys derive from Cinder.Library.kinds/0.
if url = System.get_env("PLEX_URL") do
  sections =
    for kind <- Cinder.Library.kinds(),
        section = System.get_env("#{String.upcase(to_string(kind))}_PLEX_SECTION"),
        is_binary(section),
        do: {:"#{kind}_section", section}

  config :cinder,
         Cinder.Library.MediaServer.Plex,
         [url: url, token: System.get_env("PLEX_TOKEN")] ++ sections
end

# Where Cinder hardlinks each library kind (the media server's Movies / Shows / … roots), one per
# Cinder.Library.kinds/0: MOVIES_LIBRARY_PATH, TV_LIBRARY_PATH, … → `:movies_library_path` etc.
# Separate roots so Jellyfin/Plex can point distinct libraries at each. Bootstrap default only —
# the in-app /settings value overrides it.
for kind <- Cinder.Library.kinds() do
  if path = System.get_env("#{String.upcase(to_string(kind))}_LIBRARY_PATH") do
    config :cinder, :"#{kind}_library_path", path
  end
end

config :cinder, CinderWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# secret_key_base signs cookies and, via the derived salts below, LiveView/session
# payloads. Prod requires it from the env; dev/test fall back to the throwaway value
# in config/{dev,test}.exs. Both signing salts are derived from it (domain-separated
# so they differ) — so nothing crypto-related is committed and each install gets
# unique, restart-stable salts with no extra env var. signing_salt is a salt, not a
# secret: the secret is secret_key_base.
# Prod MUST get it from the env (never a committed value): the compile-config
# fallback is gated to non-prod so a stray secret_key_base in prod.exs can't
# silently disable the raise and make every install's cookies forgeable.
secret_key_base =
  System.get_env("SECRET_KEY_BASE") ||
    (config_env() != :prod &&
       Application.get_env(:cinder, CinderWeb.Endpoint)[:secret_key_base]) ||
    raise """
    environment variable SECRET_KEY_BASE is missing.
    You can generate one by calling: mix phx.gen.secret
    """

derive_salt = fn label ->
  :crypto.hash(:sha256, secret_key_base <> label)
  |> Base.url_encode64()
  |> binary_part(0, 16)
end

config :cinder, CinderWeb.Endpoint,
  secret_key_base: secret_key_base,
  live_view: [signing_salt: derive_salt.("live_view")]

config :cinder, :session_signing_salt, derive_salt.("session")

# Cloak vault for at-rest encryption of secret settings (Cinder.Settings). Keyed off
# secret_key_base (raw 32-byte SHA-256, domain-separated from the signing salts) so no
# key is committed and each install is unique. Configured for every environment — the
# vault GenServer starts in the supervision tree and the suite encrypts/decrypts too.
config :cinder, Cinder.Vault,
  ciphers: [
    default:
      {Cloak.Ciphers.AES.GCM,
       tag: "AES.GCM.V1", key: :crypto.hash(:sha256, secret_key_base <> "cinder.vault")}
  ]

if config_env() == :prod do
  database_path =
    System.get_env("DATABASE_PATH") ||
      raise """
      environment variable DATABASE_PATH is missing.
      For example: /etc/cinder/cinder.db
      """

  # WAL + busy_timeout + foreign_keys + default_transaction_mode are pinned in config/config.exs
  # (shared by every env, so a non-prod release gets them too); only the deploy-specific bits here.
  config :cinder, Cinder.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")

  # secret_key_base + signing salts are resolved above for every environment.
  host = System.get_env("PHX_HOST") || "localhost"

  config :cinder, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :cinder, CinderWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ]

  # TLS terminates at the reverse proxy in front of Cinder (the self-host model).
  # `force_ssl` in config/prod.exs adds HSTS + the http->https redirect — it relies
  # on the proxy sending X-Forwarded-Proto and skips localhost/127.0.0.1. The mailer
  # stays on Swoosh's local adapter until a notifier transport lands (Part II / M3).
end
