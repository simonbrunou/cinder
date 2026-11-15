### Changed
- **On the Original audio pick, a non-anime TV series whose original language isn't English now
  keeps untagged releases in its season searches, ranked below each release tagged with that
  language that fits the same size limit (#882).** A movie already did. Before, a season search
  dropped every untagged release as soon as one release whose tag matches the series' language
  (MULTI included) passed its name and download-client checks, even a release for another
  episode. For a French series that wants E01 and E02, with `Show.S01E01.FRENCH.1080p.WEB-DL` and
  an untagged `Show.S01.1080p.WEB-DL` pack found, both fitting the household's size and quality
  rules, a season search now picks the FRENCH single for E01 and the pack for E02, where E02 used
  to wait for a FRENCH release. When a season search finds only untagged releases and releases
  tagged with another language, it now drops the other-language ones and picks among the
  untagged. When the upgrade sweep finds a matching release for one episode, it can now also grab
  an untagged release for another held episode whose file carries no tag matching the series'
  language, when it ranks that release better. It still skips an untagged single-episode release
  for a held file tagged with the series' language. The French and French + original picks still
  skip untagged releases. In the manual search panel, this holds for the rows that pass their name
  and download-client checks: when one of them matches the series' language, an untagged one no
  longer carries the warning badge, and its hover text reads "Untagged: assumed to be the original
  audio, ranked below a tagged match". When none matches, a row tagged with another language now
  carries the warning badge next to an untagged row, where neither did before.
