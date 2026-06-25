# Per-item preferred language — design (2026-06-25)

## Goal

Let a user choose, **per item** (per movie / per series), which audio language the
acquisition pipeline should grab — independent of the global "preferred format"
(`*_preferred_resolutions`) setting, which stays global. The household is bilingual
(fr/en): some titles they want in the original language, some they want in French.

A per-item choice means **deliberate intent**, so selection is **strict**: grab a release
that satisfies the chosen language, or park the item *visibly* — never silently grab the
wrong language. (Decision record below.)

## Decision record

Settled via a perspective-diverse council (strict vs prefer vs hybrid) and four user
decisions:

- **Strict, not prefer.** When the chosen language can't be satisfied, park the item rather
  than fall back to a wrong-language release. Rationale: this slice has **no
  quality-upgrade path**, so a prefer-fallback grab is *permanent and silent* (you find out
  at playback, recovery = delete + re-request). A strict park is *visible and recoverable*.
  Prefer is the right model for a global default; strict is right for a per-title pick.
- **Filter-only, ranking deferred.** Implement as a candidate filter before the existing
  scorer. Do **not** add `MULTI`-first / `exact > MULTI > nil` scorer ranking yet — add it
  only if a wrong-`MULTI` grab on a rare language is actually observed.
- **Menu = Original / French / Any.** Every item defaults to **Original** (its TMDB
  `original_language`) and can be set to **French** or **Any**. No separate "English" pick —
  Original *is* English for an English-original title.
- **Picker inline, at pick time.** A small `<select>` (Original / French / Any) in each
  search result's action row and one on the series detail page, pre-set to Original.
- **TV is per-series.** One language for the whole show (a field on `series`, mirroring
  `monitor_strategy`). No per-season language.

## Match model (the heart)

Resolve the user's pick to a concrete **target language code**, then test each parsed
release. For a title whose TMDB original language is `O`:

| pick        | target `T`                                  |
|-------------|---------------------------------------------|
| `"any"`     | — (filter disabled)                         |
| `"original"`| `O` (when `O` is known; else filter disabled)|
| `"french"`  | `"fr"`                                       |

A release **satisfies** target `T` when:

1. `release.language == "MULTI"` → ✅ (a multi-track release carries the wanted audio — a
   heuristic, accepted for filter-only), **or**
2. `tag(T) != nil` **and** `release.language == tag(T)` → ✅ (explicitly tagged in the
   target language), **or**
3. `release.language == nil` **and** `T == O` → ✅ (*an untagged release = original-language
   audio*).

where `tag/1` maps a TMDB code to the parser's language token:

```
"fr" -> "FRENCH"   "de" -> "GERMAN"   "es" -> "SPANISH"   "it" -> "ITALIAN"
"en" -> nil        (anything else) -> nil      # English / exotic langs have no positive tag
```

`release.language` is what `Cinder.Acquisition.Parser` already extracts (`"MULTI"`,
`"FRENCH"`, …, or `nil`).

### Why this rule is correct on the cases that matter

- **French film, Original (or French) pick** (`T=fr, O=fr`): untagged releases satisfy via
  rule 3, `FRENCH`-tagged via rule 2, `MULTI` via rule 1. The most common case no longer
  strands.
- **English film, Original pick** (`T=en, O=en`): untagged + `MULTI` satisfy; a
  `FRENCH`-tagged dub is **rejected** (no `tag("en")`, and rule 3 needs untagged).
- **English film, French pick** (`T=fr, O=en`): only `FRENCH`-tagged or `MULTI` satisfy;
  untagged-English is **rejected**. This is the case that *requires the parser widening* —
  French dubs ship as `VFF`/`VFQ`/`TRUEFRENCH`, which the parser must learn to tag `FRENCH`.

### Safety defaults

- `preferred_language` defaults to `"original"` on new rows.
- When the pick resolves to **no target** (`"any"`, or `"original"` with unknown
  `original_language`), the filter is **disabled** → today's behavior. This makes the
  feature backward-safe: existing rows (no `original_language`) behave exactly as before
  until re-requested.

## Data model changes

All additive migrations; the movie pipeline logic is otherwise untouched.

- **`movies`**: add `original_language` (string, nullable — TMDB code, set at creation) and
  `preferred_language` (string, default `"original"`). Cast `original_language` in
  `Movie.changeset/2` (creation) and both in a small edit changeset for the escape hatch.
  `preferred_language` is **not** pipeline state, so it does **not** go through
  `transition_changeset/2`.
