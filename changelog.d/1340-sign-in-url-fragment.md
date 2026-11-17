### Fixed
- **Jellyfin sign-in, and the check of your Plex server that Plex sign-in makes, now send the same
  request under a Jellyfin or Plex URL with a `#` part, such as `http://jellyfin:8096#frag`, as
  under the same URL without the `#` part (#1340).** The Plex check is the one that Plex sign-in,
  linking a Plex account and the Plex sign-in health check share. Before, under such a URL,
  Jellyfin sign-in could send the name and password to the URL's own path instead of
  `/Users/AuthenticateByName`, and the Plex check could read that path instead of `/identity`: `/`
  for a URL with no path.
