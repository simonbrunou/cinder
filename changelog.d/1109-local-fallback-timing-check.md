### Fixed
- **A translated or copied subtitle that fails the timing check is no longer written (#1109).**
  When OpenSubtitles has no match for a missing subtitle and no embedded track in the wanted
  language passes the timing check, Cinder can translate the video's default subtitle track or a
  subtitle file beside the video, or copy a subtitle file in that language saved under another
  name, such as `Movie.fre.srt`. A translation keeps its source's cue times and a copy keeps its
  bytes, and neither was checked, so a source with a cue that ends before it starts could become a
  subtitle with the same broken cue. Each source now passes the same timing check as a download or
  an embedded track, and so does the translated result. A default track that fails it is skipped
  like an embedded track, a subtitle file in the wanted language that fails it is skipped for the
  next one, and a file in another language that fails it is not translated. This change does not
  remove a translation, or a copy of a subtitle file, written earlier that fails the check.
