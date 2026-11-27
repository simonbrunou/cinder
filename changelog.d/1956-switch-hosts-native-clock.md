### Internal
- **A Switch's host list renders the running copy at Native's clock (#1956).**
  `Indexers.switch_host_pairs/4` renders the running copy's request at `Native.now/0` to find the
  hosts the indexer already sends a credential to, the clock a Cardigann search renders at. It
  read the wall clock before. No config sets Native's clock, so production reads the wall clock
  either way.
