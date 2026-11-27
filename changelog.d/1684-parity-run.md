### Internal
- **A parity run that searches the library through Prowlarr and Built-in and prints the parity
  report (#1684).** `Cinder.Indexers.ParityRun.run/1`, started over `bin/cinder rpc`, draws a
  seeded set of searches from the library and sends each through both sources with the same
  opts. Each configured indexer of the run gets at most `budget:` requests over the run, 200 by
  default, Prowlarr's included. It fetches at most one link per indexer, and sends none to a
  download client. It hands the records to `Cinder.Indexers.Parity.compare/1` and prints its
  report. It leaves the app env as it found it. A search outside a parity run sends what it sent
  before.
