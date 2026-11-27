### Internal
- **A native search in which one or more indexers failed and none reads as asked now returns the
  rows they returned before the failure, when one of those rows passes the query-origin check
  (#1738).** Before, `IndexerSource.Native` answered `{:error, {:no_indexer_answered, report}}`
  and dropped them: with one enabled Newznab indexer, a season search whose TVDB-id query
  answered and whose text query got HTTP 503 returned that error from `judge_season/3`. It now
  answers `{:ok, rows, report}`: each row whose `query_origins` is exactly `[:id_scoped]` or
  `[:free_text]`, from each failed or skipped indexer, in Native's usual row order. The report
  lists the failed indexer, so the search reads as incomplete, and `ReleaseJudge.sweep_pick/1` on
  a season that picks nothing from it returns `{:error, :incomplete_search}`. When no row passes
  that check, the answer stays `{:error, {:no_indexer_answered, report}}`. A search in which no
  indexer was asked or failed and one or more were skipped still answers
  `{:error, {:indexers_backing_off, retry_at}}` and drops any row a skipped indexer returned.
