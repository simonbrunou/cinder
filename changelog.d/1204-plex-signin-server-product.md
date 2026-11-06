### Fixed
- **Sign in with Plex works again (#1204).** plex.tv listed a Plex Media Server as a
  "controller" rather than a "server", so Cinder no longer found the household's server on any
  Plex account. Sign in with Plex then failed with "Plex sign-in failed", and linking a Plex
  account from the settings page failed with "Could not link your Plex account". The #1205 entry
  says how Cinder finds the server now.
