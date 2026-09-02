# Books B8 — Hardening, documentation, and production sign-off

**Status:** planned 2026-09-02, ahead of B7 landing. Base: `main` @ `7c44d8dc` (post-B6c) plus the
current (uncommitted) [B7 plan](2026-09-02-books-b7-audiobooks.md) draft, which this document
treats as B8's contract for module names and file boundaries until B7 actually merges. **B8 is
sequenced strictly after B7** (the roadmap's own dependency graph) — nothing here can start until
B7's five slices land; every citation to a B7-owned module below is a forward reference to that
plan, not to code that exists today, and is named as such rather than presented as already built.
**Milestone:** [B8](2026-08-20-readarr-replacement-roadmap.md#b8--hardening-documentation-and-production-sign-off)
of the [Readarr replacement roadmap](2026-08-20-readarr-replacement-roadmap.md).
**Governing spec:** [the B0 parity contract](../specs/2026-08-20-books-parity-contract.md) and the
[Bookshelf inventory audit](../audits/2026-08-20-bookshelf-inventory.md). B8 adds no new catalog
behavior the contract has not already locked; its job is to verify what B2–B7 built against that
contract, close verified gaps, and retire the product surface's silence about books. §0 states
plainly what no amount of B8 engineering closes.

## What B7 (once landed) leaves, and what B8 owns

Once B7 ships as planned, the parity matrix's only two `required later` rows (audiobook target and
Spoken profile; Audiobookshelf filesystem and scan handoff — both owner B7,
`books_b0_contract_test.exs:738-744`) become discharged: an audiobook can be searched, graded,
imported (`Cinder.Acquisition.Audiobooks`/`AudiobookScorer`/`Cinder.Library.AudiobookSources`, per
B7a/B7b), and scanned into Audiobookshelf through the `Cinder.Library.AudiobookServer` behaviour
and its `Audiobookshelf` adapter (B7c — **not** "AudiobookPublisher," a name that appears nowhere
in the B7 plan or the repo), with retry, blocklist, pause/resume, and a manual-search UI
(`AudiobookManualSearchComponent`, B7d) on `/books/:id`. Every other row was already `required for
cutover` (shipped B2–B6), `already provided by Cinder` (shared infra), or `deliberately parked`
(Calibre, automatic upgrades). **B8's "no unacknowledged cutover requirement" Done-when criterion
is therefore a verification task against `books-parity-matrix-v1.json`, contingent on B7 landing
as planned, not new build work of its own** — confirmed by reading the matrix (§B8a below
re-asserts this as a test, not a manual review, and that test can only run once the B7 code it
traces actually exists).

What is genuinely still open after B7, verified by reading the code and product surface directly
rather than assumed:

1. **The entire product/doc surface is book-free.** `README.md`, `PRODUCT.md`, `ROADMAP.md`,
   `docs/operating.md`, `docker-compose.yml`, and `Dockerfile` contain zero mentions of books,
   ebooks, audiobooks, Bookshelf, Readarr, Booklore, or Audiobookshelf — grepped directly, zero
   hits in any of the six files. `mix.exs` is still `@version "2.0.0"`, unchanged since the
   pre-books release. `CHANGELOG.md`'s only related line is a forward-looking one-liner from the
   original per-kind settings refactor ("a new media type (books, audio) is a one-line addition"),
   never updated once books actually shipped.
2. **Backup already covers every new table with no B8 code.** `Cinder.DatabaseBackup` snapshots
   via `VACUUM INTO` (whole-database, `database_backup_test.exs`) — all eleven `book_*` tables are
   in the backup with no schema-specific logic. What is missing is documentation of the boundary:
   files on disk under `books`/`audiobooks` roots are **not** in a DB backup or its restore, and
   that boundary is stated nowhere today (`docs/operating.md` documents backup for the DB only,
   pre-dating books entirely).
3. **The bounded-work discipline is already excellent and book-specific work follows it — this
   is not a gap.** Every provider (`Hardcover`, `OpenLibrary`), archive extractor (`BookArchive.Zip`
   hand-parses with a live decompression-size ceiling; `BookArchive.Rar` runs `unrar` as a
   supervised, polled, hard-killed subprocess with `@max_duration_ms 60_000`), and `ffprobe` call
   (`Ffprobe` module, shared with video) already carries an explicit timeout/size/entry bound —
   confirmed by reading each module's source, not inferred from a moduledoc claim. Every
   `Repo.transaction` under `lib/cinder/books/`, `lib/cinder/library/` (book-adjacent), and
   `lib/cinder/download/` performs only DB reads/writes inside its transaction body — no HTTP,
   `System.cmd`, or filesystem extraction call happens inside a transaction (§B8a's audit
   enumerates every site and what runs inside it; the audit is real work, the answer is already
   "no gap" for every site checked).
4. **The cross-cutting UI checks (`translations_complete_test.exs`, `no_em_dash_test.exs`,
   `no_hardcoded_strings_test.exs`) already scan `lib/cinder_web/**` unconditionally** — they are
   not video-scoped and already cover every book/audiobook LiveView and component added since B2,
   confirmed by reading each test's file glob (`lib/cinder_web/**/*.ex` / `*.heex`, no kind
   filter). **This is not a gap**, contrary to the recon note that flagged it as one; §B8a asserts
   this explicitly with a scoped smoke check rather than re-deriving the tests.
