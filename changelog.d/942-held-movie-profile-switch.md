### Fixed
- **A searching movie on an anime hold can change profile again (#942).** A movie on an Anime
  profile whose search waits on an anime hold stays searching, and its detail page and a request
  approval refused it a new profile, so switching it to Standard never lifted the hold. Its profile
  now changes, and the switch decides the hold again: Standard lifts it. The change is still
  refused while a download for that movie is pending, and for an Auto movie that holds through its
  anime fallback.
- **The detail pages say why a profile change is refused during a download (#942).** A movie or
  series detail page that refuses a profile change while the title is being searched for,
  downloaded or imported now says the profile can't change while a download is in progress,
  instead of "Couldn't update the profile."
