### Internal
- **A Native grab's limit end counts from Native's clock (#1932).**
  `Newznab.Grab.checked_and_recorded/4` reads `Native.now/0` once and passes that reading to
  `DownloadCheck.check_classified/2` as `:now` and to `IndexerStatus.record/3`.
  `DownloadCheck.check_classified/2` counts a stated wait, such as a 429's `Retry-After`, from its
  `:now` option, and from the wall clock without one. Before, it always read the wall clock, so a
  test that pinned Native's clock failed once the wall clock plus the stated wait passed 24 hours
  after the pinned time. Production reads the wall clock for both, so no backoff changes there.
