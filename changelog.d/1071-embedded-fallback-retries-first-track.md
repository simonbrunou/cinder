### Fixed
- **One failed extraction no longer leaves a lesser embedded subtitle in place for good
  (#1071).** When OpenSubtitles had no match and the video carried two text tracks in the wanted
  language, such as a regular and an SDH one, a single passing failure on the first (a timeout on
  a busy disk) made Cinder write the second, and later sweeps kept it. Cinder now records which
  track an embedded subtitle came from and tries the tracks ranked ahead of it again on later
  sweeps, without reading the one it already holds.
