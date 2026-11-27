### Added
- **`/settings` can switch the indexer source to Built-in once an enabled indexer works or waits out
  a rate limit, and back to Prowlarr at any time (#1662).** An "Indexer source" select now starts
  the Indexers group, and "Save settings" saves it with the rest of the form. On load it shows the
  stored source when that is Prowlarr or Built-in, else Prowlarr when `PROWLARR_URL` or
  `PROWLARR_API_KEY` is set and not blank, else Built-in (#1689). A save that switches to Built-in
  is refused while no enabled indexer
  is usable or in a running limit backoff: nothing in the form is saved, the select is focused, and
  the page says "Built-in needs at least one enabled indexer that works or is waiting out a rate
  limit. Add, enable or test one below first." under the select and in the error banner. A save that
  keeps Built-in, or switches to Prowlarr, is never refused this way. Each save replaces the last
  save's banner. Under the select, with Prowlarr saved, the line reads "Searches go through
  Prowlarr. The indexers below can still be added, tested and imported; Cinder searches them once
  you switch to Built-in." With Built-in saved and a Prowlarr URL set, in `/settings` or through
  `PROWLARR_URL`, it says grabs already found through Prowlarr still download through it. After each
  save, Delete's warning in the indexers table follows the saved source. `/setup` shows the same
  select from #1663 on, and refuses no switch to Built-in.

### Internal
- **`Cinder.Indexers.switch_source/1` switches the indexer source outside `/settings`, refused to
  Built-in while no enabled indexer works or waits out a rate limit (#1662).** It stores
  `"prowlarr"` or `"native"` alone under the same rule, `check_source_switch/2`, and answers
  `{:error, :no_working_indexer}` for a refused switch or `{:error, :unknown_indexer_source}` for
  any other value, storing nothing for either.
