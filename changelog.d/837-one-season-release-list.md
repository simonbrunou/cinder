### Changed
- **The automatic TV search and a season's "Find a better match" panel search a season the same
  way (#837).** For a series with scene or TVDB numbering, both now search the same alternate
  seasons and list the same releases, so the panel can no longer show a release the automatic
  search never sees. Both search the alternate seasons that reach a wanted episode. The panel
  searches the seasons that reach only imported episodes only when the season wants nothing. A
  season that the series also has as its own, with an episode still wanted, is never searched as
  an alternate season. A release that two queries return is listed once. The automatic search no
  longer grabs an alternate-season release whose numbering resolves two ways, such as a scene
  "S02" pack that could also be the series' own season 2. The panel already refused those, and the
  episodes stay wanted for a release that names them unambiguously.
