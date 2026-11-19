### Changed
- **When Cinder or the download client refuses for good to add a release that Cinder's search for
  wanted TV episodes picked, Cinder now tries to block that release for the series, and while it
  is blocked later searches skip it and can pick another one (#1492).** A refusal for good is a
  download link refused as unsupported, a torrent file that can't be read, or the client answering
  that it did not add the release, such as SABnzbd creating no job for it. It counts whether it
  comes on the first try or on a retry after another error. A release you pick by hand from a
  season's release list is not blocked when it is refused. Search attempts are counted as before.
  Before, the next search could pick the same release again, and it could fail the same way.
