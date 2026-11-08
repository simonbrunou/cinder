### Fixed
- **An oddly named filler beside a book archive no longer holds the book (#903).** With the
  default blocked and media lists, a file such as `RARBG_DO_NOT_MIRROR.exe.`, `filler.exe ` (with
  a trailing space) or `filler.exe:$DATA` beside an e-book's or audiobook's `.rar` set or `.zip`
  now counts as filler, as a plain `RARBG_DO_NOT_MIRROR.exe` already did. On its own it no
  longer stops the archive from extracting, where the import used to hold the book as an
  unsupported archive. Under the same lists, a name such as `x.exe:y.epub` or `x.exe:y.flac`
  still holds the book, since that file could be a book or a stray audio track.
