### Internal
- **`Cinder.Health` reads which native indexer states are red from
  `IndexerState.needs_admin?/1` (#1668).** On the health row of an enabled native indexer, the
  states of the moduledoc's rules 2 to 5 show red, `{:usable, _}` green and every other state
  yellow, as before.
