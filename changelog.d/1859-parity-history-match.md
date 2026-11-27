### Internal
- **A parity run now reads only the Prowlarr history entries that match a request of its own calls,
  so another client's query in a search's window opens no cell and counts toward none, unless it
  holds the same request, on an indexer of the run (#1859).** `Cinder.Indexers.Parity.compare/1`
  reads an entry as the run's when it matches a request of the try's Prowlarr calls, as
  `Cinder.Acquisition.IndexerSource.Prowlarr.requests/2` lists them: the same query term once
  the brace tokens of the search type are taken out, the same ids, the same categories, and
  the same search type or `search`, which Prowlarr 3.1 can write in place of the type. Like
  each entry of a Cinder search, it must also read `source` "Prowlarr" and hold no `limit` or
  `offset`, so a Sonarr or Radarr linked to Prowlarr matches none. A cell is now covered only
  when each request of the calls the Built-in source asked the indexer in has a matching entry,
  a TVDB request Prowlarr skips (#1933) aside. Before, the entries only had to be as many as
  the queries, and one request fetched over several pages writes an entry per page. In the
  second parity run of #1687, a live poller's anime searches on Nyaa.si opened its e-book and
  audiobook cells, which its caps exclude, and both read `uncovered (native_not_asked caps)`.