5. **Failure-mode automated coverage is uneven, verified test-by-test, not by prose citation**
   (full itemization in §B8a.2). The genuine gaps: no `BookPoller`-specific crash/restart-recovery
   test (movies/TV both have `await_restart(Poller, ...)` / `await_restart(TvPoller, ...)`
   coverage; grepping `book_poller_test.exs` for the same pattern returns nothing), and no
   documentation of what backup/restore does and does not cover for on-disk book files (item 2).
   Permission (`EACCES`) and out-of-space (`ENOSPC`) failures **are** covered, but generically
   through `Cinder.Library`/`Cinder.Disk` (`import_stage_test.exs:94`, `disk_test.exs:31,68,94,
   256`) — every book import routes through those same modules, so the coverage is real, just not
   book-specific; recorded honestly rather than claimed as book-specific.

## §0. What B8 cannot close, and what it ships instead

The roadmap's B8 Done-when list mixes two different kinds of criteria:

| Criterion | Kind |
|---|---|
| `mix test` is green and all new provider/client/publisher calls are mocked in tests | **Engineering-closable.** Ordinary CI gate. |
| The complete post-fix diff receives one fresh bounded review with no unresolved correctness/security finding | **Engineering-closable.** A scoped review pass (§B8c) at PR boundary. |
| The B0 parity matrix has no unacknowledged cutover requirement | **Engineering-closable.** A test against `books-parity-matrix-v1.json` (§B8a.1). |
| Two weeks of dogfood produce no unexplained missing acquisition, wrong import, duplicate grab, unrecoverable parked state, or file loss | **Operator-gated.** Elapsed wall-clock time plus an operator watching a running household deployment. No commit in this repository advances a calendar. |
| Readarr remains recoverable until sign-off, then can be decommissioned explicitly | **Operator-gated.** A deployment/infrastructure action (stopping a container, updating DNS/mounts) outside this codebase; B8 can document the decommission steps but cannot perform or verify them from source. |

