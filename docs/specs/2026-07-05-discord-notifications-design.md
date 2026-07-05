# Discord notifications — design (2026-07-05)

## Goal

Deliver Cinder's pipeline events to a Discord channel via a webhook, as rich embeds
(title, colored side-bar, poster thumbnail). Opt-in per install, configured in-app at
`/settings`. This is the first real transport on the `Cinder.Notifier` seam parked since M3.

Scope: **all six events** the pipeline already emits, as **rich embeds**. One new module, one
settings-registry entry, one config flip. No new dependency (`Req` is already a dep), no new env
var, no schema change.

## The existing seam (what we build on)

- `Cinder.Notifier.notify/1` dispatches a typed event to `Application.fetch_env!(:cinder, :notifier)`
  (default `Cinder.Notifier.Log`) and **swallows any raise/exit** so a transport can never break
  the pipeline.
- Six events fire today:
  - `{:request_approved, request}` — `Cinder.Requests`
  - `{:movie_available, movie}` / `{:movie_failed, movie, reason}` / `{:movie_upgrade_failed, movie, reason}` — `Cinder.Download.Poller`, `Cinder.Download`
  - `{:episodes_available, episodes}` / `{:grab_failed, grab, reason}` — `Cinder.Download.TvPoller`
- `Cinder.Settings` overlays `@base_config_fields` entries onto `Application` env; a `secret: true`
  field is Cloak-encrypted at rest and its `/settings` form field, clear-to-revert, and placeholder
  handling are all generated from the registry entry.
- `/settings` and `/setup` render every `Settings.groups()` group and its `config_fields(group)`
  generically via `CinderWeb.SettingsComponents.service_fields/1`; a "Test connection" button per
  service is wired through `services_for/1` → `decode_service/1` → `Health.check_service/1`.
- HTTP impls read `req_options` from `Application.get_env(:cinder, __MODULE__, [])` and merge it into
  `Req.new()`; `config/test.exs` sets `req_options: [plug: {Req.Test, SomeStub}, retry: false]`, and
  tests use `Req.Test.stub(SomeStub, fn conn -> ... end)`. The Discord notifier mirrors this exactly.

Poster data: `poster_path` (a TMDB path fragment like `/abc.jpg`) exists on `Movie`, `Series`, and
`Request`. The full URL is `https://image.tmdb.org/t/p/w342<poster_path>`. `:episodes_available`
already carries `episode.season.series` preloaded (the Log impl relies on it).

## New module: `Cinder.Notifier.Discord`

Implements `@behaviour Cinder.Notifier`.

- **`notify/1`**
  1. `Cinder.Notifier.Log.notify(event)` — keep today's log line verbatim (DRY, reuses the
     `episodes_summary` formatting).
  2. If `webhook_url()` is set and `embed(event)` is non-nil, POST `%{embeds: [embed]}` to the
     webhook via `Req`. Otherwise return `:ok`.
  3. Returns `:ok` always. A non-2xx response or `{:error, _}` from `Req` is **logged and
     swallowed** (returns `:ok`); the outer `Notifier.notify/1` catches raises too, so this is
     defense in depth.
