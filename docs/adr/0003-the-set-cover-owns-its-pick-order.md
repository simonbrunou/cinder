# The set-cover owns its pick order

A standard season's releases are picked by a greedy set-cover (`Cinder.Acquisition.Scorer`'s
`select_for/4`, and `select_for_ids/3` for anime). Its greedy step sorted by coverage before
`Scorer.rank_key/2`, and two callers worked around that order instead of the cover owning it
(#838). `Cinder.Acquisition.best_releases/4` re-ran the cover after a clean `:no_match` with
whole-season packs banded by the season's episode count (#268), because a pack banded that way on
the first pass would beat every in-band single behind it. The release judge kept untagged releases
under a soft "original" pick for movies only (#191), because an untagged season pack would beat
confirmed-original singles. Each new caller of the cover had to know both rules.

So the cover decides its order in one place, the `select_for/4` doc, and callers pass facts:

1. Two passes. The cover first bands every release by the still-wanted episodes it covers. Only
   when that selects nothing does it run again with each whole-season pack banded by
   `max(k, n)`, where `n` is the episodes the pack holds: the season band. A native-season pack
   holds `pack_episode_count`, the season's real episode count. That second pass is the old
   retry, except for an alternate-season pack: it holds the distinct native episodes its
   numbering maps (#895), or the native episodes of the season its mappings name, searched or
   not, when that count is larger (#1117). The old retry gave it the native count, so a scene S02
   holding 12 of native S01's 24 episodes was sized as 24.
2. Each greedy step takes a release whose language tag satisfies the audio target before an
   untagged one, then the one covering the most still-needed episodes, then the best
   `rank_key/2`. Within a pass, untagged then covers only what nothing tagged in that band can,
   which is #191's rule for `Scorer.select/2` carried to the cover. Across passes the band
   decides first: an untagged single in the still-wanted band is taken before a tagged pack that
   fits only the season band.

The TV sweep (through `Cinder.Acquisition.judge_season/3`, since #837) and the upgrade sweep both
pass `pack_episode_count`, the season's episode count, under the same name. For the upgrade sweep
the first pass equals its old single pass: in its cover (`Scorer.select_upgrades_for/4`, which
runs both passes) a native whole-season pack is claimable only when the whole season is wanted,
so the episodes it covers are the season's count, and that sweep passes no alternate numbering.
`select_for_ids/3` keeps one pass, banding a pack by `max(k, pack_episode_count)` at once, because
`Scorer.verdict_for_ids/2` has to agree with it for a release taken alone.

This refines ADR 0002's Consequences, which say the set-cover bands by the still-wanted count: it
does in the first pass, and bands a whole-season pack by the season's count only in the second.

## Considered options

- One greedy pass with the band in the key,
  `{language_rank, season_band?, -coverage, rank_key}`. It changes what the sweep grabs. With
  4 GB per episode, E19 to E22 wanted, 1 GB singles for E19 and E20 only, and a 19.7 GB pack that
  fits only the season band, one pass takes both singles and the pack in the same search. The two
  passes take the singles, and the pack only on a later search where nothing in band covers the
  rest, so singles released meanwhile still win.
- Keeping the retry in `best_releases/4` and recording why. The sweep passed
  `season_episode_count` to arm the retry while the upgrade sweep passed `pack_episode_count` to
  its first pass: two names, two effects, for one fact.
- Leaving the language rank out of the cover until a season keeps untagged releases. Every pool
  the release judge handed the cover before #882 was language-uniform (`:applied` kept only
  matches, `:fell_back` kept no match, and `:off` and an anime policy rank every release 0), so
  the rank changed no pick yet. Without it the judge's movie-only gate would still have existed
  because of the cover's order.

## Consequences

With the cover owning the language rank, #882 opened the gate: under a soft "original" pick the
judge keeps untagged releases for a TV season as it does for a movie
(`ReleaseJudge.language_stage/3`). An untagged pack now fills the episodes the matching releases
leave, including an episode no matching release in the pool can cover, which used to wait as
long as any matching release of the season was listed. A pool of untagged and wrong-tagged releases
moves from `:fell_back` to `:applied` and drops the wrong-tagged ones, where a wrong-tagged pack
used to win a tie against an untagged one by input order. The relaxation still doesn't apply to
the strict picks (french, dual) or to the anime episode guard.

The upgrade sweep judges its season list with the same guard
(`Acquisition.best_upgrade_releases/4`), so it now can grab an untagged release for a held
episode whose file carries no tag matching the pick, when `Upgrade.candidate?/4` ranks the
release better, even when the pool also holds a match. For a non-English target and a held file
whose tag matches it, `candidate?/4` ranks an untagged release a language downgrade, so the sweep
skips an untagged single for it. (For an English target an untagged release already matched,
before #882 too, and quality decides.) A release covering several episodes is grabbed when
`candidate?/4` accepts any one of them; the import's arbitration then decides each held file. In
the upgrade sweep's cover an untagged whole-season pack still can't fill one episode a matching
single leaves, since it must claim every episode it carries.

`pack_episode_count` still means two things: the season's episode count, which the cover and the
panel's season verdict read (`Scorer.verdict_for_season/4`, #836), and the count a pack must claim
in the upgrade sweep's cover, `Scorer.select_upgrades_for/4` (#839).
