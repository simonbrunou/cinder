### Fixed
- **Adding a magnet that Cinder cannot parse to qBittorrent no longer raises an error (#1179).**
  With qBittorrent as the download client, a magnet link holding a character such as `>`, `<` or
  a space could make adding the download raise an error, also when a `.torrent` link redirected
  to that magnet. qBittorrent's add step now refuses it as an unsupported download link and never
  sends it to qBittorrent.
