### Changed
- **Cinder no longer retries a failed Jellyfin or OpenSubtitles read on its own (#1414).** When
  Jellyfin answered a read, such as the user list or the library inventory, or OpenSubtitles
  answered a subtitle search, with a 408, 429, 500, 502, 503 or 504 status, or the connection
  timed out, was refused or closed, Cinder sent the read up to three more times, a few seconds
  apart, before it reported the error. It now reports the first failure.

### Internal
- `Cinder.HTTPPolicy.bounded_request/2` now gives a request whose `receive_timeout` is above 60
  seconds that value as its total deadline, so no client passes it twice (#1414). Prowlarr
  searches, the torrent fetches and a LibreTranslate batch with a timeout above 60 seconds keep
  the deadlines they had. A LibreTranslate timeout under 60 seconds now limits each wait for an
  answer within a 60-second batch, as it did before #1200. A test in `test/code_health/` fails a
  configured service URL that reaches a request without `HTTPPolicy.without_fragment/1`.
