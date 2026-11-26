### Internal
- **`Cinder.Indexers.ParserWorker.run/3` runs a CSS query plan on one HTML page in an
  OS process of its own (#1665).** It starts a fresh `erl` from the release's own ERTS,
  which loads `lazy_html`, answers the rows, then exits. A worker that crashes, passes its
  deadline, its memory cap or its output cap answers an error, and the calling VM goes on.
  `Cinder.Indexers.Definitions.LoadCheck.check/2` loads a definition file and checks each of its
  CSS selectors in one such worker, adding a "not supported" code for each kind of problem, or
  only the worker's failure when the worker fails. Cinder runs the load check on each definition
  copy it stores, and a Cardigann indexer's search or Test (#1671) runs `run/3` on each page it
  reads. The release image now ships `lazy_html`, and the image's build stage installs `cmake`
  so that `lazy_html` builds from source when its prebuilt download fails.
