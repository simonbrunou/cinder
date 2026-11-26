### Fixed
- **With the Built-in indexer source, the standard search for a movie with an IMDb id now asks
  an indexer whose movie search takes no IMDb id, but whose search takes a text query under
  a movie category, by the movie's title and year, or by its title alone when it has no year
  (#1632).** Before, that search sent such an indexer no query, so it never found the movie
  there. An indexer whose movie search takes an IMDb id still gets the id alone. A release that
  only the text query found must pass the title check that a release for a movie with no IMDb id
  passes, such as `Dune.2021.1080p.BluRay` for Dune (2021). For a movie with no year, that check
  can take another film of the same title, such as `Dune.1984.1080p.BluRay` for a Dune with no year.
