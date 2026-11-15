### Added
- **The series page flags an episode whose wanted audio is in the file but not on its default
  track, once Cinder has recorded which track that is (#786).** An episode import that records
  the file's quality now also records the language of its default audio track, as a movie import
  does. When the series' wanted audio language is in the file and the default track is another
  language, the episode's row says which language it plays as by default, with the same words as
  the movie page. No hint shows when Cinder could not tell which track is the default, or for an
  episode with no file. An episode imported before this change shows no hint until an import
  records its file's quality again or the media-info backfill reads its files again
  (`docs/operating.md`, "Media-info backfill").
