### Fixed
- **A single file check on a hung network or FUSE mount no longer holds up file reads across
  Cinder (#1114).** Several reads of download and library folders went through one queue that
  other file reads in the app wait behind: the path mapping check in a download client's health
  test and in the Sonarr, Radarr and Readarr migrations, the size check of a ZIP book archive,
  the size and safety checks of a RAR one, and the reads of subtitle files and of a video's start
  and end for subtitle search. One of them stuck on the mount held that queue until the mount
  answered. These reads of the mount now skip the queue, so one stuck there no longer holds it.
  Some writes to the mount still go through the queue.
