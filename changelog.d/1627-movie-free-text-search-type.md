### Fixed
- **The free-text movie search no longer asks Prowlarr for the `moviesearch` search type, for
  which altHUB and NinjaCentral returned no results in a month of searches (#1627).** Cinder
  searches by title for a movie with no IMDb id, and the anime movie search adds title queries.
  Both asked Prowlarr for `moviesearch`, which is no Newznab search function. They now ask for a
  plain `search`. The anime movie search keeps its anime category (5070). The search for a movie
  with no IMDb id, which named no category before, is now scoped to the movie category (2000):
  Prowlarr asks only the indexers that carry it, and leaves out a result filed only under other
  categories.
