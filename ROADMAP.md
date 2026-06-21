# Cinder — Build Roadmap

A single-household, self-hosted replacement for the Sonarr/Radarr/Seerr loop, built on
Phoenix/LiveView. This roadmap covers the **movies-only vertical slice**: request a movie →
find the best release → download it → import it into Jellyfin. TV, quality upgrades, and
multi-user are deliberately out of scope until the slice is solid (see *Parked*, bottom).

> **Status (2026-06-21):** the slice (Phases 0–5) is built and validated live. The active plan
> is now **Part II — From slice to v1.0** (bottom of this file): turn the POC into a public,
> open-source, self-hostable product that replaces all three of Radarr (movies), Sonarr (TV),
> and Seerr (multi-user request/approval). TV and multi-user are **no longer parked** — they are
> v1.0 scope. Phases 0–5 below are kept as the build record.

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

### M8 — v1.0 launch hardening (M)

**Goal:** sign off the combined movies+TV multi-user product as **v1.0** — docs cover TV, the
live torrent and TV paths are validated on real hardware, artifacts cut.

**Build:**
- README/docs updated for TV (series monitoring, season packs, calendar); new TV settings (e.g.
  per-episode size band) land in the **settings store**, not new env vars.
- **Live sign-off of the two open homelab items carried from Phase 5:** a qBittorrent torrent
  grab end-to-end (base32 magnet, `.torrent` URL fetch, malformed-torrent graceful park) and the
  `/status` visual badge-advance check.
- **Live TV smoke test:** a real monitored series grabs + imports a season pack into
  Jellyfin/Plex on real hardware.
- `v1.0.0` tag → release CI → image + CHANGELOG; the first-run wizard re-validated against the
  **published** image.

**Done when:** conventions pass + the live sign-offs above succeed on real hardware and `v1.0.0`
is tagged with its image published. **This is the single public launch.**

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

## Parked (out of scope even for v1.0)

Quality upgrades & cutoffs · per-tracker quirks and tracker RSS (v1.0 monitoring polls TMDB) ·
anime absolute numbering · OIDC / Jellyfin-Plex SSO · per-user permissions finer than
`admin`/`user` · notification fan-out beyond the M3 `Notifier` seam (Discord/email/etc.) ·
trending/discover landing pages beyond search · multi-node / hosted multi-tenant (precluded by
the SQLite decision).

Revisit only after v1.0 has run reliably for a couple of weeks.
