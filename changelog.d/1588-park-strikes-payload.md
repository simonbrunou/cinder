### Fixed
- **When "Remove download after a Usenet import" is on, Cinder now tries to remove a finished TV
  Usenet download as soon as its grab parks without blocking the release, unless a file that an
  import placed in the library still waits to be rolled back (#1588).** A grab parks without a
  block when, for example, its import fails 10 times on a file Cinder may not read. Cinder then
  asks the download client to remove the job with its files, and tries to delete the files
  itself, as it already did for a grab whose release it blocks. Its own delete runs only with the
  "Download folders" setting filled in, and refuses a path that holds a link. Such a park removes
  nothing while any file that an import placed in the library still waits to be rolled back, and
  nothing for a torrent or for a download that has not finished. Before, such a park left the
  download to the cleanup of downloads Cinder no longer owns, which removes a job at least an hour
  after it finished and only while the download client still lists it.
- **A TV release whose grab parks three times in one series without a block is now blocked for
  that series (#1588).** Each such park of a grab with a release title counts against that title
  in its series. The third one blocks the title for the series on every indexer, so the searches
  no longer grab it. An episode Search or a season Search that puts an episode of the series back
  in the search clears the series' counts, and the retention prune drops each park older than
  180 days. Clearing the counts lifts no other block on the title. Before, such parks never
  blocked the release, so the search could grab it again after each Rehunter pass.
