### Fixed
- **A forced, SDH or differently named sidecar no longer overwrites a subtitle on every sweep
  (#1070).** When OpenSubtitles had no match and the video had no usable embedded track, the
  subtitle fallback copied a sidecar in the wanted language, such as `Movie.fr.forced.srt`,
  `Movie.fr.sdh.srt` or `Movie.fre.srt`, over a `Movie.fr.srt` that Cinder had written or
  imported. It did so again on every sweep and asked the media server to rescan the library
  section each time. A subtitle you placed yourself was never touched. The fallback now leaves an
  existing subtitle alone, never takes a forced sidecar as a source, and prefers an unflagged
  sidecar over an SDH one when it fills a missing subtitle. A subtitle already replaced by a
  forced or SDH copy stays until an OpenSubtitles match or an embedded track in its language
  replaces it. To have Cinder look for it again now, delete that `Movie.fr.srt`: the next sweep
  treats it as missing.
