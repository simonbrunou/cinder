### Fixed
- **A failed check of a subtitle manifest's path no longer costs the other languages their records
  (#1210).** Before it reads a video's subtitle manifest, Cinder checks every part of the
  manifest's path for a symlink. When that check failed with an error other than a missing path,
  such as a disk I/O error, each manifest write started from an empty manifest, so a new subtitle
  for one language could rewrite the manifest with that language alone. A manifest write whose
  check before that read fails this way now leaves the manifest unchanged, fails, and logs
  `subtitle manifest cannot be read` with the video and the reason, as when the manifest file's
  read fails (#1202).
