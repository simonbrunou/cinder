### Fixed
- **A "Keep as part" decision no longer raises a database error once crash recovery has rolled
  back its staged part (#783).** When a residual file's part sat staged past its 30-second
  handoff before the decision was written, and crash recovery finished rolling it back, the
  decision raised `FOREIGN KEY constraint failed`. It now fails as a stale import and records
  nothing: the file stays undecided, so you can decide it again.
