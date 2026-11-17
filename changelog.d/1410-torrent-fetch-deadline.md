### Fixed
- **qBittorrent and Transmission grabs now give each request for a release's `.torrent` file up
  to 90 seconds, not 60 (#1410).** Cinder sets 90 seconds for that download, since Prowlarr can
  take that long to fetch the file from a site behind Cloudflare, but a request still running
  after 60 seconds ended with a timeout. Each request of the download, a redirect's included, now
  gets up to 90 seconds in all. A magnet link needs no download and is unchanged, and so is
  NZBGet's `.nzb` download.
