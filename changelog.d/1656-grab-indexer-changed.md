### Internal
- **A waiting grab whose native indexer changed after the search is dropped before its fetch
  (#1656).** When Cinder is about to hand a reserved grab to its download client, after the client
  reported no job for it and its stored link read back, Cinder checks the grab's native indexer.
  It drops the grab, with no fetch, when that configured indexer was deleted, its secrets no
  longer decrypt, or its credentials version is newer than the one the grab recorded, and drops a
  native grab that recorded no indexer id or no credentials version. Whether the configured
  indexer is enabled plays no part. Cinder also drops a grab whose indexer source is no longer the
  selected one when its fetch fails with an error Cinder would otherwise retry, or with
  `:indexer_auth_failed`. Such a grab fails as `:indexer_changed` and blocks no release: the movie
  search pass takes no strike for it, the TV sweep spends no search attempt on it in that sweep,
  `Download.start/1` searches again after it, and Cinder holds a book target as it does for its
  other dropped grabs. A grab whose fetch through the selected source answers
  `:indexer_auth_failed` (#1658, #1659) is dropped too, blocks no release
  and counts as a failed grab where the grab call counts failures. A manual movie or
  TV grab shows its own message for each of the two failures, and a held book target reads a
  sentence for them and for `grab_retries_exhausted` and `bad_download_file`. The pass over
  waiting grabs that each download poller runs now stamps the poller's progress, which `/healthz`
  reads, after each grab it finishes.
