# Books B8 dogfood checklist

This is the operator checklist for the roadmap's B8 Done-when window: two weeks with Readarr/
Bookshelf stopped (or left running but not depended on — see
[`docs/readarr-migration.md`](readarr-migration.md#decommissioning-bookshelf-after-sign-off) for
why it stays reachable until sign-off), tracking whether Cinder's e-book/audiobook pipeline is a
trustworthy replacement.

**What this window is, and is not.** Two weeks of real, unattended use are an operator-run,
elapsed-time observation — no test suite or code change can substitute for it, and none of this
document pretends otherwise. What B8 actually ships is the instrumentation that makes the window
legible: a durable log of the two pipeline events that previously left no trace at all, and this
checklist for reading it.

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

Let the household use Cinder normally — request, approve, and let the poller run unattended. Do
not manually intervene beyond what an operator would ordinarily do (checking `/dashboard`, reading
a parked reason, clicking Retry).

## At the end of the window: the roadmap's seven tracked categories

The roadmap asks that a sign-off decision track missed releases, wrong matches, parked causes,
duplicate attempts, metadata drift, scan failures, and recovery actions. Only some of these have
a durable, queryable record — say so honestly rather than inventing evidence for the rest:

| Category | How to check it | Mechanism |
|---|---|---|
| Parked causes | `/library?type=books&status=held`, and each target's own `/books/:id` hold reason | Already durable — `book_targets.hold_reason` |
| Duplicate attempts | Query `book_ops_log` for `category = 'duplicate_grab_refused'` | B8b instrumentation |
| Metadata drift | Query `book_ops_log` for `category = 'metadata_drift'` | B8b instrumentation |
| Scan failures / recovery | Query `book_ops_log` for `category IN ('scan_failure', 'scan_recovered')`, once wired to the Audiobookshelf publisher | B8b instrumentation (audiobook-only) |
| Missed releases | No automated record exists — a release the indexer never returned is invisible by construction, not a logging gap. Cross-check by spot-checking a handful of still-`:monitored` targets against the indexer/tracker directly. | Manual, operator judgment |
| Wrong matches | No automated record exists — a wrong import looks identical to a correct one by every mechanical measure Cinder has. Spot-check a sample of newly-`:available` targets against their actual file contents/metadata. | Manual, operator judgment |
| Recovery actions | No dedicated log exists for Retry/pause/resume/"Find a better match" clicks today. Cross-check against `book_ops_log`'s `duplicate_grab_refused`/`metadata_drift` rows and the parked-causes list above for context on what needed recovering. | Manual, operator judgment |

```sh
docker compose exec cinder bin/cinder rpc \
  'IO.inspect(Cinder.Repo.all(Cinder.Books.OpsLog), pretty: true, limit: :infinity)'
```

## Sign-off decision

- **Zero or fully-explained entries** in every category above → the roadmap's B8 Done-when
  criterion is met for this window; proceed to
  [decommissioning Bookshelf](readarr-migration.md#decommissioning-bookshelf-after-sign-off) if
  you are ready, or keep it running longer at no cost.
- **Any unexplained missing acquisition, wrong import, duplicate grab, unrecoverable parked
  state, or file loss** → do not sign off. File the concrete issue, fix it, and either restart the
  window or extend it — the roadmap's own instruction is "fix only concrete sign-off blockers;
  defer speculative parity," not to paper over an open question with a shorter window.
