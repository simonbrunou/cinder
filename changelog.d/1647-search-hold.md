### Internal
- **The movie and TV pollers count no strike or attempt for a search that reached no indexer, and
  leave the movie, or the episodes that search covered, out of the search pass until the
  search's `retry_at` or for 60 seconds (#1647).** When an indexer source answers a movie,
  season or anime search with `{:indexers_backing_off, retry_at}` or `:no_indexers`, the poller
  counts no strike or search attempt for it. It then leaves the movie or episodes out of its
  search pass, with no search and no write, until `retry_at`, or for 60 seconds after a
  `:no_indexers` search (the pollers' `no_indexers_hold:` start option). A `retry_at` that has
  already passed holds nothing. The holds live in the poller process's memory, so a restart
  forgets them. While a season of a standard series is held, its other seasons search as before,
  and no visit of the series runs the anime fallback. Prowlarr returns neither error, so under it
  every search goes as before.
