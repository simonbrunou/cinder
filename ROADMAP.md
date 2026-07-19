# Cinder — Build Roadmap

A single-household, self-hosted replacement for the Sonarr/Radarr/Seerr loop, built on
Phoenix/LiveView. This roadmap covers the **movies-only vertical slice**: request a movie →
find the best release → download it → import it into Jellyfin. TV, quality upgrades, and
multi-user are deliberately out of scope until the slice is solid (see *Parked*, bottom).

> **Status (2026-07-19):** the original slice and Part II form the current movies+TV product;
> remaining release sign-offs stay recorded in M8. **Part III — Anime-aware media handling**
> (bottom) is the current feature program: a per-title opt-in profile that makes discovery,
> release matching, numbering, specials, and audio/subtitle preferences anime-aware without a
> third pipeline. A0–A5 are done (a same-day cleanup pass, **A4.5**, simplified the
> implementation in place), and **A6 — alternate-season numbering — shipped 2026-07-19**,
> closing the provider-numbering gap with TMDB's own episode groups rather than a second
> metadata provider. Phases 0–5 and Part II remain the build record.

## How to run this with Claude Code

- Do **one phase per session**. `/clear` between phases so context stays clean.
- Start each phase in **plan mode** to scope it, then execute.
- **Commit at every phase boundary.** A phase is not done until its "Done when" block is green.
- Each phase's "Done when" is written so it can be pasted into `/goal` if you want an
  autonomous run for that phase.
- The Elixir tooling installed in Phase 0 runs compile/format/credo/test hooks around edits —
  that's what makes any goal run self-correcting. Don't skip Phase 0.

## Conventions (enforced every phase)

- `mix compile --warnings-as-errors` clean.
- `mix format --check-formatted` passes.
- `mix credo --strict` reports no issues.
- `mix test` fully green; every new behaviour gets a test.
- All external services (TMDB, Prowlarr, qBittorrent, Jellyfin) sit behind a **behaviour**
  (`@callback` specs) so they can be mocked with **Mox**. Tests never hit the network or a
  real service.
- HTTP via `Req`. DB via Ecto + `ecto_sqlite3`. **SQLite is now a permanent choice** (locked in
  Part II / M0): single-container, zero-dependency install. The ceiling — single instance, low
  concurrency, no hosted multi-tenant — is accepted, and M0 pins WAL + `busy_timeout` to make
  concurrent writers correct rather than flaky.
- License: GPL-3.0 (see `LICENSE`).

---

## Phase 0 — Scaffold, tooling & guardrails

Do these in order. Steps 2–4 set up the Elixir Claude Code tooling, and they change how every
later phase runs, so finish Phase 0 before touching Phase 1.

**1. Scaffold.**
- `mix phx.new cinder --database sqlite3` (or Postgres; adjust later phases).
- `cd cinder`, init git, first commit.
- Add dev deps: `credo`, `mox`. Add a `test` alias in `mix.exs` that runs
  `compile --warnings-as-errors`, `format --check-formatted`, `credo --strict`, `test`.
  This alias is the source of truth every "Done when" block checks against.
- `LICENSE` (GPL-3.0).

**2. Install the `claude` hex library (one-shot tooling base).**
```
mix igniter.install claude
```
This generates `.claude.exs`, writes `.claude/settings.json` hooks, generates subagents and
slash commands, syncs dependency usage rules into `CLAUDE.md`, and creates `.mcp.json`. (Note:
the library is confusingly just named `claude`.)

**3. Configure `.claude.exs`.** Replace the generated file with this — fast checks on every
edit, the heavier credo+test pass when Claude finishes a turn (non-blocking, so it surfaces
failures for self-correction without infinite-loop risk), and Tidewave registered as an MCP:
```elixir
%{
  hooks: %{
    # fast, every file edit
    post_tool_use: [:compile, :format],
    # turn end: heavier checks, informational so Claude self-corrects
    stop: [
      :compile,
      :format,
      {"credo --strict", blocking?: false},
      {"test", blocking?: false}
    ],
    subagent_stop: [:compile, :format],
    # only fires on git commit commands
    pre_tool_use: [:compile, :format, :unused_deps]
  },
  mcp_servers: [:tidewave],
  subagents: []
}
```
Then `mix claude.install` to apply. (Atoms expand to mix tasks: `:compile` →
`mix compile --warnings-as-errors`, `:format` → `mix format --check-formatted`; a string like
`"test"` runs `mix test`.)

**4. Wire Tidewave (runtime intelligence MCP).**
- Add the dep: `{:tidewave, "~> 0.6", only: :dev}`, then `mix deps.get`.
- In `lib/cinder_web/endpoint.ex`, immediately **above** the `if code_reloading? do` block:
  ```elixir
  if Mix.env() == :dev do
    plug Tidewave
  end
  ```
- With `:tidewave` already in `mcp_servers`, `mix claude.install` writes it into `.mcp.json`.
  (Manual equivalent if needed: `claude mcp add --transport http tidewave
  http://localhost:4000/tidewave/mcp`.)
- Start the app, then `/mcp` in Claude Code should show tidewave "connected." Now Claude can
  `project_eval`, `execute_sql_query`, `get_ecto_schemas`, `get_logs`, and `get_docs` against
  the running app — use this throughout later phases instead of guessing.

**5. App-specific setup.**
- `CLAUDE.md`: usage rules are auto-synced between markers; add your project conventions
  *outside* the markers so syncs don't clobber them.
- Define the four client behaviours (`Cinder.Catalog.TMDB`, `Cinder.Acquisition.Indexer`,
  `Cinder.Download.Client`, `Cinder.Library.MediaServer`) as empty `@callback` contracts; wire
  Mox in `test/test_helper.exs`. Config selects the real impl in prod, the mock in test.
- Confirm Phoenix 1.8's bundled Tailwind + daisyUI renders.

**Optional:** add a plugin layer — `georgeguimaraes/claude-code-elixir` (modular: Expert LSP +
mix-format/compile/credo hooks) or the heavier `oliver-kriska/claude-elixir-phoenix` (agents +
`/phx:*` commands). Don't stack the heavy one on top of these hooks blindly; they overlap.

**Done when:** the project boots (`mix phx.server`), `mix test` (the alias) passes on an empty
suite, `/mcp` shows tidewave connected, and the four behaviours + their Mox mocks compile.

---

## Phase 1 — Catalog (discovery + watchlist)

**Context:** `Cinder.Catalog`

**Build:**
- `Cinder.Catalog.TMDB` behaviour + real impl (search, fetch details) + Mox mock.
- Ecto schema for a watchlisted movie (tmdb_id, title, year, poster, status enum:
  `:requested`).
- A LiveView: search box → results from TMDB → "Add" button → persists to watchlist →
  watchlist renders below. daisyUI components, real-time updates via LiveView assigns.

**Done when:** conventions pass + a test proves "search a title (mocked TMDB) and add it
persists a `:requested` movie," and the LiveView renders the watchlist.

---

## Phase 2 — Acquisition (find the best release)

**Context:** `Cinder.Acquisition`

**Build:**
- `Cinder.Acquisition.Indexer` behaviour (Torznab query against Prowlarr) + real impl + mock.
- A release parser module: extract resolution, codec, release group, size, language from a
  release name. (No mature Elixir lib exists — write a focused parser with a test fixture set.)
- A scorer with **explicit, configurable rules**: prefer 1080p, reject releases outside a
  size band, honour a blocklist. Returns the chosen release or `:no_match`.

**Done when:** conventions pass + tests select the expected release from fixture lists for:
the happy case, the all-too-large case (→ `:no_match`), and a blocklisted-group case. No
network in tests.

---

## Phase 3 — Download (hand off + track)

**Context:** `Cinder.Download`

**Build:**
- `Cinder.Download.Client` behaviour (qBittorrent: add release, report status) + impl + mock.
- A `GenServer` poller under the app supervisor that polls active downloads and advances
  state: `:requested → :searching → :downloading → :downloaded`.
- Broadcast state changes over Phoenix.PubSub so the LiveView updates live.

**Done when:** conventions pass + a test drives a movie through the full state machine with a
mocked client, **and** a test asserts the poller restarts cleanly after a simulated crash
(this is the OTP payoff — prove it).

---

## Phase 4 — Library (import into Jellyfin)

**Context:** `Cinder.Library`

**Build:**
- `Cinder.Library.MediaServer` behaviour (trigger scan) + Jellyfin impl + mock.
- On `:downloaded`: hardlink the file into the library, rename to Jellyfin's
  `Title (Year)/Title (Year).ext` scheme, trigger a scan, set status `:available`.
- Filesystem ops behind a thin behaviour too, so the import is testable without touching disk.

**Done when:** conventions pass + a test proves a completed download produces the correct
hardlink + rename + scan call against mocked FS and Jellyfin, and the movie ends `:available`.

---

## Phase 5 — Wire the loop + live smoke test

**Build:**
- End-to-end wiring: a `:requested` movie flows automatically through acquisition → download
  → import with no manual steps.
