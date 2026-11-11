### Fixed
- **The library adoption scan of a library folder no longer reads the library folders inside it
  (#1185).** The scan of a movies or TV library folder (the configured one, an Anime one or a
  profile's library path) now leaves out every other library folder inside it, the ebook and
  audiobook folders included. The files of a movies or TV folder inside it are listed only by the
  scans of that folder itself, so the movies folder's scan no longer lists the episodes of a TV
  folder inside it. When only an inner movies or TV folder stops answering, the scan of the outer
  folder no longer gets stuck in it too, and the scan shows the inner folder as one that could not
  be scanned. Before, the outer folder's scan could also read into the inner folder and get stuck
  there as well, which made two stuck listings. While two are stuck, Cinder refuses every new
  time-limited folder listing at once, an import's included.
