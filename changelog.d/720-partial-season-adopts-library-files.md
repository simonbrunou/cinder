### Fixed
- **Before it first searches a season a request approval monitored, Cinder now links the
  episode files it can match without an operator in the show's TV library folders, and searches
  only the other episodes, unless that check still cannot finish an hour after the approval
  (#720).** For a Standard show with no scene numbering group, the check lists the top level of
  each TV library folder for the show's folders: a folder tagged with the show's `{tmdb-N}` id,
  or its `{tvdb-N}` id when Cinder knows it, or an untagged folder named by the show's title and
  year when TMDB finds exactly one show with that title and year, this one. A video file in such a
  folder whose name reads as an episode of that season, such as `Show.S01E02.mkv`, is linked to
  its episode without an operator, unless another file in the show's folders names the same
  episode, the file is a sample, Cinder already tracks the file, or the episode already has a
  file or a download. Cinder then searches only the episodes still missing. Every other file
  waits for `/library/adopt` as before, and its episode is searched. An Anime show, or one with a
  scene numbering group, gets no automatic linking. While a TV library folder cannot be read,
  TMDB does not answer for a folder named by title and year, or the linking meets an episode that
  changed meanwhile, the season waits unsearched and Cinder tries again on a later pass; an hour
  after the approval it searches the season without the check.
- **A season that is no longer airing and that the media server holds in full against TMDB's
  episode count can no longer be requested, while TMDB answers (#720).** The season
  request page already hid its Request button. A request for it now gets "Season 1 is already on
  the media server." on the page, a 409 `season_available` from `POST /api/v1/requests`, and
  "Request again" on My requests says the title is already on the media server. Plex watchlist
  sync files no request for it and does not ask again. An airing season whose aired episodes are
  all on the server, and a season the server holds only part of, can still be requested. When
  TMDB does not answer, the request goes through.
