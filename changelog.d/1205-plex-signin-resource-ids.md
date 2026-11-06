### Fixed
- **Sign in with Plex no longer depends on how plex.tv labels the household's server (#1205).**
  Cinder now looks for the server's machine id among every device plex.tv lists for the Plex
  account, whatever plex.tv says each device is or provides. Signing in with Plex and linking a
  Plex account from the settings page both run this check, and an account whose list lacks that
  id is still refused.
