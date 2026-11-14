### Added
- **The log names slow database transactions once they commit or roll back, and slow connection
  waits and stalls (#1310).** Cinder now logs a warning that starts with `db watch:` when a
  database transaction that held SQLite's write lock for its threshold or longer ends in a commit
  or a rollback, failed ones included. A transaction whose process is killed before that end logs
  nothing. Cinder also logs one when a statement outside a transaction takes its threshold or
  longer, when a query waits its threshold or longer for a database connection, and when a timer
  that Cinder runs every second fires its threshold or more late. Each threshold is 1 second
  unless `config :cinder, Cinder.RepoWatch` sets `hold_ms`, `queue_ms` or `stall_ms`. A
  transaction, statement or wait line names the process and, when Ecto passes it the call's
  stack, the code that made the call. No line holds a query's parameters or its rows.
  `grep 'db watch:'` lists them all.
