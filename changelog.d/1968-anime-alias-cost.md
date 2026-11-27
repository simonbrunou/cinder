### Fixed
- **An anime search no longer works out the series' alias lists again for each release it reads
  (#1968).** An anime episode or movie search, as the sweeps, the manual-search panel and a
  parity compare run it, now works out once per search which aliases it searches, which it
  blocks and which scene titles it may read. A parity compare replays each search many times,
  so this cost ran a run on prod past its deadline. On a built run of two anime series with 8
  aliases each and 15 other searches, with 100 rows on each query, the compare took 66 s, where
  it took 318 s before. The anime searches alone took 64 s with 40 aliases a series and 57 s
  with 8. The search picks the same releases as before.
