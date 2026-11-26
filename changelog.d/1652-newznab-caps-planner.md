### Internal
- **The request half of the Newznab and Torznab adapters, which no search calls yet (#1652).**
  `Cinder.Acquisition.Indexer.Newznab.plan/3`, which `Indexer.Torznab` shares, turns one seam
  call into the requests to send one configured indexer, each with its query origin, or into
  `{:not_asked, :caps}` when the indexer's `t=caps` answer cannot take any of them. It reads the
  caps from a new `native_indexer_caps` table, one row per configured indexer, which only
  `IndexerSource.Native.IndexerCaps` writes. When the row is missing, 7 days old or more, or
  stored under another `config_version` than the indexer's, `plan/3` fetches `t=caps` first,
  and a failed fetch answers `{:failed, tag}` with a closed tag. Deleting a configured indexer
  deletes its row. The caps answer is read as XML with the new `saxy` dependency, and a body
  that holds a document type declaration is refused as a bad response. No type maps to these
  modules in `:indexer_adapters` yet, so a native search still sends no request.
