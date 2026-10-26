# Testing

- `mix test` decides when a task is done. Before you start, write the done-when as something
  `mix test` can check, then loop until it is green.
- A bug fix starts with a test that reproduces the bug. Then make it pass.
- New functionality, such as a choke-point, a state or a writer, ships with a test.
- Tests never hit the network or a real service. `config/test.exs` points each external-service
  behaviour at its Mox mock, so a test that needs service behaviour sets an expectation on the
  mock. The behaviour list is in [architecture.md](architecture.md).
- A new UI string fails `translations_complete_test` until you run
  `MIX_ENV=test mix gettext.extract --merge` and write its French msgstr in
  `priv/gettext/fr/LC_MESSAGES/default.po`. When an existing msgid is close enough, the merge
  fills the new one with that translation and flags it `#, fuzzy`. Remove the flag and rewrite
  that msgstr by hand, especially when the new msgid contains an old one: "Jellyfin web URL"
  was filled with "URL Jellyfin", the translation of "Jellyfin URL". For more than a few new
  msgids, write each with its French msgstr into a scratch `.po` and fill the catalog from it with
  `scripts/gettext-fill.exs` ([workflow.md](workflow.md) "Merge conflicts" has the command),
  which also clears the `#, fuzzy` flag on the entries it fills.
- A test sets a `:cinder` env key with `Cinder.ConfigCase.put_env/2`, which restores the old value
  on exit; `put_env/1` takes a keyword list of keys. For a keyword-list key, `Cinder.ConfigCase.put_config/2` merges the overrides and
  restores the same way. The household size band (`:tv_min_size`, `:tv_max_size`, read by
  `Cinder.Acquisition.HouseholdPolicy.band/1`) is one such key. When other test modules also read
  the key, as several read the band, set it from an `async: false` module.
- A test picks the media server through `Cinder.ConfigCase` too: `store_media_server_type/1`
  writes the type row without `Cinder.Settings.put/2`, which would swap the global impl off the
  Mox mock for the rest of the run. `put_plex_url/1` and `put_media_server_bootstrap/1` set
  process-global state (an OS env var, the overlay's boot capture), so only an `async: false`
  module calls them. All three restore on exit.
- Each committed movie or episode file queues a subtitle task on the one shared
  `Cinder.Subtitles.Fetcher`. A test calls `Cinder.LibraryStubs.await_subtitle_tasks/0` before
  it ends when an import it commits records sidecar languages, or the task can run after the
  test restores its library roots and log `subtitle manifest write failed ... :unsafe_destination`.
  A test that turns subtitle languages on calls it first, so a task an earlier test queued runs
  while they are still off instead of consuming this test's provider expectations (#685).
- A list built from a directory listing (`File.ls/1`, `Cinder.Library.PathPolicy.walk/2`,
  `Cinder.Library.Filesystem`'s `find_files/1`, so `Cinder.Library.Sidecars.files/1` too) comes
  in the order the disk returns. That is creation order on the btrfs dev host and can be any
  order on CI, so neither a local nor a CI pass proves a test ignores it. A test compares such a
  list sorted unless the code under test sorts it (#919).
