### Fixed
- **Subtitle corrections no longer leave a hidden folder behind for good (#795).** Each subtitle
  timing correction used to leave a hidden `.cinder-subtitle-sync-cas-*` folder beside the
  sidecar, holding one empty file, and nothing ever removed it. A correction now removes its own
  once its result is recorded, and logs the folder's path when it cannot. When Cinder analyzes
  the subtitles of a video it manages, it also removes up to 50 such folders that earlier
  corrections and resets left in that video's folder, once its interrupted resets and
  replacements have finished. It takes only folders unchanged for an hour that no subtitle record
  it can read there names, so a large backlog clears over several analyses. A folder that holds
  subtitle bytes, a second name of a download's file or anything else stays. When an interrupted
  cleanup leaves such a folder empty, a later correction or reset of that subtitle goes ahead
  instead of failing.
