### Fixed
- **With the fake-download check on and its default lists, a movie or TV download holding only
  `X.webm` and `Codec.exe`, or only a DVD's `VIDEO_TS` folder and `RARBG.com`, now counts as a
  fake (#1448).** The check, on by default, blocks a download that holds a file on its blocked
  list and nothing on its media list. By default the blocked list holds `.exe`, `.com` and `.lnk`,
  among others. For a movie or TV download, the default media list held
  `.m2ts`, `.mpg`, `.mpeg`, `.webm`, `.flv`, `.ogm`, `.iso`, `.img`, `.vob`, `.ifo` and `.bup`
  besides the archive and parity files and the video formats Cinder imports. Cinder imports none
  of these eleven, yet a download whose only video was one of them passed the check beside an
  `.exe`. That media list now holds the archive and parity files and only the video formats Cinder
  imports: `.mkv`, `.mp4`, `.avi`, `.m4v`, `.mov`, `.wmv` and `.ts`. Such a download is then
  handled like any other blocked download. A configured `media_extensions` list still applies to
  every download, as before.
