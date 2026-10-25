### Fixed
- **Anime series no longer grab another show's episode from a TVDB-scoped search (#699).** A
  result from the TVDB-scoped anime episode search is taken when the indexer reports the series'
  own TVDB id on it, or when its name starts with the series title or one of its aliases (native
  and romaji aliases count). A result naming another series, or reporting another series' TVDB
  id, is skipped, and so is one whose name carries a year more than one off the series'. The
  manual search lists such a result as "title doesn't match" and still lets you grab it when it
  maps to an episode. If an anime series now misses releases published under a name Cinder
  doesn't know, add that name as an alias on the series page.
