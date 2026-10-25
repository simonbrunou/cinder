### Fixed
- **The media server link follows `PLEX_URL` when no type is saved (#806).** On an install with
  no media server type saved (saving the `/settings` form or the setup wizard stores one),
  `PLEX_URL` makes Cinder run against Plex, and the discovery and My requests pages now link at
  Plex too. With only a Jellyfin web URL configured, they show no link instead of linking at
  Jellyfin. Set the Plex web URL in `/settings` to get the link back.
