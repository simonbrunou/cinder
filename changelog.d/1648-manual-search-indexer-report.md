### Changed
- **The manual-search panels show each result's indexer when the source names it, a text for
  each kind of search error, and the indexers that did not answer when the source reports them
  (#1648).** In the movie, TV and book panels, each result row shows the name of the indexer it
  came from, when the indexer source sends one. When the search's report lists an indexer that
  failed or was skipped, one line names each such indexer with its reason, such as "One (timed
  out)" or "Two (waiting until 14:35)". Times show in the household time zone, with the date
  first when the day is not today there. The Prowlarr source reports no indexer, so under it
  this line never shows. The anime movie and anime season panels now also show "Some indexers
  could not be reached; results may be incomplete." when a query of the search failed while
  another answered, unless the failed query had no enabled indexer or skipped every indexer
  that could take it. A failed search no longer shows "Couldn't reach the indexer. Try again."
  for every error: it says that no indexer answered, that no indexer is enabled, until when
  every indexer is waiting when the search skipped them all, that the search failed (an anime
  preference that cannot resolve, or a search that crashed), or, for any other error such as
  one from Prowlarr, "Couldn't reach Prowlarr. Try again."
