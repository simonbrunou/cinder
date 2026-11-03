### Fixed
- **A season pack numbered by a scene or TVDB-aired season is judged by the episodes it holds
  (#895).** When an episode mapping splits a season in two, for example a 24-episode S01 that the
  scene numbers S01 (episodes 1 to 12) and S02 (episodes 13 to 24), a scene "S02" pack holds 12
  episodes. The automatic search and the "Find a better match" panel sized it as the whole native
  season of 24 when nothing smaller fit. So a pack twice too large for its 12 episodes could be
  grabbed, and a correctly sized one could read "outside size band" under a minimum size. In that
  case both now size it by the 12 episodes the mapping gives that scene season, counting any the
  search skips: one already downloading, or a missing one that is unmonitored or not aired yet.
  The panel's row for such a pack that covers no episode you still want, as for an upgrade, now
  counts those skipped episodes too, so its "outside size band" label can change.
