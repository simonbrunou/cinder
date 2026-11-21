### Fixed
- **A TV download that completes as one regular file Cinder does not import as video, such as a
  `.7z` archive, in the download folders and with no link on its path, now counts as a download
  with no video, as a folder of such files already did (#1586).** For a download Cinder imports
  without an anime mapping, the import then parks it on its first try and tries to block the
  release for the series. With "Remove download after a Usenet import" on and the "Download
  folders" setting filled in, Cinder also tries to remove a Usenet download and its file. Before,
  unless the content check blocked the file at completion, the import took it for a file it may
  not read: it retried up to 10 times, then parked the download without blocking the release or
  removing its file, so the next search could grab the same release again. On one install that
  left about 100 copies of each episode on the disk. A file Cinder may not read, such as a link, a
  file reached through a linked folder or a file outside the download folders, is still retried as
  before.
- **A grab from the TV search for wanted episodes no longer gives the episode a fresh 10 searches
  (#1586).** A release that parks on every grab now runs the episode's searches out, and the
  episode shows Search failed until something puts it back in the search, such as the Rehunter or
  a Search. A release you pick by hand and the upgrade search still give the episode a fresh count,
  unless Cinder picks the release as anime. Before, each grab of a release the search did not pick
  as anime started the count over, so such a release could be grabbed again without end. A grab of
  a release Cinder picks as anime never started the count over, and still does not.
