# Release source preference (web / Blu-ray / …) — design

**Date:** 2026-06-26
**Status:** approved, pre-plan

## Problem

The scorer can already filter/rank releases by **resolution** (`preferred_resolutions`, a
strict per-kind allow-list) and a size band, but there is no way to express a preference for the
release **source** — BluRay vs WEB-DL vs HDTV, etc. A user who wants Blu-ray (or who wants to
avoid HDTV/cam rips) has no lever today.

This adds a `source` dimension that **mirrors the existing `preferred_resolutions` machinery**,
with one deliberate behavioural divergence (untagged releases pass through — see below).

Out of scope (stays parked per ROADMAP "Quality upgrades & cutoffs"): named quality *tiers*,
upgrade *cutoffs*, re-grabbing an already-imported file because a better source appeared. This is
pure selection preference, exactly like resolution.

## Decisions (settled in brainstorming)

1. **Shape:** a separate `source` field parallel to resolution — not Radarr-style combined
   quality definitions.
2. **Default unset = accept any source** (empty list), *not* a populated default. There is no
   universal "everyone wants BluRay" the way everyone wants HD, so a populated default would
   silently filter existing installs. Empty-by-default = opt-in, non-breaking. The scorer's
   `allowed?(_, [])` → true already gives this.
3. **Untagged handling when a list IS set:** a release whose source the parser can't detect
   (`nil`) **passes through** (ranked last among sources). Only a *recognized but unlisted*
   source is rejected. This is the one divergence from `preferred_resolutions`, which rejects
   `nil` resolution. Rationale: source is missing from release names — and harder to parse
   exhaustively — more often than resolution, so strict-reject-untagged would strand otherwise-good
   grabs on a parser miss.
4. **Ranking priority:** resolution primary, **source secondary**, size tertiary. A 1080p WEB-DL
   beats a 720p BluRay. (Alternative source-primary ordering was considered and rejected as the
   unusual case.)

## Components

### 1. Parser — new `source` field (`parser.ex`, `release.ex`)

A `@sources` regex table, most-specific-first (same `first_match/2` mechanism as `@codecs`),
emitting downcased canonical tokens. Collision-prone 2-letter abbreviations (`ts`, `tc`, `bd`,
`scr`, `dsr`) are intentionally **excluded**, following the project's no-2-letter-token discipline
(the `vf` note in `@language_registry`).

| token    | matches                                              | notes |
|----------|------------------------------------------------------|-------|
| `remux`  | `remux`                                               | ordered first so it wins over `bluray` |
| `bluray` | `bluray`, `blu-ray`, `bdremux`, `brrip`, `bdrip`     | |
| `webrip` | `webrip`, `web-rip`                                   | checked before `webdl` |
| `webdl`  | `web-dl`, `webdl`, bare `web`                         | |
| `hdtv`   | `hdtv`, `pdtv`                                        | |
| `dvd`    | `dvdrip`, `dvd`                                       | |
| `cam`    | `cam`, `telesync`, `telecine`, `screener`            | |

All patterns `\b`-anchored. No match → `nil`.

- `Cinder.Acquisition.Release`: add `:source` to `defstruct`.
- `Parser.parse/1`: add `source: source(name)` to the returned map; add `:source` to the
  non-binary fallback map (all-`nil`).
- `source/1`: `first_match(name, @sources)`.

### 2. Scorer — `preferred_sources` filter + ranking (`scorer.ex`)

- `rules/1`: thread a `sources` value (`Keyword.get(rules, :preferred_sources, [])`). The
  returned tuple grows from 4 to 5 elements; both `select/2` and `select_for/4` updated.
- `allowed_source?/2` (new), run in **both** pipelines right after `allowed_resolution?`:
  ```elixir
  defp allowed_source?(_release, []), do: true
  defp allowed_source?(%Release{source: nil}, _preferred), do: true   # untagged passes
  defp allowed_source?(%Release{source: source}, preferred), do: source in preferred
  ```
- `source_rank/2` (new), mirroring `resolution_rank/2`: index in the preferred list, `nil`/unlisted
  sorts last.
- Ranking, source slotted after resolution, before size:
  - movie `sort_key` → `{resolution_rank, source_rank, -size}`
  - TV `greedy_key` → `{coverage, -resolution_rank, -source_rank, size}` (the `band`/`cover`
    threading carries `sources` so `greedy_key` can read it; source is **not** part of the
    per-episode size band, only the tiebreak).

### 3. Settings — per-kind `preferred_sources` (`settings.ex`, `settings_components.ex`)

- Add `"preferred_sources"` to `@band_suffixes` (149). This alone extends `flat_keys/0` (220),
  so form **load** (280) and **save** (616) handle the new key with no further change.
- `preferred_sources_key/1` helper (mirrors `preferred_resolutions_key/1`).
- `parse_sources/1` (mirrors `parse_resolutions/1`: csv → trimmed/downcased list, blank → `nil`).
- `apply_kind_config/2` (442): one more `parse_sources` + `Application.put_env(:cinder,
  :"#{kind}_preferred_sources", sources)`.
- `Acquisition.band_opts/2` (20): add `preferred_sources: Application.get_env(:cinder,
  :"#{kind}_preferred_sources")` (nil-rejected like the others → unset omits → scorer default `[]`).
  Both pollers already append `band_opts`, so movies and TV are configured identically for free.
- `settings_components.ex` (`:releases` group, ~129): one text input per kind, placeholder
  `bluray, webdl`, plus help text listing the valid tokens (`remux, bluray, webrip, webdl, hdtv,
  dvd, cam`).

## Testing

- **Parser** (`parser_test.exs`): one case per token; `remux` wins over `bluray`; `webrip` wins
  over `webdl`; bare `web` → `webdl`; an untagged name → `source: nil`; an excluded abbreviation
  (e.g. a title containing "TS") does not false-match.
- **Scorer** (`scorer_test.exs`): recognized-but-unlisted source rejected; untagged source kept;
  source tiebreak within the same resolution; empty `preferred_sources` accepts all; the
  `select_for/4` (TV) path honours the same filter + tiebreak.
- **Settings**: a round-trip proving a saved `movies_preferred_sources` overlays
  `:cinder, :movies_preferred_sources` and a cleared field reverts to nil/unbounded.

## Docs

- `CHANGELOG.md` `[Unreleased]`: new per-kind preferred-sources setting (additive, non-breaking).
- README + `docs/operating.md`: extend the band-tuning section with the source preference and the
  valid token list.

## Touch list

`lib/cinder/acquisition/release.ex`, `lib/cinder/acquisition/parser.ex`,
`lib/cinder/acquisition/scorer.ex`, `lib/cinder/acquisition.ex` (1 line),
`lib/cinder/settings.ex`, `lib/cinder_web/components/settings_components.ex`, the three test
files above, `CHANGELOG.md`, `README.md`, `docs/operating.md`. **No migration, no new machinery.**
