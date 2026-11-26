### Added
- **Cinder now checks GitHub for new Prowlarr/Indexers definitions at start, then 24 hours after
  each run once it holds a set (#1669).** A new background job asks `github.com` for the commit on
  Prowlarr/Indexers' `master` branch when Cinder starts and 24 hours after each run ends. When that
  commit is not the one Cinder holds, it downloads the whole definitions set from
  `codeload.github.com` and stores it as `Cinder.Indexers.Definitions.apply_set/2` allows. It always
  asks for the whole set, never only the definitions your indexers use. While Cinder holds no set, a
  failed run is retried after 1, 5, 15 and 30 minutes, then every hour. Until a set is applied,
  Cinder holds no definition, so an install that cannot reach GitHub cannot add a Cardigann indexer.
  When it starts, before its first download, the job checks again, with no network call, each stored
  definition that has no check result from this Cinder's definition reader, then tries to decide
  again which copy each pinned Cardigann indexer runs and holds. `/activity` lists the job under
  "Background sweeps" as `Updater` until its label lands.

### Internal
- **The definitions job's runs (#1669).** `Cinder.Indexers.Definitions.Updater.update_now/1`
  starts a run or joins the one in progress, and each run's outcome is stored in one SQLite row
  and broadcast on PubSub. `Cinder.Indexers.Definitions.set_state/1` now reads
  `{:never_loaded, %{error: tag}}`, with the last run's error tag, until an answer is applied or
  refused. It reads `{:update_failing, ...}` in place of `{:loaded, ...}` once every run since the
  last success has failed and that success, or the set's load when no run succeeded, ended more
  than 72 hours ago. No page shows these yet.
- **A definition load check that raises, throws or exits no longer logs its message (#1669).** A
  load check that raises, throws or exits now logs the blob hash with its exception's module or
  `exit` or `throw`, no longer the exception's message and stack trace, which could quote a URL from
  the definition. Like a raise, an exit now stores no result for that copy and lets the other
  copies' checks finish.
