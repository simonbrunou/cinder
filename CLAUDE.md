# CLAUDE.md — Cinder

## What this is

Cinder is a single-household, self-hosted replacement for the Sonarr / Radarr / Seerr loop:
request a movie → find the best release → download it → import it into Jellyfin. It is built on
Phoenix/LiveView. The current target is the **movies-only vertical slice**; TV, quality
upgrades, and multi-user are out of scope until that slice is solid.

The authoritative build plan is **@ROADMAP.md**. Read it at the start of every session and work
the current phase only.

## Stack

- Elixir / Phoenix 1.8, LiveView (HEEx).
- Ecto with `ecto_sqlite3` (single-household scale; not Postgres on purpose).
- HTTP via `Req`.
- UI via Tailwind + daisyUI (Phoenix 1.8 default). No React; shadcn does not apply here.
- Tests via ExUnit + `Mox`. Static checks via `credo`.
- Tidewave MCP is available in dev — prefer it (`project_eval`, `get_ecto_schemas`,
  `execute_sql_query`, `get_logs`) over guessing about the running app.
- Licensed **GPL-3.0** (see `LICENSE`).

## Commands

- `mix test` — the project alias; runs `compile --warnings-as-errors`,
  `format --check-formatted`, `credo --strict`, then the suite. This is the source of truth for
  "is it green." Every "Done when" block in the roadmap checks against it.
- `mix phx.server` — run the app (dev).
- `mix format` — format before committing.

## Architecture & conventions

- Four contexts mirror the pipeline: `Cinder.Catalog` (discovery), `Cinder.Acquisition`
  (release search/scoring), `Cinder.Download` (client + poller), `Cinder.Library` (import).
- **External services are reached only through behaviours**: `Cinder.Catalog.TMDB`,
  `Cinder.Acquisition.Indexer`, `Cinder.Download.Client`, `Cinder.Library.MediaServer`. Never
  call TMDB / Prowlarr / qBittorrent / Jellyfin directly from a context.
- The concrete impl is resolved from config (`Application.compile_env!/2`); `config/test.exs`
  points each at its Mox mock. **Tests never hit the network or a real service.**
- Prefer searching indexers by IMDb id over free-text title — `Catalog.get_movie/1` carries
  `imdb_id` through for exactly this.
- Background work (download polling, import) runs under the supervision tree, not in the request
  path. Crash-recovery is a feature: prove it with a test.

## Workflow

- One phase per session. Do not start a later phase until the current phase's "Done when" block
  passes. Commit at every phase boundary.
- Start non-trivial phases in plan mode; lay out the plan, get agreement, then execute.
- A phase's "Done when" block can be handed to `/goal` for an autonomous run.

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
- `/clear` between phases so stale context doesn't leak across them.
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
