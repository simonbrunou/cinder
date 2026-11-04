### Fixed
- **Anime series now grab and import an episode whose name has a year before the episode number
  (#1132).** A title-search result such as `Show.2021.S01E01` was skipped unless the year was the
  series' own, and a result such as `[Group] Show (2020) - 01` was skipped from either search: the
  manual search listed it as "stable episode mapping required". The same names on downloaded
  files stopped the import at "Needs mapping" in the same cases. Cinder now reads the episode
  when a year from 1900 to next year stands between the title or alias and the episode number of
  a name it reads without that year, set apart from both, with only spaces, dots, underscores,
  dashes and one matching pair of brackets or parentheses around the year between them, and only
  spaces inside that pair. The exception is a bare year joined by one dot or hyphen straight to
  the digits of an episode number with no `S01E01`-style season: `Show.2020.01` still reads as a
  date, not as a year and an episode. Whether that year names another series is still decided as
  for a year anywhere else in the name, by the series' year and the TVDB id the indexer reports.
