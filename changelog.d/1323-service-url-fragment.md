### Fixed
- **A URL with a `#` part, such as `http://prowlarr:9696#frag`, set for Prowlarr, SABnzbd,
  qBittorrent, Radarr, Sonarr, a Readarr-compatible book manager, Jellyfin, Plex,
  Audiobookshelf, Hardcover, Open Library or LibreTranslate now reaches that service's API as the
  same URL without the `#` part does (#1323).** Cinder drops the part from the `#` on before it
  builds a request to that service. A URL that also holds a `?` part, such as
  `http://prowlarr:9696?x=1#frag`, still misses the API, as it does without the `#` part.
  Before, each of those requests went to the URL's own path instead of the API's, `/` for a URL
  with no path. Jellyfin sign-in, and the check of your server that Plex sign-in makes, still go
  to the URL's own path under such a URL, so remove the `#` part to sign in through them.
