### Added
- **The series page can show the movie page's default-audio hint on an episode, once Cinder has
  recorded the episode's default audio track (#786).** An episode import that records the file's
  quality now also records the language of its default audio track, as a movie import does. The
  episode's row then shows the hint the movie page shows, with the same words and the same check:
  the file holds the series' wanted audio language and plays another language by default. That
  check counts a track only by a language code Cinder lists for a language: it skips a
  wanted-language track tagged with another code, and shows no hint when the default track is
  tagged with one. No hint shows either when Cinder could not
  tell which track is the default, or for an episode with no file. An episode imported before
  this change shows no hint until an import records its file's quality again or the media-info
  backfill reads its files again (`docs/operating.md`, "Media-info backfill").
