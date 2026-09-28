# Source-aware import-time upgrade — design

**Date:** 2026-06-27
**Status:** approved, pre-plan
**Follows:** PR #50 (release source preference) — this closes its deferred follow-up (review finding #5).

## Problem

The selection scorer now ranks releases `language → resolution → source → size` (PR #50). The
import-time upgrade comparator `Cinder.Library.Upgrade.better?/4` still ranks
`language → resolution → size` — it has no source axis. On a same-movie/same-episode collision
(a newly-grabbed file lands at the same library dest as an existing file), the importer can
therefore **discard a Blu-ray the scorer deliberately chose** over an imported WEB-DL at the same
resolution, because it sees a resolution tie and falls straight to size. Selection and
import-replace disagree on "better."

This makes the import-time *replace* decision consistent with selection, for **movies and TV**
(both paths are symmetric). It does **not** add re-grabbing for a better source — that stays
parked under "Quality upgrades & cutoffs."

## Why a schema column (not re-derivation)

The imported file is renamed to a clean `Title (Year).ext` / `Show (Year) - SxxEyy.ext` scheme
that **strips the source token**, so source cannot be re-parsed from the library filename at
comparison time. This is exactly why `imported_resolution` / `imported_size` /
`imported_language` are already persisted columns. `imported_source` joins them.

## Decisions (settled in brainstorming)

1. **Comparator ordering: mirror the scorer** — `language → resolution → source → size`. Source
   ranks *above* size (not as the weakest tiebreak), so "what the scorer picked" and "what import
   keeps" never disagree.
2. **No data backfill.** The migration adds `imported_source` nullable, default `nil`. Existing
   `:available` rows keep `nil`, which ranks last on the source axis — same convention as a nil
   resolution. Inert in practice: `:available` items aren't re-grabbed.
3. **Movies + TV both**, in one migration and symmetric code changes.
4. **Re-expose `Scorer.source_rank/2` as public.** It was made private in PR #50 (finding #7,
   "no external caller"); `Upgrade` is now that caller, so it goes back public, mirroring the
   already-public `Scorer.resolution_rank/2` (string-or-`%Release{}` clauses). Shared ranking, no
   duplicated helper.

## Components

### 1. Migration + schemas

- One additive migration: `add :imported_source, :string` (nullable) to `movies` and `episodes`.
- `Cinder.Catalog.Movie` (`movie.ex`): add `field :imported_source, :string`; add
  `:imported_source` to the `transition_changeset` cast list.
- `Cinder.Catalog.Episode` (`episode.ex`): same two edits.

### 2. Capture + persist the imported source

- `library.ex` movie path (`import_movie`, ~L60): `new_q` gains `source: parsed.source`.
- `library.ex` TV path (`place_episode`, ~L366): `new_q` gains `source: parsed.source`.
- `existing_quality/2` (~L97) and the movie `old_q` (~L107) gain `source: movie.imported_source`;
  the episode `old_q` (~L392) gains `source: ep.imported_source`. The returned `quality` map then
  carries `source` automatically.
- Persist sites add one key each:
  - `poller.ex` (~L188, movie import → `transition`): `imported_source: q.source`.
  - `catalog.ex` `finish_grab` (~L1018, episode quality): `imported_source: q.source`.
- Reset sites add `imported_source: nil` alongside the existing `imported_resolution: nil`:
  `catalog.ex` ~L689 and ~L754 (retry / cancel zeroing).

### 3. The comparator (`upgrade.ex`)

- `quality_better?/3 → quality_better?/4` (add `preferred_sources`): compare
  `{resolution_rank, source_rank, size}` lexicographically — i.e. better resolution wins; on a
  resolution tie a better (lower-rank) source wins; on a source tie the larger size wins. Still
  gated under the existing language-first `cond` in `better?`.
- `better?/4 → better?/5`: add a `preferred_sources` parameter, threaded to `quality_better?`.
- `new`/`old` maps documented as `%{resolution:, size:, language:, source:}`; moduledoc updates
  from "resolution preference, then size" to "resolution, then source, then size."
- `nil_baseline?` / `nil_q?` stay unchanged (they already key off resolution/size/language; a row
  with only `source` set never occurs, so source need not join the all-nil check).

### 4. Scorer (`scorer.ex`)

- `source_rank/2` goes from `defp` back to a public `def`, mirroring `resolution_rank/2`: a
  `def source_rank(source, preferred) when is_binary(source) or is_nil(source)` clause plus the
  `def source_rank(%Release{} = release, preferred)` clause. Body unchanged (`rank_in/2`).
  `sort_key`/`greedy_key` keep calling it; `Upgrade` now calls the string clause.

### 5. Call sites

- `library.ex` `upgrade?/2` (~L114) and `ep_upgrade?/3` (~L398): pass
  `preferred_sources(:movies)` / `preferred_sources(:tv)` as the new `better?/5` arg, where
  `preferred_sources(kind)` reads `Application.get_env(:cinder, :"#{kind}_preferred_sources")`
  (mirrors the existing `preferred_resolutions/1` helper).

## Testing

- **`upgrade_test.exs`:** same resolution + better source replaces; same resolution + worse source
  keeps; a resolution change still outranks source; a language change still outranks both; `old`
  source `nil` ranks last (a known source beats it at equal resolution); empty `preferred_sources`
  leaves the decision exactly as today (source ties → falls to size — regression guard).
- **`library` import test:** a same-resolution, higher-ranked-source release on a collision
  replaces the existing file and persists the new `imported_source`; a lower-ranked-source release
  is kept (no replace). Mirror an existing movie collision test; add a thin episode variant.
- **No-config invariant:** with `preferred_sources` unset, `source_rank` ties at `length([]) = 0`
  for all, so the comparator behaves byte-for-byte as before (covered by the empty-list test).

## Docs

- `CHANGELOG.md` `[Unreleased]`: import-time upgrade now honors the source preference (additive).
- The `Upgrade` moduledoc line is updated as above. No README/operating change — the user-facing
  setting (`preferred_sources`) already shipped in PR #50.

## Touch list

One migration; `lib/cinder/catalog/movie.ex`, `lib/cinder/catalog/episode.ex`,
`lib/cinder/library.ex`, `lib/cinder/library/upgrade.ex`, `lib/cinder/acquisition/scorer.ex`,
`lib/cinder/download/poller.ex`, `lib/cinder/catalog.ex` (3 sites); `test/.../upgrade_test.exs`,
a `library` import test; `CHANGELOG.md`.
