### Fixed
- **Monitoring an episode or a season of an unmonitored series now marks the series monitored
  (#1557).** A series set to "None" and then given back a season with "Monitor all", or an
  episode with its checkbox, still read "Unmonitored" in its page header and in the library while
  Cinder searched the aired ones. Under "None", the badge turns back to "Unmonitored" once no
  season and no episode of the series is monitored, also after a file delete that stops
  monitoring or a TMDB refresh that removes an episode. Under "All episodes" or "Future
  episodes", unmonitoring episodes or seasons leaves the badge as it was.
