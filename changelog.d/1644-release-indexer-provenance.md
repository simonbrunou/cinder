### Internal
- **Release structs carry their indexer's source, name and credentials version (#1644).**
  `Cinder.Acquisition.Release`, `EbookRelease` and `AudiobookRelease` gain `indexer_source`,
  `indexer_name` and `credentials_version`. `new/1` copies them from the indexer map and reads an
  absent or nil `indexer_source` as `"prowlarr"`. `IndexerSource.Prowlarr` fills
  `indexer_source: "prowlarr"` and `indexer_name` from each result's `indexer` field. Three
  functions keep one result per link and indexer: Prowlarr's `merge_query_origins/1`, which runs
  when both of `search_tv/3`'s queries answer, `Cinder.Acquisition`'s `deduplicate_tv_releases/1`
  and `Cinder.Acquisition.Anime`'s `deduplicate/2`. Each now gives every indexer's result of a
  link it merges the indexer id, source, name, link origin and credentials version of that
  indexer's first copy, through the new `Release.put_provenance/2`. Before, every indexer's
  result of such a link carried the same link origin. The new `Release.from_book/1` builds the
  release a book grab reserves with the book release's provenance, so a new book download intent
  stores the release's indexer id when it is an integer, as a TV grab's does.
  `Kernel.inspect/1` of the three structs leaves out `download_url`, which can hold an indexer's
  API key.
