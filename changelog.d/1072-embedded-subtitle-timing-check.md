### Fixed
- **An embedded subtitle track that fails the timing check no longer becomes a sidecar (#1072).**
  When OpenSubtitles has no match, Cinder copies a video's embedded track in the wanted language
  next to the video. That copy now passes the same timing check as a download or the video's own
  track. A track that fails it is skipped for the next track in that language. With no track left,
  Cinder falls back to a translation or a sidecar as before, or writes no sidecar, and players can
  still show the track inside the video. This change does not remove a sidecar written earlier
  from a track that fails the check.
