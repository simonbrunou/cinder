### Fixed
- **A TV season's "Find a better match" panel judges a release's size the way the automatic search
  does (#836).** A row now reads "outside size band" exactly when the automatic search would skip
  that release for its size. The band counts the still-wanted episodes the release covers, and for
  a whole-season pack, the season's full episode count as the fallback the search uses. The panel
  used to count every episode it searched, imported ones included, so a pack the search would take
  could read "outside size band" and a pack it would never take could read acceptable. A release
  that covers only imported episodes is judged by the episodes it names, or for a whole-season pack
  by the season's full episode count, unaired episodes included, the band the upgrade search uses.
  So in a season still airing, a pack of only the aired episodes can now read "outside size band".
