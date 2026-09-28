# Cinder Constitution

## Core Principles

### I. External Services Only Through Behaviours
Every external service (TMDB, Prowlarr, torrent/Usenet clients, Jellyfin/Plex, Audiobookshelf,
Booklore) MUST be reached only through a behaviour (`Cinder.Catalog.TMDB`,
`Cinder.Acquisition.Indexer`, `Cinder.Download.Client`, `Cinder.Library.MediaServer`,
`Cinder.Books.Metadata`, `Cinder.Library.AudiobookServer`), never called directly from a
context. The concrete implementation MUST be resolved with `Application.fetch_env!/2`, never
`compile_env!/2` — the Mox mock is defined at runtime, so compile-time resolution breaks
`compile --warnings-as-errors`. `config/test.exs` MUST point each behaviour at its Mox mock, and
tests MUST NOT hit the network or a real service.
*Rationale: it is the only way to keep the app runtime-configurable via `Cinder.Settings` and the
test suite hermetic.*

### II. Status and Derived-State Writes Go Through the Catalog/Books Choke-Points
A movie's `:status` and an episode's derived state (`file_path` / `part_file_paths` / `grab_id`)
MUST be written only inside `Cinder.Catalog` and its submodules, principally
`Catalog.transition/3` (its `expect:` form is the race-safe poller write) and
`transition_episode/3`, plus the audited siblings that each own one lifecycle (grabs, upgrades,
release verification, adoption, deletion, TMDB refresh). The books/audiobooks track follows the
same discipline through `Cinder.Books.transition_target/3` /
`BookTargetTransition.guarded/4` and its audited siblings (`hold_target/4`, `pause_target/1`,
`monitor_target/4`, `import_resolution/1`, `Files.record_import/3`, `Grabs`). Each transition
MUST emit exactly one broadcast, after commit, never inside the enclosing `Repo.transaction`.
This is **not** a blanket "no direct `Repo` writes" rule: creation, deletion, monitor flags,
language, counters, and the TMDB/metadata refresh are sanctioned direct writes inside
`Catalog`/`Books`. Caller modules (`lib/cinder/download/*`, `acquisition.ex`,
`lib/cinder/library/*` bar `import_stage.ex` and `sidecar_quarantine.ex`, `Cinder.Download.BookPoller`)
MUST hold no `Repo` mutations of their own — `download.ex` is the one caller-side exception,
writing only its own `download_intents` tables. A new sanctioned direct-write site (a module
owning its own table, nothing derived) is a legitimate outcome only when called out explicitly
in a plan, and when it lands it MUST be added both to the exception list in
`.omp/rules/catalog-write-choke-points.md` and to the corresponding paragraph in `AGENTS.md`.
*Rationale: SQLite is pinned to WAL + `busy_timeout: 5000` so a web write racing the poller waits
rather than failing "database busy" — but only while all writes funnel through the choke-points.*

### III. The Approval Gate Lives in the Data Model
`Cinder.Requests` MUST be the only path that creates a `:requested` movie/series row or a book
target from a user action, API included. A non-admin request MUST write only a `:pending`
`Request` row until an admin approves (or `auto_approve_all` — a live DB setting — is on).
`/api/v1` request mutations MUST route through `Cinder.Requests`; API actions MUST NOT write
request lifecycle state directly.
*Rationale: the poller auto-consumes any `:requested`/wanted row with no further auth check, so
"a row exists" is equivalent to "the pipeline grabbed it" — the gate has to sit upstream of that
row's existence, not downstream of it.*

### IV. Service Configuration Lives in `Cinder.Settings`, Not New Env Vars
Only boot-critical keys stay environment variables — needed before the DB/settings store is up,
or fixed per deployment: `SECRET_KEY_BASE`, `DATABASE_PATH`, `PHX_HOST`, `PHX_SERVER`, `PORT`,
`POOL_SIZE`, `RELEASE_NAME`. Everything else — external-service URLs, API keys, the media-server
choice — MUST live in the `Cinder.Settings` registry: DB-backed, editable in `/settings`,
overlaid on env-as-bootstrap. A new service config value MUST get a `Cinder.Settings` registry
entry, never a new `System.get_env` call site. Secrets MUST be Cloak-encrypted at rest (key
derived from `SECRET_KEY_BASE`) and MUST NEVER be echoed into a form value, a socket assign, or a
log line.
*Rationale: DB overrides env, a cleared setting reverts to env, and every context reads the same
keys unchanged — a stray env var would fork that contract.*

### V. Bounded Work, Supervised Recovery
Provider HTTP MUST go through the bounded request policy (`Cinder.HTTPPolicy.bounded_request/2`:
size ceiling, receive/hard-deadline timeouts). Any subprocess (ffprobe, archive listing) MUST use
a `Task.async` + `Task.yield(timeout)` + `Task.shutdown(:brutal_kill)` idiom with the
missing-binary rescue inside the task. Archive extraction MUST carry entry-count and
expanded-size ceilings. Background work (download polling, import, book/audiobook pollers) MUST
run under the supervision tree, not in the request path, and crash-recovery MUST be proven with a
test.
*Rationale: a single-tick poller or an unbounded external call can freeze every target sharing
that tick, not just the one file/request in flight.*

