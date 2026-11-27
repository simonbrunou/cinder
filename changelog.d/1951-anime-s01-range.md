### Fixed
- **The anime search now reads `[Erai-raws] Cowboy Bebop S01  - 01 ~ 26` and
  `[Judas] Cowboy Bebop S01 01-26` as Cowboy Bebop's season 1 episodes 1 to 26 (#1951).**
  Nyaa.si's definition can write ` S01 ` into a batch name, and prod's search got the Erai-raws
  name that way. Before, Cinder read no episode in these two names, so the search skipped them.
  The range is read only right after `S01` and the series' title or an alias that has no scene
  numbering. Names such as `Cowboy Bebop S02 - 13 ~ 24`, `Bleach S01  - 001 ~ 366` (more than
  100 episodes), `Cowboy Bebop S01 01-26 Recap` and `Cowboy Bebop S01 (BD 1080p HEVC Opus)`
  still read as no episode, and the import reads file names as before.
