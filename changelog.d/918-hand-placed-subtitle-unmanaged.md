### Fixed
- **An import no longer takes over a subtitle you put next to the video (#918).** A movie or
  episode import marked every `<video>.<lang>.srt` it found next to the file as Cinder-managed,
  so the subtitle fetch that follows could overwrite one you placed by hand. An import now manages
  only the subtitle files it placed itself and the ones Cinder already managed. A subtitle an
  earlier import already took over stays managed.
