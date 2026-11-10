### Fixed
- **`[Group] Show (2017) - 01` no longer reads as episode 1 of an anime series from 2016
  (#1138).** Since #1132, for a series from 2016, a result such as `[Group] Show (2017) - 01` read
  as the series' episode 1, so Cinder could grab it for season 1's first episode and import a
  downloaded file of that name there. A later season released under the series' title can carry
  its own year and number its episodes from 1 again. Now `[Group] Show (2017) - 01` is skipped
  from either search, listed as "stable episode mapping required" in the manual search, and the
  same name on a downloaded file stops the import at "Needs mapping", while
  `[Group] Show (2016) - 01` still reads as episode 1. For a series whose year Cinder does not
  know, `[Group] Show (2016) - 01` is skipped from either search too. For a series from 2020,
  `Show.2021.S01E01` still reads as `S01E01`.
