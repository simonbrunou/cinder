### Fixed
- **Sign in with Plex works again (#1204).** plex.tv now lists a Plex Media Server as a
  "controller" rather than a "server", so Cinder no longer found the household's server on any
  Plex account. Sign in with Plex then failed with "Plex sign-in failed", and linking a Plex
  account from the settings page failed with "Could not link your Plex account". Cinder now also
  recognises the server by its product name, Plex Media Server.
