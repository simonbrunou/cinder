### Fixed
- **The Search failed hint no longer blames the indexers for a movie the download client refused
  (#1721).** On `/activity` and My requests, the hint under a movie at Search failed now reads
  "Cinder couldn't search the indexers or hand a release to the download client. Open it to
  retry." It used to name only the indexers, which was wrong for a movie parked because the
  download client refused its release, or because handing a release to the client kept failing.
  The movie's row does not keep the cause that parked it, so the one hint names both.
