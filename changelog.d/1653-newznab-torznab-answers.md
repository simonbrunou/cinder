### Internal
- **A search through the native indexer source now returns the results of the Newznab and
  Torznab indexers whose caps take the query (#1653).** The `:indexer_adapters` app env maps
  `newznab` to `Cinder.Acquisition.Indexer.Newznab` and `torznab` to
  `Cinder.Acquisition.Indexer.Torznab`. A search through `IndexerSource.Native`, which a stored
  `indexer_source` of `native` selects, sends each configured indexer of those types that it asks
  the requests its caps can take, and returns the items of its RSS answers as rows. An item gives a
  row when its title is not blank and at most 1,024 bytes, and when it has a link the indexer's
  protocol carries: on a Torznab indexer the torrent file, else the magnet; on a Newznab indexer
  the NZB link. One answer gives at most 1,000 rows, and a link repeated inside one answer gives
  one row; the same link from two indexers gives a row each. A row records the base URL's origin
  as its link origin only when the link sits on that origin. The new
  `Cinder.Acquisition.Indexer.NewznabAnswer.classify/4` and `classify_caps/4` read each search
  and `t=caps` answer by the HTTP status and the `<error>` code into a closed class, and Native
  records it in the search report as the indexer's failure reason: rejected credentials, a limit
  with the time it ends (#1654), an HTTP status, an indexer error code, a bad
  response or a body over 4 MiB. In a search answer, an `<error>` code 200 to 203 or 300 fails
  only that request: the indexer is reported failed, and the other requests of the same search
  still run, unless a backoff or a credentials rejection that another search recorded meanwhile
  holds them back (#1655). Their rows are kept when another indexer answered; when none did,
  the search answers `{:error, {:no_indexer_answered, report}}` and those rows are lost (#1738).
  In a caps answer, every `<error>` code fails the indexer, and `<error code="100">` now reads as
  rejected credentials.
