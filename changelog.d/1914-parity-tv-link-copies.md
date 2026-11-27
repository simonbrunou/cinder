### Internal
- **A parity report no longer counts a TV row difference where Built-in returns a link from both its
  queries and Prowlarr returns two copies of that release, each with a link of its own (#1914).**
  `Cinder.Indexers.Parity.Rows.native_count_keys/2` now counts each copy Native returns, as
  `count_keys/1` counts each Prowlarr row. Each row of Prowlarr's for the same call and indexer
  that carries both query origins, the row its adapter merges from copies that share a link,
  makes the copies of one Native link of that title and size count once. Before, `count_keys/2`
  counted Native's copies of one link once whatever Prowlarr returned. So in both TV searches of
  the early Usenet-only parity run on prod, altHUB, NinjaCentral and NZBgeek each read "Prowlarr
  only" rows, one for each link Native returned from both queries. A link Native returns from
  both queries now reads as a difference where Prowlarr returns that release from one query only.
