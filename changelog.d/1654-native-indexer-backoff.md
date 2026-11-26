### Internal
- **The native indexer source now backs off an indexer that fails or hits a limit, and sends no
  request to one whose credentials were rejected (#1654).** A new `native_indexer_status` table,
  written only by `IndexerSource.Native`, holds one row per configured indexer, gone with it.
  Each Newznab or Torznab search answer, failed caps fetch and crashed search goes through its
  rules, unless the request started before an edit that raised the indexer's `config_version`.
  A failure (no connection, a timeout of its own, a body that does not parse or is over 4 MiB,
  an `<error>` code outside the credentials, limit and query sets, an HTTP status other than
  2xx, 401 and 429 with no `<error>` answer, or a crashed search) backs the indexer off for 1, 5,
  15 or 30 minutes, then 1, 3, 6, 12 and 24 hours, one step per failure. A DNS failure or a
  refused connection backs it off for 1 minute and climbs no higher than the first step.
  Prowlarr's HTTP 429 "Indexer is disabled till" backs it off until the wait the answer states,
  clamped to 1 minute to 24 hours, or for the next step when it states none. A limit (any other
  HTTP 429, or `<error>` code 500 or 501 that mentions a limit) waits the time the indexer
  states, else 1 hour, clamped to 1 minute to 24 hours, and the search report now carries that
  end where it carried no time before. A failure during a limit that has not ended keeps the
  limit and its end, and climbs one step for the next failure. A success steps the ladder down one
  and ends a failure backoff, but not a running limit. `<error>` codes 100 to 102 and 910 and
  HTTP 401 mark the credentials rejected, with no backoff: later searches send that indexer no
  request and report it failed, until a passing Test (`:test_success`, which #1657 is to
  record) or a rise of its `config_version`. Codes 200 to 203 and 300 change nothing. Each
  answer's times count from when it came in. A search skips an indexer in backoff and reports it
  skipped with the time its backoff ends; when it skips every indexer that could take the query,
  it answers `{:error, {:indexers_backing_off, retry_at}}` with the earliest such time, or 60 s
  after the search when that comes first and the deadline cut another indexer. A change to an
  indexer's base URL, API path, settings, FlareSolverr toggle or secrets raises its
  `config_version`, which ends its failure backoff and rejected credentials, not a limit. Every
  Newznab and Torznab request now gets one retry 2 s after an HTTP 502, 503, 504 or 408 answer,
  when the search deadline leaves time for it.
