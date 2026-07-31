# CLAUDE.md — Cinder

## What this is

Cinder is a single-household, self-hosted replacement for the Sonarr / Radarr / Seerr loop:
request a movie or TV series → find the best release → download it → import it into
Jellyfin/Plex. Built on Phoenix/LiveView.

**Status: released — v1.0.0 (2026-07-03).** Movies, TV (series/season/episode, season packs,
calendar), multi-user with a request→approval gate, and an opt-in per-title anime handling
profile are all shipped. Work is now incremental — issues, fixes, one-off features. There is no
"current phase."

`ROADMAP.md` is the **build record** (Phases 0–5, M0–M8, A0–A6), not a live plan — read it only
when you need the history behind a decision. It is deliberately *not* `@`-imported; don't
re-add the `@`. Per-feature design and plan docs live under `docs/specs/`, `docs/plans/`,
`docs/audits/`, and `docs/superpowers/`.

## Stack

- Ecto with `ecto_sqlite3` (single-household scale; not Postgres on purpose).
- UI via Tailwind + daisyUI (Phoenix 1.8 default). No React; shadcn does not apply here.
- Tidewave MCP is available in dev — prefer it (`project_eval`, `get_ecto_schemas`,
  `execute_sql_query`, `get_logs`) over guessing about the running app.

## Commands

- `mix test` — the project alias; runs `compile --warnings-as-errors`,
  `format --check-formatted`, `credo --strict`, then the suite. This is the source of truth for
  "is it green." Every "Done when" block in the roadmap checks against it.

## Architecture & conventions

- **External services are reached only through behaviours**: `Cinder.Catalog.TMDB`,
  `Cinder.Acquisition.Indexer`, `Cinder.Download.Client`, `Cinder.Library.MediaServer`. Never
  call TMDB / Prowlarr / qBittorrent / SABnzbd / Jellyfin / Plex directly from a context.
- The concrete impl is resolved from config at runtime (`Application.fetch_env!/2`, not
  `compile_env!` — the Mox mock is defined at runtime, so compile-time resolution breaks
  `--warnings-as-errors`); `config/test.exs` points each at its Mox mock. **Tests never hit the
  network or a real service.**
- Prefer searching indexers by IMDb id over free-text title — `Catalog.get_movie/1` carries
  `imdb_id` through for exactly this.
- Background work (download polling, import) runs under the supervision tree, not in the request
  path. Crash-recovery is a feature: prove it with a test.
