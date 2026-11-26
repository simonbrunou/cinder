### Internal
- **`IndexerSource.Native.fetch_download/3` fetches a grab's Newznab or Torznab link while its
  configured indexer is the one the search used, and records in Native's backoff state the indexer
  failures and limits that the indexer's own answer shows, unless an edit changed the indexer, or a
  delete removed it, during the fetch (#1659).** It reads the configured indexer that the fetch
  options' `indexer_id` names, enabled or not, and answers `{:error, :indexer_changed}` with no
  request when that id is not an integer or the `credentials_version` is missing, the row is gone,
  its secrets no longer decrypt, or its credentials version is newer than the grab's: a key rotated
  after `GrabFailure.check/1` passed would otherwise be rejected for the old key's answer. A type
  that the `:indexer_adapters` map names no adapter for, or whose adapter has no
  `fetch_download/3` answers `{:error, :not_supported}` with no request.
  `Indexer.Newznab.Grab.fetch_download/3`, which the Newznab and Torznab adapters call, fetches the
  link with the configured indexer's base URL origin, read from the row, as the trusted origin. The
  origin stored with the link plays no part, so a link off the row's origin is DNS-pinned and
  refused at a private address. It waits for no slot of `Native.Lease`. It fetches through
  `Download.Client.Fetch.attributed/3`, a new function that returns `answer/3`'s answer beside
  whether a hop on the source origin, after only such hops, gave it. The answer goes through
  `DownloadCheck.check_classified/2`, a new function that returns `check/2`'s answer with the
  parser's class beside it. The check's reason decides what is recorded, and the existing transition
  of Native's backoff state (#1654) sets each wait. It records rejected credentials for
  `:indexer_auth_failed`, a limit for `{:indexer_limit, until}`, a failure step for
  `:indexer_disabled`, Prowlarr's "Indexer is disabled till", with the wait its answer states, if
  any, and a failure step for `{:indexer_error, code}`. The check gives these four reasons only for
  an answer whose every hop stayed on the row's origin. It records a failure step for
  `:challenge_page` and for a reason with a 5xx status when every hop stayed on the row's origin,
  and for `:https_downgrade` when a hop on the row's origin, after only such hops, sent that
  redirect. The backoff state drops the answer when the indexer's `config_version` changed during
  the fetch, or the indexer was deleted. Every other answer records nothing.
