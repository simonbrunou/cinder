### Added
- **`/settings` lists your configured indexers in a table in the Indexers group (#1660).**
  Each row shows the indexer's name, its kind and protocol (Newznab on Usenet, Torznab or
  Cardigann on torrent), a badge for its state with the state's detail text (green when usable,
  grey when disabled, red when you must act, yellow otherwise), and, once it has been tested,
  the last Test's outcome and time in the household's time zone. Rows sort by priority, then
  id, disabled ones included. Each row has an enable switch and a Delete button, which save at
  once and say so under the table, and a Test button. Delete asks first, and when the indexer
  source is Built-in and this is the only indexer that is usable or in a running limit backoff,
  the question adds that searches stop until another one works. After a Delete, keyboard focus
  moves to the next row's Delete, else the previous row's, or to the group's title once the
  table is empty. Test runs that indexer's Test, disabled indexers included; it runs on after
  you close the page, and its button stays disabled with a spinner until it ends. The line
  under the table says when it starts and how it ended. It is disabled for an indexer whose
  credentials can't be decrypted, and a disabled row then says so under its grey badge. A Test
  stores no outcome when, while it runs, its indexer is deleted or an edit changes its URL,
  API path, settings, FlareSolverr toggle or secrets. After such an edit the line says the Test
  stored nothing, and a Test started after another page deleted its indexer says it no longer
  exists. When a backoff ends while the page is open, the table reads the states again. With
  no indexer configured, the group says so. The Import button comes later.

### Changed
- **The Indexer group of `/settings` is now titled "Indexers" (#1660).** It shows its section
  help, the text and the Prowlarr settings guide link that `/setup` shows, above the table.
  Every other group still shows its help in `/setup` only.

### Internal
- **`IndexerSource.Native.TestRunner` runs the per-indexer Test outside the page (#1660).**
  `TestRunner.start/1` starts `Native.test_indexer/1` for one configured indexer in a task
  under its own `Task.Supervisor`, and refuses while a Test of that indexer still runs. It
  broadcasts each start and end on `Cinder.PubSub`, the end once the indexer's mark has cleared,
  a task that raised or was killed included. A restart of the runner ends the Tests it held.
  `Cinder.Health.native_indexer_level/1` now gives the colour that both the dashboard's
  per-indexer rows and the table read.
