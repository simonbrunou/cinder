### Internal
- **A parity report's link check that did not run now says why (#1954).** Its reason and
  evidence lines print the cause after `not_run`, in fixed words and closed tags that hold no
  title or link. The check runs before any retry, so it reads each search's first try:
  `no Native row in any first try`; `pick over its own first-try rows:` with the caller's pick
  over the indexer's own rows in each first try that held one, by the search's number, such as
  `#0 no_match`, or `no_link` when no row with the picked title and size has a link; `stopped`
  and the stop's reason, such as `stopped budget`; or `deadline passed`. A stop wins over a
  deadline that has also passed. Before, each of these printed `not_run` alone, so on #1687's
  second run telling them apart took more searches and reads on prod.
