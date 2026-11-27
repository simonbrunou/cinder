### Internal
- **The offline parity engine that compares Prowlarr with Built-in (#1683).**
  `Cinder.Indexers.Parity.compare/1` takes what both sources returned for the same searches,
  with Prowlarr's history and indexer status as `Cinder.Indexers.Parity.ProwlarrReads` reads
  them, and answers a verdict (`:pass`, `:fail` or `:inconclusive`), its reasons, the searches
  to run again and a text report. It runs the real callers again over the recorded rows through
  `Cinder.Indexers.Parity.Replay`, which answers each search call from the record, or with
  `{:error, :not_recorded}` when the record holds no such call. The report never
  prints a row's link or an error term, and prints each word of its input text that holds `=` or
  `://` as `[redacted]`. The parity run of #1684 calls it.
