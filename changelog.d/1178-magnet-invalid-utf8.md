### Fixed
- **A magnet holding a byte that is not valid UTF-8 no longer makes the magnet check raise
  (#1178).** Before Cinder sends a magnet to Transmission or qBittorrent, it checks the magnet's
  trackers and web seeds (`tr`, `ws`, `as` and `xs`). A tracker or web seed whose decoded link
  held a byte that is not valid UTF-8, such as `%FF`, could make that check raise an error.
  Cinder now drops that tracker or web seed, as it drops one it cannot parse. A magnet holding
  such a byte without percent-encoding could make the check raise too: the check now refuses it.
  With Transmission as the download client, Cinder then reports it as an unsupported download URL
  without sending it to Transmission.
