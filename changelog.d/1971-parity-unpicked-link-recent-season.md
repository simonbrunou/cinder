### Internal
- **A parity run's link check now fetches an indexer's first Native row with a link in the
  searches' first tries when no pick of a search's caller names a row of it with a link, and the
  run draws a season that airs now before the other seasons (#1971).** The row is the first in
  search order. It goes through the same fetch, budget and pass rules as a picked row. The report
  prints the check's class, then `(unpicked row)`, such as `passed (unpicked row)`, and such a
  pass counts as a passed link check in the verdict. An indexer with no Native row with a link in
  any first try still reads `not_run` with its reason. Before, the check read `not_run` whenever
  the caller picked none of the indexer's rows: on #1944's probe the title guard dropped every
  Torrent9 season row, whose names carry no year. The season draw now takes a season with an
  episode that aired from 30 days before the run's household date to that date before the
  imported seasons and the others, and the run searches the seasons right after the anime
  episodes, before the movies.
