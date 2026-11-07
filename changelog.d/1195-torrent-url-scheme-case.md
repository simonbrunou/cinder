### Fixed
- **Torrent links with an upper-case scheme now download (#1195).** qBittorrent and Transmission
  read a release link's scheme in any letter case, as RFC 3986 allows. A `MAGNET:` or `Magnet:`
  link, an `HTTP://` or `HTTPS://` torrent URL, and a download link that redirects to `MAGNET:`
  now go through as their lower-case forms do. Before, Cinder dropped these releases as
  unsupported, except that Transmission fetched an `HTTP://` or `HTTPS://` URL and kept retrying
  such a magnet. Transmission now drops a `MAGNET:` link it cannot parse, and a link that is
  neither a magnet nor an `http://` or `https://` URL, at once, as qBittorrent does, instead of
  retrying it.
