### Internal
- **The subtitle manifest answers its callers' questions about an entry (#1412).**
  `Cinder.Subtitles` and `Cinder.Subtitles.Sync` now ask `Cinder.Subtitles.Manifest` whether an
  entry is syncable, which entry records a sidecar file, and whether it holds a sync record or a
  cleanup journal, instead of reading the entry's fields themselves. The stored manifest is
  unchanged.
