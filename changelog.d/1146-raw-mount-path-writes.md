### Fixed
- **A file change in a download or library folder on a hung network or FUSE mount can no longer
  hold up file reads and writes across Cinder (#1146).** Several of the changes Cinder makes in
  those folders, during an import, a subtitle write, a book archive extraction, a deletion and
  the library health check, went through one queue that other file calls in the app wait behind.
  Many of its changes in a library folder run in a helper program instead, but the lookup of that
  program, `python3`, went through the queue before each one, as did the lookup of the `sync` and
  `mv` programs. One change stuck on the mount could hold that queue until the mount answered.
  These changes and lookups now skip the queue, so one stuck on the mount no longer holds it. A
  change that skips the queue can still wait on the mount with no time limit, which holds the
  import or other task that made it until the mount answers.
