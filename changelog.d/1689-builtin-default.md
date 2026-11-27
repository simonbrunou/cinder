### Changed
- **A new install preselects Built-in as its indexer source, unless `PROWLARR_URL` or
  `PROWLARR_API_KEY` is set and not blank (#1689).** With no stored source that is Prowlarr or
  Built-in, and neither variable set and not blank, the "Indexer source" select of `/setup` and
  `/settings` now shows Built-in, and searches go through Built-in. From the first load of
  `/setup`, its checklist then holds Finish as #1663 does for a saved Built-in: it needs an
  enabled indexer that works or waits out a rate limit, and, once a download client passed its
  check, one of a protocol such a client uses. A "Save & validate" in `/setup` that saves and
  leaves the select alone stores Built-in. A non-blank `PROWLARR_URL` or `PROWLARR_API_KEY` keeps
  such an install on Prowlarr, as before. The migration of #1651 stores Prowlarr on an install
  that had finished setup or stored a Prowlarr setting before this release, unless it already
  stores an indexer source. A stored Prowlarr or Built-in always wins, and Prowlarr stays an
  option. The Indexers group's help on `/setup` and `/settings` now reads "For Prowlarr, choose
  it above, add your indexers there, then copy its URL and API key from Settings > General."