- **`series`**: add the same two fields. Cast `original_language` + `preferred_language` in
  `Series.create_changeset/1`; **exclude both from `refresh_changeset/2` and
  `admin_changeset/2`** (user-controlled, like `monitor_strategy`, so a TMDB refresh / admin
  metadata edit never clobbers them).
- **`requests`**: add `preferred_language` (string, nullable) and `original_language`
  (string, nullable). Both are captured from the discover result at request time and carried
  onto the created Movie at approval (and onto the Series for a non-admin season request).
  Cast in `Request.create_changeset/2`.
- **`Cinder.Catalog.TMDB` behaviour + concrete impl + Mox mock — land atomically.**
  Add `original_language` to the normalized maps returned by **`search/1`**, **`search_tv/1`**
  (needed so the inline picker can default to / store Original *before* the item exists),
  **`get_movie/1`**, and **`get_series/1`**. The raw TMDB JSON already contains
  `original_language`; this is extraction only, no new request. Update the behaviour `@doc`
  map shapes and the Mox expectations in the same change (the project's behaviour-churn
  rule).

`seasons` / `episodes` get **no** language field (per-series only).

## Acquisition integration (filter, plumbing)

- A pure predicate, e.g. `Cinder.Acquisition.Language.satisfies?(release, target, original)`
  implementing the rule above, plus `resolve_target(pref, original)` and `tag/1`. ~15 lines,
  fully unit-testable.
- **Movies:** in `Acquisition.best_release/2`, `Enum.filter` the parsed releases by
  `satisfies?/3` **before** `Scorer.select`. The preference + `original_language` are read
  off the Movie row in `Download.start/1` and threaded as opts, mirroring the existing
  `band_opts/1` pattern. The existing `:no_match → park` path is unchanged.
- **TV:** insert the same `Enum.filter` into the `best_releases/4` chain **beside the
  existing `title_matches?` guard, before `Scorer.select_for`**. Because filtering happens
  *before* the greedy set-cover, the cover's existing **partial-coverage** path handles "some
  episodes have a French release, some don't" for free — unmatched episodes simply stay
  `wanted`. `TvPoller.search_group/1` reads the series' preference + `original_language` and
  threads it as an opt.
- **No `Scorer` ranking change.** `select/2`, `select_for/4`, `sort_key`, `greedy_key` are
  untouched (filter-only).

## Parser widening

In `Cinder.Acquisition.Parser` `@languages`, add French **audio-dub** markers mapping to
`"FRENCH"` (the table is ordered, `MULTI` stays first so it still wins):

```
TRUEFRENCH, VFF, VFQ, VFI, VF   ->  "FRENCH"     # (existing \bfrench\b stays)
```

`\bfrench\b` does **not** match `TRUEFRENCH` (no word boundary before "french"), so
`TRUEFRENCH` needs its own entry. **Deliberately do not map `VOSTFR` / `SUBFRENCH`** — those
are *original audio + French subtitles*, so they correctly fall to `nil` (= original audio):
they satisfy an **Original** pick but **not** a **French** (audio) pick. Add a fixture per
new marker (and a `VOSTFR → nil` negative fixture documenting the choice).

## UI

- **Movie discovery (`DiscoverLive`):** add a 3-option `<select>` (Original / French / Any)
  to each result's action row (`result_action/1`), pre-set to the result's
  `original_language`-derived "Original". The value reaches `handle_event("add", …)` via the
  form/`phx-value-*`; `add/2` puts `preferred_language` + `original_language` into the request
  attrs. Label the Original option with its language for clarity (e.g. "Original (French)").
- **Series detail (`SeriesDiscoveryLive`):** one `<select>` for the whole series, written to
  the `series` row on add. (TV add is admin-direct, so no request carry-through.)
- **Editing after add (the escape hatch UI):** a language `<select>` on the movie row in
  `/status` (and/or the watchlist) and on the series detail page; changing it triggers the
  re-search behavior below.
- daisyUI `select` per the existing `CoreComponents.input type="select"` pattern. New labels
  go through `gettext` (en/fr) like the rest of the UI.

## Escape hatch + visibility

