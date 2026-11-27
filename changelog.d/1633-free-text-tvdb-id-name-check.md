### Fixed
- **A non-anime TV series no longer takes its own TVDB id, reported on a result only its title
  search returned, as proof of the result's name (#1633).** Before, when an indexer reported the
  series' TVDB id on such a result, automatic selection could take it whatever its name, unless
  every year in the name was more than one off the series' year. So an indexer that put the id on
  an unrelated release could get that release grabbed. Such a result now has to name the series
  the way a result with no TVDB id does: the series title followed right away by a season or
  episode code, or by a year within one of the series' year, as in `The.Office.S01`,
  `The.Office.S01E01` or `The.Office.2005.S01E01` for The Office (2005). `The.Office.US.S01E01` and
  `The.Office.1080p.S01E01` do not count. For a series with a known year, the id still spares
  such a result the year a result with no id has to carry, so `The.Office.S01E01` is kept for
  The Office (2005), while a name whose every year is more than one off is still skipped. A
  result the TVDB id search also returned is judged as before: with the series' id it needs no
  series title, so a release named by another title of the series ("La Casa de Papel" for "Money
  Heist") is still found. For a series with no known year, a result only the title search
  returned whose name puts a year right after the title, such as `The.Office.2021.S01E01`, is now
  skipped even when it reports the series' id.
