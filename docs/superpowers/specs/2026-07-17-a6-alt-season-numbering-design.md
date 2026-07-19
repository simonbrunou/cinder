# A6 — Alternate-season numbering via TMDB episode groups

**Date:** 2026-07-17 · **Status:** design · **Scope:** anime series only (standard TV tracked in
issue #132; movies immune — IMDb-id-only queries)

## Problem

Cinder's episode trees are TMDB-shaped, and every search query it emits uses that numbering.
TVDB-indexed indexers (NZBGeek et al.) answer TVDB coordinates. When the two providers disagree
about season boundaries, wanted episodes become unfindable:

- **Frieren (TMDB 209867, reported live 2026-07-17):** TMDB folds all 38 episodes into Season 1
  (deliberate TMDB "TV Bible" policy for continuously-numbered anime; `/tv/209867/season/2` is a
  404). TVDB splits 28+10. Real releases are TVDB-shaped (`Sousou no Frieren S2 - 01`,
  `S02E10` on nyaa). Cinder's queries — id-scoped `{TvdbId:<id>}{Season:1}`, free-text aliases,
  and the (dormant-anyway) coordinate query `"Frieren S01E29"` — can never match them
  (`lib/cinder/acquisition/anime.ex:556`, `lib/cinder/acquisition/indexer/prowlarr.ex:43-44`).
- **Re:Zero (TMDB 65942, A5 finding F2):** same class, different mechanism — recorded in
  `docs/audits/2026-07-14-a5-live-dogfood.md` as the A6 trigger.

There is **no mis-mapping risk**, only a discovery gap: a TVDB-numbered release resolves
`:unmatched` and is dropped at selection (`lib/cinder/catalog/anime_resolver.ex`), and a
TVDB-numbered batch holds at preflight (`needs_mapping`). The safety invariant already covers
the downstream side.

## Decision

Close the gap **inside TMDB** — no second metadata provider. TMDB's own *episode groups* often
publish exactly the alternate split (Frieren's "Seasons (Production)" group is Specials/28/10,
matching TVDB). Cinder already ingests episode groups (type 2 / Absolute) into
`episode_coordinates`; this phase ingests one **operator-chosen** season-shaped group per series
as `scheme: "scene"` coordinates and lights up the seams that are already wired for them.

Per the A0 finding (no metadata signal is safe to auto-trust), the group choice is **always an
explicit operator action** — Cinder never auto-picks a group, and the UI shows the derived
mapping before saving.

If A5/A6 evidence later shows a title TMDB has *no* usable group for, the external-provider
option (TheXEM / anime-lists) remains open — this design does not preclude it.

## Build

### 1. Data model (one migration)

- `series.scene_numbering_group_id` — nullable string; the TMDB episode-group id the operator
  chose. Nil = feature off for that series (default; today's behavior).
- Coordinates land in the existing `episode_coordinates` / `episode_coordinate_memberships`
  tables: `source: "tmdb"`, `scheme: "scene"`, `namespace: <group id>`,
  `canonical_value: "SxxEyy"` (`Episode.code/2` format), `precedence: :inferred`, one
  coordinate per episode in the group. No schema change — `scheme` is already an unconstrained
  string and the resolver matches non-"standard" schemes generically.

### 2. Sync (mirror `sync_absolute_coordinates`)

- TMDB behaviour: `get_episode_groups/1` + `get_episode_group/1` already exist. Extend
  `normalize_group/1` to keep `group_count`/`episode_count` (currently discarded — the picker
  UI wants them).
- New `sync_scene_coordinates(series, ...)` in `sync_series_identity/3`: when
  `scene_numbering_group_id` is set, detail-fetch that group and
  `Identity.replace_provider_coordinates(series, "tmdb", group_id, coords)` — the same
  delete-non-manual-then-reinsert flow, so a `:manual` correction survives every refresh
  (existing guard, `lib/cinder/catalog/identity.ex:101-121`).
- **SxxEyy derivation** (confirmed against live payloads, 2026-07-17): season number from the
  subgroup name when it parses (`"Season N"`/`"Nth Season"` → N, `"Specials"` → 0 — Re:Zero's
  "Separate Seasons" group uses the ordinal form), else the subgroup's `order` field (in every
  probed group, Specials sit at order 0 and "Season N" at order N); episode number = the
  entry's 0-based `order` within its subgroup, plus 1. Frieren's "Seasons" group Season-2
  subgroup carries canonical S1E29..S1E38 at orders 0..9 → `S02E01..S02E10`. The
  operator-facing preview makes a wrong derivation visible before it is ever saved.
- Drift behavior: a fetch failure or deleted group **keeps** the last-synced rows and logs —
  never silently strips search ability mid-cour. An episode absent from the group simply gets
  no scene coordinate (falls back to today's behavior for that episode).

### 3. Search (`Anime.episode_queries/3`)

- **Id-scoped alt-season queries (the load-bearing addition):** union the wanted TMDB seasons
  with the distinct scene-coordinate seasons covering still-wanted episodes, and emit
  `search_tv(tvdb_id, title, alt_season)` → `{TvdbId:<id>}{Season:2}` — the query a
  TVDB-indexed indexer answers with full-season coverage.
- **Coordinate queries:** zero code — `"scene"` is already in `@queryable_schemes`
  (`anime.ex:11`); persisting scene rows activates the free-text `"<title> S02E01"` family on
  the next sweep.

### 4. Resolution (`Anime.mappings_for_value/3`)

Parsed `"standard"` values (the parser emits `S02E01` as scheme "standard") additionally match
persisted `scheme: "scene"` rows by exact value. Today the "standard" branch matches *only* the
in-memory canonical mapping (`anime.ex:265-282`), which is what makes scene rows unreachable on
the parse side. Collision rule needs no new code: canonical mappings are `precedence: :manual`
and always outrank `:inferred` scene rows, so a value both know (e.g. `S01E05`) resolves
canonically; for Frieren the overlap is also literally the same episode ids.

### 5. Import

**No changes.** `mapping_snapshot` is frozen from `context.mappings` at grab time and already
includes persisted coordinates; with the resolver change, `S02Exx`-named files inside a grabbed
batch resolve through the snapshot in `AnimePreflight`. Every hold path (ambiguous, duplicate,
outside-set, unknown) is untouched.

### 6. UI (series detail, anime section)

An "Alternate numbering" picker: lists the series' TMDB episode groups (name, type label,
group/episode counts), shows a preview of the derived season mapping (e.g. "Season 2 → episodes
29–38") for the selected group, Save syncs immediately, "None" clears the column and deletes the
non-manual scene rows for that namespace. Admin-gated like the rest of the anime identity UI.

## Out of scope

- Standard TV path (issue #132 — the coordinates built here are series-level and reusable).
- Auto-detection of the right group (A0: never guess).
- External providers (TheXEM / anime-lists / TVDB API) — only if evidence shows a TMDB-group
  gap; Re:Zero's verdict comes from the probe.
- Movies, specials re-mapping beyond what the chosen group itself expresses.

## Done when

Conventions pass, plus a Frieren-shaped fixture (TMDB tree 1×38 + a Production-style group
28+10) proves, in order:

1. Choosing the group syncs scene coordinates (`S02E01` → episode-29's id, …, `S02E10` →
   episode-38's id) and re-running the refresh preserves a hand-added `:manual` coordinate.
2. `episode_queries` for wanted episodes 29–38 emits the id-scoped `{TvdbId}{Season:2}` query
   and a scene coordinate query.
3. A release named with TVDB coordinates (`... S02E01 ...`) resolves to the correct episode and
   is selected; before this change the same fixture yields `:no_match` (the A6 Done-when
   "failed before, passes after").
4. Import preflight maps a batch of `S02E01..E10` files to episodes 29–38 via the frozen
   snapshot; an unmatched file still holds the whole grab.
5. The full standard (non-anime) suite is byte-for-byte green.

## Probe results (2026-07-17 — all former open items resolved)

Live TMDB API probe against tv/209867 (Frieren) and tv/65942 (Re:Zero); raw JSON saved as
fixture source material.

- **Payload semantics confirmed:** group detail = nested `groups[]`, each with `name`,
  `order`, and `episodes[]` carrying a 0-based `order` plus the canonical
  `season_number`/`episode_number`. Frieren "Seasons" (type 6, id
  `679231eba8ce3489ceb57efc`): Specials(0)=26 / Season 1(1)=28 / Season 2(2)=10, Season 2 =
  canonical S1E29..E38 at orders 0..9 — exactly TVDB's split.
- **Type ids confirmed from live payloads:** 2=Absolute, 4=Digital, 5=Story Arc,
  6=Seasons/Production, 7=TV. Cosmetic only — selection is by group id.
- **Re:Zero verdict: F2 closes with this same mechanism.** All three of its type-6 groups
  model Season 2 as canonical S1E26..E50 (25 eps), matching scene `S02Exx`; the interleaved
  Re:PETIT shorts live in the Specials subgroup. No external provider (TheXEM / anime-lists)
  is needed for either evidenced case; that option stays parked unless a title with no usable
  TMDB group shows up.
- Caveat observed: group naming is free-form ("Seasons", "Separate Seasons", "S0", localized
  "剧集") and one Re:Zero group is a mislabeled type-2 single-bucket — reinforcing that
  selection is operator-only with a mapping preview, never automatic.
