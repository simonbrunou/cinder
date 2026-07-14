# A5 corpus re-run: TMDB/Prowlarr provider contracts vs A0 baseline

**Date:** 2026-07-14
**Phase:** A5 — Live dogfood and sign-off (`ROADMAP.md`, "Run the full A0 corpus again against
current provider behavior")
**Baseline:** `docs/audits/2026-07-12-anime-provider-contracts.md` (A0, corpus v1, decided
`tmdb_sufficient`)
**Corpus:** `test/support/fixtures/anime/corpus-v1.json`, version 1, 7 titles (one-piece, bleach,
attack-on-titan, demon-slayer, pokemon, re-zero, your-name) — unchanged since A0.

## Method

`mix cinder.anime.probe` was deleted in A4.5 once the A0 decision was recorded (ROADMAP: "the probe
tool and its 40k-line raw evidence dump were deleted ... once the decision was recorded in the audit
doc and git history"). For this re-run it was **temporarily resurrected into the working tree only**
— never committed — by pulling the four task files back out of git history at the commit just before
deletion:

```
lib/mix/tasks/cinder.anime.probe.ex
lib/mix/tasks/cinder.anime.probe/corpus.ex
lib/mix/tasks/cinder.anime.probe/http.ex
lib/mix/tasks/cinder.anime.probe/report.ex
```

restored via `git show 59dbb43:<path>` (`59dbb43` = parent of the A4.5 deletion commit `0389165`).
`mix compile` was clean against current `main` with no changes needed to the resurrected files. The
probe was run live against real TMDB (v4 bearer token) and real Prowlarr (prod credentials, sourced
from the CT121 prod cinder container's env — never printed), each request bounded at the tool's
built-in 15s timeout, and pointed at scratch output paths so the A0 baseline file was never touched:

```
mix cinder.anime.probe --json /tmp/a5-probe-out/rerun.json --markdown /tmp/a5-probe-out/rerun.md
```

Wall time: ~61s for all 7 titles (TMDB search/alternatives/details/episode-groups + Prowlarr search,
2 queries × 2 categories per title). No title failed; no retry was needed. The resurrected probe
files were discarded from the working tree after the run (`git checkout`/`git clean` — see below);
only this document is committed.

## Per-title results

| Title | Discovery (native/romaji/licensed) | Absolute-entries | Group-integrity | Specials | Prowlarr inventory | Status |
| --- | --- | --- | --- | --- | --- | --- |
| one-piece | pass (3/3 queries) | pass (1208 ≥ 1000) | pass (0 wrong mappings) | pass | recorded (50/query/category) | **pass** |
| bleach | pass (3/3 queries) | pass (419 ≥ 366) | pass (0 wrong mappings) | pass | recorded (50/query/category) | **pass** |
| attack-on-titan | pass (3/3 queries) | pass (97 ≥ 0) | pass (0 wrong mappings) | pass | recorded (50/query/category) | **pass** |
| demon-slayer | pass (3/3 queries) | pass (63 ≥ 0) | pass (0 wrong mappings) | pass | recorded (50/query/category) | **pass** |
| pokemon | pass (3/3 queries) | pass (1240 ≥ 0) | pass (0 wrong mappings) | pass | recorded (50/query/category) | **pass** |
| re-zero | pass (3/3 queries) | pass (138 ≥ 0) | pass (0 wrong mappings) | pass | recorded (50/query/category) | **pass** |
| your-name | pass (3/3 queries) | pass (0 ≥ 0, movie) | pass (0 wrong mappings) | pass (none required) | recorded (50/query/category) | **pass** |

7/7 titles pass, 0/7 fail. 51 pass-type checks (discovery/absolute-entries/group-integrity/specials,
plus the one-piece and bleach group-type checks) all passed; 28 `recorded` Prowlarr-inventory checks
are informational samples, not pass/fail gates — identical distribution to A0 (51 pass / 28 recorded,
0 fail there too).

## Prowlarr field coverage

Byte-identical to the A0 baseline:

| Check | Status | Evidence |
| --- | --- | --- |
| prowlarr-anime-category-sample | pass | `%{observed: 700}` |
| prowlarr-categories | pass | `%{complete: 1400, sampled: 1400}` |
| prowlarr-indexer-identity | pass | `%{complete: 1400, sampled: 1400}` |
| prowlarr-published-at | pass | `%{complete: 1400, sampled: 1400}` |
| prowlarr-sample | pass | `%{observed: 1400}` |

## Provider decision

```
Decision: tmdb_sufficient
A0 status: pass
Recommended next action: Proceed to A1 with TMDB as the metadata provider.
```

Identical to the A0 baseline decision. The "Future behavior contracts: 24 recorded" list (the static
catalog of not-yet-built release/resolver/preflight/snapshot behaviors) is also byte-identical
between the two runs — expected, since that list is derived from the corpus's own fixture data, not
from live provider responses.

## DRIFT vs the 2026-07-12 baseline

A0's expectation (ROADMAP A0 "Done when") was: TMDB finds every title under native/romaji/licensed
name, Prowlarr's anime category/fields are documented, and zero cases would produce an automatic
wrong mapping. **All three hold in this re-run — no contract check flipped status in either
direction (no pass→fail, no fail→pass) across the 79 pass/recorded rows.** A full-file diff between
the baseline markdown and the re-run markdown surfaces exactly two kinds of change, both expected
live-data churn rather than provider-contract regressions:

**1. TMDB discovery — two titles picked up extra alternate-title IDs (still all required IDs present)**

- `pokemon` / query "Pokemon" and "Pokémon": baseline observed 20 ids including `327899`/`327351`/
  `327354`; re-run observed 20 ids including `296540` instead. Set changed by a few entries at the
  tail (TMDB's alternate-titles list for a 25+ year old franchise churns); the expected id `60572`
  was present in both, so `discovery:*` stayed `pass` in both.
- `re-zero` / query "Re:ゼロから始める異世界生活": baseline observed `[65942, 328061, 328062]`;
  re-run observed `[65942, 328061, 328062, 328396]` — one new alternate-title id appeared. Expected
  id `65942` present in both; check stayed `pass`.
- `attack-on-titan` and `bleach` showed **zero** diff of any kind (not even inventory rows).

**2. Prowlarr live inventory — release lists rotated over the 2-day gap (expected; Prowlarr indexes rolling releases)**

- `one-piece`: the largest single delta. The baseline (2026-07-12) query window caught the "One
  Piece Heroines" movie release cluster (7/08–7/11) plus early EP1169 releases; the re-run
  (2026-07-14) window caught the *later* EP1169 release wave (7/12–7/14, e.g. new `[ASW]`,
  `[Onalrie]`, `[HatSubs]`, `[ToonsHub]` uploads) — both are within the indexer's most-recent-50
  sampling window per query/category, which is exactly the "recorded" (not pass/fail) contract.
  Sampled/complete counts stayed `50` per query/category and `1400`/`1400` overall — the coverage
  contract held.
- `demon-slayer`: two `[Mo7tas]` releases from 6/01 fell out of the top-50 window, replaced by two
  newer `[ShouryuuReppa] Mugen Ressha-hen` releases from 7/12.
- `your-name`: one release's filename changed representation only (`[NoobSubs].your.name...` →
  `[NoobSubs] your name...`, same size/date) — cosmetic dedup/normalization on Prowlarr's/indexer's
  side, not a new release.

**No absolute-entries, group-integrity, specials, or category/field-coverage check moved.** The
provider decision, its rationale, and the future-behavior-contracts list are unchanged. Net
conclusion: TMDB and Prowlarr's live behavior on 2026-07-14 is consistent with the A0 baseline within
the tolerance the A0 contracts were designed for (fixed required ids/thresholds, "recorded" sampling
for time-varying release inventory) — **no drift that affects the A0 provider decision or any
downstream A1–A4.5 assumption.**

## Disposition

The resurrected probe files (`lib/mix/tasks/cinder.anime.probe.ex` and the three files under
`lib/mix/tasks/cinder.anime.probe/`) were discarded from the working tree after this run — this
branch carries only this audit document, matching A4.5's rationale for deleting the tool (the
decision is recorded in the audit doc and git history, not in a standing one-shot script).
