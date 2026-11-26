### Internal
- **A native indexer source, which no page offers yet (#1651).** A new `indexer_source` setting,
  which `/settings` does not show, names the source a search uses when its caller names none:
  `prowlarr` or `native`. A migration stores `prowlarr` on an install that has finished setup or
  stores any Prowlarr setting, unless it already stores an `indexer_source`. With no stored value,
  or one that is neither option, Cinder uses Prowlarr. Every search in Cinder runs through the
  configured source, so every install searches through Prowlarr until `Cinder.Settings.put/2`
  stores `native`. `IndexerSource.Native` asks each enabled configured indexer whose secrets
  decrypt and whose FlareSolverr toggle is off, unless it is backing off or its credentials were
  rejected (#1654), in a process of its own, through the adapter its
  type maps to in the `:indexer_adapters` app env, under one 90 s deadline for the whole search.
  It kills a search still running 1 s past that deadline. It reports an indexer whose type maps
  to no adapter as not supported, and with no enabled configured indexer whose secrets decrypt
  it answers `{:error, :no_indexers}`. #1653 maps the Newznab and Torznab types.
  `Native.fetch_download/3` answers `{:error, :not_supported}`.
  `Cinder.HTTPPolicy.bounded_request/2,3` now kills its request task once the process that
  called it exits.
