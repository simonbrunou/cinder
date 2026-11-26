### Internal
- **The native indexer source sends each configured indexer one request at a time, at least 2 s
  apart, with manual searches first (#1655).** A new supervised `IndexerSource.Native.Lease`
  holds one slot per configured indexer, not per host, so two indexers on one Prowlarr or Jackett
  host are still asked at once. Every Newznab and Torznab search request and caps fetch waits for
  its indexer's slot (`Indexer.leased/4`) and holds it while it is sent and its answer recorded
  in the backoff state (a caps fetch that succeeds records nothing). The slot frees then, or when
  that process dies. The next request to that indexer starts at least 2 s after the previous one
  ended. The one retry that `Indexer.request/3` gives an HTTP 502, 503, 504 or 408 is sent inside
  the same hold, `retry_delay_ms` (2 s) after the first answer, when the deadline leaves more time
  than that. A request granted the slot reads
  the backoff state again before it is sent, so one queued behind a failure or a credentials
  rejection sends nothing and reports that backoff or rejection. The manual-search panels run
  their search inside `IndexerSource.interactive/1`, so their requests are granted before every
  poller request waiting for the same indexer; a request already running is not cut. A request
  still waiting at the search's 90 s deadline is never sent, changes no backoff state and reports
  its indexer skipped by the deadline. An indexer that answered an earlier query of the same
  search keeps that answer's rows and reads as asked. A search where no indexer answered or
  failed and one or more were skipped by the deadline or backing off answers
  `{:error, {:indexers_backing_off, retry_at}}`, which the pollers hold on as before: `retry_at`
  is the earliest of each backing-off indexer's backoff end and, when the deadline skipped one,
  60 s after the search.
