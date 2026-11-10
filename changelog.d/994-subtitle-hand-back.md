### Added
- **A subtitle you placed that Cinder took over can be handed back (#994).** An import by an
  earlier Cinder version could record a `<video>.<lang>.srt` you put next to the video as a
  sidecar that came with the release, and the media-info backfill records one too. A later
  subtitle fetch can then replace it with an OpenSubtitles download or a track from the video.
  `Cinder.Subtitles.hand_back/2`, run over `bin/cinder rpc` with the video's path and the
  language, drops that record. No fetch then writes to the file while it is there, until a
  media-info backfill run records it again. It refuses a subtitle Cinder wrote itself, and a
  record that also holds subtitle-sync state. The Subtitles section of `docs/operating.md` shows
  the command and each answer.
