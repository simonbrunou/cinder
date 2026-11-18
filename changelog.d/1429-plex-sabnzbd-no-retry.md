### Fixed
- **Cinder no longer resends a Plex library scan or listing, or a SABnzbd job read, that got a
  408, 429, 500, 502, 503 or 504 answer or whose connection timed out, was refused or closed
  (#1429).** When Plex answered a library scan, a library listing or the plex.tv shared-user list,
  or SABnzbd answered a lookup of Cinder's jobs in its queue or history, a job's file list or a job
  removal, with one of those statuses, or the connection timed out, was refused or closed, Cinder
  sent the request up to three more times. It now sends it once and reports the first failure.

### Internal
- `Cinder.HTTPPolicy.bounded_request/2,3` now sends a request that sets no `retry:` option once,
  so a client that leaves out `retry: false` no longer gets Req's default retries (#1429). A
  request that sets `retry:` itself keeps that value.
