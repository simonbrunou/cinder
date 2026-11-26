### Internal
- **A Cardigann configured indexer runs a pinned copy of its definition, and risky updates wait
  for the admin (#1668).** `Cinder.Indexers.create/3` now creates a Cardigann row: it pins the
  mirror copy the form rendered, refuses a hash the mirror no longer holds, a copy that fails to
  load and a base URL outside the copy's `links`, and stores every setting's effective value,
  `text` and `password` values in the encrypted secrets. Each apply of the upstream set, and
  each `Definitions.store_results/1` call, decides each indexer's copies again; nothing calls
  `store_results/1` at boot yet. A copy that fails to load or reads not supported is held,
  and so is every update of an indexer whose secrets do not decrypt. For an indexer with a
  stored secret that differs from its running copy's default for a setting that copy declares,
  a copy is also held when it names a host its running copy does not, changes its certificates,
  or removes or retypes a setting that holds a credential. For any indexer whose running copy
  loads, a copy is held when it declares again a setting the running copy does not, with a
  stored secret that differs from the copy's default. Every other update applies once its load
  check has a result, without raising `config_version`, and a move of the effective base URL of
  an indexer with no credentials writes an audit row. `Definitions.accept/3` applies a hold of
  a credential rule and raises `config_version`. The native indexer states gain the definition
  codes, and a running copy that no longer loads turns its indexer's health row red. No page
  creates a Cardigann row or shows these states yet.