- **`embed/1`** — one clause per event, returns a Discord embed map (`%{title:, description:,
  color:, thumbnail: %{url:}}`) or omits `thumbnail` when no `poster_path`:
  - `{:request_approved, request}` — green. Title "Request approved", description the request title.
    Thumbnail from `request.poster_path`.
  - `{:movie_available, movie}` — green. "🎬 Now available", `"#{title} (#{year})"`. Thumbnail from
    `movie.poster_path`.
  - `{:movie_failed, movie, reason}` — red. "Failed", `"#{title} (#{year})"` + `inspect(reason)`.
  - `{:movie_upgrade_failed, movie, reason}` — red. "Upgrade failed", title + `inspect(reason)`.
  - `{:episodes_available, episodes}` — green. "📺 Now available", series title + the `S01E02, …`
    codes (same helper shape as the Log impl, with the same bare-count fallback when the tree isn't
    loaded). Thumbnail from `episode.season.series.poster_path` when loaded.
  - `{:grab_failed, grab, reason}` — red. `"TV grab ##{grab.id} failed"` + `inspect(reason)`. No
    thumbnail (the grab tree isn't reliably preloaded here).
  - catch-all `embed(_other)` → `nil` (unknown events log via Log but don't post).
  - Colors: green `0x2ECC71`, red `0xE74C3C` as module attributes.
- **`health/0`** — for the `/settings` Test button. `nil` webhook → `{:error, :not_configured}`;
  otherwise POST a small test embed and return `:ok` on 2xx, `{:error, reason}` otherwise.
- **`webhook_url/0`** — `Application.get_env(:cinder, __MODULE__, []) |> Keyword.get(:webhook_url)`,
  blank → nil.
- **`post/2`** — builds `Req.new(url: url, json: %{embeds: [embed]})` merged with the config's
  `req_options`, POSTs, maps 2xx → `:ok`, else `{:error, reason}`; logs on error.

## Config / wiring

- `config/config.exs`: `notifier: Cinder.Notifier.Log` → `notifier: Cinder.Notifier.Discord`.
  **With no webhook configured, Discord delegates to Log and posts nothing — behaviourally
  identical to today.** Discord is purely opt-in.
- `config/test.exs`: unchanged `notifier: Cinder.TestNotifier`, plus a new
  `config :cinder, Cinder.Notifier.Discord, webhook_url: "https://discord.test/hook",
  req_options: [plug: {Req.Test, Cinder.DiscordStub}, retry: false]` so the Discord module's own
  unit test can exercise the real POST path against a stub.
- **No `DISCORD_WEBHOOK_URL` env var** — per the "add a `Cinder.Settings` registry entry, not a
  service env var" convention. The webhook is in-app only.

## Settings store

- Add one entry to `Cinder.Settings.@base_config_fields`:
  `%{key: "discord_webhook_url", module: Cinder.Notifier.Discord, field: :webhook_url,
  secret: true, group: :notifications, label: "Discord webhook URL",
  placeholder: "https://discord.com/api/webhooks/…"}`.
- Add `notifications: "Notifications"` to `Cinder.Settings.@groups` (render order: after
  `media_server`, before/after `library`/`releases` — placed last is fine).
- Because the entry is `secret: true`, it is picked up by the compile-time `@secret_keys` set and
  encrypted automatically. The `apply_config_fields/1` overlay writes `webhook_url` onto
  `Application.get_env(:cinder, Cinder.Notifier.Discord)`. No other `Settings` change.

## Settings UI (Test connection)

In `CinderWeb.SettingsComponents`:
- `services_for(:notifications) → [{"discord", "Discord"}]`
- `decode_service("discord") → :discord`

In `Cinder.Health`:
- `check_service(:discord), do: run(Cinder.Notifier.Discord)` — `run/1` already calls `mod.health()`
  inside `safely/1`, so an undecryptable/blank webhook surfaces as a red badge, never a crash.

The generic group rendering means the `:notifications` group and its field/button appear with no
LiveView template change. The wizard (`/setup`) passes the same `service_fields` component but
Discord is **not** a required setup gate — an operator can finish setup without it. (Discord's
group simply renders in the wizard too; that is acceptable and needs no extra code. If we want to
hide it from the wizard we would add a flag — deferred unless it looks wrong in review.)

## Tests

- `test/cinder/notifier/discord_test.exs` (async where possible; no DB needed for embed shape):
  - Each event type → `Req.Test.stub(Cinder.DiscordStub, …)` asserts the posted JSON has the
    expected `embeds` title, `color`, and `thumbnail.url` (or absence).
  - No `poster_path` → no `thumbnail` key.
  - Webhook unset (override app env to `[]` for the test) → `notify/1` returns `:ok` and the stub is
    never hit (assert no POST; the Log delegation isn't asserted — `Logger.info` is below the test
    log level, per the M3 notifier note).
  - Stubbed non-2xx and a simulated transport error → `notify/1` returns `:ok`, no raise.
  - `health/0`: unset → `{:error, :not_configured}`; 2xx stub → `:ok`.
- Settings/Health: a small test that `Health.check_service(:discord)` resolves and returns a result
  (reuses the stub), and that `decode_service("discord") == :discord`.

## Deliberate simplification (ponytail)

Single transport that also logs — **not** a generic multi-transport fan-out registry (roadmap-
parked). Discord is hard-wired as the default impl and delegates to `Cinder.Notifier.Log`; the
upgrade path, if email/Slack/etc. are ever wanted, is a real fan-out dispatcher behind the same
`notify/1` seam. `// ponytail:` comment marks this in the module.

## Non-goals

- No message templating/customisation UI (fixed embed copy).
- No per-user or per-event routing / muting.
- No retry queue for a failed Discord post (best-effort; the event still shows in-app + logs).
- No new env var, no wizard gate, no schema change.
