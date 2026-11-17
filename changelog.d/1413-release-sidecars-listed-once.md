### Fixed
- **An import links only the release subtitles it listed (#1413).** Cinder lists a release
  folder's subtitle files at most once per video and links none it did not list. Before, the
  commit listed the folder again to link its files, so a subtitle in a new language added after
  staging could be linked next to the video but missing from the languages recorded for it.
