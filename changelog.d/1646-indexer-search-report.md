### Internal
- **An indexer source can report what each search did with each indexer (#1646).** The new
  `Cinder.Acquisition.IndexerSource.Report` records, per indexer keyed by its source and id, its
  name and one outcome: asked, not asked, skipped or failed, each with a reason from a closed set
  that `Report.put/4` enforces. When some seam call of a search answered, it also counts the
  search's calls that failed. A search callback may now answer `{:ok, rows, report}` beside
  `{:ok, rows}`, and may return `:no_indexers`, `{:indexers_backing_off, retry_at}` or
  `{:no_indexer_answered, report}` as its error. Every seam call site reads all three shapes through
  `Report.from_result/1`. The anime and book searches combine their queries through
  `Report.combine/1`: a query whose indexers were all backing off, or one with no indexer, no longer
  makes the search incomplete. When no query answered they return the first error among the queries
  that is neither of those two, else the backoff that ends first, else `:no_indexers`; when that
  error is `{:no_indexer_answered, report}`, its report merges every such error's report. A standard
  movie search that picks nothing (`:no_match` or `:no_language_match`) from an incomplete search,
  and a standard season search that picks nothing from one, now return
  `{:error, :incomplete_search}`, so the Auto profile's anime fallback does not run and the poller
  counts an attempt. Each search entry of `Cinder.Acquisition`, `Cinder.Acquisition.Ebooks` and
  `Cinder.Acquisition.Audiobooks` takes the source module as `indexer_source:`, else reads
  `IndexerSource.configured/0` once, and the movie and TV sweeps read it once per movie search and
  per series visit, so a standard search and its anime fallback use one source. A book search in
  which no query answered now returns the error that rule picks, in place of `:indexer_unavailable`:
  under Prowlarr the first query's own error, such as `{:prowlarr_status, 500}`. The book panel
  shows its search error as before. Prowlarr returns no report and none of the new errors, so under
  it every search picks what it picked before.
