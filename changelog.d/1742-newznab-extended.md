### Fixed
- **Under the Built-in indexer source, Newznab and Torznab searches now send `extended=1`, and
  a Newznab indexer's searches send its additional parameters, but none whose name Cinder sets
  or relies on (#1742).** Each search request to a Newznab or Torznab indexer, and the search
  its Test sends, now carries `extended=1`, as Prowlarr's searches do, which asks the indexer
  for every `newznab:attr` of each result. A Newznab indexer's search requests and Test search
  now also carry its additional parameters, in the order they are stored. Before, Cinder stored
  them but sent none. A pair that names a parameter Cinder sets or relies on (`t`, `o`, `q`,
  `cat`, `imdbid`, `tvdbid`, `season`, `ep`, `title`, `author`, `extended`, `limit`, `offset`,
  `apikey` or `passkey`, in any case, spacing or percent-encoding, or as a PHP array name such as
  `cat[]`) is left out. The `t=caps` request carries neither.