- A status dashboard LiveView: every movie with its live state, real-time via PubSub.
- Replace mock configs with real Prowlarr / qBittorrent / Jellyfin in dev config.

**Done when:** conventions pass **and** a manual live smoke test succeeds: request one real
movie and watch it land in Jellyfin. (Mocked tests prove wiring and logic; only a live run
proves your actual indexer returns what you expect.)

### Phase 5 — remaining to sign off

The core loop is validated live (2026-06-20): a real movie went `:requested → :available`,
imported as a true hardlink, scanned into Plex. See the live-validation report for the running
config and ops gotchas. Still open:

- **[done] Media-server scan is best-effort** — a failed scan no longer strands a correctly
  hardlinked movie at `:import_failed`; the import reaches `:available` and the server picks the
  file up on its next periodic scan. (`Cinder.Library.import_movie/1`.)
- **[done] `/status` retry action** — a parked `:search_failed`/`:no_match`/`:import_failed`
  movie shows a "Retry" button that resets it to `:requested` with attempt counters zeroed; the
  poller re-queues it next tick. The transition is guarded server-side
  (`Cinder.Catalog.retry_movie/1`) so an in-flight movie can't be yanked back. Replaces the
  documented IEx reset.
- **[done] `/status` config-health** — a "Service health" panel on `/status` pings each
  configured external service (indexer, every download protocol's client, media server) via a new
  `health/0` behaviour callback and shows it reachable/unreachable. Checks run async on load (a
  down service can't block the page) with a manual "Recheck" button. `Cinder.Health.check_all/0`
  resolves the impls; reachability-first — Prowlarr/qBittorrent/Jellyfin endpoints are
  authenticated (so they also catch bad creds), SABnzbd/Plex are reachability-only. The
  live/visual confirmation is the separate "visual check" item below.
- **Torrent path — live sign-off (needs homelab):** the live run went via Usenet/SABnzbd. Exercise
  a qBittorrent grab end-to-end — base32 magnet, `.torrent` URL fetch, `Cinder.Download.Torrent.infohash/1`
  status polling — and confirm a malformed/HTML "torrent" parks gracefully rather than looping.
- **`/status` visual check (needs homelab):** open the dashboard against the running instance and
  confirm badges advance live.
- **[done] Deploy auto-migration:** releases migrate at boot — `Cinder.Application` supervises
  `{Ecto.Migrator, skip: skip_migrations?()}`, and `skip_migrations?` is false whenever
  `RELEASE_NAME` is set, so every release start migrates before serving. `bin/cinder eval
  "Cinder.Release.migrate()"` remains only a manual fallback (e.g. migrating without a restart).

---

# Part II — From slice to v1.0 (the public product)

The slice above is built and validated live. Part II turns it into a **public, open-source,
self-hostable product** that strangers install and operate, replacing all three:

- **Radarr** (movies — already done) + **Sonarr** (TV: series/season/episode, monitoring,
  season packs, multi-file imports, a calendar) + **Seerr** (true multi-user: real accounts,
  roles, non-admins request → an admin approves/denies → it grabs, attributed per user).

**Decided scope (settled 2026-06-21):**

- **Public self-host.** Installable and operable by people who didn't write it.
- **Multi-user with approval.** Real local accounts, `admin`/`user` roles, a request→approval
  gate. (Not just a nicer single-admin UI.)
- **Movies + TV** both in v1.0.
- **SQLite stays** (see Conventions). Single-container, zero-dependency.
- **Private until v1.0 — one public launch, no public beta.** You *dogfood privately* at the
  movies-complete (M3) and movies+TV (M6) checkpoints to shake out your own bugs first.

**Same working discipline as Part I:** one milestone per session, `/clear` between, start in
plan mode, **commit at every boundary**, the Conventions block above is enforced every
milestone, and each "Done when" is written to hand to `/goal`. Split the **L/XL** milestones
into sub-sessions — they are too big for one clean context.

## Milestones

The spine runs **foundation → movies UX complete → TV → release**. Sizes: S/M/L/XL.

### M0 — Architecture hardening + secrets seam (S)

**Goal:** lock the cross-cutting decisions and pin cheap insurance *before* a second writer or
any feature lands. No user-visible change — everything downstream depends on it.

**Build:**
- Pin SQLite `journal_mode = WAL` + `busy_timeout` (5000 ms) in Repo config across
  dev/runtime/test (only `pool_size` is set today).
- Move the hardcoded `signing_salt` (`endpoint.ex`), the LiveView `signing_salt`
  (`config.exs`), and `secret_key_base` to runtime/generated secrets.
- Clean scaffold noise: stock README, `PHX_HOST` `example.com` default, commented Mailgun/SSL
  blocks in `runtime.exs`, stock `.dockerignore` comments.
- Document & lock the env-vs-DB config split: **boot-only keys stay env** (`SECRET_KEY_BASE`,
  `DATABASE_PATH`, `PHX_*`, `POOL_SIZE`, `RELEASE_NAME`, `DNS_CLUSTER_QUERY`); everything else
  moves to the M1 settings store.
- Concurrency note in `CLAUDE.md`: every writer goes through `Catalog.transition`.

**Done when:** conventions pass + a test drives two concurrent writes (poller + a web write)
through the serialized path with no `database busy` error, and a grep shows no secret salt left
hardcoded.

### M1 — Settings store + in-app config (L)

**Goal:** kill the hand-write-the-env-vars install story; make external-service config editable
in-app, overlaid on env-as-bootstrap, with **zero context-code changes** (leverage the existing
`Application.get_env` seam the contexts already read).

**Build:**
- `Cinder.Settings` context + `settings` table (`key`, `value`, `is_secret`). On boot (after
  Repo, before the poller) and on every save, `Application.put_env` the same `:cinder` module
  keys the contexts already read — so no context changes.
- Encrypt `is_secret` fields at rest (Cloak.Ecto AES-GCM keyed off `SECRET_KEY_BASE`) —
  decision-gated; if deferred, redact-on-display only.
- Settings LiveView: grouped form (TMDB / Indexer / Download clients / Media server / Library)
  with per-field **Test connection** reusing `Cinder.Health` (single-service variant).
- Media-server type becomes a Jellyfin/Plex dropdown that writes the `media_server` impl key
  (replacing the `runtime.exs` `PLEX_URL` flip); torrent/usenet client toggles.
- Documented precedence (DB overrides env), surfaced in the UI.

**Done when:** conventions pass + the full movie loop runs end-to-end from UI-entered config
with **no service env vars set**, and a test proves DB settings override env and are applied on
boot and on save.

**[done 2026-06-21]** Shipped: `Cinder.Settings` (registry-driven) overlays the existing
`Application.get_env` seam at boot (a one-shot supervised loader, `start_link → :ignore`, after
PubSub/before the poller) and on save — zero context changes. The overlay merges DB onto a
one-time `:persistent_term` bootstrap snapshot, so DB overrides env and a cleared setting reverts.
Secrets encrypted at rest via **Cloak**, **secret rows only** (non-secrets stay
plaintext/inspectable), key derived from `SECRET_KEY_BASE`; an undecryptable secret is skipped
(logged), never bricks boot. Settings LiveView at `/settings` (admin-gated by `:admin_auth` until
M2) with secret redaction (never echoed, blank-keeps, explicit Clear) and per-service Test
connection via `Health.check_service/1` on **saved** config (+ a new TMDB `health/0`). The
`PLEX_URL` impl-flip is gone; media-server impl is a setting (Plex-if-`PLEX_URL` bootstrap
default). Decisions: encrypt secrets-only; the `/settings` auth-gap to M2 is accepted + documented
(run behind the Basic-auth/reverse-proxy edge); Test-connection probes saved config, not entered
values (clean impl; mitigated by encryption + Clear). The live "no-env-vars" loop run is the
manual dogfood step (M3).

### M2 — Accounts, roles, request/approval model (L)

**Goal:** replace the shared Basic password with real local accounts + an `admin`/`user` split +
a **separate requests table that gates pipeline entry**. This is the security spine of the whole
Seerr layer, and the second concurrent writer M0 de-risked.

**Build:**
- `phx.gen.auth`: Accounts context, `User` + `UserToken`, `UserAuth` on_mount/plug,
  login/register/settings/reset LiveViews + migrations (bcrypt). **Review the generated code**
  to pass the strict `mix test` alias — don't blind-commit the generator output.
- `role` enum `[:admin, :user]`; first registered user becomes admin; `require_admin`
  on_mount + plug; split routes (discovery open to users; `/status`, settings, the approval
  queue admin-only; gate the `/dev` routes).
- `Cinder.Requests` context + `requests` table (`user_id`, `movie_id`, `status`
  `:pending`/`:approved`/`:denied`, `denial_reason`, `approved_by_id`) — built
  polymorphic-ready so TV can reuse it.
- **Pipeline-entry rewire:** a non-admin "Add" creates a **pending request** — it does NOT
  write a `:requested` movie. Admin approval find-or-creates the movie at `:requested`; an
  admin's own request auto-approves. The poller pickup line is unchanged.

**Done when:** conventions pass + a **security test** asserts a non-admin request never reaches
the poller until an admin approves (no movie row at `:requested` before approval), and role/route
gating is covered. — *Release checkpoint: internal-alpha (private).*

### M3 — Onboarding wizard + requester UX  →  movies feature-complete (M)

**Goal:** make the multi-user *movies* product installable-and-operable by a stranger:
first-run wizard, a My-requests view, per-title request state, optional quotas, and a minimal
notifier so approvals aren't silent.

**Build:**
- **First-run wizard:** a no-admin / no-settings boot routes to setup → create admin →
  enter+validate TMDB/indexer/download/media-server via `Health` → mark `setup_complete` →
  redirect to `/`.
- Requester **My requests** view + a per-title state badge on the discovery grid
  (Requested / Pending / Approved / Available / Denied), scoped to the current user.
- Optional per-user `request_quota` (nullable int; `nil` = unlimited) enforced in
  `Requests.create_request`.
- `Cinder.Notifier` behaviour (`notify/1` over typed events) with a Log/PubSub default impl;
  call sites for request-approved / available / failed.
- Admin approval queue shows requester + poster/title, live via the requests PubSub topic.

**Done when:** conventions pass + a test drives a non-admin request → admin approval → movie
reaches `:available` attributed to the requester, with a notifier event emitted, and quota
enforcement is tested. — ***Dogfood checkpoint:*** run it privately as your household movie
instance.

**[done 2026-06-22]** Shipped (design: `docs/specs/2026-06-22-m3-design.md`, plan:
`docs/plans/2026-06-22-m3-onboarding-requester-ux.md`). **Wizard:** `SetupLive` at `/setup`
(admin-gated) reuses the settings field markup (extracted to `CinderWeb.SettingsComponents`,
shared with `/settings`), validates every service via `Health`, and only enables Finish once the
loop is green — TMDB + indexer + media server + writable library + ≥1 download client — then sets
the `setup_complete` KV flag. Admin creation reuses the existing registration flow. First-run
routing is a `:require_setup` on_mount (gated by `config :cinder, :enforce_setup`, on in prod, off
in test) wired into the `:authenticated`/`:admin` sessions: incomplete setup sends admins to
`/setup`, parks non-admins at log-in. **Quota:** per-user `request_quota` (nullable int on `users`,
`nil` = unlimited), concurrent-pending count enforced as the first guard in
`Requests.create_request` (admins + `auto_approve_all` bypass); settable via a minimal admin
`/users` page. **Requester UX:** `MyRequestsLive` at `/my-requests` (request status + live pipeline
state); the discovery grid shows a per-user composite badge (Pending/Approved/Available/Denied,
available outranks a stale denied) instead of a bare Add; approval queue renders the requester
poster; root nav exposes the pages. **Notifier:** `Cinder.Notifier` behaviour + `Cinder.Notifier.Log`
default (a rescuing dispatcher so a transport can't break the pipeline); events
`{:request_approved, _}` (in `Requests`), `{:movie_available, _}` and `{:movie_failed, _, reason}`
(in the poller, the latter via a single `park/3` choke-point). **`library_path`** moved into the
Settings store (overlays `:cinder, :library_path`, reverts to env bootstrap when cleared) +
`Health.check_service(:library)` (writable-dir probe). Decisions: concurrent-pending quota,
all-green wizard, library_path in settings, minimal `/users` page, Log-only default (in-app
reactivity already rides the existing topics); the test notifier re-broadcasts on a
`"notifications"` PubSub topic (`Cinder.TestNotifier`) so assertions use `assert_receive` rather
than fighting the `:warning` log level. `mix test` green (373). The live "no-env-vars" wizard run
is the M3 dogfood step.

### M4 — TV data model + discovery (L)

**Goal:** land the **Series → Season → Episode** schema and TMDB TV discovery behind monitoring
flags, **without touching the validated movie pipeline**. This is the deepest break from the
1:1 row=request=file assumption, so settle the schema forks first.

**Build:**
- **DECISION (lock first, gates M4–M6):** separate `series`/`seasons`/`episodes` tables
  (recommended — clean FKs) vs a single polymorphic `media_items` table.
- Additive migrations: `series` (tmdb_id/tvdb_id, title, year, poster, `monitored`,
  `monitor_strategy` `:all`/`:future`/`:none`), `seasons` (series_id FK, season_number,
  monitored), `episodes` (season_id FK, episode_number, air_date, title + the per-item
  pipeline fields copied from `Movie`).
- **DECISION (lock, gates fan-out + import):** season-pack representation — a grab/download
  join table (one download → N episodes) vs episode-level download_ids.
- TMDB behaviour grows `search_tv`/`get_series`/`get_season` callbacks (impl + Mox mock updated
  **atomically**, kept distinct from the movie callbacks); `Catalog.add_series_to_watchlist`
  persists the tree.
- `requests` table extended to a **polymorphic target** (movie OR series/episode);
  series/episode PubSub topics; a series-detail LiveView with a per-episode monitor toggle
  reusing the movie card/badge patterns.

**Done when:** conventions pass + a test adds a series (mocked TMDB) with a monitor strategy and
persists the season/episode tree with monitor flags, and the **movie loop is untouched** (its
tests still green).

**[M4a done 2026-06-22 — data layer]** (design: `docs/specs/2026-06-22-m4-design.md`). Split M4
into **M4a (data, shipped)** + **M4b (discovery UI, next session)**. Shipped: the
`series`/`seasons`/`episodes` schema (one additive migration; movie loop untouched, poller stays
movies-only) and `Catalog.add_series_to_watchlist/2` persisting the tree via one `cast_assoc`
insert, flagging episodes per `monitor_strategy` (`:all`/`:future`/`:none`, default `:future`,
applied uniformly — specials handling is M6). TMDB grew `search_tv`/`get_series`/`get_season`
(impl + Mox auto-cover, atomic; `date_from/1` tolerates `""`/missing `air_date`). Council-driven
scope cuts: **Episode = identity + monitoring only** (`tmdb_episode_id` kept as the M6
renumbering-reconciliation key; the download/import pipeline fields + `status` deferred to M5,
avoiding the approve-by-default trap and the redundancy with M5's locked grab/download join
table); `imdb_id` on series dropped (re-derivable in M5); the `"series"` PubSub topic deferred to
M4b (no subscriber yet); **TV add is admin-only direct** (no request gate — no TV poller exists to
auto-grab; requester flow is M5). Also fixed a latent suite-wide SQLite test flake:
`config/test.exs` `pool_size: 5 → 1` (the Sandbox's deferred read-then-write txns hit
`SQLITE_BUSY` that `busy_timeout` can't rescue; one connection serializes writers, no speed cost).
**Deferred to M4b:** TV search in the grid + a series-detail LiveView with per-episode monitor
toggles + nav. **Deferred to M5:** episode pipeline fields/transition, the grab/download join
table, the TV poller, and the requester request/approval flow.

**[M4b done 2026-06-22 — discovery UI]** Shipped: admin-only `/series` (TMDB TV search +
add) and `/series/:id` (season/episode tree). TV discovery is a **separate admin-gated page**
(not a tab on `/`) — admin-only direct add until M5's requester flow, so gating is free via the
`:admin` live_session and the movie page's *functionality* is untouched (one role-gated "TV
series →" nav link added). Catalog grew `search_tv/1`, `get_series_with_tree/1` (ordered preload),
`set_episode_monitored/2`, `set_season_monitored/2` (season-cascade in one transaction). The add
runs off-process via **`start_async`** (1 + N TMDB calls per the M4a guardrail). Monitor flags are
**not pipeline state**, so the setters write directly (not via `Catalog.transition` — that's the
movie-status choke-point) and broadcast on the new minimal **`"series"` topic**
(`{:series_updated, id}` only, subscribed only by the detail view for the two-tabs case). Decisions
(user + council): separate `/series` page; episode toggles **+ season bulk control** rendered as
"N/M monitored" + a "Monitor all/none" button (not a tri-state checkbox — `season.monitored` is a
standalone bool and HTML `indeterminate` is JS-only); the `"series"` topic kept **minimal** (dropped
`{:series_added}` + list subscription + any edit to M4a's shipped `insert_series` — no genuine
out-of-band consumer until M5's poller). Council-flagged house-style fixes folded in: catch-all
`handle_event` + non-numeric `phx-value` tolerance; `/series/:id` parses the param (no `Repo.get`
CastError); per-toggle `aria-label`s; async-add de-dupe by id. `mix test` green (407).

### M5 — TV acquisition + multi-file import (XL)

**Goal:** make monitored episodes actually download and import — the genuinely new logic. Reuse
the OTP skeleton (stateless, bounded-retry, isolated); rewrite only the work it derives.

**Build:**
- Indexer gains a **TV `@callback`** (`tvsearch` / season+episode tokens, TV categories); impl +
  Mox mock changed atomically; the movie search path kept distinct.
- Parser **additions**: `S01E02`, `1x02`, `S01`/`Season 1`/`Complete` (season pack), multi-ep
  ranges `S01E01-E03` — new regex tables + a grown fixture matrix; existing
  resolution/codec/group/language untouched.
- Scorer/Acquisition **pack-vs-episode** selection: score a pack against the set of
  still-needed episodes, may return multiple releases; a per-episode/season size band; the
  movie single-result path intact.
- A **separate TV poller pass** sharing the skeleton: derive missing monitored episodes, start
  downloads, and fan a completed pack out to N episode imports in **one `Repo.transaction`**.
- `Library.import_episode/import_pack` sibling: parse `S01E02` per file, map to its `Episode`
  row, hardlink+rename to `Show (Year)/Season 01/Show (Year) - S01E02.ext`; **gracefully park**
  files that can't be matched. `import_movie` untouched.

**Done when:** conventions pass + tests import (a) a single episode and (b) a season pack into
the correct hardlink layout against mocked FS + media server, mapping each pack file to its
`Episode` row, and an unmatchable file parks gracefully.

**[M5a done 2026-06-22 — data layer]** (design: `docs/specs/2026-06-22-m5-design.md`, plan:
`docs/plans/2026-06-22-m5a-tv-pipeline-data-model.md`; PR #24). Split M5 (XL) into **M5a (data,
shipped)** + **M5b (acquisition logic)** + **M5c (poller + multi-file import; carries the Done
when)**. M5a ships the **grab-centric** schema: episodes stay status-less (state is derived —
`file_path` ⇒ available, `grab_id` ⇒ downloading, else monitored+aired+missing ⇒ wanted, per the
`episode.ex` "never a bare status sweep" rule), and a transient `grabs` table owns the download
(one download → N episodes; `content_path` nil ⇒ downloading, set ⇒ ready to import). Additive
migration; movie loop untouched. Catalog gained `transition_episode/2` (episode pipeline
choke-point, broadcasts on the existing `"series"` topic), the grab lifecycle (`create_grab/3` in
one transaction, `mark_grab_downloaded/2`, `delete_grab/1` via FK `:nilify_all`,
`list_grabs_downloading/0`, `list_grabs_downloaded/0`), and `wanted_episodes/0` (SQL-expressible
set; backoff/bound filtering stays in the M5c poller). Decisions (council + user): grab-centric
over mirror-Movie (no episode status enum; the locked "grab/download join table" realized as a
one-to-many `grab_id` FK, not a join table); grabs transient (deleted after import/park); TV stays
**admin-direct** — the requester→approval flow is deferred out of M5. `/code-review` (xhigh recall)
findings addressed: `create_grab` uses `Repo.insert` + `Repo.rollback` (not `insert!`, matching
`set_season_monitored`); `broadcast_series/1` nil-safe. `mix test` green (417). **Deferred to M5b:**
parser S0xE0y/packs/ranges, Indexer TV callback, Scorer pack-vs-episode. **Deferred to M5c:** the
`Cinder.Download.TvPoller`, `Library.import_episode/import_pack`, the pack fan-out transaction.

**[M5b done 2026-06-22 — acquisition logic]** Shipped the three pure/fixture-testable pieces; the
movie acquisition path is logic-untouched (`Acquisition.best_release/2`, `Scorer.select/2`,
`search/1`, and the parser's movie fields keep their exact behaviour). **Parser** gained
`season`/`episodes` via a unified episode-tail scan (`SxxEyy`, `SxxEyyEzz`, `SxxEyy-Ezz`,
`SxxEyy-zz`, `1x02`; numbered packs `S01`/`Season NN`/`S01.COMPLETE` ⇒ `episodes: nil`); seasons
bounded 1..99 and episodes 1..99, with multi-season names (`S01S02`, `S01-S03`), `S00` specials,
year-as-season, daily/absolute numbering, and descending ranges all parking as `nil/nil`. The
`Release` struct carries the two new fields. **Indexer** gained `search_tv/3` (behaviour + Prowlarr
+ Mox auto-cover, atomic): `type=tvsearch` with a `{TvdbId:N}{Season:N}` token, free-text
title-+season fallback when `tvdb_id` is nil (it usually is — only set from TMDB `external_ids`);
contract verified against the Servarr "Prowlarr Search" wiki. **Scorer** gained `select_for/4`:
greedy set-cover over a wanted-episode set (coverage-primary, ties by resolution then size) with a
**per-episode** size band (`k*min ≤ size ≤ k*max`, `k` = still-wanted episodes covered), config
merged like `select/2`; returns one-or-more releases or `:no_match`, partial coverage allowed.
Council pass (3 reviewers) caught + fixed pre-impl: the bare-season-eats-`S01E02` precedence trap,
descending-range empty-list bug, resolution-eating range (`S01E01-1080p`), coverage-primary greedy
sort, and the multi-season silent-drop trap. **Deferred to M5c:** `Cinder.Download.TvPoller`,
`Library.import_episode/import_pack` (must **log** unmatched files, not silently drop — the
red-team's silent-failure catch), the pack fan-out transaction, and the `Acquisition` TV
composition fn. `mix test` green (441).

**[M5c done 2026-06-22 — poller + multi-file import; carries the M5 Done-when]** Shipped the TV
loop end to end; the movie pipeline is logic-untouched (`Poller`, `Download.start/1`,
`import_movie/1`, `best_release/2`, `Scorer.select/2` unchanged + still green). **`Cinder.Download.TvPoller`**
mirrors the movie poller skeleton (separate GenServer, gated by the same `:start_poller` flag, added
to `application.ex`; `@max_attempts 10`, `search_due?` backoff, per-unit `isolate` with a `catch`
clause too — checkout-timeout exits under two-poller contention aren't rescue-able) with three
DB-derived passes: **advance** (`list_grabs_downloading` → client status → `mark_grab_downloaded`,
bounded-retry/park on anomaly), **import** (`list_grabs_downloaded` → `Library.import_episodes` →
`finish_grab`, park on deterministic empty match), **search** (`wanted_episodes` minus
search-parked/backed-off → group by `{series, season}` → `Acquisition.best_releases` → `client.add`
+ `create_grab`, bump `search_attempts` on the not-grabbed). **`Library.import_episodes/2`** (one
unified fn, not the doc's two) maps files → episodes by parsing `SxxEyy` per file against the grab's
episodes (double-episode → both), with a largest-wins fallback for a lone-episode grab whose files
name no episode; layout `Show (Year)/Season NN/Show (Year) - SxxEyy.ext`; unmatched files logged +
skipped (graceful park); reuses the movie `link`/`scan`/naming primitives. **`Acquisition.best_releases/4`**
composes `search_tv` → parse → protocol filter → **series-title-match guard** (normalized,
NFD-folded substring — rejects a same-season release of another show on the title-fallback path;
imperfect for same-named variants, those need tvdb_id = M6) → `Scorer.select_for`. **`Scorer.select_for`**
now returns `{:ok, [{release, covered_numbers}]}` (single source of truth for episode→grab
assignment; no caller re-derives coverage). **Catalog** gained `finish_grab/2` (one txn: per-episode
`file_path`+`grab_id: nil`, bump `search_attempts` on non-imported *before* the FK-nilifying delete,
delete grab), `park_grab/1` (= `finish_grab(grab, [])`), `increment_grab_attempts/1`,
`increment_search_attempts/1`; and hardened the M5a fns it leans on: `create_grab` guards
`is_nil(grab_id)` and rolls back rather than leave an orphan grab, `mark_grab_downloaded` resets
`download_attempts` at the boundary (single grab-lifetime retry budget; `episode.import_attempts`
left unused — noted, not deleted), `wanted_episodes` excludes season 0 (specials unaddressable in
M5). Decisions (2 plan reviewers + a 3-seat council + `/code-review` high): single source of truth
for coverage over a re-derivation footgun; one unified import fn; title-match guard (user-approved)
over deferring; folded review fixes — total `normalize_title` NFD (a garbled indexer title can't
stall a season), orphan-grab rollback, retry-stable fallback tiebreak, `create_grab` extracted to
clear credo nesting. **Deferred to M6:** specials/S00, the calendar/sweep, TMDB renumbering
reconciliation; **deferred past M5:** the TV requester→approval flow (TV is admin-direct). `mix test`
green (479).

### M6 — TV monitoring sweep + RSS/calendar (M)

**Goal:** close the Sonarr loop — a wanted-episodes query drives the search sweep efficiently,
and an air-date-aware refresh marks newly-aired monitored episodes search-eligible so they grab
automatically. Leanest cut: **poll TMDB**, not per-tracker RSS.

**Build:**
- An indexed **wanted-episodes** query (monitored + missing file) so the poller targets only
  wanted episodes, not every episode row each tick.
- Monitor-strategy enforcement (`:all`/`:future`/`:none`) gating which episodes the sweep grabs
  (prevents flooding the client on a freshly added show).
- Periodic TMDB refresh reconciling season/episode data; when a monitored episode's `air_date`
  passes, mark it search-eligible.
- A simple **upcoming/calendar** view of monitored episodes.
- Reconciliation for TMDB renumbering / late air-date fills so monitored episodes don't strand
  un-grabbable.

**Done when:** conventions pass + a test proves a monitored, just-aired episode becomes
search-eligible and grabs automatically, and the wanted-episodes query is used (not a full
scan). — ***Dogfood checkpoint:*** run movies+TV privately for ~2 weeks before packaging.

**[done 2026-06-22]** (design: `docs/specs/2026-06-22-m6-design.md`, plan:
`docs/plans/2026-06-22-m6-tv-monitoring-sweep-calendar.md`). A read of the TV subsystem showed
three of the five build-items were **already landed**: air-date eligibility (`wanted_episodes/0`
already filters `air_date <= today` — with the derived-state episode model, "just-aired ⇒
search-eligible" happens automatically as time passes, no flag to flip), monitor-strategy
enforcement (at the per-episode `monitored` leaf via `monitored?/3`; the sweep reads it), and the
wanted-driven sweep (`TvPoller.search_wanted/1`, no full scan). So M6's real work was narrower:
**keep TMDB data fresh so the existing eligibility fires on time**, plus the index and calendar.
Shipped: (1) a partial index `episodes_wanted_index` on `episodes(air_date)` (`WHERE file_path IS
NULL AND grab_id IS NULL AND monitored`) backing `wanted_episodes/0`; (2) `Catalog.refresh_series/1`
— re-fetch a series from TMDB and reconcile in one transaction, **matching existing episodes by
`tmdb_episode_id`** (series-wide, so a renumber across seasons is handled) and updating
`air_date`/`episode_number`/`title`/`season_id` in place while **preserving**
`monitored`/`file_path`/`grab_id`/counters, inserting newly-announced episodes (strategy applied)
and new seasons, leaving vanished rows untouched (the **late-air-date fill** is the headline
Done-when case — an episode added `air_date: nil` under `:future` is invisible to the sweep until a
refresh fills the date, then grabs on the next tick); (3) `Cinder.Catalog.Refresher`, a 12h
self-scheduling GenServer mirroring the poller skeleton, `:start_poller`-gated, interval as module
config (not `/settings` — no int-coercion seam there); (4) `Catalog.upcoming_episodes/0` +
admin-gated `/calendar` LiveView (windowed `today-7..+90`, derived per-episode state badge, live via
the `"series"` topic). Decisions (user-approved): all three pieces in one session; **fresh + grow**
refresh depth. A post-merge `/code-review` (PR #30) surfaced that the initially-deferred renumber
ceiling ("self-heals") was inaccurate — a mid-season reorder/shift collides across the board and
stays stale — so on user decision M6 also shipped: **two-pass renumber** (park each matched row to a
unique `-(id)` sentinel → finalize to target → insert new; reorders/swaps/shifts now apply cleanly;
the only residual collision is a target reusing a *vanished* row's retained slot, logged + skipped)
and **series-row reconciliation** (backfill `tvdb_id`/`title`/`year`/`poster_path` from TMDB,
preserving `tmdb_id`/`monitored`/`monitor_strategy`), plus a Refresher log on `refresh_series`
`{:error}`. `mix test` green (501). **Deferred:** specials grabbing (parser limit); per-episode TV size-band as
a `/settings` field (M8); the **movies/TV library-path split** (now an M8 build-item — today a single
`:cinder, :library_path` roots both importers); vanished-row deletion. `mix test` green (496).

### M7 — Public release packaging (M)

**Goal:** turn the working multi-user movies+TV product into something strangers find, install,
and pin. **Packaging, not rewriting.**

**Build:**
- `docker-compose.yml`: cinder service + named volumes (SQLite DB, library path), a boot-only
  env stub, commented example wiring to Prowlarr/qBittorrent/Jellyfin.
- A GitHub Actions **release workflow** on tag push: build + push
  `ghcr.io/<namespace>/cinder:<tag>` and `:latest`, layered on the existing mix-test CI.
- Semver tags + `CHANGELOG.md` + `mix.exs` package metadata (description, `GPL-3.0-or-later`,
  repo links); bump off `0.1.0`.
- A real **README** (what/why, screenshots, compose quickstart, a full config-reference table
  marking env-bootstrap vs in-app) + one operator docs page replacing the stale Phase-5
  smoke-test note; `CONTRIBUTING` + an SPDX note.
- **DECISION (lock before the first tag — it appears in compose + docs):** image registry +
  namespace (GHCR vs Docker Hub; personal `simonbrunou` vs a new org).

**Done when:** conventions pass + `docker compose up` from the README boots to the first-run
wizard on a freshly built image, a tag push publishes a versioned image, and
README/compose/CHANGELOG are present.

**[done 2026-06-23]** Shipped the packaging layer; no app code changed beyond `mix.exs` metadata.
**Locked:** registry `ghcr.io/simonbrunou/cinder` (GHCR personal — matches the remote + CI badge),
**amd64-only** image, first version **0.7.0**. Added: `docker-compose.yml` + `.env.example` (the
`cinder` service builds locally pre-publish via `build: .` and pulls the published image after; one
`/media` mount documents the hardlink same-filesystem rule + the `nobody`/PUID-65534 permission
gotcha), `.github/workflows/release.yml` (tag `v*.*.*` → buildx → GHCR with `latest` +
`{{version}}` + `{{major}}.{{minor}}`, OCI source label), `CHANGELOG.md`, a real `README.md`
(quickstart + the env-bootstrap-vs-in-app config tables + precedence), `docs/operating.md`
(replaces the deleted `phase-5-smoke-test.md`; ports the BitTorrent-v1-only + SABnzbd
"Pause on Duplicates" + parked-state caveats), and `CONTRIBUTING.md` (dev flow + the release /
GHCR-make-public step + SPDX `GPL-3.0-or-later`). A pre-impl perspective-diverse **council** pass
drove the refinements: explicit `latest` tagging, the **first-publish GHCR package is private** →
documented one-time make-public step, `--build` in the quickstart, the OCI source label, the
PUID/PGID note, and a loud **admin-bootstrap** warning (don't expose `:4000` before creating the
admin — registration must stay open for the multi-user model, so the mitigation is proxy/VPN +
create-admin-first, **not** closing registration). One council "migrations are skipped in a release"
claim was **verified false** (`skip_migrations?` returns true only when `RELEASE_NAME` is unset,
i.e. not a release; a release migrates on boot). **Deferred to M8:** the movies/TV library-path
split (both import under `library_path` today), arm64, real screenshots, and the live
torrent/TV/badge sign-offs.

### M8 — v1.0 launch hardening (M)

**Goal:** sign off the combined movies+TV multi-user product as **v1.0** — docs cover TV, the
live torrent and TV paths are validated on real hardware, artifacts cut.

**Build:**
- README/docs updated for TV (series monitoring, season packs, calendar); new TV settings (e.g.
  per-episode size band) land in the **settings store**, not new env vars.
- **Split the library path into movie + TV roots (S).** Today a single `:cinder, :library_path`
  setting roots both importers (`Library.build_dest` for movies, `build_episode_dest` for
  episodes). Add a `tv_library_path` setting alongside it (movies keep `library_path`), point
  episode imports at the TV root, and validate **both** roots writable in
  `Health.check_service(:library)` + the onboarding wizard + a second `/settings` field — mirroring
  the existing `apply_library_path`/`plan_library_path` pattern in `Cinder.Settings` (a settings +
  import-path change, no new machinery). Jellyfin/Plex want separate Movies/Shows roots, so this is
  how strangers will deploy.
- **Live sign-off of the two open homelab items carried from Phase 5:** a qBittorrent torrent
  grab end-to-end (base32 magnet, `.torrent` URL fetch, malformed-torrent graceful park) and the
  `/status` visual badge-advance check.
- **Live TV smoke test:** a real monitored series grabs + imports a season pack into
  Jellyfin/Plex on real hardware.
- `v1.0.0` tag → release CI → image + CHANGELOG; the first-run wizard re-validated against the
  **published** image.

**Done when:** conventions pass + the live sign-offs above succeed on real hardware and `v1.0.0`
is tagged with its image published. **This is the single public launch.**

**[code/docs done 2026-06-23 — live sign-offs + v1.0 tag remain]** Shipped the buildable portion;
the live sign-offs and the `v1.0.0` tag are the maintainer/homelab steps that close M8. A
perspective-diverse **council** (architecture / implementation / red-team) reviewed the plan first
and caught three blockers folded into the build. **Library split (strict):** episodes import under
a separate, **required** `tv_library_path` (env bootstrap `TV_LIBRARY_PATH`, in-app at `/settings`),
mirroring the flat-key `library_path` overlay in `Cinder.Settings` (`apply_/base_tv_library_path`,
`plan_flat` generalized over `@flat_keys`); `Health.check_service(:tv_library)` + a second wizard
gate validate it writable. No fallback to the movie root — but `Library.import_episodes` returns
`{:error, :tv_library_not_configured}` when unset so the `TvPoller` bounded-retries and **parks**
(the council's catch: a raise there would hot-loop every tick, since `isolate` only logs). **TV size
band in `/settings`:** `tv_min_size`/`tv_max_size` (decimal GB → bytes) + `tv_preferred_resolutions`
(csv → downcased list) overlay **dedicated** `:cinder` keys; `TvPoller` reads them and passes
non-nil opts to `Acquisition.best_releases` → `Scorer.select_for` (per-call `Keyword.merge` override
— the **movie** `Scorer.select/2`/`best_release/2`/poller are byte-for-byte untouched). Coercion
degrades `≤0`/blank to nil (unbounded) so a bad band can't silently reject every release; UI help
text flags the decimal-GB unit + the per-episode `k×max` semantics. **Docs:** README + `operating.md`
cover TV (monitoring, season packs, calendar, the two roots, band tuning) with an upgrade/migration
note; `docker-compose.yml` + `.env.example` add `TV_LIBRARY_PATH` and drop the stale "separate TV
root is v1.0" comment; `CHANGELOG [Unreleased]` marks the config change **BREAKING**. `mix.exs`
version intentionally **not** bumped — the `v1.0.0` tag is the final live-sign-off step. `mix test`
green (510). **Deferred (carry the Done-when):** live qBittorrent torrent sign-off, `/status` badge
check, live TV season-pack smoke test, and cutting `v1.0.0`.

## Release & dogfood checkpoints

- **internal-alpha** (after M2) — real accounts + the approval gate over the movie pipeline; you
  run it, no public artifact.
- **movies-complete dogfood** (after M3) — your household movie instance, privately.
- **movies+TV dogfood** (after M6) — the full feature set, privately, ~2 weeks, to shake out
  your own bugs.
- 🏁 **v1.0.0** (after M8) — the single public launch: a Sonarr + Radarr + Seerr replacement,
  validated live.

## Architecture decisions (locked in Part II)

- **SQLite stays** — WAL + `busy_timeout`; single-container, zero-dependency. Ceiling accepted:
  single instance, low concurrency, no hosted multi-tenant. (Supersedes the old "swap to
  Postgres later" note.)
- **Every writer goes through `Catalog.transition`**; TV pack fan-out is wrapped in one
  `Repo.transaction`. This is what makes WAL + `busy_timeout` correct, not just hopeful.
- **In-app settings overlay the existing `Application.get_env` seam** — no context-code changes.
- **The approval gate lives in the data model** (a separate `requests` table), never the UI.
- **No Oban for now** — the bespoke poller + `busy_timeout` is enough at household I/O scale;
  revisit only if hand-rolling M6's calendar cron proves annoying.
- **Separate Series/Season/Episode tables** (not polymorphic) — locked at M4.

## Decisions deferred to their milestone (with current recommendation)

- **Secrets-at-rest (M1):** encrypt (Cloak) — recommended for a public product; document that
  master-key loss = re-enter all creds.
- **Email confirmation (M2/M3):** make it optional for single-household self-host (only
  `Swoosh.Local`/`Test` is wired today) — don't force SMTP.
- **Auto-approve (M2):** admins' own requests auto-approve; offer a global "auto-approve all"
  toggle for trusted households (restores today's request==grant).
- **Quota shape (M3):** concurrent-pending count (simplest); default unlimited.
- **Keep the env Basic password** as an optional outer reverse-proxy gate after real accounts
  land, so an unconfigured instance isn't wide open.
- **Season-pack representation (M4):** a grab/download join table.
- **Pack-vs-individual default (M5):** score packs against still-missing episodes, fall back to
  per-episode; make it configurable later.
- **Monitor-strategy default (M4/M6):** `:future` for a newly added series (don't flood the
  client).
- **Image registry/namespace (M7):** pick before the first tag.

## Top risks to manage

- **SQLite single-writer *correctness*, not throughput.** An unpinned `busy_timeout` surfaces as
  flaky "database busy" the moment a web write races the poller (or a TV fan-out writes N episode
  rows). M0 pins it — but only works if *every* writer uses the choke-point.
- **The approval gate is security-critical and must be in the data model.** The poller
  auto-consumes any movie at `:requested` (`poller.ex:80`), so a non-admin who can write a
  `:requested` row is an approve-by-default leak. M2 ships with the regression test or not at all.
- **TV is the deepest break.** The 1:1 row=request=file assumption is baked into `Movie`,
  `Download.start/1`, `Library.import_movie/1`, and the poller sweep. Lock the two schema forks
  before writing TV code; use a *separate* TV pass, don't overload the working movie poller.
- **Season-pack import is the highest bug-density area.** File→episode mapping depends on the
  parser handling messy real-world names (mixed numbering, `S00` specials, double episodes).
  Strong fixtures + graceful park for unmatched files.
- **Secrets-at-rest:** creds in a plain SQLite file turn every backup/volume snapshot into a
  leak — worse than env. Encrypt at M1; document the key-loss failure mode.
- **Behaviour-signature churn** (Indexer/TMDB TV callbacks) changes every impl *and* its Mox
  mock at once; land them atomically and keep movie/TV callbacks distinct rather than overloading
  one `search/1`.
- **`phx.gen.auth` output must pass `credo --strict` + `--warnings-as-errors`.** Budget review
  time; don't blind-commit the generator.

---

# Part III — Anime-aware media handling

**Design:** `docs/superpowers/specs/2026-07-12-anime-media-handling-design.md`.

Anime is a **per-title opt-in handling profile** (`Auto` / `Standard` / `Anime`) layered onto the
existing movie and TV pipelines — not a third pipeline, not a separate library layout, not a new
context. `Auto` behaves exactly like `Standard` unless a title is explicitly confirmed as Anime: A0
found no metadata signal reliable enough to auto-detect anime safely, so a Western cartoon or a
Japanese live-action title is never silently reclassified. Confirming a title as Anime changes how
Cinder searches for and imports it — title aliases and absolute/scene episode numbering, specials
(Season 0) handling, audio/subtitle/release-group preferences, and a stricter post-download check —
never where the file lands or how Jellyfin/Plex see it.

The one piece of vocabulary worth knowing is the **grab snapshot**: when a release is reserved,
Cinder freezes an immutable copy of the episode-mapping decision and the release-policy values
(audio mode, subtitle mode, release-group preferences) in force at that moment, and that frozen copy
— not whatever `/settings` says later — is what the completed download gets checked against. That's
what stops a mid-flight grab from being invalidated by a settings change or a TMDB renumber that
happens while it's downloading.

**Safety invariant, plainly:** Cinder will not file away a downloaded anime batch until it is certain
which episode every video in it is. A file that's ambiguous, unidentifiable, a duplicate claim, or
doesn't belong to what was actually grabbed stops the *whole* batch and waits for a human to look at
it — it never guesses. (Post-A5, issue #123 sanctioned one narrow exception: exactly one non-ignored
video that parses no episode markers, for a grab that reserved exactly one episode, is inferred to be
that episode instead of holding; every other case still stops for a human.)

This was the single largest feature program in the codebase to date — five phases, each sized **XL**.
It was designed and built end-to-end by a different model as a trial run; a same-day audit
(2026-07-14) found the result functionally sound (every gate below was green throughout) but
substantially over-built for the problem and stylistically inconsistent with the rest of the app.
**A4.5**, below, simplified the implementation in place without touching the safety invariant.
A5's dogfood and corpus re-run signed off 2026-07-14, and **A6** closed the evidenced numbering
gap TMDB-internally on 2026-07-19.

### A0 — Corpus and provider contracts (XL)

**Goal:** before writing any anime-specific code, measure what TMDB and Prowlarr actually return for
a fixed set of well-known anime titles, and decide whether a second metadata provider is needed on
top of TMDB.

**Build:**
- A versioned fixture corpus (One Piece, Attack on Titan, Bleach, Demon Slayer, Pokémon, Re:Zero…)
  with must-support checks: discovery under native/romaji/licensed titles, absolute-episode-count
  coverage, specials presence, episode-group integrity.
- A one-shot research tool (`mix cinder.anime.probe`) running the corpus live against TMDB and
  Prowlarr and recording a raw evidence dump.
- A written audit of the results: required Prowlarr fields/categories for anime, and the
  metadata-provider decision.
- Safe-stop fixtures: cases the corpus expects to fail closed rather than guess.

**Done when:** for the fixed title corpus, TMDB search finds every title under its native, romaji,
and English-licensed name; Prowlarr's anime category and the fields Cinder needs are documented; and
the write-up records zero cases where the corpus data would have produced an automatic wrong
mapping, plus the provider decision (TMDB alone vs. TMDB+AniDB) with its evidence.

**[done 2026-07-12]** (plan: `docs/superpowers/plans/2026-07-12-a0-anime-corpus-provider-contracts.md`;
audit: `docs/audits/2026-07-12-anime-provider-contracts.md`). Corpus v1 passed with zero known
incorrect automatic mappings; TMDB was chosen as the only metadata provider for A1–A4 (no
anime-identity signal strong enough on its own to justify a second provider — see A6). The probe
tool and its 40k-line raw evidence dump were deleted in the A4.5 cleanup once the decision was
recorded in the audit doc and git history; the corpus fixtures stay and keep running.

### A1 — Identity foundation (XL)

**Goal:** give Cinder somewhere to record "this title is anime" and the genuinely many-to-many
mapping between a canonical episode and however different providers/releases number it, without
touching how Standard movies/TV behave.

**Build:**
- An operator-owned `media_profile` (`:auto` / `:standard` / `:anime`) on movies and series,
  defaulting to `:auto`.
- A request/approval seam where a requester can propose Anime for a new title and an admin's
  approval confirms it; a direct admin picker on the movie/series detail page for changing it later.
- `title_aliases` (native/romaji/licensed/scene names, sourced and precedence-ranked) and
  `episode_coordinates` + `episode_coordinate_memberships` (many-to-many: absolute number, scene
  number, provider group entry ↔ Cinder's own episode id).
- Sourced episode classification (`:regular` / `:story_special` / `:recap` / `:extra`).
- A TMDB refresh that keeps aliases and numbering current without ever overwriting a manual
  correction, and a pure resolver turning a parsed release's coordinates into "this is episode N."

**Done when:** a series can be switched to Anime (directly, or by requester proposal + admin
approval) and a later TMDB refresh doesn't silently switch it back or lose a manual alias edit; a
series with both a Japanese and an English title alias resolves a release under either name to the
same episode; and a hand-corrected episode mapping survives the next provider refresh untouched.

**[done 2026-07-13]** (design: `docs/superpowers/specs/2026-07-12-anime-media-handling-design.md`,
plan: `docs/superpowers/plans/2026-07-13-a1-anime-identity-foundation.md`). Shipped the Build list
above. `Auto` stays `Standard` unless explicitly confirmed, per the A0 finding that no metadata
signal is strong enough to auto-detect anime safely. Acquisition, download, and import behavior are
untouched at this point — A1 is identity-only.

### A2 — Anime acquisition (XL)

**Goal:** make release search and selection anime-aware — search by alias and anime category, parse
absolute/scene numbering, pick the right release out of a batch — while leaving the movie and
standard-TV search paths byte-for-byte alone.

**Build:**
- Additive Prowlarr searches (anime category, stored title aliases, provider-ID queries) layered
  onto the existing search, not replacing it.
- Context-aware release parsing recognizing absolute numbers, scene groups, and anime-specific
  tokens.
- Stable-ID set-cover selection: resolve every coordinate in a candidate release to a Cinder episode
  id and pick the release(s) covering the most of what's still wanted.
- Anime-movie selection reusing the existing movie pipeline (a movie needs no episode mapping).
- Preferred-group waiting: hold for a configured group up to a fallback delay before grabbing the
  next-best option, without spending a search attempt while waiting.
- Immutable intent snapshots recording exactly what a release matched, so a later refresh or
  restart can't retroactively change what a grab thought it downloaded.

**Done when:** a One Piece `1122v2` absolute-numbered release resolves to the correct episode
without any TMDB season/episode math; a season pack from a group that isn't on the preferred list
waits (without burning a retry) until the configured fallback delay passes, then grabs the
next-best option; and an ordinary (non-anime) movie or TV search's results are unchanged.

**[done 2026-07-13]** (design: `docs/superpowers/specs/2026-07-13-a2-anime-acquisition-design.md`,
plan: `docs/superpowers/plans/2026-07-13-a2-anime-acquisition.md`). Shipped the Build list above; the
A0 corpus's expected releases were selected correctly and the Standard movie/TV selection paths were
unchanged. Episodic anime still has no safe import path, so none of this reaches the live
`TvPoller` yet — snapshot-bearing episodic matches are held pending A3.

### A3 — Safe import and mapping recovery (XL)

**Goal:** actually let an anime batch download and import, with the safety invariant enforced:
nothing is filed away until every video in the batch is certainly mapped to one episode.

**Build:**
- Copy an A2 intent snapshot atomically into the grab at download time, so the mapping decision
  that chose the release is frozen, not re-derived later.
- Inventory-bound exact preflight: before staging anything, check every file in the batch against
  the grab's reserved episode set; an unmapped, ambiguous, duplicate, or outside-the-set file fails
  the *whole* batch closed.
- A durable `Needs mapping` hold for a batch that fails preflight, surviving an app restart.
- Same-season and cross-season canonical Jellyfin/Plex naming for whatever the batch turns out to
  contain.
- *(Superseded by A4.5, below.)* The initial ship also included a bespoke grab-local
  correction/promotion/resume UI for fixing a `Needs mapping` hold in place.

**Done when:** a season pack where every file cleanly maps to one wanted episode imports
automatically; a batch with one duplicate-claimed file or one file the parser can't identify holds
the *entire* grab as `Needs mapping` rather than importing the other 90%; and after an app restart,
that held grab is still there with the same reason, not lost or auto-resolved. (Post-A5 carve-out,
issue #123: a lone unparseable non-ignored file against a lone reserved episode is inferred instead
of held.)

**[done 2026-07-13]** (design:
`docs/superpowers/specs/2026-07-13-a3-safe-import-mapping-recovery-design.md`, plan:
`docs/superpowers/plans/2026-07-13-a3-safe-import-mapping-recovery.md`). Shipped the Build list
above, including the grab-local correction UI later replaced in A4.5. The versioned `import-v1.json`
fixture (single/range/batch/many-to-many/mutated-inventory/cross-season cases) and the full suite
passed with no partial-import cases.

### A4 — Specials and release preferences (XL)

**Goal:** make specials (Season 0) individually controllable instead of ignored, give Anime titles
their own audio/subtitle/release-group preferences, and verify a downloaded file's actual
audio/subtitles against those preferences before it's ever staged.

**Build:**
- Classification-driven specials acquisition: a Season 0 episode is searched and grabbed only when
  it's classified `story_special` or `recap` *and* monitored — an unclassified special or a pure
  `extra` is never auto-grabbed.
- Global Anime release preferences in `/settings` — audio mode (original/dub/dual/any),
  embedded-subtitle mode (allow/prefer/require), preferred/blocked release groups, and a
  preferred-group fallback delay — plus, in the initial ship, a per-title override tier (dropped in
  A4.5).
- The hard portion of that policy frozen into the grab's snapshot at reservation time.
- Post-download MediaInfo (`ffprobe`) verification against the frozen policy: a file that provably
  violates it is rejected and blocklisted (not imported, not silently accepted) and its episode
  requeues; a probe that can't reach a verdict (e.g. `ffprobe` missing) holds the release for a
  manual re-check rather than guessing either way.

**Done when:** a Season 0 episode classified as a story special and monitored gets searched and
grabbed exactly like a regular episode, while an unclassified special never does; a downloaded
release whose actual audio track (checked via `ffprobe`) doesn't match the configured Anime
audio-mode policy is rejected and blocklisted rather than staged, and its episode re-searches; and
the global Anime preferences apply the same way to a title just switched to Anime as to one that's
been Anime all along.

**[done 2026-07-14]** (design:
`docs/superpowers/specs/2026-07-13-a4-anime-specials-preferences-design.md`, plan:
`docs/superpowers/plans/2026-07-13-a4-anime-specials-preferences.md`). Shipped the Build list above,
including the per-title preference tier later dropped in A4.5. Gate evidence at the time: a focused
21-file `mix test` run passed 572 tests, the explicit Standard/A2/A3 regression run passed 110, and
the full suite passed 1,691. Live Jellyfin/Plex dogfood and provider sign-off were explicitly
deferred to A5.

### A4.5 — Consistency cleanup (done 2026-07-14)

A0–A4 were designed and built end-to-end by a different model as a trial run. A same-day audit found
the result functionally correct — every gate above was green throughout — but substantially
over-built for the problem and stylistically out of step with the rest of the app: a bespoke
correction-workflow UI where the product otherwise uses one hold-and-retry idiom everywhere, a
per-title preference tier nobody had exercised yet, and a row-versioning layer largely duplicating
guards that were already there. A cleanup pass fixed a real bug and then simplified in place without
touching the safety invariant: (1) fixed a parser bug where `SxxEyy-Ezz`/`SxxEyy-zz` batch-range
shorthand silently dropped episodes; (2) deleted the one-shot `mix cinder.anime.probe` tool and its
40k-line evidence dump (the A0 decision is recorded in the audit doc and git history), the
never-shipped v1-snapshot back-compat branch, and a manual-classification setter with no caller; (3)
replaced the A3 grab-local mapping-correction pipeline (a dedicated LiveView plus
resume/promote/override machinery) with the app's standard idiom — a preflight failure holds the
grab with a plain-English reason on `/activity`, "Retry import" re-runs preflight against current
disk state after the operator fixes the files, and "Discard" reuses the existing cancel path; the
safety invariant itself (ambiguous/duplicate/outside/unknown mappings never stage a file) is
unchanged; (4) collapsed the 12-column per-title release-preference override tier to global-only
settings, since nothing had exercised per-title yet — the frozen release-policy-snapshot flow is
unchanged; (5) dropped the SQLite trigger-bumped `row_version` column: the audit found it was
genuinely load-bearing at only two of its eight call sites (the two verification-hold guards), so
those two were rewritten to compare `release_title` directly instead of removing the safety check
outright; (6) made "Needs verification" render through the same `badge_spec` component everywhere
(grabs and movies alike) instead of a hand-rolled span, with a consistent "Retry verification"
action label; (7) reworked the series-detail anime UI down to two things an operator actually needs
— a muted absolute-episode-number annotation and a plain "Story special"/"Recap" label on Season 0 —
deleting the raw provenance/coordinate/precedence rendering and collapsing the alias list into the
page's existing disclosure pattern; (8) extracted `Cinder.Catalog.ReleaseVerification` out of
`catalog.ex` (which had grown past 3,100 lines) as a plain code-motion refactor, made the Identity
alias/coordinate writers broadcast like every other writer, and made `ffprobe` operable — a
`ffprobe_bin` setting, a `MediaInfo.health/0` callback, and a row in both `/status` service health
and `/settings` Test connection. `mix test` green throughout (1,605 tests).

### A5 — Live dogfood and sign-off

**Goal:** prove A0–A4.5 against the versioned corpus *and* real Jellyfin/Plex libraries, not just
mocks.

**Build:**
- Run the full A0 corpus again against current provider behavior.
- Live single-episode, episode-range, full-season-batch, story-special, cross-season-pack, and
  dual-audio-release imports into a real Jellyfin and a real Plex library.
- Confirm every automatic mapping is right (zero wrong auto-imports) and every case the pipeline
  can't handle stops safely and is documented, not silently mis-filed.

**Done when:** the corpus fixtures still pass; a live single episode, a live range grab, a live
season batch, a live story special, a live cross-season pack, and a live dual-audio release each land
correctly in both Jellyfin and Plex (Jellyfin descoped 2026-07-14: not deployed in this household —
Plex is the production media server); nothing was automatically mapped wrong; and the standard
(non-anime) suite is still green.

**[dogfood + corpus done 2026-07-14 — 2/6 cases landed cleanly, 4/6 safe-stopped with documented
root causes; zero wrong auto-imports; Plex-only (no Jellyfin deployed, operator descope); corpus
re-run pass vs A0 baseline; suite 1606 green]** (dogfood:
`docs/audits/2026-07-14-a5-live-dogfood.md`; corpus re-run:
`docs/audits/2026-07-14-a5-corpus-rerun.md`). Landed cleanly: a full-season Demon Slayer S1 batch
(26 episodes, 40.04 GB, Plex `leafCount=26`) and a dual-audio Your Name import after correctly
rejecting+blocklisting four wrong-audio "Dual Audio" releases first (6.24 GB, Plex `ratingKey`
1637). Safe-stopped, each with a named root cause: a single-episode Bleach grab (zero standalone
releases exist on any indexer — only oversized batches, correctly excluded by newly-configured size
bands, F1); an episode-range Re:Zero grab (TMDB's tree diverges from scene numbering — interleaved
shorts, no season 2 — the A6 trigger evidence, F2); a story-special substitution (the real Nyaa
batch used a CJK wave-dash `~` range separator `AnimeParser` doesn't recognize, F3); and a
cross-season Attack on Titan pack (both boundary episodes downloaded, then correctly held at
`verification_blocked` on untagged audio rather than guessing, F5). Landing the four blocked cases
is gated on ecosystem/provider gaps, not a cinder defect: no standalone releases exist for the
Bleach coordinate, the Re:Zero TMDB tree divergence is the A6 trigger, the `~` parser gap needs a
parser change, and the AoT files need either a re-tagged release or an operator override — none of
these reopen A0–A4.5. Also surfaced: a global-only `anime_audio_mode` silently holds titles with no
DB-visible marker when the configured mode can't be satisfied (F4, fixed for this instance by
reverting to `:original`).

### A6 — Additional metadata provider (optional; only if A5 evidence demands it)

A0 chose TMDB alone because no corpus title needed more. If A5's live run turns up a specific,
evidenced case TMDB genuinely can't resolve (e.g. a scene-numbering disagreement TMDB has no
coordinate for), add a focused behaviour for one additional provider — AniDB and TheXEM remain the
candidates from the A0 design — to close *that* gap, not a general second-provider integration.
Skip this phase entirely if A5 turns up nothing that needs it.

**Trigger evidence now exists:** A5's live Re:Zero episode-range case found TMDB id 65942's tree
diverging from real-world scene numbering (interleaved Re:PETIT shorts, no season 2) — see F2 in
`docs/audits/2026-07-14-a5-live-dogfood.md`.

**Done when (only if triggered):** a named, evidenced-in-A5 gap has a fixture that failed before and
passes after the new provider is wired in, and every A0–A5 fixture plus the standard suite stays
green.

**[done 2026-07-19 — realized TMDB-internally, no second provider]** (design:
`docs/superpowers/specs/2026-07-17-a6-alt-season-numbering-design.md`). Triggered live a second
time by **Frieren** (TMDB 209867): TMDB folds all 38 episodes into Season 1 (deliberate "TV Bible"
policy), while the TVDB-indexed NZBGeek answers `{Season:2}` — the last 10 episodes were
unfindable. A live TMDB API probe (2026-07-17, run by the operator) showed TMDB's own **episode
groups** publish exactly the alternate split (Frieren's "Seasons" group: Specials/28/10, matching
TVDB), and that **Re:Zero's F2 closes with the same mechanism** (all three of its type-6 groups
model Season 2 as canonical S1E26..E50) — so AniDB/TheXEM stay parked unless a title with no
usable TMDB group appears. Shipped: `series.scene_numbering_group_id` (nullable; nil = today's
behavior) chosen by an **operator-only** "Alternate numbering" picker on the series detail page
(never auto-picked, per A0) with a both-sides preview ("Season 2 → S02E01–E10 (episodes 29–38)",
order-derived, unmatched entries counted separately — preview and persistence share one
derivation); sync ingests the chosen group as `scheme: "scene"` coordinates through the existing
`episode_coordinates` machinery (delete-non-manual-then-reinsert, so `:manual` corrections
survive; fetch failure keeps last-synced rows — drift never strips search ability); search unions
id-scoped alt-season queries (`{TvdbId}{Season:2}`) and activates the dormant `"scene"` coordinate
queries; resolution bridges parsed `"standard"` values to persisted scene rows (same bridge in
`AnimePreflight` — found test-first, its matcher is independent); **import is untouched** (frozen
snapshot; every hold path intact). All TMDB fetching happens before any `Repo.transaction` (M0
invariant), mirroring `refresh_series/1`. The Done-when gate holds: the Frieren-shaped fixture
yields `:no_match` before and selects/imports after. Three xhigh `/code-review` rounds on PR
#133 (15 + 13 + 12 findings, severity declining each round) were fixed in-branch before merge —
notably: fail-loud vs no-op save semantics on a TMDB fetch failure, scheme-scoped
`Identity.replace_provider_coordinates/5`, both derived-coordinate collision directions dropped
per the never-guess rule, race-free save/refresh via fresh in-transaction reads, and a picker
that can never silently show "None" over a saved group. Suite green (1,760). Standard TV reuse
of these coordinates is tracked in issue #132.

---

One phase per session; each phase gets its own design/plan and commit boundary. Do not start a later
phase until the current Done-when block is green.

---

## Parked (out of scope even for v1.0)

*Automatic* quality upgrades & cutoffs (the **manual** upgrade path shipped post-0.7.0: "Find a
better match" grabs a chosen release for an `:available` movie and atomically swaps the file via
`:upgrading`) · per-tracker quirks and tracker RSS (v1.0 monitoring polls TMDB) ·
OIDC / Jellyfin-Plex SSO · per-user permissions finer than
`admin`/`user` · notification fan-out beyond the M3 `Notifier` seam (Discord/email/etc.) ·
trending/discover landing pages beyond search · multi-node / hosted multi-tenant (precluded by
the SQLite decision).

**[shipped post-0.7.0] Release blocklist** — remember a rejected/failed release (by parsed
release title, scoped per movie/series) so a title whose only available release is wrong-language
or keeps failing isn't re-grabbed and re-downloaded every search cycle. Landed as the
`blocked_releases` table + a `release_blocklist` scorer exclusion fed into both pollers' search
opts; captured at the terminal park sites (deterministic import failures + exhausted download
failures), cleared on manual Retry.

Revisit the rest only after v1.0 has run reliably for a couple of weeks.
