### Fixed
- **Every download client now refuses an `http://` or `https://` link from Prowlarr that does not
  parse, such as `https://indexer.example/a b.torrent`, as unsupported (#1230).** Cinder then
  drops the link's reservation, as it does for any unsupported link. Transmission and qBittorrent
  now refuse an `http://` or `https://` link before any request or DNS lookup when it does not
  parse (a raw space, `>`, `"`, `{` or `\`), is not valid UTF-8, or has no host, a port outside
  1 to 65535, user info or a fragment. SABnzbd and NZBGet refuse those links too, and also a link
  with no scheme, an `http:` link with no `//`, or another scheme, such as a magnet or `ftp://`
  link. Before, the client answered each of these links with another error, which Cinder retried
  with backoff. A link that Cinder refuses after a DNS lookup, because its host does not resolve
  or resolves to a private address, is still retried, and so is a redirect refused for its host,
  port, user info or fragment.
