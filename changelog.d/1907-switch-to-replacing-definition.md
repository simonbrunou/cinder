### Added
- **Switch to <name> for a Cardigann indexer whose definition was replaced upstream (#1907).** A
  row whose definition reads "Replaced by <name>" shows Switch to <name>. When Cinder can run the
  new site's copy, it opens the form on that copy with the indexer's name, priority and Enabled,
  each checkbox and select value whose setting the new copy keeps as the same kind and accepts
  the value of, and the new copy's first address; otherwise it says the replacing definition
  can't be used. Above the fields, the form lists each host the save would send the indexer's
  credentials to that the indexer does not send them to today, read again as you change the
  address, a setting or a secret, with a host that a secret fills shown as its template. An
  indexer that holds no credential it sends today lists every such host. Saving moves the
  indexer to the new definition and keeps each stored secret whose setting the new copy declares
  as text or password, unless you type a new value or tick its Clear box. A save whose host list
  differs from the one the form showed is refused and shows the new list. While the indexer's
  stored secrets cannot be decrypted, the save goes through only once you type or clear every
  secret the new definition declares, and until then the form asks you to and lists no host.
  Switching drops the indexer's grabs still waiting to be sent, and the form says so.

### Fixed
- **Saving an indexer's Edit form with the name cleared no longer crashes the settings page
  (#1907).** The save is refused, and the form stays open and asks you to enter a name.
