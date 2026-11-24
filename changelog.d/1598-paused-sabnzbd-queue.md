### Fixed
- **The time a SABnzbd queue is paused no longer counts toward a download's stall limit, except for
  a Force job (#1598).** A waiting job's badge now reads "Paused by download client" instead of
  "Downloading" or "Upgrading" with `0m 0s remaining`. Once Cinder records the pause, that time no
  longer counts toward the no-progress limit (24 hours by default), so the release is not removed
  or blocklisted for that wait. A job with SABnzbd's Force priority keeps its normal badge and
  limit, because SABnzbd keeps it downloading through a pause, except while post-processing holds
  the queue. A job paused or failed on its own in SABnzbd is handled as before. The #1602 entry
  covers a download that NZBGet, qBittorrent or Transmission holds.
