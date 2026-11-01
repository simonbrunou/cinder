### Fixed
- **The media server link follows Jellyfin when no type is saved and `PLEX_URL` is unset
  (#939).** In that case Cinder runs against Jellyfin, but the discovery and My requests pages
  linked at Plex when a Plex web URL was the only one configured. They now link at the Jellyfin
  web URL, or show no link when it is not set. Only an install whose stored settings lack the
  media server type reaches this: every save of the `/settings` form or the setup wizard stores
  one.