This covers the gap that TV episodes have **no** manual retry (movies have `/status`
Retry; episodes don't).

- **Editing an item's `preferred_language` re-searches it:**
  - **Movie** parked at `:no_match` / `:search_failed` (or set to `"any"`) → reset to
    `:requested` with `search_attempts` zeroed (reuse `Catalog.retry_movie/1`) so the poller
    re-searches with the new preference. A `:requested`/`:searching` movie just updates the
    field. An `:available` / in-flight movie updates the field only — **no auto re-grab** (no
    upgrade path in this slice).
  - **Series** → zero `search_attempts` on its still-`wanted` episodes (`file_path IS NULL
    AND grab_id IS NULL`) so they re-enter the next sweep. Available / in-flight episodes
    untouched.
- **Visible "no language match":** when the pre-filter candidate set was non-empty but the
  post-filter set is empty (i.e. the park is *caused* by language, not by "nothing found"),
  the poller emits the existing `Cinder.Notifier` event with reason **`:no_language_match`**
  (`{:movie_failed, movie, :no_language_match}` / `{:grab_failed, grab,
  :no_language_match}`). Movie `status` stays `:no_match` — **no new status enum** — and
  `/status` surfaces the distinguishable reason ("No French release found"). The pipeline
  distinguishes the two cases at the `best_release` / `best_releases` boundary (return a
  richer no-match reason, or have the caller compare pre/post sets).

## Non-goals (explicit scope cuts)

- `MULTI`-first / `exact > MULTI > nil` scorer **ranking** — filter-only is correct now.
- **English** as an explicit pick (Original covers it).
- **Per-season** language.
- **Re-grabbing an already-`:available`** item when its language changes (no upgrade path).
- Backfilling `original_language` onto pre-existing rows (they behave as "Any" until
  re-requested; acceptable).
- Languages beyond fr/en in the menu (the parser already detects de/es/it, but they're not
  offered).

## Test plan

- **Parser:** fixtures for `TRUEFRENCH`/`VFF`/`VFQ`/`VFI`/`VF` → `"FRENCH"`; `VOSTFR` →
  `nil` (negative, documents the subtitle/audio distinction); existing language fixtures
  stay green.
- **`Language.satisfies?/3`** unit table: the five cases in "Why this rule is correct",
  plus `MULTI` satisfies any target, `"any"`/unknown-original disables the filter.
- **Acquisition (movies):** mixed release list + a French pick selects the French/`MULTI`
  release; an all-English list + French pick → `:no_match` with `:no_language_match`;
  Original pick on an English title accepts untagged, rejects a `FRENCH` tag.
- **Acquisition (TV):** a season where only some episodes have a satisfying release grabs
  those and leaves the rest `wanted` (partial coverage); an all-non-satisfying season parks
  with `:no_language_match`.
- **Escape hatch:** changing a parked movie's language resets it to `:requested`; changing a
  series' language zeroes `search_attempts` on wanted episodes only.
- **Request carry-through:** a non-admin movie request with a French pick, once approved,
  produces a Movie with `preferred_language: "french"` and the carried `original_language`.
- **Backward-compat:** a row with `preferred_language: "original"` and `original_language:
  nil` searches exactly as today (filter disabled). The whole movie suite stays green.

## Rough build order (for the plan)

1. Parser widening (+ fixtures) — standalone, highest-leverage, no dependencies.
2. TMDB behaviour/impl/mock: thread `original_language` (atomic).
3. Migrations + schema/changeset changes (movies, series, requests).
4. `Language` predicate module + acquisition filter wiring (movies, then TV) + poller opt
   threading.
5. UI: inline picker (movie + series), then the edit-to-re-search escape hatch +
   `:no_language_match` notifier reason.
6. Tests alongside each step; `mix test` (the alias) green throughout.

## Open questions / risks

- **`MULTI` is a heuristic** (could be English-primary with a token French track). Accepted
  for filter-only; the ranking refinement is the lever if it bites.
- **Parser coverage is the ceiling.** A French release tagged in a form not in the table
  parses to `nil` → looks like original audio. The widening covers the common French-dub
  markers; the escape hatch ("Any" / re-search) is the recovery for the long tail.
- **Real-world tag rates** on the household's actual Prowlarr are unknown; they decide how
  often strict-French parks. The escape hatch makes that recoverable rather than fatal.
- **`requests` gains two columns** for movie carry-through — accepted as the cost of the
  per-item requirement.
