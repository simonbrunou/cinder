### Fixed
- **An archive-packed e-book or audiobook imports when scene files sit beside it (#781).** A
  `.rar` set or `.zip` with an `.nfo`, an `.sfv`, a cover image or a filler `.exe` beside it was
  held as `unsupported_archive`. Cinder now extracts it and imports the book; the files beside it
  stay in the download folder. The files it ignores there are `.nfo`, `.sfv`, `.md5`, `.par2`,
  `.txt`, `.url`, `.jpg`, `.jpeg`, `.png`, and the executables and shortcuts the download content
  check blocks (`.exe`, `.lnk`, `.bat` and the rest of its list). Any other file beside the
  archive, such as a loose `.epub` or `.flac`, still holds the book. A book already held this way
  keeps that release blocked: press Retry on its page to search again.
