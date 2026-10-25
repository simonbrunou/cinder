# The set-cover owns its pick order

A standard season's releases are picked by a greedy set-cover (`Cinder.Acquisition.Scorer`'s
`select_for/4`, and `select_for_ids/3` for anime). Its greedy step sorted by coverage before
`Scorer.rank_key/2`, and two callers worked around that order instead of the cover owning it
(#838). `Cinder.Acquisition.best_releases/4` re-ran the cover after a clean `:no_match` with
whole-season packs banded by the season's episode count (#268), because a pack banded that way on the
first pass would beat every in-band single behind it. The release judge kept untagged releases
under a soft "original" pick for movies only (#191), because an untagged season pack would beat
confirmed-original singles. Each new caller of the cover had to know both rules.

So the cover decides its order in one place, the `select_for/4` doc, and callers pass facts:

1. Two passes. The cover first bands every release by the still-wanted episodes it covers. Only
   when that selects nothing does it run again with each whole-season pack banded by
   `max(k, pack_episode_count)`, the season's real episode count: the season band. That second
   pass is the old retry, unchanged, alternate-season packs included.
2. Each greedy step takes a release whose language tag satisfies the audio target before an
   untagged one, then the one covering the most still-needed episodes, then the best
   `rank_key/2`. Within a pass, untagged then covers only what nothing tagged in that band can,
   which is #191's rule for `Scorer.select/2` carried to the cover. Across passes the band
   decides first: an untagged single in the still-wanted band is taken before a tagged pack that
   fits only the season band.

The TV sweep and the upgrade sweep both pass `pack_episode_count`, the season's episode count,
under the same name. For the upgrade sweep the first pass equals its old single pass: under
`full_claim_only` a native whole-season pack is claimable only when the whole season is wanted,
so the episodes it covers are the season's count, and that sweep passes no alternate numbering.
`select_for_ids/3` keeps one pass, banding a pack by `max(k, pack_episode_count)` at once,
because `Scorer.verdict_for_ids/2` has to agree with it for a release taken alone.

This refines ADR 0002's Consequences, which say the set-cover bands by the still-wanted count: it
does in the first pass, and bands a whole-season pack by the season's count only in the second.

## Considered options

- One greedy pass with the band in the key, `{language_rank, season_band?, -coverage,
  rank_key}`. It changes what the sweep grabs. With 4 GB per episode, E19 to E22 wanted, 1 GB
  singles for E19 and E20 only, and a 19.7 GB pack that fits only the season band, one pass takes
  both singles and the pack in the same search. The two passes take the singles, and the pack
  only on a later search where nothing in band covers the rest, so singles released meanwhile
  still win.
- Keeping the retry in `best_releases/4` and recording why. The sweep passed
  `season_episode_count` to arm the retry while the upgrade sweep passed `pack_episode_count` to
  its first pass: two names, two effects, for one fact.
- Leaving the language rank out of the cover until a season keeps untagged releases. Every pool
  the release judge hands the cover today is language-uniform (`:applied` keeps only matches,
  `:fell_back` keeps no match, and `:off` and an anime policy rank every release 0), so the rank
  changes no pick yet. Without it the judge's movie-only gate would still exist because of the
  cover's order.

## Consequences

The judge still keeps untagged releases for movies only, now as a product choice. Keeping them for
a season would let an untagged pack fill the episodes the tagged releases leave, and would move a
pool of untagged and wrong-tagged releases from `:fell_back` to `:applied`, dropping the
wrong-tagged ones. #882 decides it; opening the gate is one guard in
`ReleaseJudge.language_stage/3`.

`pack_episode_count` still means three things: the season's episode count in the cover, the count a pack
must claim under `full_claim_only` (#839), and the approximate count the panel's `Scorer.verdict/2`
bands a pack by (#836).