### VI. `mix test` Is the Only Green Gate
The `test` Mix alias — `compile --warnings-as-errors`, `format --check-formatted`,
`credo --strict`, then the suite — MUST stay green before every commit and is the sole source of
truth for "is it done." A new behaviour (a new choke-point, a new state, a new writer) MUST ship
with a test. "Fix the bug" means "write a test that reproduces it, then make it pass"; "add X"
means "X works and `mix test` is green."
*Rationale: this is the same alias CI runs on every push and PR — there is no separate manual
bar.*

### VII. Minimum Code, Touch Only What You Must
Write the minimum code that solves the problem: no unrequested features, abstractions,
flexibility, or configurability. Every changed line MUST trace directly to the request; remove
imports/variables/functions your change made unused, but do not delete pre-existing dead code
unless asked. If a request has more than one reasonable interpretation, or something is unclear,
state the assumption or ask rather than guessing — do not hide confusion.
*Rationale: diffs stay small, predictable, and reviewable in a codebase maintained mostly by
agents working from fresh context each session.*

## Technology & Platform Constraints

- **Scale**: one self-hosted instance per household — low concurrency, a single admin who
  approves, a handful of requesters. Design and defaults target that scale, not multi-tenant SaaS.
- **Database**: Ecto with `ecto_sqlite3`, pinned to WAL + `busy_timeout: 5000` across
  dev/test/runtime — not Postgres, on purpose. Do not introduce a second database engine or an
  external DB dependency.
- **UI**: Tailwind v4 + daisyUI (Phoenix 1.8 default), Phoenix LiveView (HEEx), heroicons. No
  React; shadcn does not apply here. State renders via the shared `status_badge` primitive
  (icon + text + color, never color alone).
- **Dev tooling**: Tidewave MCP is wired in dev (`project_eval`, `get_ecto_schemas`,
  `execute_sql_query`, `get_logs`) — prefer it over guessing about the running app.
- **Secrets**: Cloak-encrypted at rest (secret rows only), key derived from `SECRET_KEY_BASE`,
  never echoed back to a form. Session/LiveView signing salts are derived from `secret_key_base`
  at runtime in `config/runtime.exs` — nothing crypto-related is committed.
- **Defense in depth**: an optional HTTP Basic gate fronts every browser route and `/api/v1`
  (no-op when both `CINDER_BASIC_AUTH_USER`/`PASSWORD` are unset, fail-closed if exactly one is
  set); `/api/v1` additionally requires the SHA-256-hashed household API key.
- **Books/audiobooks**: the B0–B8 track is shipped (v3.0.0+). There is no automatic release
  search for books by design — an admin picks the release in manual search until a measured
  corpus-precision threshold is met; do not "fix" this as a missing feature.

## Development Workflow

- Keep each unit of work focused: one issue, fix, or feature per branch off `main`, merged
  through a PR kept green on `mix test` (chores such as flake bumps may land directly).
- Non-trivial work goes through Spec Kit: `/speckit.specify` → optionally `/speckit.clarify` →
  `/speckit.plan` → `/speckit.tasks`, with explicit agreement on the spec and plan before
  `/speckit.implement`. A genuinely small, obvious fix does not need this ceremony — follow
  `AGENTS.md` directly.
- Every "done when" MUST be decidable by `mix test`; loop until it is green rather than declaring
  victory early.
- Audits and open-ended reviews deliver GitHub issues, not inline fixes — use
  `/speckit.taskstoissues` as the bridge from a task breakdown to filed issues. Each fix then gets
  its own scoped session and PR; do not run "find and fix everything" rounds in one session.
- Route reviews to the matching specialist skill before merge: request/approval/role-gating
  changes → `approval-gate-reviewer`; LiveView/HEEx/component changes → `liveview-ui-reviewer`;
  release-name parsing/scoring/import changes → `release-parser-reviewer`. Non-trivial
  multi-PR features coordinate through `cinder-orchestrator`.
- Feature specs produced by Spec Kit live under `specs/NNN-slug/`. `ROADMAP.md` is the historical
  build record (Phases 0–5, M0–M8, A0–A6, B0–B8), not a live plan — read it only for the history
  behind a decision, never auto-import it.
- After modifying project source, run `graphify update .` to keep the local knowledge graph
  (`graphify-out/`) current; prefer `graphify query`/`explain` over re-reading the whole tree.

## Governance

This constitution supersedes conflicting practice. `AGENTS.md` is the canonical runtime
development-guidance file for coding agents working in this repository and MUST stay consistent
with the principles here; where the two conflict, update `AGENTS.md` to match this constitution
rather than the reverse.

Amendments land via a normal PR that edits this file, with a semantic version bump reflecting the
scope of the change (MAJOR: a principle is removed or redefined incompatibly; MINOR: a principle
or section is added; PATCH: wording/clarification with no behavioral change) and an updated
"Last Amended" date below.

Compliance is checked at two points: the "Constitution Check" gate in `/speckit.plan` for
non-trivial work, and normal PR review for everything else — including the repo-local reviewer
skills (`approval-gate-reviewer`, `liveview-ui-reviewer`, `release-parser-reviewer`) where a
change touches their domain.

**Version**: 1.0.0 | **Ratified**: 2026-09-28 | **Last Amended**: 2026-09-28
