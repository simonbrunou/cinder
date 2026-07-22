# #159 — TVDB-split / TMDB-combined episode cardinality: decision record

**Date:** 2026-07-22 · **Status:** decided — no pipeline code this cycle; work deferred to #158 ·
**Scope:** standard TV (movies immune — IMDb-id only; anime unaffected — its own coordinate path)

## Problem

cinder's episode identity is TMDB-only. TVDB sometimes disagrees with TMDB on episode
*cardinality*, not just order: a "supersized" episode (The Office S4: TVDB E15+E16) or a two-part
finale (Grey's S11E24+E25, B99 S8E09+E10) that TVDB counts as two, TMDB folds into **one** episode
row. A source file numbered per TVDB (`S04E16`) then has **no TMDB episode slot**. This is an N↔1
cardinality mismatch, distinct from the 1↔1 reorder/offset case A6 (#133) / #157 already handle.

Evidenced entirely during **library adoption** (#158): The Office US (9 unmatched: S4E15–19,
S6E25–26, S7E25–26), Grey's Anatomy (S11E25), Brooklyn Nine-Nine (S8E10).

## What we confirmed (investigation + two review councils)

- **The evidenced cases are all adoption, and adoption bypasses the import pipeline.** The #158
  workaround sets `file_path` via `Catalog.transition_episode/2` directly; `Cinder.Library.Backfill`
  only annotates already-filed rows. Neither touches `Library.stage_episodes/2` (the live poller
  import path). So any guard added in `stage_episodes` would not see the migration files at all.
- **Live combined-file releases already import correctly.** A real `...S04E15E16.mkv` is parsed to
  `[15,16]`, lands on the E15 row, and the extra number is harmlessly ignored
  (`lib/cinder/acquisition/parser.ex:431-463`, `lib/cinder/library.ex:1426-1434`). The orphan only
  appears with *physically split* source files — the adoption shape.
- **The live standard path silently drops an unmatched file** (imports the matched, finalizes, only
  a `Logger.warning`; `lib/cinder/download/tv_poller.ex:192-221`, `lib/cinder/library.ex:1619-1624`),
  whereas the anime path holds the whole batch. Real, but reachable only via a live TVDB-numbered
  *pack* grab containing split files — uncommon, and not the evidenced shape.
- **The data model needs no migration for N→1.** `episode_coordinate_memberships` is many-to-many
  (`lib/cinder/catalog/episode.ex:41-43`); one episode can own both `S04E15` and `S04E16`
  coordinates, which `AnimeResolver.resolve/3` already treats as unambiguous. Standard search/import
  don't consult coordinates today — that wiring is #132.
- **`episodes.file_path` is a single scalar**, and `episode_state/2` derives `:available` from its
  truthiness (`catalog.ex:3462-3470`); shared-file deletion keys on path string-equality
  (`catalog.ex:2496`). A "stacked part-files" schema would fight all three for a payoff whose
  Plex/Jellyfin *episode* rendering is unverified.

## Decisions

1. **Do not add a live-path hold/gate now.** A gate in `stage_episodes` wouldn't touch the evidenced
   (adoption) cases, and on the only path it *would* affect (live pack grabs) it is net-negative: the
   true positive (a physically-split pack) is rare, while a whole-batch hold on any out-of-TMDB-range
   file would newly **block good episodes** on a completed-season pack that legitimately contains a
   recap/special/absolute-numbered/metadata-lag file. Standard grabs carry no reservation snapshot and
   match by exact `SxxEyy`, so holding the matched episodes buys no safety — it would cargo-cult the
   anime invariant onto a path that lacks it.

2. **Reject a stacked part-files schema.** The combined TMDB episode is the correct catalog artifact
   for a TMDB-shaped library; the TVDB halves are a source-packaging artifact. Never introduce N
   files per episode row.

3. **The real fix is an adoption-time reconciliation, owned by #158**, backed by **stored per-episode
   TVDB numbers** so the TVDB↔TMDB correspondence is *data, not filename inference* (cinder stores only
   `series.tvdb_id` today). With that data, #158 imports the cleanly-matched episodes and resolves the
   orphan **per-episode**: fold it onto the combined TMDB episode via the existing coordinate
   memberships + `dedupe_per_episode/1` keep-largest for a supersized recut; **hold** (never
   auto-discard) a genuine two-part finale, where keep-largest would delete a whole episode. No
   migration for the fold; never stack.

## Handoff to #158 (adoption feature)

When #158 is built, include:

- Store **per-episode TVDB numbers** during adoption/refresh (Sonarr API or air-order), so the
  correspondence is data.
- On import, **import the matched episodes** and reconcile each orphan per-episode: fold a supersized
  recut onto the combined TMDB episode (N:1 coordinate membership, `dedupe` keep-largest); **hold** a
  genuine two-parter for operator review; surface anything unresolved rather than silently dropping.
- This subsumes the silent-drop on the live standard pack path — fix it there, per-episode, not with a
  blind grab-level hold.

## Known limitations left open until #158

- The live standard path still silently drops an unmatched file from a TVDB-numbered pack grab. Rare
  (combined-file releases dominate); accepted until #158.
- The genuinely dangerous variant — a wrong-content file that *matches* a numerically-coincident TMDB
  slot when a fold shifts later numbering (offset within TMDB range) — is invisible to any
  hold-on-unmatched guard and is only correctable with the stored per-episode TVDB numbers above.
  Also #158/#132 territory.

## Related

#158 (adoption — owner of the fix), #132 (wire standard TV to `episode_coordinates`), #133/#157 (A6
anime alt-season coordinates — the 1↔1 mechanism this reuses), #88 (the 1-file→N-episodes transpose).
