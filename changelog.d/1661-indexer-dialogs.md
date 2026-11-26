### Added
- **Add and edit Newznab and Torznab indexers from `/settings` (#1661).** "Add indexer" beside the
  indexers table opens a dialog: search the list of types by name or description, pick Newznab
  (any Usenet indexer with an API key) or Torznab (any torrent indexer with a Torznab API, or
  Jackett and Prowlarr), then fill the form and press "Save and test". Each Newznab and Torznab
  row gains an Edit button that opens the same form, saved with "Save". The form holds the name,
  the kind as text, the base URL, the API path (`/api` to start with), the API key, additional
  parameters for Newznab only, a priority from 1 to 50 (25 to start with; a lower number comes
  first in results) and Enabled. Each refused value shows its reason under its field, and focus
  moves to the first refused field. The API key is never shown: a saved key reads "•••• saved
  (leave blank to keep)", a blank key keeps it, a typed one replaces it and "Clear saved value"
  removes it. When the saved key can't
  be decrypted, the dialog says so, and an edit of other fields keeps it as it is. Saving an
  enabled indexer starts its Test, after an add and after an edit of the base URL, API path,
  additional parameters or API key, typed or cleared, unless a Test of it is still running.
  An edit of only the name, priority or enabled state starts none and keeps the last Test's
  outcome. A save of an indexer that another tab changed or deleted since the dialog opened is
  refused and says so. A Newznab or Torznab indexer whose base URL is your saved Prowlarr URL
  and whose API path is `/<number>/api` says in its form that Prowlarr drops results with no
  size or no categories and dates undated results now. Each dialog keeps keyboard focus inside
  it and closes on Escape. When it closes, after a save too, focus goes back to the button that
  opened it, or to "Add indexer" once the edited indexer is gone.

### Security
- **Request and LiveView event logs print `[FILTERED]` for the `secrets` parameter (#1661).**
  The indexer dialogs send the API key and its Clear box under `secrets`, so those logs print
  `[FILTERED]` in place of the key.
