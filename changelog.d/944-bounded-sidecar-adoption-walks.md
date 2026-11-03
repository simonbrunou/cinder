### Fixed
- **A hung network or FUSE mount no longer freezes subtitle work or the adoption scan (#944).**
  Listing the subtitle files beside a video, which imports, subtitle sync and subtitle fetching
  all do, now gives up after 30 seconds and carries on as if the folder held no subtitles. On
  the library adoption page, a library folder whose scan takes more than 5 minutes shows "This
  library root could not be scanned." and the other folders still appear. While such a read
  stays stuck, new reads anywhere under that download or library folder fail at once instead of
  piling up.
