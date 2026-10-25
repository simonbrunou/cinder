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
For a standard season the sweep and the panel also share the search (#837): one function,
`Cinder.Acquisition.judge_season/3`, builds the release list for both from one Catalog read
(`Cinder.Catalog.season_acquisition_context/2`). It derives the numbering bridge from the same
episodes and native seasons, searches the same alternate seasons, drops duplicate results and
freezes bridged episode ids, and the judge's mapping stage drops a bridged release whose numbering
resolves two ways, which the panel refuses and the sweep used to grab. One input still differs,
and `judge_season/3`'s doc names it: the still-wanted episodes. The sweep passes those it searches
this tick, because it grabs on its own and must not spend a release on an episode it is resting.
The panel passes every searchable one, backing off or parked included, because the operator may
search what the sweep is resting. That changes the verdicts and the set-cover's band, never the
releases judged.

## Considered options

- One entry point that also runs the search: the agreement tests would need the indexer mock, and
  because the two searches differ, the query would carry an automatic/manual switch. Once a
  standard season's two searches agreed (#837), `judge_season/3` became that entry point for it,
  outside the judge, and its agreement test uses the indexer mock.
- A stage list as data, with one shape per target kind and a separate panel projection: three
  shapes don't need it yet, and it would add a "release decision" term next to the release judge.
  #775 took a stage list once the anime kinds made five guards: one list for anime episodes, which
  need stages of their own (role, mapping), and one for every other guard. It still has no
  separate projection and no new term.
- Keeping the panel's simulation of the sweep: it had drifted twice on the language badge alone.

## Consequences

The panel's verdict column is unchanged: only the IMDb-scoped and anime guards say "title doesn't
match", because the Title.Year and season guards also reject for year evidence. The anime episode
guard (#699, for a TVDB-scoped result) rejects for a year too, but only for a name that carries
another series' year, which is a same-titled other series.

Since #836, a TV row's verdict is the set-cover's for that release alone
(`Scorer.verdict_for_season/4`). The set-cover bands by the still-wanted count, so the season guard
carries the still-wanted episodes, and `judge_season/3` passes the season's episode count for
both. A row covering no still-wanted episode, which the cover never takes, is banded by what it
carries (the episodes it names or resolves to, else the season's count for a pack), so an operator
upgrade still reads whether it fits.

Since #837 both paths take the numbering bridge's costs alike. A native season whose only wanted
episodes are parked stays native, so its scene twin isn't searched as an alternate season until
those episodes are filled, re-queued or unmonitored. With more than four alternate seasons
reaching wanted episodes, one reaching only backing-off episodes can take a slot from one reaching
an episode due this tick. A season wanting an episode doesn't search the alternate seasons that
reach only its imported ones, so the panel lists no bridged upgrade for those until nothing is
wanted.

An anime row the judge keeps carries the anime selection's own verdict: the anime policy, then the
quality rules, then the group wait. The group wait stays a verdict rather than a stage that drops
rows, because the episode cover needs the delayed releases, in indexer order, to know which
episodes to wait for.
