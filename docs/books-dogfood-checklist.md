# Books B8 dogfood checklist

This is the operator checklist for the roadmap's B8 Done-when window: two weeks with Readarr/
Bookshelf stopped (or left running but not depended on — see
[`docs/readarr-migration.md`](readarr-migration.md#decommissioning-bookshelf-after-sign-off) for
why it stays reachable until sign-off), tracking whether Cinder's e-book/audiobook pipeline is a
trustworthy replacement.

**What this window is, and is not.** Two weeks of real, unattended use are an operator-run,
elapsed-time observation — no test suite or code change can substitute for it, and none of this
document pretends otherwise. What B8 actually ships is the instrumentation that makes the window
legible: `Cinder.Books.BookOpsLog` (table `book_ops_log`), a durable log of the pipeline events
that previously left no trace at all, and this checklist for reading it.

## Before starting the window

- [ ] Take and verify a fresh database backup (`docs/operating.md#backups`) — `PRAGMA
      integrity_check` returns `ok`. This is your rollback point if anything in the window goes
      wrong.
- [ ] Confirm the Bookshelf instance(s) you migrated from are still running and reachable — do
      **not** decommission them yet (see the runbook link above). They are your fallback for the
      length of this window.
- [ ] Confirm `/dashboard` shows every book/audiobook-relevant health row green: metadata
      providers (Open Library, and Hardcover if configured), the indexer, the download client(s),
      the `books`/`audiobooks` library roots, and (if audiobooks are in scope)
      `Audiobookshelf`.
- [ ] Note the current count of monitored e-book and audiobook targets (`/library?type=books`),
      so drift over the window is measurable against a real baseline rather than guessed.

## During the window

Let the household use Cinder normally — request, approve, and use **manual search** on
`/books/:id` to pick releases (there is no automatic release search for books, by design; see
`docs/operating.md`'s Books and audiobooks section). Let the poller run unattended after that. Do
not manually intervene beyond what an operator would ordinarily do (checking `/dashboard`, reading
a parked reason, clicking Retry).

## At the end of the window: the roadmap's seven tracked categories

The roadmap asks that a sign-off decision track missed releases, wrong matches, parked causes,
duplicate attempts, metadata drift, scan failures, and recovery actions. **`book_ops_log` durably
tracks four of the seven** — duplicate attempts, metadata drift, scan failures, and scan recovery
are all real, wired write sites today, not a schema-only placeholder for some of them. Parked
causes are covered by a pre-existing surface. The remaining three have no code-observable signal
at all — say so honestly rather than inventing evidence for them:

| Category | How to check it | Mechanism |
|---|---|---|
| Parked causes | `/library?type=books&status=held`, and each target's own `/books/:id` hold reason | Already durable — `book_targets.hold_reason` |
| Duplicate attempts | Query `book_ops_log` for `category = 'duplicate_grab_refused'` | `book_ops_log` (B8b) |
| Metadata drift | Query `book_ops_log` for `category = 'metadata_drift'` | `book_ops_log` (B8b) |
| Scan failures / recovery | Query `book_ops_log` for `category IN ('scan_failure', 'scan_recovered')` | `book_ops_log` (B8b) |
| Missed releases | No automated record exists — a release the indexer never returned is invisible by construction, not a logging gap. Cross-check by spot-checking a handful of still-`:monitored` targets against the indexer/tracker directly. | Manual, operator judgment |
| Wrong matches | No automated record exists — a wrong import looks identical to a correct one by every mechanical measure Cinder has. Spot-check a sample of newly-`:available` targets against their actual file contents/metadata. | Manual, operator judgment |
| Recovery actions | No dedicated log exists for Retry/pause/resume/"Find a better match" clicks today. Cross-check against `book_ops_log`'s rows and the parked-causes list above for context on what needed recovering. | Manual, operator judgment |

Reading `book_ops_log` — the last 20 rows are also visible on `/library`'s books tab under
"Recent activity," but the window is two weeks, so query the database directly for the full
period:

```sh
sqlite3 /data/cinder.db \
  "SELECT category, COUNT(*) FROM book_ops_log
   WHERE inserted_at >= datetime('now', '-14 days')
   GROUP BY category;"
```

Or, from the running release, through the real read function rather than a raw query:

```sh
docker compose exec cinder bin/cinder rpc \
  'IO.inspect(Cinder.Books.list_recent_ops_log(1_000), pretty: true, limit: :infinity)'
```

**Two behavioral details that change what you should expect to see:**

- **`scan_failure`/`scan_recovered` are edge-triggered, not per-occurrence.** `Cinder.Books`'
  `log_scan_failure/1` writes one row only on the healthy-or-startup-to-failing transition, and
  `log_scan_recovered/0` writes one row only on the failed-to-succeeded transition — not one row
  per poller tick (the poller's 5-second interval would otherwise write roughly 241,920 rows over
  a continuously-down two-week window, which is not a count any operator can read). **Zero recent
  `scan_failure` rows does not mean "no failures happened"** — it means no new healthy→failing
  transition. Check which category the *most recent* `scan_failure`/`scan_recovered` row is, to
  know whether Audiobookshelf is currently down or currently fine:

  ```sh
  sqlite3 /data/cinder.db \
    "SELECT category, detail, inserted_at FROM book_ops_log
     WHERE category IN ('scan_failure', 'scan_recovered')
     ORDER BY id DESC LIMIT 1;"
  ```

- **`metadata_drift` compares the contributor NAME SET, not a count.** A same-cardinality author
  swap or a rename is detected (a count comparison alone cannot see that), and the `detail` column
  names the people actually added/removed/swapped — e.g. `"contributors: Old Name → New Name"` —
  not just a before/after count.

## Sign-off decision

- **Zero or fully-explained entries** in every category above → the roadmap's B8 Done-when
  criterion is met for this window; proceed to
  [decommissioning Bookshelf](readarr-migration.md#decommissioning-bookshelf-after-sign-off) if
  you are ready, or keep it running longer at no cost.
- **Any unexplained missing acquisition, wrong import, duplicate grab, unrecoverable parked
  state, or file loss** → do not sign off. File the concrete issue, fix it, and either restart the
  window or extend it — the roadmap's own instruction is "fix only concrete sign-off blockers;
  defer speculative parity," not to paper over an open question with a shorter window.
