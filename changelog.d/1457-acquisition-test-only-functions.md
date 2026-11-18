### Internal
- **Two release-pick functions that only tests called are gone (#1457).**
  `Acquisition.best_releases/3,4` and `Acquisition.Anime.select_episodes/3,4` had no caller in
  Cinder's own code. Their tests now check the same cases through the picks the sweeps take:
  `Acquisition.judge_season/3` then `ReleaseJudge.pick/1` for a TV season,
  `Acquisition.best_upgrade_releases/4` for the upgrade sweep's season list, and
  `Acquisition.Anime.best_episodes/4` for anime episodes. Which releases Cinder grabs is
  unchanged.
