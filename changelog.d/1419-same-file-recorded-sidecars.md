### Fixed
- **A re-import from a release folder onto its own video now records the subtitles it links,
  also when the movie or episode already had a recorded quality (#1419).** When the file at the
  library path was already the release's own video and the import was not a forced upgrade, a
  movie or episode with a recorded quality kept the subtitle languages it had recorded, while
  Cinder linked the release folder's subtitles next to the file. The movie and series pages then
  could list a language that was not on disk and miss the one Cinder linked, and that subtitle
  was not marked as Cinder's own unless the record already listed its language. Cinder now
  records the languages of the subtitles already next to the file followed by the release's,
  keeps the rest of the recorded quality, and marks the subtitle it linked as its own. A subtitle
  you put next to the file stays yours, unless Cinder already managed a subtitle in its
  language there. A single-file download links no subtitles, and the movie or episode keeps its
  recorded list.
