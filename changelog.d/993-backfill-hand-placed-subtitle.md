### Fixed
- **The media-info backfill no longer takes over a subtitle you put next to the video in a
  language Cinder does not manage (#993).** The backfill (`mix cinder.media_info.backfill`, or `Cinder.Library.Backfill.run()` over
  `bin/cinder rpc`) recorded a `<video>.<lang>.srt` it found next to a library file as a
  subtitle Cinder manages, one you placed yourself included, so a later subtitle fetch could
  replace it. It now records one only in a language Cinder already manages for that video. To
  also record the others, for media imported before Cinder kept a record of its subtitle files,
  pass `--register-untracked` to the task, or `register_untracked: true` to `run/1`: a subtitle
  you placed can then become managed too. The Subtitles section of `docs/operating.md` shows
  both commands.
