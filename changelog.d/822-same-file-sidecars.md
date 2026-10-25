### Fixed
- **A re-import of a release whose video is already in the library records its subtitles
  (#822).** When the movie or episode file at the library path was already the release's own
  video, as after a forced re-import or a retry after a crash, Cinder linked the release folder's
  subtitles next to it but recorded none of them. The subtitle fetch after the import then
  searched for languages the release had already brought. Cinder now records those languages, and
  a TV upgrade that keeps an episode's file because that file is the release's own video now
  links the release's subtitles too. Titles imported before this fix keep their recorded list.
