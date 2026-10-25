# Configuration and secrets

## Env vars vs `Cinder.Settings`

Only boot-only keys are environment variables, because they are needed before the settings store
is up or are fixed per deployment: `SECRET_KEY_BASE`, `DATABASE_PATH`, `PHX_HOST`, `PHX_SERVER`,
`PORT`, `POOL_SIZE`, `RELEASE_NAME`.

Everything else (external-service URLs, API keys, the media-server choice) lives in the
`Cinder.Settings` store: DB-backed, editable in `/settings`, overlaid on env as bootstrap. A new
service config value gets a setting definition in `Cinder.Settings.Registry`, never a new
`System.get_env` call site.

A setting definition (`Cinder.Settings.Definition`) carries everything about one key: its shape,
group, label, rejection message, env target and bootstrap fallback. A plain text, secret or
positive-integer setting is one `field/3` entry plus its French msgstr after
`mix gettext.extract --merge`. That entry renders in its group, validates, saves, overlays the
env, joins `Cinder.Settings.env_keys/0` (which the test env snapshots derive from) and registers
its strings in `CinderWeb.SettingsLabels.known/0`. Edit `settings_components.ex` only when the
setting needs custom rendering (`render: :custom`; the `/settings` page test fails until its input
is named after its key), and `Cinder.Settings.Shape` only for a new shape. An overlay writer that
assembles one env value from several keys finds each definition with `Registry.one!/1`, by target
and slot, never by key. Code that reads a kind's library root calls
`Cinder.Settings.configured_library_path/2` and never builds the env key itself. Code that picks
or links a media server reads the `media_server_type` options (outside `Cinder.Settings.Shape`,
through `Cinder.Settings.Registry.media_servers/0`): each one has a `value`, a `server` atom, a
`module` and an `os_env`.

A registry-driven loader `Application.put_env`s stored values onto a one-time bootstrap snapshot
at boot (a one-shot supervised child, after PubSub and before the poller) and on every save. So
DB overrides env, a cleared setting reverts to env, and contexts read the same keys unchanged.

The env readers already exist, so a change usually edits one of them rather than adding a call
site:

- `config/runtime.exs` reads the boot-only keys.
- `lib/cinder/application.ex` loads the bootstrap snapshot and checks `RELEASE_NAME`.
- `lib/cinder/settings/overlay.ex` applies the env-as-bootstrap overlay. The `PLEX_URL`
  media-server fallback is the Plex option's `os_env` in `Cinder.Settings.Registry`, and
  `Cinder.Settings.Shape` reads it for the overlay and the form.
- `lib/cinder_web/router.ex` reads the `CINDER_BASIC_AUTH_*` pair for the Basic gate.
- `config/config.exs` reads `MIX_TAILWIND_PATH` into `config :tailwind, path:` each time Mix
  loads its config. Only the image build sets it, to its pinned Tailwind binary (#867).

## Secrets

- Secret rows are Cloak-encrypted at rest, with a key derived from `SECRET_KEY_BASE`.
- A secret never appears in a form value, a socket assign or a log line.
- Session and LiveView signing salts are derived from `secret_key_base` at runtime in
  `config/runtime.exs`, so nothing crypto-related is committed. `signing_salt` is a salt, not a
  secret; the secret is `secret_key_base`.

## Access gates

- `/settings` requires an admin account (`UserAuth` `:require_admin`, inside the `:admin`
  live_session).
- An optional HTTP Basic gate (`plug :basic_auth` in the `:browser` and `:api` pipelines,
  `router.ex`) fronts every browser route and the `/api/v1` scope as defense in depth. It is a
  no-op when `CINDER_BASIC_AUTH_USER` and `CINDER_BASIC_AUTH_PASSWORD` are both unset, and fails
  closed when exactly one is set.
- The `/api/v1` scope adds `CinderWeb.Plugs.ApiAuth` and the household API key, SHA-256-hashed in
  `Cinder.ApiKey`: a raw non-registry setting, generated and shown once in `/settings`. The same
  admin credential protects the `/api/v1` request mutations, which route through
  `Cinder.Requests` as [architecture.md](architecture.md) describes.
