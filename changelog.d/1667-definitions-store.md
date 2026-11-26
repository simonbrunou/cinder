### Internal
- **`Cinder.Indexers.Definitions.apply_set/2` stores in SQLite an upstream definitions answer that
  passes its version and size checks (#1667).** It refuses an answer whose `MIN_VERSION` is above
  the engine's schema version 12. It also refuses a first answer under 100 file names and an answer
  under 90% of the stored set's names, counting only names with a file in a folder from
  `MIN_VERSION` up to 12, unless `accept_smaller_set/1` took that refused commit and neither a
  successful apply nor a refusal at another commit has followed. A refusal keeps every
  stored copy, load result and entry. Otherwise it runs `LoadCheck.check/2` before its write
  transaction on each copy with no result under the current loader fingerprint, keeps for each file
  name the copy in the highest folder from `MIN_VERSION` up to 12, records only the number of a
  higher folder that holds another copy, and deletes the copies and load results the new set no
  longer uses. `name_status/1` and `picker/0` read the mirror per file name, and `set_state/0` reads
  the last outcome. No code outside the tests calls `apply_set/2` yet.
  `mix cinder.definitions.canary [commit]` load-checks every upstream file in the folders from
  `MIN_VERSION` up to 12 and prints the counts per unsupported feature and per failure reason,
  writing no database row. A release has no Mix, so the task runs only from a checkout.
