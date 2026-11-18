### Changed
- **Cinder now refuses at once, without retrying, a magnet link named by the sixth redirect of an
  NZB link for SABnzbd (#1444).** The SABnzbd fetch answered "too many redirects" there before, a
  submission error Cinder retries. Now it answers that the download client can't use the link, a
  submission error Cinder does not retry, as it already answered for a magnet named by an
  earlier redirect.

### Internal
- **SABnzbd fetches an NZB link through the shared download-link fetch (#1444).** It had its own
  copy of the redirect checks that the torrent clients and NZBGet already share. The fetch keeps
  SABnzbd's 20 MiB cap and its 15 s limit on each wait for data, and still follows at most 5
  http(s) redirects.
