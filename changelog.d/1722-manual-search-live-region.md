### Changed
- **Screen readers now announce a manual search that fails, misses an indexer or finds nothing
  (#1722).** The manual-search panel of a movie, a season and a book now holds its lines about
  the search in a live region (`role="status"`) that is on the page while the search runs. When
  the search ends, a screen reader announces the error, "Some indexers could not be reached;
  results may be incomplete.", the "Not every indexer answered: ..." line and "No releases
  found.". The result rows stay outside the region, so a search that ends with releases and none
  of those lines announces nothing. The error line also shows an icon beside its red text.
