# Configuration and secrets

## Env vars vs `Cinder.Settings`

Only boot-only keys are environment variables, because they are needed before the settings store
is up or are fixed per deployment: `SECRET_KEY_BASE`, `DATABASE_PATH`, `PHX_HOST`, `PHX_SERVER`,
`PORT`, `POOL_SIZE`, `RELEASE_NAME`.

`PHX_HOST` also binds passkeys: `CinderWeb.Passkey.relying_party/1` takes the RP ID and origin
from the endpoint URL, `https://<PHX_HOST>` in production, so an install served under another host
name sets `PHX_HOST` to that name, or adding and using passkeys fail there.

Everything else (external-service URLs, API keys, the media-server choice) lives in the
`Cinder.Settings` store: DB-backed, editable in `/settings`, overlaid on env as bootstrap. A new
service config value gets a setting definition in `Cinder.Settings.Registry`, never a new
`System.get_env` call site.

A setting definition (`Cinder.Settings.Definition`) carries everything about one key: its shape,
group, label, rejection message, env target and bootstrap fallback. A plain text, secret or
positive-integer setting is one `field/3` entry, its French msgstr after
`mix gettext.extract --merge`, and its key in each literal list of
`test/cinder/settings/definition_test.exs` that it belongs to: every key (`@keys`), the keys
`save_form/1` can reject (`@validated`) and the secret keys. Those lists are written out by hand
on purpose, as a truth independent of the registry. The `field/3` entry renders in its group,
validates, saves, overlays the env, joins `Cinder.Settings.env_keys/0` (which the test env
snapshots derive from) and registers its strings in `CinderWeb.DomainLabels.known/0`. Edit
`settings_components.ex` only when the setting needs custom rendering (`render: :custom`; the
`/settings` page test fails until its input is named after its key), and `Cinder.Settings.Shape`
only for a new shape. A new shape that can reject a value also joins `Shape.validates?/1`:
`Shape`'s own `@validated` list for an atom shape, the tag list of its first clause for a tagged
tuple. `save_form/1` checks only a definition that `Definition.validated?/1` passes: one saved
with the form (`save: :form` or `:always`) whose shape `validates?/1` accepts or that names a
`check`. An overlay writer that assembles one env value from several keys finds each definition
with `Registry.one!/1`, by target
and slot, never by key. Code that reads a kind's library root calls
`Cinder.Settings.configured_library_path/2` and never builds the env key itself. Code that reads
a video kind's release rule (a size band, a preferred list, the upgrade cutoff) takes its env key
from `Cinder.Settings.Registry.release_env_key!/2` in a module attribute, so a renamed slot fails
the build. Code that picks
a media server reads the `media_server_type` options (outside `Cinder.Settings.Shape`, through
`Cinder.Settings.Registry.media_servers/0`): each one has a `value`, a `server` atom, a `name`,
a `module` and an `os_env`. A page shows the product name through
`Cinder.Settings.media_server_name/1`, never a literal of its own. It finds the server that runs
with `Shape.running_media_server/2` (the stored type, else the option whose `os_env` is set),
never with `Shape.option/2` alone. Code that reads
data a media server wrote, such as the season inventory, asks
`Cinder.Settings.media_server_type/0`, and code that links at the server asks
`Cinder.Settings.media_server_web_link/0`. Both pick through one private step that also names the
bootstrap server when neither applies, so whenever the type names a server, the link names the
same one.

A new external service's `health/0` keeps the 3 s connect and receive timeouts the
`Cinder.Health` moduledoc names: `receive_timeout: 3_000, connect_options: [timeout: 3_000]`. The
connect `timeout` is the one to remember: without it, a request to a configured service URL
connects through Req's Finch pool, which waits up to Finch's 5 s default.

A registry-driven loader `Application.put_env`s stored values onto a one-time bootstrap snapshot
at boot (a one-shot supervised child, after PubSub and before the poller) and on every save. So
DB overrides env, a cleared setting reverts to env, and contexts read the same keys unchanged.

The env readers already exist, so a change usually edits one of them rather than adding a call
site:

