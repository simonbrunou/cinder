### Fixed
- **An open season request page reads TMDB again (#964).** A `/series/tmdb/:id` page kept the
  TMDB answer it read when it opened. So for a show Cinder never added, a season the viewer had not requested
  kept reading "Up to date, airing", with Request, on a page left open past its finale, even once
  the media server held all of it, until a reload. The page now reads TMDB again when the media
  server's season inventory or a series in Cinder changes, at most once every 5 minutes; a change
  inside those 5 minutes is read once they end. The season reads Available once such a read lists
  no next episode in it and the server holds the whole season. A failed read leaves the page as
  it was.
