# The sweep and the manual-search panel share one release judge

Automatic selection (the movie and TV sweeps) and the manual-search panel used to compose the same
stages by hand: protocol filter, title guard, audio pick, then `Scorer`. Which stages ran, and in
what order, differed per path, and two shipped bugs were one path skipping a stage (#634 listed
another film as acceptable; #692 skipped the title guard on anime movies). The panel also
re-simulated the sweep to decide its language badges. So for movies and TV seasons one release
judge (`Cinder.Acquisition.ReleaseJudge`) runs every stage once, in one order, and returns a row
for each release: kept, or the stage that dropped it, plus the verdict and language fact the panel
shows. The movie sweep takes its pick from the record, the TV sweep runs its set-cover over the
record's kept releases, and the panel renders the rows (#746).

The judge is pure: it takes parsed releases, and `Cinder.Acquisition` keeps the indexer searches.
The sweep and the panel still search differently for a season: both add alternate-numbered
seasons, but from different parts of the numbering bridge, and only the panel drops duplicates and
freezes bridged episode ids. So the judging is shared and the inputs are not.

## Considered options

- One entry point that also runs the search: the agreement tests would need the indexer mock, and
  because the two searches differ, the query would carry an automatic/manual switch.
- A stage list as data, with one shape per target kind and a separate panel projection: three
  shapes don't need it yet, and it would add a "release decision" term next to the release judge.
- Keeping the panel's simulation of the sweep: it had drifted twice on the language badge alone.

## Consequences

The panel's verdict column is unchanged: only the IMDb-scoped guard says "title doesn't match",
because the Title.Year and season guards also reject for year evidence. A TV row's verdict still
bands a pack by an approximate episode count, while the set-cover bands by the still-wanted count.
The anime movie and episode searches keep their own composition until #775.
