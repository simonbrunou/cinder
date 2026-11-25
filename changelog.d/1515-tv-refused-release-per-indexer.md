### Changed
- **When Cinder or the download client refuses for good a TV release that Cinder's own search
  for wanted episodes picks from now on, Cinder tries to block it only for the Prowlarr indexer
  that offered it, when that search result named one, so later automatic searches can grab the
  same release title from another indexer (#1515).** This covers an episode, a season pack or an
  anime episode, refused on its first try or on a retry after another error. A release you pick
  by hand from a season's release list is still not blocked when it is refused. Such a block
  still skips the title in a result from that indexer and in a Prowlarr result that names no
  indexer. In the release list of a season that is not anime, those two results show as blocked
  unless the list rejects them for another reason first, such as their size. A refused result
  that named no indexer, a release Cinder had already set aside for a retry before this update,
  and every other kind of block still skip the title from every indexer in the searches they
  applied to before. When two indexers offer the same download link, a search now keeps one
  copy for each indexer, so the copy from the indexer that is not blocked can be grabbed. Before,
  the block skipped the title from every indexer, so while it lasted no automatic search grabbed
  a good copy of the same release from another indexer.
