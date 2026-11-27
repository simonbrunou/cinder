### Internal
- **A parity run now spaces each indexer between the sides of a search and between searches
  (#1969).** A side starts once `indexer_spacing_ms:`, 10,000 ms by default, has passed for each
  indexer it may reach since the last side, link check or caps read that sent that indexer a
  request. The run reads which indexers a side may reach from their stored caps or running
  Cardigann copy, so a movie-only indexer does not hold back a book search, and an indexer with no
  stored caps counts as reached. Requests inside one side go out as before. A try starts only when
  its first side's wait ends before the deadline, and its second side waits in full. The header's
  `Limits:` line prints the spacing. Before, the run started each side and each search at once,
  and on #1687's third run Torrent9 answered a limit and was stopped for the rest of the run.
