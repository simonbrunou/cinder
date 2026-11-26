### Internal
- **A download client fetches a grab's http(s) link only through the indexer source its intent
  recorded, and an intent that records a source other than Prowlarr or the native one reaches no
  client's `add/2` (#1650).** `Cinder.Acquisition.IndexerSource` gains a `fetch_download/3`
  callback, and
  `IndexerSource.Prowlarr`'s calls `Cinder.Download.Client.Fetch.bytes/3` with the same arguments,
  as each download client did itself before. `Cinder.Download` now passes the four clients a
  `fetch:` function in `add/2`'s options, and each client fetches an http(s) link only through it,
  with the fetch options it used before. That function calls the `fetch_download/3` of the source
  the download intent recorded, never the configured one: an intent with no recorded source or with
  `prowlarr` uses Prowlarr's, and one with `native` uses `IndexerSource.Native`'s (#1651,
  #1659), unless Cinder dropped that intent first (#1656). It adds
  three keys to the fetch options: `indexer_source`,
  the recorded source or `"prowlarr"` when there is none, and the intent's `indexer_id` and
  `credentials_version`, each nil when the intent records none. When `Cinder.Download` is about
  to call `add/2` for an intent that records any other source, it makes no fetch and no `add/2`
  call, and hands the reason `:unknown_indexer_source` to `Cinder.Download`'s retry step, as
  it does a client error that is neither one of `Download.permanent_submission_errors/0` nor
  `:indexer_changed` or `:indexer_auth_failed` (#1656). A magnet
  link of an intent with no recorded source or with `prowlarr` still reaches a torrent client's
  magnet path with no fetch.