B8 does not pretend to discharge the two operator-gated rows. What it ships instead, to make the
two-week window actually *productive* rather than merely elapsed — the roadmap names seven tracked
categories ("missed releases, wrong matches, parked causes, duplicate attempts, metadata drift,
scan failures, and recovery actions"). Checked one at a time (§B8b.1): real durable coverage
already exists for one of the seven (parked causes), two more (scan failures/recovery) are now
buildable and built since B7c landed `Cinder.Library.AudiobookServer` on `main` before this PR
branched, and two are not mechanically observable from inside this codebase at all (missed
releases, wrong matches). B8 instruments every remaining, genuinely-uninstrumented,
buildable-today gap:

- A **book operations log** (§B8b), scoped to what is actually missing rather than to all seven
  categories: a durable record for duplicate-grab refusals (today silently discarded, no trace
  anywhere), metadata-drift detection on unattended refresh (today a blind overwrite with no
  comparison at all), and Audiobookshelf scan failure/recovery (today only a throttled log line).
  §B8b.1 states plainly which categories this does and does not cover, and why.
- A **dogfood readiness checklist** (`docs/books-dogfood-checklist.md`, §B8d) — the concrete,
  reusable steps an operator runs before starting the window (confirm backup, confirm Readarr
  still reachable, confirm the ops log is live) and at its end (query the ops log for the four
  categories it tracks, read the existing `hold_reason`/`/library?status=held` surface for parked
  causes, and rely on direct observation for the categories no code can watch).

Neither artifact makes two weeks pass faster or substitutes for an operator's judgment call; both
are the only parts of "run a two-week dogfood" that are actually code.

## Slice decomposition

| Slice | Owns | Est. |
|---|---|---|
| **B8a** | Parity-matrix verification test, bounded-work audit (documented, not new bounds), failure-mode gap closure (`BookPoller` restart-recovery test) | 1.5–2d |
| **B8b** | Minimal book-pipeline instrumentation: duplicate-grab-refusal log + metadata-drift detection on unattended refresh, read surface on `/library` | 3–4d |
| **B8c** | Security/privacy/accessibility review pass (SSRF/path-policy, secret redaction, role gating, requester/admin authorization, API privacy, gettext extraction, light/dark, a11y) against the full books diff since B2 | 1d review + fixes for whatever it finds (budget 1d) |
| **B8d** | Documentation and first-run validation: `README.md`, `PRODUCT.md`, `ROADMAP.md`, `docs/operating.md`, `docker-compose.yml`, `mix.exs`, `CHANGELOG.md`, `setup_live.ex` book/audiobook root checks, backup-coverage note, dogfood checklist, Readarr decommission runbook | 2–2.5d |

Total 7.5–9.5d — slightly above the roadmap's 5–8d estimate; the excess is metadata-drift
detection (§B8b) and first-run validation (§B8d), both discovered by fact-checking this plan
against the actual repo rather than assumed, not scope invented here. Each ends in `mix test`
green and is independently reviewable/mergeable: B8a and B8d touch disjoint files (tests/audit vs.
prose docs/setup) and can ship in either order; B8b is additive (one new migration/table plus two
new logging call sites — `Cinder.Books.Grabs.create/5`'s existing `:book_grab_exists` branch, and
`Cinder.Books.Refresher`'s import path) and depends on nothing from B8a; B8c is ordered last
because it reviews the cumulative diff, including B8a/B8b's own new code, and is scoped to
review-plus-targeted-fixes, not a rewrite.

---

## B8a — Parity verification, bounded-work audit, restart-recovery gap

### 1. Parity matrix: assert the post-B7 state, not just structure

`books_b0_contract_test.exs` already asserts `books-parity-matrix-v1.json`'s row-level structure
(every row has one of the four dispositions, `:60-64`) and, specifically, that the two audiobook
rows are `"required later"` owned by `"B7"` (`:738-744`). After B7 ships, those two rows are
*satisfied*, not merely *scheduled* — the matrix's disposition vocabulary has no "satisfied" state
distinct from "required for cutover" (a row's disposition names *when* work is required, not
whether it is done). B8a therefore does not change the fixture's disposition strings (that would
misrepresent the matrix's own frozen vocabulary, which B0's contract locks against undocumented
edits) but adds one new assertion in `books_b0_contract_test.exs`: for every row whose disposition
is `"required for cutover"` or `"required later"`, the code paths named in its acceptance criterion
exist and are exercised by at least one passing test — enumerated per row against `grep`-verified
call sites (e.g. the Audiobookshelf handoff row's "scan failure is retryable post-commit" maps to
whichever test B7c's own plan creates for the `AudiobookServer`/`Audiobookshelf` scan-retry
property — a forward reference to planned coverage, not a citation of code that exists today).
This is a **traceability** assertion (row → test file), not new production logic; it is what turns
"no unacknowledged cutover requirement" from a manual review claim into something `mix test`
enforces going forward, so a future edit that silently drops a covering test fails the suite.

### 2. Failure-mode scenario table

For every failure mode the roadmap names, verified against an actual test file (not prose):

| Scenario | Book-pipeline coverage today | B8 action |
|---|---|---|
| Deletion | No book target/file deletion feature exists at all (B5's and B7's own "What stays out" both confirm) — nothing to test because nothing exists to delete. | None. Out of scope; unchanged from B5/B7. |
| Replacement | `files_test.exs` ("replaying an already-committed replace import is a true no-op"), `book_poller_test.exs:734` (same, end-to-end through the poller) | Covered. No action. |
| Backup/restore | `database_backup_test.exs` covers the DB generically (VACUUM INTO, corruption rejection, no-clobber restore) — book tables ride along for free, but no test or doc names them specifically. | Document the DB-vs-files boundary (§B8d); add one `database_backup_test.exs` case asserting a `book_targets`/`book_files` row round-trips through backup+restore, closing the "for free" claim from an inference to an assertion. |
| Interrupted staging | `book_poller_test.exs:662-665` (crash between commit and grab-delete, re-import converges), `book_sources_test.exs`/`book_archive_test.exs` (stale scratch directory from a crashed extraction wiped on retry) | Covered. No action. |
| Out-of-space | `disk_test.exs:31,256` (`ENOSPC` propagated, not swallowed) — generic `Cinder.Disk`, exercised by every import path including books. | Covered (generically). No action; noted as shared infra in §B8a's write-up, not re-tested per-kind. |
| Permission | `import_stage_test.exs:94` (`EACCES` on cleanup), `disk_test.exs:68,94` (`EACCES` on read) — generic `Cinder.Library`/`Cinder.Disk`. | Covered (generically). No action. |
| Provider outage | `hardcover_test.exs`/`open_library_test.exs` (timeout/non-200 → `{:error, _}`, never raise), `identity_test.exs` (a provider outage never silently first-result-falls-back) | Covered. No action. |
| Indexer outage | `books_test.exs:161-166,192-197` ("every query failing is an error, so an outage is never read as an absence", `:indexer_unavailable`) | Covered. No action. |
| Client outage | `book_poller_test.exs:100-102,352-358` (client timeout on remove/status leaves the grab and target untouched, "an unreachable client is not evidence about the download") | Covered. No action. |
| Publisher outage | e-book: no publisher API exists (filesystem root **is** the publisher, per B5's own finding — nothing to be "down"). Audiobook: B7c's own plan already specifies scan-failure retry as a test-plan property ("a scan failure leaves the target `:available`... and a second tick retries") against the `AudiobookServer`/`Audiobookshelf` module it defines — no such module or test exists yet on `main`. | Deferred to B7c by design (not B8's to build). B8a's traceability assertion (§1) verifies the actual test exists once B7c merges; B8 does not write it or invent its filename in advance. |
| Restart recovery | Movies/TV: `poller_test.exs`/`tv_poller_test.exs` both have explicit `Process.exit(pid, :kill)` + `await_restart/2` crash-recovery tests. **Books: no equivalent exists** — `book_poller_test.exs` has crash-*replay* tests (re-running an already-committed step) but no test that kills the live `BookPoller` process and asserts the supervisor restarts it and it resumes work, unlike its movie/TV siblings. | **Genuine gap. B8a adds it**: a `BookPoller`-specific test mirroring `poller_test.exs`'s "the poller recovers from a crash and still advances work (OTP payoff)" — start `BookPoller` under `start_supervised!`, begin a download, `Process.exit(pid, :kill)`, `await_restart(BookPoller, pid)`, assert the next poll still advances the same grab to import. |

### 3. Bounded-work audit (documentation, one code check)

Produces `docs/audits/2026-09-02-books-bounded-work-audit.md`, enumerating (verified by reading
each site, not restating a moduledoc claim):

- Every provider call: `Hardcover`/`OpenLibrary` — `@max_response_bytes 4 MB`, `receive_timeout:
  15_000`, `connect_options: [timeout: 5_000]`, `pool_timeout: 5_000`, via `HTTPPolicy`.
- Archive extraction: `BookArchive.Zip` — streamed decompression with a live size ceiling checked
  during inflation, not after; entry-count ceiling. `BookArchive.Rar` — `unrar` as a supervised
  `Port`, `@max_duration_ms 60_000`, polled destination-size kill.
- `System.cmd`/subprocess invocations touching books: `unrar` (bounded above), `Ffprobe`
  (shared with video, `System.cmd` with no explicit timeout on the Elixir side — flagged as a
  pre-existing, video-and-books-shared limitation, not new to B8, and out of scope to fix here
  since it is not book-specific: filed as a note in the audit, not a code change).
- ffprobe calls: `MediaInfo`/`Ffprobe` — degrade to "unknown, import anyway" (audio-language check)
  or `{:unavailable, _}` (policy verification), never block indefinitely; no explicit process
  timeout is set (same note as above).
- Library scans: no book-side polling scan exists beyond the poller tick interval itself (config,
  not per-call bound) — nothing to add.
- Every `Repo.transaction` under the three named directories, with what runs inside each: listed
  exhaustively — `adoption.ex:97` (DB inserts only, `import_resolution/1`'s own transaction wraps
  further DB-only calls), `book_target_transition.ex:44` (one `update_all`), `files.ex:43`
  (`maybe_supersede`/`insert_or_existing`/`arm_target`, all DB), `migration_adoption.ex:684`
  (`revalidate_catalog`, DB reads). **No I/O other than the SQLite connection itself runs inside
  any of them.** This closes the roadmap's "verify no unbounded work runs inside Ecto
  transactions" line as a documented, evidence-backed pass, not an assumption.

### Done when

- `books_b0_contract_test.exs` gains the traceability assertion (§1); it fails if a future edit
  removes a test a `required for cutover`/`required later` row depends on.
- A `BookPoller` crash/restart-recovery test exists and passes, mirroring `poller_test.exs`'s own
  property.
- `database_backup_test.exs` gains one case asserting a book row survives backup+restore.
- `docs/audits/2026-09-02-books-bounded-work-audit.md` is committed.
- `mix test` green.

---

## B8b — Minimal book-pipeline instrumentation

### 1. Audited against what already exists — four categories, four different answers

The roadmap asks B8 to help track seven categories during dogfood: missed releases, wrong matches,
parked causes, duplicate attempts, metadata drift, scan failures, and recovery actions. Checked one
at a time against actual code, not assumed:

- **Parked (with reason) — already durable, queryable, and rendered. No B8 code needed.**
  `book_targets.hold_reason`/`hold_transient` (`book_target.ex:20-21`) are written by
  `Books.hold_target/4`, which fires `{:book_target_held, target}` (`books.ex:278`), is filterable
  at `/library?type=books&status=held` (`library_live.ex:396,538-540`), and is shown with its exact
  reason on `/books/:id` (`book_detail_live.ex:596-601`). The only real gap — losing a prior hold's
  reason when a target is later re-held for a different one — is not what the roadmap asks for
  ("parked causes," not "parked-cause history"), so it stays out.
- **Duplicate attempts — genuinely nowhere, not even `Logger`. Real gap; B8b instruments it.**
  `Books.Grabs.create/5` returns `{:error, :book_grab_exists}` (`grabs.ex:49-51`) when the DB's
  unique-index fence catches a repeated grab; `Download.create_book_grab/1` converts that into
  `:download_intent_busy` and silently deletes the intent (`download.ex:898-900`) with no log at
  all; the poller treats a duplicate as bare success (`poller.ex:108-112`). Nothing durable records
  that this ever happened.
- **Metadata drift — genuinely nowhere, and needs real new logic, not a hook into an existing
  diff.** `Cinder.Books.Refresher` re-fetches a monitored work and folds it through
  `import_resolution/1` → `upsert_in_tx/5` (`books.ex:785-1021`), which is a blind
  changeset-and-update: no branch anywhere compares the work's prior title/contributor-set/edition
  state against the refreshed one before overwriting. Building a comparison is real, scoped work
  (§3), not a one-line log call at an existing branch — corrected from an earlier draft of this
  plan, which wrongly claimed the refresher "already computes" such a diff.
- **Scan failures/recovery — was "cannot be built yet," now buildable and built.** An earlier
  draft of this plan, written ahead of B7 landing, deferred this pair because the target module
  (`AudiobookServer`, B7c) did not exist on `main` at the time. B7c has since landed as `4d36d825`
  and B7d/B7e as `eae8ebc9`: `Cinder.Library.AudiobookServer` and the retryable-scan mechanism
  (`Cinder.Download.BookPoller`'s `scan_pending/1`/`request_audiobookshelf_scans/0`) are on `main`
  now, so both write sites named in §2's schema comment are real, reachable call sites, not a
  forward reference. B8b wires both.

Two roadmap categories have no code-observable signal at all, and B8b does not attempt one:
**missed releases** (nothing in this codebase names the event "a release existed and matched but
was never grabbed" — the scorer only ever reports acceptance/rejection of releases it actually
saw; a release the indexer never returned is invisible by construction, not a logging gap) and
**wrong matches** (an operator judgment call made after import completes successfully by every
mechanical measure available). **Recovery actions** (Retry, clear-blocklist, pause/resume, replace)
are likewise not logged anywhere today — no `Cinder.Audit` call exists on any book-target LiveView
event handler, verified by grep. Instrumenting operator actions is real, additional scope beyond
what B8b builds; it is named here as an acknowledged gap, not silently dropped, and would be a
natural low-cost follow-up once this table exists (each handler gains one more log call in the
identical shape §3 establishes), not something this slice builds speculatively ahead of demand.

**Honest summary: of the roadmap's seven tracked categories, B8b closes four (duplicate attempts,
metadata drift, scan failures, scan recovery) with new code, one is already covered by existing
surfaces (parked), and two remain genuinely untracked by any mechanism (missed releases, wrong
matches) because no code signal exists to hang a log on.**

### 2. Schema

New table, migration `priv/repo/migrations/<ts>_create_book_ops_log.exs`:

```elixir
create table(:book_ops_log) do
  add :book_target_id, references(:book_targets, on_delete: :nilify_all)
  add :category, :string, null: false  # "duplicate_grab_refused" | "metadata_drift" |
                                        # "scan_failure" | "scan_recovered"
  add :detail, :string, null: false
  timestamps(type: :utc_datetime, updated_at: false)
end

create index(:book_ops_log, [:category])
create index(:book_ops_log, [:inserted_at])
```

`book_target_id` is nullable (`on_delete: :nilify_all`) so a log row outlives a deleted target —
there is no book-target deletion feature today (§B8a.2), but the column is written defensively
against a future one, exactly as `book_blocked_releases`' own FK does. No new backup work: it is
one more table under the existing `VACUUM INTO` snapshot.

### 3. Write sites — four, shipped in this slice, all best-effort and post-commit

Mirrors `Cinder.Books.hold_target/4`'s own "best-effort, log and continue on failure" blocklist
insert precedent (B5a) — an ops-log write failure never blocks or rolls back the operation it is
recording:

- `Books.Grabs.create/5`'s existing `{:error, :book_grab_exists}` branch
  (`test/cinder/download/book_poller_test.exs:842` asserts the refusal itself, not this new log —
  a new, separate test case covers the log write) — logs `category: "duplicate_grab_refused"`
  before returning the error; the refusal behavior itself is unchanged.
- `Cinder.Books.Refresher` gains an actual comparison: before calling `import_resolution/1`, read
  the work's current `title` and current contributor NAME SET via a narrow, two-query
  `Books.work_identity_snapshot/1` read (not the full `get_work/1` preload shape, which the
  refresher does not otherwise need); after the refresh commits, compare against the new values.
  A change to either logs `category: "metadata_drift"` with a `detail` naming what changed
  (`"title: old → new"`, or, for contributors, the actual names added/removed/swapped, e.g.
  `"contributors: Old Name → New Name"` for a same-count swap, or `"contributors: added A, B;
  removed C"` otherwise — **a count comparison alone cannot see a same-cardinality swap**, which
  is exactly the failure mode this exists to catch, so the comparison is over the name set, not
  its size). Both comparisons are trimmed and case-folded before comparing, so whitespace or
  capitalization noise from a provider is never reported as drift. This is genuinely new
  comparison logic, sized to the two fields most likely to silently drift and cause a
  wrong-looking catalog entry during two unattended weeks, not every field `import_resolution/1`
  touches.
- `Cinder.Download.BookPoller`'s `scan_pending/1`: an `AudiobookServer.impl().scan()` failure logs
  `category: "scan_failure"` only on the healthy-or-startup-to-failing transition, and a later
  successful scan logs `category: "scan_recovered"` only on the failed-to-succeeded transition
  (both tracked in one `:persistent_term` flag, the same VM-global, cross-restart-durable
  mechanism `PollerSkeleton` already uses for its own tick stamps). Deliberately not "every
  occurrence": this call site's poller tick is 5 seconds, so a continuously unreachable
  Audiobookshelf across the full two-week dogfood window would write 14 * 86,400 / 5 = 241,920
  rows under an every-occurrence design — not a count any operator can read. One row marking
  when an outage started, paired with one marking when it ended, answers the operator's actual
  question ("is it down, and for how long") without unbounded growth, and a steady run of
  healthy ticks never accumulates a row either.

### 4. Read surface

`/library`'s books tab (`LibraryLive`, B5c) gains a small "Recent activity" panel — the last 20
`book_ops_log` rows, newest first, target title linked where `book_target_id` is present, French
`gettext`-backed category labels. Read-only, no new write affordance; a new ops-log row insertion
broadcasts `{:book_ops_log_entry, entry}` so an open `/library` tab updates live, matching every
other LiveView-visible table's existing convention in this codebase.

### Done when

- Each of the four write sites produces exactly one `book_ops_log` row per occurrence (or, for
  `scan_recovered`, per failed-to-succeeded transition), asserted in new test cases extending
  `test/cinder/books/grabs_test.exs` (duplicate-grab), `test/cinder/books/refresher_test.exs`
  (metadata-drift), and `test/cinder/download/audiobookshelf_scan_test.exs` (scan
  failure/recovery) respectively.
- A log-write failure (simulated `Repo` error) does not fail or roll back the operation it
  instruments — asserted directly, mirroring `hold_target/4`'s own blocklist-write-failure test.
- `/library`'s books tab renders the panel and updates live on a new entry (`library_live_test.exs`
  case).
- Every new label goes through `gettext` with a real French translation
  (`translations_complete_test.exs` stays green with zero new fuzzy/missing entries).
- `mix test` green.

---

## B8c — Security/privacy/accessibility review pass

A scoped review of the cumulative books diff (B2 through B8b), not a rewrite. Checklist, each item
with a concrete artifact to check against, not a general audit:

- **SSRF/path policy.** `Cinder.Library.PathPolicy.contained?/2` gates every book/audiobook write
  destination (`BookNaming`, and `AudiobookNaming` once B7 lands) exactly like video;
  `Library.safe_source_file`/`safe_walk` gate every archive/file read (`BookArchive`,
  `BookSources`) — confirm no book-specific path construction bypasses either, by grepping every
  `Path.join` under `lib/cinder/library/book*` and `lib/cinder/library/audiobook*` for one that
  skips the shared helper.
- **Secret redaction.** `hardcover_api_key`/`open_library_api_key` (if any) and, once B7c lands,
  `audiobookshelf_api_key` — like the already-shipped `readarr_api_key` — are `Cloak`-encrypted,
  `secret: true` registry fields per AGENTS.md's existing mechanism; confirm each new B7 settings
  field actually sets `secret: true` and is never interpolated into a log line (grep
  `Logger.\w+.*api_key` under `lib/cinder/books/`, `lib/cinder/library/`).
- **Role/route gating.** `/books/:id`, `/library?type=books`, and every new B8b read surface sit
  inside the same `live_session` role gates as their video siblings — confirm no book route was
  added outside an existing `:admin`/authenticated `live_session` block in `router.ex`.
- **Requester/admin authorization** (roadmap Work item 3, named explicitly, not folded into route
  gating above). Confirm a non-admin requester can request a book/audiobook work only through
  `Cinder.Requests`' existing approval-gate choke-point — no book-specific path creates a
  requested-state row outside it — and that every admin-only book action (retry, pause/resume,
  replace, author-policy edits) is unreachable by a non-admin session.
- **API privacy** (roadmap Work item 3, named explicitly). Confirm `/api/v1` never exposes a book
  work/target's provider identifiers, internal ids, or file paths beyond what the equivalent
  movie/TV API surface already exposes, and that the same `CinderWeb.Plugs.ApiAuth`/household-key
  gate covers any book-related API route added since B2.
- **Gettext extraction** (roadmap Work item 3, named explicitly — already enforced, verified here
  rather than re-derived). `test/cinder_web/translations_complete_test.exs`'s `:gettext_extract`
  tag already runs `mix gettext.extract --check-up-to-date`; confirm it stays green through every
  B8 slice's new strings rather than assuming it does.
- **Accessibility.** New components from B7d (`AudiobookManualSearchComponent`, once it lands) and
  B8b (the ops-log panel) get icon-only-control `aria-label` review against the same bar
  `liveview-ui-reviewer` applies to video components.
- **Light/dark theme.** Visual smoke check of the audiobook manual-search panel (once B7d lands)
  and the ops-log panel in both daisyUI themes.

### Done when

- Every checklist item above has an explicit pass/fail note in the PR description, with file:line
  for anything fixed.
- Any finding is fixed in the same PR (budgeted 1 day; if a finding is large enough to need more,
  it is filed as a separate issue per AGENTS.md's "audits deliver issues, not inline fixes" rule
  and named explicitly as deferred, not silently dropped).
- `mix test` green.

---

## B8d — Documentation and product-surface cutover

Per-file, exactly what changes:

- **`README.md`** — adds books/audiobooks to the feature list alongside movies/TV; names Booklore
  and Audiobookshelf as the consumers, matching the movies/TV section's existing Jellyfin/Plex
  phrasing exactly.
- **`PRODUCT.md`** — extends the product description's request→approve→acquire→publish loop to
  name books/audiobooks as a third and fourth request kind, alongside movie/TV.
- **`ROADMAP.md`** — since it is the "build record," appends a short B0–B8 summary section in the
  same historical style as the existing M0–M8/A0–A6 entries, not a live plan (matching AGENTS.md's
  own framing of this file).
- **`docs/operating.md`** — the settings section (currently listing only
  `movies_library_path`/`tv_library_path`-equivalents, per the recon's line-148 citation) gains
  `books_library_path`/`audiobooks_library_path` — **settings-store rows, not env vars**, per
  AGENTS.md's "no new service env var; add a `Cinder.Settings` registry entry" rule and confirmed
  directly against `Cinder.LibraryKind`'s `root_role(:ebook) == :books` /
  `root_role(:audiobook) == :audiobooks`, which is what `Settings.Registry`'s per-role
  comprehension already turns into those two setting keys. The backup section gains the
  DB-vs-files boundary paragraph named in §B8a's audit: *the database backup captures every
  `book_*`/`audiobook_*` catalog row; it does not capture the files themselves under the `books`/
  `audiobooks` roots — those are the operator's own filesystem backup responsibility*, worded
  identically to whatever the existing (if any) equivalent note says for movies/TV, or added fresh
  if none exists.
- **`docker-compose.yml`** — no example book/audiobook root bind-mount exists today alongside the
  movies/TV ones; adds `./books:/data/books` and `./audiobooks:/data/audiobooks` example mounts,
  matching the existing movies/TV mount style exactly.
- **`lib/cinder_web/live/setup_live.ex`** (first-run validation, roadmap Work item 5, verified
  absent today: `required_services/0` builds its checklist from `Settings.library_kinds()` filtered
  to `video?: true` only, `setup_live.ex:17-24` — first run validates the movies/TV roots and never
  checks `books_library_path`/`audiobooks_library_path` at all, even though both are already
  operator-configurable settings once books ship). Drops the `video?: true` filter so every
  configured `LibraryKind` contributes its own `"#{kind}_library"` check, and `service_label/1`
  gains `"books_library"`/`"audiobook_library"` clauses alongside the existing
  `"movies_library"`/`"tv_library"` ones. A fresh install now fails first-run Finish until its book
  and audiobook roots are writable, exactly like movies/TV already do.
- **`Dockerfile`** — no book-specific runtime dependency needs adding: `unrar` presence is already
  optional (feature degrades to `:unsupported_archive`, §B8a's audit), and `ffprobe` is already
  shipped for video. Confirmed no new binary is required; **no change**.
- **`mix.exs`** — bump `@version` to `"2.1.0"` (minor: a genuinely new top-level feature surface,
  matching the project's own precedent of moving `2.0.0` at the movies/TV/multi-user release).
- **`CHANGELOG.md`** — a new dated entry under the version bump, summarizing books/audiobooks as a
  feature addition (one paragraph, in the file's existing entry style — not a slice-by-slice
  history, which belongs in the plan docs, not the changelog).
- **New: `docs/books-dogfood-checklist.md`** — the operator checklist named in §0: pre-window
  (confirm a fresh verified backup exists, confirm Readarr/Bookshelf instances remain running and
  reachable, confirm the B8b ops log is receiving writes) and post-window (query `book_ops_log` for
  duplicate-grab-refusal and metadata-drift entries over the elapsed window; read
  `/library?status=held` for parked causes; note that missed releases, wrong matches, and recovery
  actions have no automated record and must be assessed from direct operator observation — either
  "zero/explained" across all seven roadmap categories or "unexplained — do not sign off").
- **New: `docs/readarr-decommission.md`** — the explicit steps to stop and remove the two Bookshelf
  containers and their settings rows, gated behind "only after the dogfood window's sign-off
  decision," extending B6c's existing migration runbook rather than duplicating its prose.

### Done when

- Every file above is updated exactly as specified; grepping the same set of terms the recon used
  (books, ebook, audiobook, Bookshelf, Readarr, Booklore, Audiobookshelf) against `README.md`,
  `PRODUCT.md`, `docs/operating.md`, `docker-compose.yml` now returns non-zero hits.
- `docs/books-dogfood-checklist.md` and `docs/readarr-decommission.md` exist and are linked from
  `docs/operating.md`.
- `mix test` green (no test asserts documentation content directly, but the settings-key names used
  in `docs/operating.md` are checked against `Cinder.Settings.Registry`'s actual accessor names
  before merge, so nothing here invents a nonexistent key).

---

## Roadmap Done-when → slice mapping

| Roadmap criterion | Satisfied by |
|---|---|
| `mix test` is green and all new provider/client/publisher calls are mocked in tests | All slices; enforced at every PR boundary. |
| The complete post-fix diff receives one fresh bounded review with no unresolved correctness/security finding | **B8c**. |
| The B0 parity matrix has no unacknowledged cutover requirement | **B8a** (traceability assertion against `books-parity-matrix-v1.json`). |
| Two weeks of dogfood produce no unexplained missing acquisition, wrong import, duplicate grab, unrecoverable parked state, or file loss | **Operator-gated (§0).** B8b's ops log and B8d's checklist are what B8 ships to make the window legible; the elapsed window itself is not engineering-closable. |
| Readarr remains recoverable until sign-off, then can be decommissioned explicitly | **Operator-gated (§0).** B8d's decommission runbook documents the steps; performing them is an operator action after sign-off, outside this repository. |

## What stays out

- **Fixing the `Ffprobe`/`System.cmd` process-level timeout gap.** Flagged in §B8a.3 as real but
  pre-existing and shared with video, not book-specific — fixing it here would be exactly the
  "audit finds something, ship a rewrite" scope creep AGENTS.md's audit workflow warns against;
  it is a candidate for its own issue, not a B8 line item.
  Repo transaction sites — none exist today (§B8a.3's finding), so there is nothing to close.
- **A general book-target deletion feature.** B5 and B7 both declined it explicitly; B8 finds no
  new evidence that changes that judgment, and the ops-log (B8b) does not need it — a held
  target's payload staying on disk is already the documented recovery story.
- **Automated dogfood-window analysis or alerting.** The ops log (B8b) is a passive read surface;
  it does not page an operator or auto-decide sign-off. Building that is speculative given the
  roadmap names a manual operator review at the end of the window, not an automated gate.
- **Load/performance benchmarking beyond what B0 already captured.** The parity contract is
  explicit that its latency figures are "a representative deployment snapshot, not a load
  benchmark"; B8 does not add new load-testing infrastructure on that basis.
- **A second production asset/container build tool.** The roadmap's own Verification section
  already names "the repository's production asset build, container build, migration/rollback
  rehearsal ... and the B0 corpus end-to-end suite" as pre-release steps run once, manually, at
  release time — not a new CI job B8 needs to author.