- `config/runtime.exs` reads the boot-only keys.
- `lib/cinder/application.ex` loads the bootstrap snapshot and checks `RELEASE_NAME`.
- `lib/cinder/settings/overlay.ex` applies the env-as-bootstrap overlay. The `PLEX_URL`
  media-server fallback is the Plex option's `os_env` in `Cinder.Settings.Registry`, and
  `Cinder.Settings.Shape` reads it through `Shape.running_media_server/2` for the overlay, the
  form, `Cinder.Settings.media_server_web_link/0` and `Cinder.Settings.media_server_type/0`.
- `lib/cinder_web/router.ex` reads the `CINDER_BASIC_AUTH_*` pair for the Basic gate.
- `config/config.exs` reads `MIX_TAILWIND_PATH` into `config :tailwind, path:` each time Mix
  loads its config. The image build sets it to its pinned Tailwind binary (#867), and the flake
  dev shell to one in the Nix store (#889).

## Secrets

- Secret rows are Cloak-encrypted at rest, with a key derived from `SECRET_KEY_BASE`.
- A stored Vault ciphertext names the row it belongs to only for a configured indexer's secrets,
  whose scope and id `Cinder.Indexers.Secrets.open/1` checks. So with database write access, a
  secret setting's value, a configured indexer's `secrets_ciphertext` or a user's `plex_token`
  copied into a secret setting decodes there, and `Settings.undecryptable_secret_keys/0` does not
  list it. Copied into `prowlarr_api_key`, with `prowlarr_url` pointed at another host, the decoded
  text goes to that host as the Prowlarr adapter's `x-api-key` header. Cinder accepts this (#1702).
  The same write access sends the stored `prowlarr_api_key` to another host by rewriting
  `prowlarr_url` alone, so the copy adds only reach from one secret to another. For a configured
  indexer's secrets it adds nothing: the Newznab and Torznab adapters send `apikey` to the row's
  plaintext `base_url`, `Cinder.Indexers.Definitions.CredentialHosts.hosts/2` lets a Cardigann
  indexer send its credentials to that `base_url`'s host, and that write access rewrites `base_url`
  too. A scope on every stored secret would take a migration that re-seals each secret setting, Plex
  token and download intent's link (`download_url_ciphertext`), which rewrites stored data.
- A secret never appears in a form value, a socket assign or a log line.
- A passkey's credential id, public key, challenge and user handle are logged nowhere: the
  WebAuthn fields travel under a `passkey` key, which `config :phoenix, :filter_parameters`
  filters from request and LiveView event logs, and `Cinder.Accounts.Passkeys` runs its queries
  that carry them with `log: false`.
- Each new write of a ciphertext, to a new column or an existing one, runs with `log: false`,
  since Ecto's `:debug` query log prints the query's parameters. It gets a test like
  `test/cinder/indexers_log_test.exs` and
  `test/cinder/acquisition/indexer_source/native/indexer_cookies_log_test.exs`: the test lowers
  the global Logger level to `:debug`, captures the writes, checks that the capture holds a logged
  statement on the table, such as the insert or a read, and refutes the ciphertext. On #1680 the
  cookie table's two writes logged their ciphertext until the approval-gate review caught it.
- A refused Plex, Jellyfin or OIDC sign-in or link, and a refused passkey sign-in POST
  (`CinderWeb.PasskeyAuthController.create/2`), log through
  `CinderWeb.SignInRefusal`, whose `render/1` prints only the closed set of shapes its moduledoc
  lists. An identity provider's
  library writes what it rejected into its message text (Assent's
  `Invalid issuer "<iss>" in ID Token`) and the whole HTTP response into an exception's
  `message/1`, so neither `HTTPPolicy.sanitize_log/1` nor a mask over that text keeps a claim's
  email out. On #1214 the first renderer passed Assent's strings through `sanitize_log/1`, and
  the mask that followed (quoted values, words holding `@`) still leaked three shapes: two review
  rounds, about 24 minutes from the first finding to a clean re-check.
- A failed mail delivery logs only `Cinder.Mailer.reason_tag/1`, the exception module or the
  reason's atom tag. Its reason can hold the SMTP password or the whole email with its
  confirm-link token, as the comment above `Cinder.Accounts.UserNotifier`'s `deliver/3` says, and
  `HTTPPolicy.sanitize_log/1` only removes line breaks and cuts the text at 500 bytes (#1544).
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
