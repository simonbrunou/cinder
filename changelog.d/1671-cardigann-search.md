### Internal
- **The built-in indexer source can search a Cardigann indexer whose pinned definition loads,
  such as one on Nyaa.si's definition, though no page adds such an indexer yet (#1671).**
  `Cinder.Acquisition.Indexer.Cardigann` reads the definition's HTML search pages, with no
  sign-in. It sends the queries the definition's modes list, under the site categories the
  search's categories reach; a search that reaches none does not ask the indexer. Each request
  goes only to a public address, follows a redirect only when the definition asks for it and
  at most five times, and reads at most 2 MiB, inflated when the site sends gzip. A secret
  setting that is not blank and differs from its default goes only to a host that the indexer's
  base URL, definition or settings name, and a row whose link holds it is dropped unless the
  link is a web address on such a host. A definition with a feature Cinder does not run yet,
  such as a sign-in, reads "not supported" and gets no request. #1676
  brings the form that adds such an indexer.
- `mix cinder.definitions.canary` also sends one fixed query through each of the Nyaa.si and
  Torrent9 definitions that loads, prints the feature of one that reads "not supported"
  instead, and fails when a fixed query fails, gives no row, or drops a row for a missing title
  or link.
