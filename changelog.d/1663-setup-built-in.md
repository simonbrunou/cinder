### Added
- **Step 2 of the setup wizard offers Built-in indexers: the "Indexer source" select and the
  indexers table (#1663).** Step 2 of `/setup` now reads "Add your indexers, or connect
  Prowlarr." Its Indexers group starts with the "Indexer source" select of `/settings`, then the
  section help, then the indexers table with its Add, Edit, Test, enable switch and Delete.
  "Save & validate" stores the chosen source with the other fields and refuses no switch. The
  Indexers group's help, on `/setup` and `/settings`, now reads "Cinder searches your indexers
  itself (Built-in), or through Prowlarr if you already run it. For Built-in, add each indexer
  below; Cinder tests each enabled indexer when you add it. For Prowlarr, choose it above, add
  your indexers there, then copy its URL and API key from Settings > General." (#1689 added
  "choose it above".) The Prowlarr settings guide link stays.
- **With Built-in saved, Finish needs an enabled indexer that works or waits out a rate limit,
  and once a download client passed its check, one of a protocol such a client uses
  (#1663).** The setup checklist's Indexers row reads the saved indexers, with no request. It is
  red with the reason while no enabled indexer works or waits out a limit; an indexer never
  checked does not count. It is green when every enabled indexer works, else yellow with the
  reason. Once a download client passed its last check, it also needs such an indexer of a
  protocol that some client which passed uses (Usenet for Newznab, torrent for the other types),
  and reads "No usable indexer uses the same protocol as a working download client." in red
  without one. The row and Finish follow each saved indexer add, edit, enable switch and Delete,
  each finished Test and the end of an indexer's limit or failure wait, with no click on
  "Save & validate". Once a Test or a save has shown the badge beside "Test Indexers", it follows
  the same changes (#1689). Finish checks the saved indexers again before it completes setup. With
  Prowlarr saved, the row stays Prowlarr's live check, with no protocol check.

### Changed
- **The setup checklist shows a warning in yellow with its reason, and the warning still unlocks
  Finish (#1663).** Before, `/setup` showed a warning, such as SABnzbd's configuration warnings,
  as a plain green check. The Download clients row is now green when every client that passed
  its check answered OK, yellow with the first warning when one of them warns, and red when every
  checked client failed. The warning's reason also shows beside that client's Test badge.
  The page's subtitle and the hint under "Finish setup" now end "Finish unlocks once every
  checklist row is green or yellow." instead of naming connected services.
