### Internal
- **A planned kind whose draw gives no search no longer keeps a parity run from pass (#1915).**
  `Cinder.Indexers.ParityRun.run/1` now hands `Cinder.Indexers.Parity.compare/1` the kinds it
  planned a search of, those with a count above 0. Each cell of a planned kind that has no search
  in the run reads `not asked (no candidate in the library)` and no longer keeps the verdict
  from pass, and the report's head prints `not drawn: <kind> (no candidate in the library)`.
  Before, such a cell read uncovered (`no_search`), so no run with an indexer whose kinds list
  `season_zero` could pass on a library with no season 0 of a standard series. Only such a kind
  changes: the cells of a kind counted 0, and of a kind the draw gave a search of, read as before.
