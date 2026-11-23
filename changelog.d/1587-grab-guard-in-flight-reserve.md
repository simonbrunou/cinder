### Fixed
- **The grab disk guard now sets aside what in-flight downloads of recorded size still have to
  write when it checks a release of known size against a readable download root (#1587).**
  Before a movie search, a TV sweep or an upgrade hunt hands a release of known size to its
  download client, Cinder takes those bytes off each download root's free space. It skips the
  grab when every download root reads as too small for the release plus the 2 GiB margin. Before,
  the guard compared each release with free space alone, so several grabs could each pass while
  earlier downloads had not written their bytes yet. With several download roots the whole reserve
  comes off each root, since Cinder cannot tell which root a download lands on. The disk check
  still admits a release of unknown size, and any release when no download root is configured or
  inferred from the library paths, or when a root's free space cannot be read. Manual grabs and
  book grabs still run no guard, but their size counts against the automatic grabs. A download
  with no recorded size, such as one grabbed before this update or one whose indexer reported no
  size, reserves nothing.
