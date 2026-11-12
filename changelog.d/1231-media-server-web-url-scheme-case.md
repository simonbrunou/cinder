### Fixed
- **A Plex or Jellyfin web URL with an upper-case scheme now gives the same "Open in" link as its
  lower-case form (#1231).** Cinder reads the `http` or `https` scheme of the Plex and Jellyfin
  web URLs in any letter case, as RFC 3986 allows, and writes it lower-case in the link. So
  `HTTPS://plex.example.com` links like `https://plex.example.com`, and
  `Http://jellyfin.example.com` like `http://jellyfin.example.com`. Before, such a URL gave no
  link, as if no web URL were set.
