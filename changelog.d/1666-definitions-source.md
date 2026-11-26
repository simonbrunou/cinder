### Internal
- **`Cinder.Indexers.Definitions.Source.fetch/1` reads the Prowlarr/Indexers definitions from
  GitHub (#1666).** It reads the commit `master` names from the repository's `info/refs` and
  answers `:unchanged` when that is the stored commit. Otherwise it downloads that commit's zip
  from codeload and reads it with `Cinder.Indexers.Definitions.Archive.read/2`, which keeps only
  `VERSIONS` and the `definitions/v<N>/*.yml` files, each with its git blob hash, and refuses the
  whole archive on an unsafe name, a layout other than one root folder for the commit, a corrupt
  entry, a size or entry-count cap, or a missing or unreadable `VERSIONS`. The definitions update
  job (#1669) calls `fetch/1`, and only `fetch/1` calls `read/2`.
