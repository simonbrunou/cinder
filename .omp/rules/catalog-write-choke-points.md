---
description: Status and derived-state writes must go through the Catalog choke-points; these caller modules hold no Repo mutations of their own.
globs:
  - lib/cinder/download/**
  - lib/cinder/library/**
  - lib/cinder/acquisition.ex
  - lib/cinder/acquisition/**
condition: 'Repo\.(insert|insert!|update|update!|delete|delete!|insert_all|update_all|delete_all)'
---

You are adding a `Repo` mutation to a module that is supposed to have none.

A movie's `:status` and an episode's derived state (`file_path` / `part_file_paths` /
`grab_id`) are written **only** inside `Cinder.Catalog` and its submodules under
`lib/cinder/catalog/` — principally `Catalog.transition/3` (its `expect:` form is the
race-safe poller write) and `transition_episode/3`, plus the audited siblings that each
own one lifecycle (grabs, upgrades, release verification, adoption, deletion, TMDB
refresh). Each emits exactly one broadcast, *after* commit.

`lib/cinder/download/*`, `acquisition.ex` and `lib/cinder/library/*` are callers. They
stay clean.

The two sanctioned exceptions, both owning their own table and nothing derived:

- `lib/cinder/library/import_stage.ex` owns `import_stages`.
- `download.ex` writes only its own `download_intents` tables.

If your write is neither of those, move it behind a Catalog choke-point instead.

If a new slice genuinely needs a **new** sanctioned direct-write site — a module owning its
own table and nothing derived, the way `import_stage.ex` owns `import_stages` — that is a
legitimate outcome, not a violation. Two conditions: call it out explicitly in the plan
rather than slipping it in, and when it lands add it to the exception list above *and* to
the corresponding paragraph in `AGENTS.md`. A rule that has silently gone stale is worse
than no rule, because it trains you to dismiss it.

This is **not** a blanket "no direct `Repo` writes" rule — creation, deletion, monitor
flags, language, counters and the TMDB refresh are all sanctioned direct writes *inside
Catalog*. Derive the current write sites rather than trusting this list: search for
`Repo\.(insert|update|delete|update_all)` across `lib/cinder/catalog.ex` and
`lib/cinder/catalog/`.

Why it matters concretely: SQLite is pinned to WAL + `busy_timeout: 5000` across
dev/test/runtime, so a web write racing the poller waits rather than failing with
"database busy" — but only while writes go through the choke-points.
