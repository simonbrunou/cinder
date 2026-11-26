### Changed
- **Cinder now checks each download it fetches through a Prowlarr link before the download client
  gets it (#1658).** A body that is neither an NZB nor a torrent never reaches the client. Cinder
  handles a plain body of that kind as it handles a torrent the client cannot read, and an HTML
  page without a login form as a failed attempt. An NZB sent gzip-compressed reaches the client
  decompressed, unless it grows past the download's size cap. An answer that reached Cinder
  only through Prowlarr's own address and rejects Cinder's credentials drops the grab as one
  with rejected credentials: HTTP 401, a Newznab error 100 to 102 or 910 of at most 4 MiB on
  any status but 404, 410 or 429, a redirect to a /login path, or a login page on a 2xx, 401 or
  403 answer. Such an answer that asks Cinder to wait holds the grab, with no strike: HTTP 429,
  other than a Prowlarr "Indexer is disabled till" answer of at most 4 MiB, or a Newznab error
  500 or 501 about a limit, of at most 4 MiB, on any status but 401, 404 or 410. It waits until
  the stated time, or 1 h later when it states none. That time is between 1 min and 24 h later,
  or the grab's own retry delay if that ends later. A grab that keeps failing on an HTTP error
  status not sorted above, a Newznab error 900, or 500 or 501 not about a limit, on an HTTP
  200 answer, an HTML page without a login form, a redirect from https to http or too many
  redirects stops at its fifth attempt, and every earlier attempt but a wait counts. A movie
  still searching spends one of its search attempts on each of those attempts. A movie, or the
  episodes of a TV grab, are then searched again until their search attempts run out, and a
  book still monitored is held with "The indexer kept failing to send this download. Search again."
