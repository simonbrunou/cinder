### Fixed
- **Cinder now tries to remove a subtitle it copied from an embedded track that fails the timing
  check, once OpenSubtitles has no match, while the file reads back as what Cinder wrote and
  Cinder holds no timing-correction record for it (#1110).** Before #1072, when OpenSubtitles had
  no match, Cinder copied a video's embedded subtitle track next to the video, such as
  `Movie.fr.srt`, without the timing check, so a track with a broken cue (a blank line inside a
  cue, for example) could become that copy. Later sweeps could keep it until an OpenSubtitles
  match replaced it. Now, when OpenSubtitles has no match for the copy's language, Cinder reads
  the copy, unless it holds a timing-correction record for it, such as a correction made by hand
  or by an alignment, or the record of a reset. When the copy still holds the bytes Cinder wrote
  and fails the same timing check, Cinder tries to remove it, and logs `subtitle removal failed`
  when it cannot, for example when the file changed after the read. The check never removes a
  copy you edited since Cinder wrote it, or one Cinder cannot read. Once the copy is gone, Cinder
  asks the media server to rescan, then looks for a subtitle as it does for a missing one: another
  embedded track in that language that passes the check, then a translation or a subtitle file in
  that language under another name. When it finds none, no subtitle file is left for that
  language, and players can still show the track inside the video.
