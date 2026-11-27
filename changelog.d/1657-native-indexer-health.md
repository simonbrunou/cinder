### Changed
- **The dashboard's Prowlarr row now reads "Indexers (Prowlarr)" (#1657).** The indexer row is
  named for what it checks, the indexer source, and names that source in brackets. The `/setup`
  checklist row reads "Indexers", and the row's Test button in `/setup` and `/settings` reads
  "Test Indexers".
- **A Test in `/settings` that fails or warns now shows its reason as text (#1657).** The reason
  shows beside the badge, in red or yellow. Before, only the badge's tooltip held it, which
  keyboard and touch users could not open. `/setup` shows a failed or warning Test's reason the
  same way (#1663).

### Internal
- **The native indexer source now reports each configured indexer's state, and can Test one
  indexer (#1657).** `IndexerSource.Native.IndexerState.list/1` lists every configured indexer,
  disabled ones and ones whose secrets do not decrypt included, with one state from what Native
  recorded, in this order: disabled, credentials that do not decrypt, not supported (a type with
  no adapter, or the FlareSolverr toggle on), credentials rejected, a limit backoff that has not
  ended, a failure backoff that has not ended, failures or a limit whose backoff has ended, usable
  (a success recorded with no failure or limit after it), and never checked. Under the native
  source the dashboard's indexer row shows `Native.health/0`, which sends no request: red with
  no indexer added or none enabled, green when every enabled indexer is usable, else yellow
  while one is usable and red when none is, naming the first 5 that are not and how many more.
  Under it, one row per enabled indexer shows its state, with times in the household's time
  zone: red for credentials rejected, not supported or not decrypting, yellow while it waits,
  green when usable. Each wait counts from the instant the check judged the states. A failure
  backoff after HTTP 410 reads "Disabled in Prowlarr", after 404 "Not found in Prowlarr". The
  stored-credentials row now also counts configured indexers whose secrets do not decrypt,
  disabled ones included. `IndexerState.passes_gate?/1` is true while some enabled indexer is
  usable or in a limit backoff that has not ended. `Native.test_indexer/1` asks one indexer
  whatever its backoff state, disabled ones included, under a 90 s budget. For a Newznab or
  Torznab indexer it refetches the caps, then sends one search with no query terms, with its API
  key when it has one, in the type's default category (Movies for Newznab, TV for Torznab). For
  a Cardigann indexer (#1671) it sends the first request of the definition's keywordless search,
  under the mappings the definition marks `default`. Each request gets the one retry a search
  request gets. For a `post`, `get` or `form` login (#1680), it sends the login's requests first
  when the indexer has no stored session. After an answer that shows a login sign, it sends them,
  then that request once more. No login request is retried.
  It records the answer in the backoff state as a search answer would, except that a pass also
  ends rejected credentials and a request the budget cut counts as a timeout, and stores the
  last Test's outcome and time in new `native_indexer_status` columns. A request still waiting
  for the indexer's slot when the budget ends is never sent and records nothing. It refuses an
  indexer whose secrets do not decrypt or that is not supported, with no request, and drops its
  answer when an edit raised the indexer's `config_version` meanwhile.
