### Fixed
- **A flag word in a release's title no longer flags its subtitle files (#1087).** Cinder read
  `forced`, `sdh`, `cc` or `hi` anywhere in a loose subtitle file's name as a flag, so
  `Forced.Entry.1983.1080p.BluRay.x264-GRP.fr.srt` was imported as a forced French subtitle
  (`Forced Entry (1983).fr.forced.srt`) and never used as a source for a missing subtitle, and
  `Hi.Mom.2021.1080p.WEB-DL.fr.srt` was ranked as hearing-impaired. Cinder now reads a flag only
  among the language and flag words at the end of the name, such as `.fr.forced.srt`. Subtitle
  files already in the library keep their names, so one imported with a wrong flag is still read
  as flagged: rename it without the flag, for example `Forced Entry (1983).fr.forced.srt` to
  `Forced Entry (1983).fr.srt`.
