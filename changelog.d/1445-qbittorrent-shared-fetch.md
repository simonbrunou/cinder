### Internal
- **qBittorrent fetches a `.torrent` link through the shared download-link fetch (#1445).** It
  had its own copy of the redirect checks that Transmission and NZBGet already share. The fetch
  keeps qBittorrent's 10 MiB cap and its 90 s wait per hop. It still follows at most 5 http(s)
  redirects, and still adds the magnet link that a redirect names, even after those 5.