- **Status and derived-state writes go through the Catalog choke-points.** A movie's `:status`
  and an episode's derived state (`file_path` / `part_file_paths` / `grab_id`) are written only
  inside `Cinder.Catalog` and its submodules under `lib/cinder/catalog/` — principally
  `Catalog.transition/3` (its `expect:` form is the race-safe poller write) and
  `transition_episode/3`, plus audited siblings that each own one
  lifecycle (grabs, upgrades, release verification, adoption, deletion, TMDB refresh). Each
  emits one broadcast, *after* commit. This is **not** "no direct `Repo` writes" — creation,
  deletion, monitor flags, language, counters and the refresh are all sanctioned direct writes.
  **Don't reconstruct the full set of write sites from memory, or from this file — it is long,
  it moves with every Catalog split, and it has been documented wrong here before.** Derive it:
  `rg -l 'Repo\.(insert|update|delete|update_all)' lib/cinder/catalog.ex lib/cinder/catalog/`
  (naming `catalog.ex` explicitly matters — the choke-points themselves live there, so a
  directory-only search reports that they don't write).
  The callers stay clean: `lib/cinder/download/*`, `acquisition.ex` and `lib/cinder/library/*`
  (bar `import_stage.ex`, which owns `import_stages`) hold no `Repo` *mutations* of their own —
  keep it that way; `download.ex` itself writes, but only its own `download_intents` tables.
  SQLite is pinned to WAL + `busy_timeout: 5000` (config across
  dev/test/runtime), so a web write racing the poller waits rather than erroring with "database
  busy" — but that only holds if writes don't sidestep the choke-point.
  - Movie **creation** is a separate insert: `Catalog.add_movie/1` and
    `Catalog.find_or_create_at_requested/2` (the only path reachable from a user action, gated
    by `Cinder.Requests`); creation is announced post-commit by `Cinder.Requests`
    (`{:movie_created, movie}`) so open `/` views update — the Catalog insert itself never
    broadcasts mid-transaction. The **approval gate lives in the data model**:
    `Cinder.Requests.create_request/2` is the only caller allowed to create a movie from a user
    action — a non-admin request never writes a `:requested` row until an admin approves.
    `auto_approve_all` is a live-read DB setting (`nil → false`), admin-written via `/settings`.

## Configuration: env vs in-app settings

Two tiers. **Boot-only keys stay environment variables** (needed before the DB/settings store is
up, or fixed per deployment): `SECRET_KEY_BASE`, `DATABASE_PATH`, `PHX_HOST` / `PHX_SERVER` /
`PORT`, `POOL_SIZE`, `RELEASE_NAME`. Everything else — external-service URLs,
API keys, the media-server choice — lives in the **`Cinder.Settings` store** (DB-backed,
editable in `/settings`, overlaid on env-as-bootstrap). Don't add new service env vars; add a
registry entry in `Cinder.Settings` instead. A registry-driven loader `Application.put_env`s the
stored values onto a one-time bootstrap snapshot at boot (a one-shot supervised child, after
PubSub/before the poller) and on every save, so DB overrides env, a cleared setting reverts, and
the contexts read the same keys unchanged. Secrets are Cloak-encrypted at rest (secret rows only;
key derived from `SECRET_KEY_BASE`) and never echoed back to the form. `/settings` is admin-gated
by real accounts (`UserAuth` `:require_admin`, inside the `:admin` live_session). Separately, an
optional HTTP Basic gate (`plug :basic_auth` in the `:browser` **and `:api`** pipelines,
`router.ex`) fronts *every* browser route and the `/api/v1` scope as a defense-in-depth edge: a
no-op when both `CINDER_BASIC_AUTH_USER` and `CINDER_BASIC_AUTH_PASSWORD` are unset, and
fail-closed (it raises) if exactly one is set. The read-only `/api/v1` scope adds its own gate on
top: `CinderWeb.Plugs.ApiAuth` + the SHA-256-hashed household key in `Cinder.ApiKey` (a raw
non-registry settings key, generated and shown once in `/settings`).

Signing salts (session + LiveView) are **derived from `secret_key_base` at runtime** in
`config/runtime.exs` — nothing crypto-related is committed. `signing_salt` is a salt, not a
secret; the secret is `secret_key_base`.

## Workflow

- One unit of work per session (an issue, a fix, a feature). `/clear` between them.
- Audits and open-ended reviews deliver **GitHub issues**, not inline fixes. Each fix then gets
  its own scoped session and PR. No "find and fix everything" rounds in one session.
- Start non-trivial work in plan mode; lay out the plan, get agreement, then execute.
- Define "done when" up front as something `mix test` can decide, then loop until it's green.
- Feature work goes on a branch and through a PR; `main` is PR-merged. (Chores like flake bumps
  have landed directly — acceptable, but default to the PR.)

## How to work in this codebase (behavioral principles)

> Adapted from the `andrej-karpathy-skills` guidelines (Forrest Chang, MIT-licensed), derived
> from Andrej Karpathy's January 2026 notes on LLM coding pitfalls. Restated for this project.
> These bias toward caution over speed; for a trivial one-line fix, use judgment.

**1. Don't assume; don't hide confusion; surface tradeoffs.**
State assumptions explicitly. If a request has more than one reasonable interpretation, present
them — don't silently pick one. If something is unclear, stop and name what's confusing rather
than guessing. If a simpler approach exists than the one asked for, say so. Push back when
warranted; honest disagreement is more useful than agreeable wrong answers.

**2. Write the minimum code that solves the problem.**
Nothing speculative. No features beyond what was asked, no abstractions for single-use code, no
"flexibility" or configurability that wasn't requested. If 200 lines could be 50, write the 50.
The test: would a senior engineer call this overcomplicated? If yes, simplify. (This is also why
the slice is movies-only and the DB is SQLite — resist the urge to generalize early.)

**3. Touch only what you must.**
Every changed line should trace directly to the request. Remove imports, variables, or functions
that *your* change made unused — but don't delete pre-existing dead code unless asked; mention it
instead. Keep diffs small and predictable.

**4. Define success criteria, then loop until verified.**
Turn imperative tasks into verifiable goals before starting. "Fix the bug" becomes "write a test
that reproduces it, then make it pass." "Add X" becomes "X works and `mix test` is green." Strong
criteria let you iterate independently; vague ones ("make it work") force constant check-ins. For
multi-step work, write the plan first.

## Session discipline

(The four principles above predate hooks/subagents/long autonomous sessions — these cover the gap.)

- Keep sessions bounded. If a debugging loop has run long and is going in circles, stop,
  summarize what's been tried and what's left, and start fresh rather than spiraling.
- `/clear` between units of work so stale context doesn't leak across them.
- When you finish a turn, the hooks run compile/format/credo/test — read their output and fix
  what you broke before moving on.

<!-- Dependency usage rules are auto-synced below this line by the `claude` library
     (`mix claude.install`). Do not hand-edit inside its markers; put custom guidance above. -->

<!-- usage-rules-start -->
<!-- usage-rules-header -->
# Usage Rules

**IMPORTANT**: Consult these usage rules early and often when working with the packages listed below.
Before attempting to use any of these packages or to discover if you should use them, review their
usage rules to understand the correct patterns, conventions, and best practices.
<!-- usage-rules-header-end -->

<!-- igniter-start -->
## igniter usage
_A code generation and project patching framework_

[igniter usage rules](deps/igniter/usage-rules.md)
<!-- igniter-end -->
<!-- usage_rules-start -->
## usage_rules usage
_A dev tool for Elixir projects to gather LLM usage rules from dependencies_

[usage_rules usage rules](deps/usage_rules/usage-rules.md)
<!-- usage_rules-end -->
<!-- usage_rules:elixir-start -->
## usage_rules:elixir usage
[usage_rules:elixir usage rules](deps/usage_rules/usage-rules/elixir.md)
<!-- usage_rules:elixir-end -->
<!-- usage_rules:otp-start -->
## usage_rules:otp usage
[usage_rules:otp usage rules](deps/usage_rules/usage-rules/otp.md)
<!-- usage_rules:otp-end -->
<!-- phoenix:ecto-start -->
## phoenix:ecto usage
[phoenix:ecto usage rules](deps/phoenix/usage-rules/ecto.md)
<!-- phoenix:ecto-end -->
<!-- phoenix:elixir-start -->
## phoenix:elixir usage
[phoenix:elixir usage rules](deps/phoenix/usage-rules/elixir.md)
<!-- phoenix:elixir-end -->
<!-- phoenix:html-start -->
## phoenix:html usage
[phoenix:html usage rules](deps/phoenix/usage-rules/html.md)
<!-- phoenix:html-end -->
<!-- phoenix:liveview-start -->
## phoenix:liveview usage
[phoenix:liveview usage rules](deps/phoenix/usage-rules/liveview.md)
<!-- phoenix:liveview-end -->
<!-- phoenix:phoenix-start -->
## phoenix:phoenix usage
[phoenix:phoenix usage rules](deps/phoenix/usage-rules/phoenix.md)
<!-- phoenix:phoenix-end -->
<!-- claude-start -->
## claude usage
_Batteries-included Claude Code integration for Elixir projects_

[claude usage rules](deps/claude/usage-rules.md)
<!-- claude-end -->
<!-- claude:subagents-start -->
## claude:subagents usage
[claude:subagents usage rules](deps/claude/usage-rules/subagents.md)
<!-- claude:subagents-end -->
<!-- usage-rules-end -->

## graphify

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

`graphify-out/` is gitignored — regenerate with `graphify update .` if it's missing.

Rules:
- For questions about **project source** (`lib/`, `test/`), run `graphify query "<question>"` first when graphify-out/graph.json exists. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- It does **not** apply to `deps/`, `_build/`, `config/`, `mix.exs`, or tooling/config files — the graph has nothing to say about those, so just grep/read them directly. The `graphify-nudge` PreToolUse hook (user-level, `~/.claude/hooks/graphify-nudge.py`) encodes exactly this scoping; if it nudges where it shouldn't, fix the hook's `EXCLUDE` list rather than working around it.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).
