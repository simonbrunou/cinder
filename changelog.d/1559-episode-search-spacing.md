### Fixed
- **With the default settings, a wanted episode's searches now spread over about 36 h, and the
  Rehunter searches a search-parked episode again a day later (#1559).** Cinder searched a wanted
  episode again 60 s after each miss, so it spent all 10 searches in about 10 minutes after the
  start of the air date, often hours before a US episode aired, then stopped. It now waits 1 min,
  4 min and 16 min after the first three misses, then 6 h after each later one. A download that
  fails or stalls counts as a miss, so from the fourth one on it also waits 6 h. With the Rehunter
  on (the default), a search-parked episode goes back to the search 24 to 30 h after its last
  search. Before, the metadata refresh that runs at every start and every 12 h by default reset
  that clock on each episode TMDB still listed, so those parked episodes waited for a manual
  Search.
