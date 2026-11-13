### Added
- **The dashboard's Service health panel now lists the folder reads Cinder counts as stuck,
  whenever its service checks finish and its folder-read guard answers within a second (#948).**
  The panel reads them with its service checks, when the dashboard loads and on Recheck. These are
  the folder reads that go through that guard, such as the walk of a completed download's folder
  before its import, sidecar file lookups, the library adoption scan and the leftover download
  folders scan. Cinder counts one as stuck once it passes its deadline, once the process that
  started it, such as a page's scan, exits while the read still runs, or when the guard restarts
  while it runs. While one under a known folder is stuck, Cinder can refuse new ones under that
  folder, and while two or more are stuck, it refuses every new one. The panel shows a warning row
  for each stuck read with its folder, or says its folder is unknown for a read the guard took over
  in a restart, until that read's caller, still running, reports it past its deadline. One more
  row shows while every new one is refused. A download folder's row says Cinder
  can refuse imports from it.
