### Internal
- **A parity run expects one Prowlarr query, not two, for each TV search call with a
  TVDB id to an indexer whose TV search caps, as the run read them, do not list `tvdbid`
  (#1933).** Prowlarr 3.1.0.5799, the version prod runs, skips the id-scoped search of
  `Cinder.Acquisition.IndexerSource.Prowlarr.search_tv/3` for such an indexer and writes
  no history entry for it. `Cinder.Indexers.ParityRun.IndexerSet.caps/3` now reads, after
  the caps read that gives the indexer's kinds, whether its TV search lists `tvdbid`, and
  `Cinder.Indexers.Parity.compare/1` expects one history entry per such call when it does
  not. An indexer whose TV search caps the run did not read still expects two: a stopped indexer,
  every indexer once the run is past its deadline, a Cardigann copy that does not run, Newznab
  or Torznab caps that cannot be read, and a Newznab or Torznab caps row that is no longer
  usable when read again after the kinds: its indexer was deleted, the row turned 7 days old,
  or another search stored the caps again after an edit of the indexer. Before, the engine
  expected two for every indexer, so in the first parity run of #1687 on prod every TV cell of
  Nyaa.si and Torrent9 read `uncovered (prowlarr_not_asked)`.
