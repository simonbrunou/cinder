### Fixed
- **Anime series no longer grab a same-titled other show's episode from a title search (#871).**
  A result from the anime episode title search that starts with the series title or an alias is
  now skipped when the indexer reports a TVDB id on it other than the series' own, or when every
  year in its name is more than one off the series' year. A year that is part of the title or an
  alias ("Bubblegum Crisis 2040") does not count, and a series with no year skips the year check.
  When the indexer reports the series' own TVDB id on such a result, its year is not checked. A
  series with no TVDB id skips the id check, and duplicates of one result that report different
  TVDB ids, one of them the series', count as carrying none. The manual search does not list the
  skipped results, as it does not list a title-search result naming another title.
