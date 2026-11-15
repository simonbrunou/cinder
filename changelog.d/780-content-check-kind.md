### Fixed
- **With the default lists, a movie or TV download whose only media is an e-book or audiobook
  file Cinder imports, such as an `.mp3` or an `.epub`, beside an executable now counts as a
  fake, as does a book download whose only media is a video (#780).**
  The fake-download check, on by default, blocks a download that holds a file on its blocked list
  (an `.exe`, a `.lnk` and the rest) and nothing on its media list. With the default lists, that
  media list held video files, archives and the e-book and audiobook formats Cinder imports, for
  every download. So a movie or TV download holding only an `.mp3`, `.m4b`, `.epub`, `.azw3` or
  `.mobi` beside an `.exe`, or an e-book or audiobook download holding only an `.mkv` beside one,
  passed the check. With the default lists, the check now counts as media only archives and the
  files of the requested family: video for a movie or TV download, the e-book and audiobook
  formats for a book download. Such a download is then handled like any other blocked download.
  E-books and audiobooks share one family, so with the default lists an e-book download holding
  an `.mp3` beside an `.exe` still passes. A configured `media_extensions` list still applies to
  every download, as before.
