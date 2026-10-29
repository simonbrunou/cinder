# Testing

- `mix test` decides when a task is done. Before you start, write the done-when as something
  `mix test` can check, then loop until it is green.
- When the issue carries a triage Agent Brief, the done-when names a test for each requirement
  in **Desired behavior** as well as each **Acceptance criteria** box. On #972, prod's mount
  layout, a `devino-hash` mount and `verify_legacy_selection`'s refusals were Desired-behavior
  requirements with no test until the Spec review, which cost a second review round.
- A bug fix starts with a test that reproduces the bug. Then make it pass.
- New functionality, such as a choke-point, a state or a writer, ships with a test.
- A lock test runs the waiter in another process than the holder: the lock id carries `self()`
  and `StagedImport.run/1` is re-entrant, so a waiter in the holder's process never blocks. A
  short `refute Task.yield(task, 100)` shows it blocked (`Cinder.Library.StagedImportTest`,
  "run/1"). After the release, the waiter wakes at its next `:global.trans/2` retry, a random
  sleep whose ceiling doubles from 250 ms to 8 s. What sets the await is how long the lock stays
  held after the waiter starts: the default 5 s covers a few hundred ms, and a hold of seconds,
  such as a whole `TvPoller.poll/0` import, needs about 15 s.
- Tests never hit the network or a real service. `config/test.exs` points each external-service
  behaviour at its Mox mock, so a test that needs service behaviour sets an expectation on the
  mock. The behaviour list is in [architecture.md](architecture.md).
- Inject a one-time filesystem failure with `Cinder.Test.BarrierFilesystem.fail_once/1` or
  `fail_in_order/1`. Each fails the test when the failure never fired. A failure armed by hand
  with `Application.put_env` gets no such check: keep that for a failure that must stay armed.
- A failure fires on the first matching operation whose source contains `source_contains`. A
  bound reports the path it was opened or created at as its source. Only a bound created outside
  the library roots reports its `/proc/<pid>/fd/<n>` path.
- The identity probes that verify a subtitle exchange close bounds on the same paths. Arm a close
  failure meant for after the exchange from a barrier, as `fail_close_after_exchange/4` in
  `sidecar_transaction_test.exs` does.
- Release a barrier inside the log capture whose output the test asserts: send `{ref, :continue}`
  from the `capture_log/1` or `with_log/1` function. The paused task logs as soon as it resumes,
  so on a slow runner a release before the capture prints the warning to the console and the
  capture reads `""` (#969). `code_health_test.exs` fails on a release followed by a capture in
  the same block.
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
- A test that saves settings (`Cinder.Settings.save/2`, or `put/2`, `delete/1` and `save_form/1`,
  which go through it) runs in an `async: false` module that restores every
  `Cinder.Settings.env_keys/0` key, as `Cinder.SettingsTest` does. Each save rebuilds those keys
  from the boot capture (`Cinder.Settings.Overlay.base/1`) plus the stored rows, so a `put_env/2`
  or `put_config/2` value on one of them is gone once the save returns. Seed the starting state as
  rows with the raw `save/2`, which also stores a value `save_form/1` refuses (required embedded
  subtitles with no subtitle language). Seed before creating the rows under test: a save that
  changes the anime defaults decides every anime hold again (#791).
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
- A child process inherits the suite's own priority, and that priority differs by route. On the
  dev host, `nix develop -c mix test` runs at nice 16, the idle I/O class and `SCHED_IDLE`
  (ananicy-cpp's `nix` rule). CI runs at nice 0 and the default class. A test of a subprocess's
  niceness or I/O class compares it with the suite's own. That check proves little at nice 16
  and the idle class, since nice stops at 19 and the class is already idle, so the test also
  pins the exact command line with recording shims on `PATH`, as
  `Cinder.Library.MediaInfo.FfprobeTest` "whole-file reads" does (#862).
- A list built from a directory listing (`File.ls/1`, `Cinder.Library.PathPolicy.walk/2`,
  `Cinder.Library.Filesystem`'s `find_files/1`, so `Cinder.Library.Sidecars.files/1` too) comes
  in the order the disk returns. That is creation order on the btrfs dev host and can be any
  order on CI, so neither a local nor a CI pass proves a test ignores it. A test compares such a
  list sorted unless the code under test sorts it (#919).
