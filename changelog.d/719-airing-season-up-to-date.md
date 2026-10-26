### Changed
- **An airing season up to date on the media server reads "Up to date, airing" (#719).** On the
  season request page, a season still airing whose aired episodes are all on Plex or Jellyfin
  used to read "8 of 10 episodes available", counting the announced episodes too. It now shows
  an "Up to date, airing" badge and keeps its Request button, so a request still lets Cinder
  pick up the episodes to come. Once requested, it reads Pending, Approved or Denied, with
  "Every aired episode available" under its name. A season that is partly on the server while
  it airs counts against the episodes aired so far ("7 of 8"). A finished season counts every
  episode, as before.
