# The sweep and the manual-search panel share one release judge

Automatic selection (the movie and TV sweeps) and the manual-search panel used to compose the same
stages by hand: protocol filter, title guard, audio pick, then `Scorer`. Which stages ran, and in
what order, differed per path, and two shipped bugs were one path skipping a stage (#634 listed
another film as acceptable; #692 skipped the title guard on anime movies). The panel also
re-simulated the sweep to decide its language badges. So for movies and TV seasons one release
judge (`Cinder.Acquisition.ReleaseJudge`) runs every stage once, in one order, and returns a row
for each release: kept, or the stage that dropped it, plus the verdict and language fact the panel
shows. The movie sweep takes its pick from the record, the TV sweep runs its set-cover over the
record's kept releases, and the panel renders the rows (#746). The anime movie and episode
searches joined it in #775: their sweeps take the pick from the same record the panel renders.

The judge never searches: it takes the releases a search returned, and `Cinder.Acquisition` and
`Cinder.Acquisition.Anime` keep the indexer searches. Under an anime policy it reads the clock
once, so the group-wait verdicts and the pick agree. For anime episodes the judge first parses
each release and freezes its stable-id mapping, because its role and mapping stages read them.
The sweep and the panel still search differently for a season: both add alternate-numbered
seasons, but from different parts of the numbering bridge, and only the panel drops duplicates and
freezes bridged episode ids. So the judging is shared and the inputs are not.

## Considered options

- One entry point that also runs the search: the agreement tests would need the indexer mock, and
  because the two searches differ, the query would carry an automatic/manual switch.
- A stage list as data, with one shape per target kind and a separate panel projection: three
  shapes don't need it yet, and it would add a "release decision" term next to the release judge.
  #775 took a stage list once the anime kinds made five guards: one list for anime episodes, which
  need stages of their own (role, mapping), and one for every other guard. It still has no
  separate projection and no new term.
- Keeping the panel's simulation of the sweep: it had drifted twice on the language badge alone.

## Consequences

The panel's verdict column is unchanged: only the IMDb-scoped and anime movie guards say "title
doesn't match", because the Title.Year and season guards also reject for year evidence.

Since #836, a TV row's verdict is the set-cover's for that release alone
(`Scorer.verdict_for_season/4`). The set-cover bands by the still-wanted count, so the season guard
carries the still-wanted episodes, and the panel passes the season's episode count as the TV sweep
does. A row covering no still-wanted episode, which the cover never takes, is banded by what it
carries (the episodes it names or resolves to, else the season's count for a pack), so an operator
upgrade still reads whether it fits.

An anime row the judge keeps carries the anime selection's own verdict: the anime policy, then the
quality rules, then the group wait. The group wait stays a verdict rather than a stage that drops
rows, because the episode cover needs the delayed releases, in indexer order, to know which
episodes to wait for.
