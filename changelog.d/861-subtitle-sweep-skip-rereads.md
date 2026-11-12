### Fixed
- **The subtitle sweep no longer reads whole video files again for results that cannot change
  (#861).** Every 12-hour pass used to extract the same embedded tracks again: an own track the
  timing check had rejected, an embedded sidecar already written (which also logged
  `wrote <lang> subtitle` and asked Plex to rescan), and a default track used as a translation
  source that did not parse, or whose translation could not be used. Cinder now records each of
  these per file and skips them until the file changes. Each track is also extracted at most once
  per fetch, and a track listing is no longer broken by an ffprobe warning on stderr. The first
  pass after the upgrade still reads each such file once. For an embedded sidecar that fails the
  timing check, see #1110.
