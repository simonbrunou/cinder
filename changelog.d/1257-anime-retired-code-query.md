### Fixed
- **When an anime series' search picks the TMDB episode code to search for a season, it now skips
  each code that a saved season offset took from its episode, unless a mapping made by hand names
  that code for the episode (#1257).** On an anime series "Show"
  whose episodes carry only their TMDB codes and the codes of an offset that makes TMDB's S03E01
  the scene S04E01, with S03E01 the only episode to find, the automatic search, the upgrade search
  and the "Find a better match" panel now send the indexer "Show S04E01" without "Show S03E01",
  and still search seasons 3 and 4. A TMDB code that a mapping made by hand names for its own
  episode stays in use: on that series with S03E05 also to find and such a mapping naming "S03E05"
  for it, they send "Show S03E05" in place of "Show S03E01". A code an offset took can still go
  out as another episode's scene code: on such a series with an offset from season 2 instead,
  "Show S03E01" still goes out for TMDB's S02E01 when it is the first episode of season 2 to find.
