### Fixed
- **Anime series now grab and import names such as `Show.2021.S01E01`, with a year before the
  episode number (#1132).** A title-search result such as `Show.2021.S01E01` was skipped unless the
  year was the series' own, and a result such as `[Group] Show (2020) - 01` was skipped from either
  search: the manual search listed it as "stable episode mapping required". The same names on
  downloaded files stopped the import at "Needs mapping" in the same cases. For a series from
  2020, Cinder now reads the episode in `Show.2021.S01E01`, `[Group] Show (2021) S01E01`,
  `[Group] Show (2020) - 01` and `[Group] Show [2020] - 01`, while `[Group] Show (2021) - 01`
  reads no episode (#1138). `Show.2020.01` still reads as a date, not as a year and an episode.
