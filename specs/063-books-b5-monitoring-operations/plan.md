# Books B5 — Monitoring, wanted state, author policies, and operations

**Status:** planned 2026-09-01. Base: `origin/main` (post-B4c, post the two operator-surface
fixes below).
**Milestone:** [B5](2026-08-20-readarr-replacement-roadmap.md#b5--monitoring-wanted-state-author-policies-and-operations)
of the [Readarr replacement roadmap](2026-08-20-readarr-replacement-roadmap.md).
**Governing spec:** [the B0 parity contract](../specs/2026-08-20-books-parity-contract.md) — owns
the monitoring-state vocabulary, the author-policy requirement, the accepted-format list, and the
metadata-provider set. Decisions below are *taken* from it, not chosen; §0 records the one place
it is silent.

## What B4c left, and what B5 owns

B4c shipped the operator surface for a *single* monitored e-book target: `/books/:id`, manual
release search, Grab, and live download progress. Its own "What stays out" ([§10 of the B4c
plan](2026-09-01-books-b4c-operator-surface.md#10-what-stays-out)) named four things explicitly
as B5's to pick up — retry/blocklist-clearing for a `:held` target, "Find a better match" for an
`:available` one, and the `/library` books tab — plus one obligation it flagged but could not
discharge itself (the `:unmonitored` blank-badge case). Two of those are **already done**,
confirmed against current code, not taken on the task's word:

- **The `/library` books tab shipped read-only**, post-B4c (commit `81514704`, PR #417).
  `CinderWeb.LibraryLive` already has a third tab (`?type=books`), listing every `BookTarget`
  with its status badge and a link to `/books/:id` (`library_live.ex:1-70,235-238,315-317,
  363-366,667-711`). It writes nothing — no cancel/delete/pause exists on it today. That gap is
  exactly what B5c below closes.
- **The `:unmonitored` badge exists.** `CinderWeb.LiveHelpers.book_badge_state/2` already has
  `book_badge_state(nil, :unmonitored), do: :unmonitored` (`live_helpers.ex:94`, commit
  `ed93614f`, PR #410), and `BookComponents.book_state_badge/1` renders it (only `:none` renders
  nothing). B4c's "blank-badge obligation" is discharged — nothing in B5 needs to touch the
  badge helper itself. B5a below is what makes `:unmonitored` actually *reachable* on an
  already-approved target for the first time (pause), which is the event B4c's note anticipated.

One more correction to the roadmap's own B5 "Likely files" list, found while reading
`lib/cinder/health.ex` rather than assumed: **book-root AND publisher health are already shipped
— because for books today they are the same probe.** The roadmap's Work list names "health for
metadata provider, publisher, book roots, and audiobook/e-book-specific dependencies" as four
nouns; tracing the actual publish path (`BookImport.import_grab/1` → `place/6`, `book_import.ex:
47-83`) shows there is no separate publisher *component* to health-check yet — books publish by
`StageEngine.stage_book_place/3` writing directly under `Settings.library_root(media_kind,
target)`, the identical hardlink/copy filesystem staging movies/TV already use, gated by
`BookNaming.book_dest/3`. There is no Calibre adapter wired in (contract parks it) and no
Audiobookshelf API call (B7). `Health.library_checks/0` already iterates every non-video
`LibraryKind` and reports `{:library, :ebook}`/`{:library, :audiobook}` (`health.ex:107-116`) via
the same writable-path probe movies/TV use — and since the filesystem root **is** the whole
publisher for books today, that probe already answers "is the publisher reachable," not just "is
the directory present." A future publisher adapter (Calibre/Audiobookshelf, both parked past B5)
would be the first time "publisher health" and "book-root health" diverge into two different
questions; until one exists, there is exactly one component and one probe. "Health for... book
roots [and publisher]" needs no B5 code. What is genuinely missing — verified
by grep, no `health/0` callback exists anywhere on `Cinder.Books.Metadata` or its adapters — is
**metadata-provider health**, which B5c adds.

## §0. A B0 gap: no numeric threshold for automatic *release* selection

The task that produced this plan asked for "the corpus precision threshold that gates automatic
release selection," to be taken from the contract. It is not there. The parity contract's
[metadata provider decision](../specs/2026-08-20-books-parity-contract.md#metadata-provider-decision)
sets a 90% threshold for **work identity resolution** (Open Library + Hardcover measured
92.5%) — that gates *which providers B2 must implement*, and it is already met and shipped. It
says nothing about a precision bar for *matching a release to a chosen edition*, which is what
`Cinder.Acquisition.Books.candidates/2`'s eventual `best_book_release/2` would need. The roadmap's
own prose ("enable automatic choice only after corpus precision meets the B0 threshold",
quoted verbatim in `lib/cinder/acquisition/books.ex:10-17`) asserts such a threshold exists; the
contract does not define one for this axis.

This is a genuine B0 gap, not a B5 decision to paper over. It does not block this plan: the
roadmap's own B5 Work list is unambiguous regardless — "**Keep automatic upgrades parked**; expose
a manual 'Find a better match' path only after initial acquisition is stable" — so B5 does not
add `best_book_release/2` or a `BookPoller` search pass under any reading. Flagged here so a
later milestone does not invent a number to fill the gap without an explicit spec change, per the
contract's own amendment rule (line 19).

## Slice decomposition

| Slice | Owns | Est. |
|---|---|---|
| **B5a** | Retry, book release blocklist, "Find a better match" (replace), bounded unattended retry (`Books.Rehunter`) | 4–5d |
| **B5b** | Author monitoring policies: preview, confirm, bounded bibliography refresh | 4–5d |
| **B5c** | Wanted/Missing filter + pause/resume on `/library`, metadata-provider health, book-target notifier events, quiet logging | 2–3d |

Each ends in `mix test` green and is independently reviewable/mergeable in order — B5b's preview
UI lives on `/books/:id`, which B5a is also editing, but touches disjoint functions
(`set_author_policy`/`preview_author_policy` vs. `retry_target`/blocklist), so B5b rebases cleanly
onto B5a. B5c's `library_live.ex` edits are independent of both and could ship first if desired;
ordered last here only because "visible" (its Done-when contribution) reads better once B5a's
holds and B5b's policy-driven targets exist to *be* visible.

---

## B5a — Retry, blocklist, and "Find a better match"

### 1. The blocklist: a table with no B4-era equivalent

Movies and TV bound their *automatic* re-grab loop with `blocked_releases`
(`Cinder.Catalog.Grabs`, `catalog/grabs.ex:534-626`) — every automatic re-search excludes a title
already proven bad. Books have no automatic search pass (fact, unchanged by B5), so nothing has
needed this yet: a `:held` book target today just sits there with a `hold_reason` string
(`books.ex:224-228`) and no memory of *which release* failed. That breaks the moment B5 adds two
manual re-entry points that must not re-offer a release just proven bad: Retry (§2) and Find a
better match (§3).

New table, migration `priv/repo/migrations/<ts>_create_book_blocked_releases.exs`:

```elixir
create table(:book_blocked_releases) do
  add :book_target_id, references(:book_targets, on_delete: :delete_all), null: false
  add :release_title, :string, null: false
  add :reason, :string, null: false
  timestamps(type: :utc_datetime)
end

create index(:book_blocked_releases, [:book_target_id])
```

No unique constraint — mirrors `blocked_releases` (`catalog/blocked_release.ex`), which has
none either; a repeat block of the same title is harmless, and `insert_blocked_release/1`'s
existing pattern of "best-effort, log and continue on failure" is what `Books.block_release/3`
below copies.

`Cinder.Books` (`books.ex`) gains:

- `hold_target(target, reason, release_title \\ nil, transient \\ false)` — the existing 2-arity
  `hold_target/2` becomes a thin call into this with `release_title: nil, transient: false`;
  unchanged callers keep working. `transient` is written to the new `hold_transient` column
  (§5) in the same guarded transition; it has no bearing on the blocklist write below.
  Behavior: the guarded transition runs exactly as today (`expect: :monitored`), and **only on
  `{:ok, held}`**, if `release_title` is present, a best-effort
  `%BookBlockedRelease{book_target_id: held.id, release_title: release_title, reason:
  hold_reason(reason)}` insert follows — after commit, non-transactional, matching
  `Catalog.reap_stalled_upgrade/1`'s own "block after the revert commits" ordering
  (`catalog.ex:724-750`) and `insert_blocked_release/1`'s "the writer is best-effort by design"
  comment (`catalog/grabs.ex:605-621`). A failed insert is logged and swallowed — the hold itself
  already recorded the failure durably; the blocklist row is a convenience for the next search,
  not the record of truth.
- `blocked_release_titles(target_id)` — read, downcased-or-not exact titles for `target_id`,
  mirroring `Catalog.blocked_release_titles/1` exactly — defined in `catalog/grabs.ex:623-625`
  and merely `defdelegate`d from `catalog.ex:1397`, not defined in `catalog.ex` itself.
- `clear_blocklist(target_id)` — `Repo.delete_all` scoped to the target. No status write, no
  broadcast — mirrors `Catalog.clear_stalled_blocklist/1`'s "no side effect" contract
  (`catalog/grabs.ex:571,577,583`, its three clauses).
- `retry_target(target)` — `transition_target(target, %{status: :monitored}, expect: :held)`.
  One line: `BookTarget.transition_changeset/2` already clears `hold_reason` automatically the
  moment status leaves `:held` with no explicit `hold_reason` in `attrs`
  (`book_target.ex:58-66`); §5 extends that same clearing branch to also null `hold_transient`.
  Deliberately does **not** clear the
  blocklist — a manual retry re-enters `:monitored` for a *human* to pick a *different* release
  next; the dead one staying blocklisted is what stops it being re-offered by the very next
  search (§4 wires the blocklist into the scorer).
- `pause_target(target)` — **not** a plain guarded transition. Traced the race first: a bare
  `transition_target(target, %{status: :unmonitored}, expect: :monitored)` would succeed even
  while a `BookGrab` is downloading, because a grab never changes `book_targets.status`
  (`book_poller.ex` lists/advances grabs independently of target status). If the download then
  completes, `Files.record_import/3` → `arm_target/1` guards `status in [:monitored, :available]`
  (`files.ex:98-107`) — now neither, since the target is `:unmonitored` — so it matches zero
  rows, `{0, _} -> {:error, :stale_status}`, the whole `record_import/3` transaction rolls back
  (no `book_files` row), and `BookPoller.do_import_one/2`'s `{:error, :stale_status}` clause just
  **deletes the grab and returns `:ok`** (`book_poller.ex:337-339`) — no fence, no cleanup call.
  A successfully downloaded, already-validated file is silently lost: the grab record is gone and
  nothing ever imports the bytes the download client already delivered. A UI-only gate (disabling
  the Pause button while a grab shows) does not close this — a second admin tab, or a grab created
  in the instant after the button rendered, races it regardless.

  Fix: `pause_target/1` performs the guarded status transition **and** a `book_grabs`
  non-existence check inside one `Repo.transaction/1`, rolling back with `{:error,
  :grab_in_progress}` if a grab for the target exists — closing the race rather than narrowing it,
  since SQLite serializes concurrent writers (WAL + `busy_timeout: 5000`, per AGENTS.md) so a
  grab-creation write racing this transaction serializes against it instead of interleaving.
  `BookDetailLive`/`library_live.ex` render `{:error, :grab_in_progress}` as a flash ("This target
  has a download in progress — wait for it to finish before pausing.") rather than a generic
  failure.
- `resume_target(target)` — `transition_target(target, %{status: :monitored}, expect:
  :unmonitored)`. `profile_id` is untouched by either — it was set at approval and pausing never
  clears it, so resume needs no profile re-selection.

Callers updated to pass the release title where one exists — verified against the real signatures,
not assumed:

- `Download.abandon_reserved/2` (`download.ex:731-736`) has the title in scope (`intent.release`,
  the map form of `%Release{}`) but does not itself call `hold_target`; it calls the private
  `hold_book_target(target_id, reason)` (`download.ex:743-748`), whose signature carries neither
  the intent nor a title today. Both change: `abandon_reserved/2` reads
  `intent.release["title"]` and passes it through a new third argument to `hold_book_target/3`,
  which forwards it into `Books.hold_target/4` — a signature change to a private function, called
  out explicitly since an earlier draft implied the title was already reachable inside
  `hold_book_target/2` without one.
- `BookPoller.hold/3` (`book_poller.ex:369-383`) already has `grab` (and therefore
  `grab.release_title`) directly in scope — no signature change needed there.
- `BookPoller.hold_orphaned_target/2` (`book_poller.ex:274-284`) does **not** have `grab` in
  scope — its signature is `(target, reason)`, called from `fail_download/2`
  (`book_poller.ex:266-272`), which is the function that actually holds `grab`. Fixed the same
  way: `fail_download/2` passes `grab.release_title` through a new third argument to
  `hold_orphaned_target/3`. An earlier draft of this plan said `grab.release_title` was "already
  in scope" inside `hold_orphaned_target/2` itself, which is wrong as written — corrected here
  rather than left for an implementer to discover mid-diff.


**This slice ships `hold_target/4` with no `Notifier.notify` call.** B5c adds exactly one line to
its success branch (§B5c.3) — noted here explicitly so a reviewer of B5a's diff does not read the
absent notify as an omission; it is a deliberate boundary between the two slices, not a gap.


### 2. Retry, on `/books/:id`

`BookDetailLive`'s existing `searchable?/2` gate (`book_detail_live.ex:170-171`) only ever
rendered a search button for `%BookTarget{media_kind: :ebook, status: :monitored}` with no grab.
This slice adds a second render branch, not a widened `searchable?/2` — the UX differs (Retry is
a one-click state change, not a search panel):

- `status == :held` → a **Retry** button (`phx-click="retry_target"`, target id) calling
  `Books.retry_target/1` directly. On success the live `{:book_target_updated, target}` broadcast
  (already emitted by `transition_target/3`, unchanged) re-renders the section; the target is now
  `:monitored`, and the existing Search button appears with no separate code path.
- Alongside it, when `Books.blocked_release_titles(target.id) != []`, a **Clear blocklist**
  button (`phx-click="clear_blocklist"`) calling `Books.clear_blocklist/1` — a plain read+delete,
  no reload of `@work` needed since it changes nothing `book_state_badge` or the language form
  render from.
- The hold-reason text already rendered (`book_detail_live.ex:242-248`) is unchanged.

### 3. "Find a better match": replace on an `:available` target

`Cinder.Books.Files.record_import/3` already tolerates re-import onto an `:available` target —
its `arm_target/1` guard accepts `expect in [:monitored, :available]` on purpose, documented as
"so an import REPLAY... converges" (`files.ex:77-108`). Left as-is, a genuinely *different*,
better release grabbed through this new path would not replace the old file — it would insert a
**second** `book_files` row alongside the first, since `insert_conflict/3`'s dedup key is
`book_files.path`, not "one file per target." Nothing in the contract or B2–B4 defines upgrade
semantics for books; this slice must, because "Find a better match" is meaningless without them.

**Decision: replace, not accumulate.** A confirmed "Find a better match" grab must leave the
target with exactly one current file, the same guarantee a movie upgrade gives
(`Catalog.abort_upgrade/2` / the poller's upgrade-completion path keep exactly one live file).

- `book_grabs` gains a `replace :boolean, null: false, default: false` column
  (`priv/repo/migrations/<ts>_add_book_grab_replace_flag.exs`). `Books.Grabs.create/4` becomes
  `create(book_target_id, download_id, protocol, release_title, opts \\ [])` — a 5th, **optional**
  trailing keyword list defaulting to `[]`, not a required 5th positional. This is deliberate:
  the function has one production caller (`Download.create_book_grab/1`, `download.ex:852`) but
  seven direct test call sites across `grabs_test.exs`, `book_poller_test.exs`, `cleaner_test.exs`,
  and `book_detail_live_test.exs`, all passing exactly 4 args today — an optional opt with a
  matching default leaves every one of them compiling and behaving unchanged; only
  `download.ex:852` needs an actual behavioral edit, to pass `replace: intent-carried flag`.
  `create/5` reads `Keyword.get(opts, :replace, false)` and threads it into the insert.

**BLOCKER, found and fixed before this plan shipped: the first draft of `replace` was not
replay-safe and would have destroyed a household's book.** `Files.record_import/3` accepts
`expect in [:monitored, :available]` specifically so that a REPLAY — a crash or swallowed error
between the import transaction's commit and `BookImport`'s post-commit `finish/2` deleting the
grab (`book_import.ex:155-159`) — re-runs the same import as a no-op instead of demoting the
target: `book_files.path` carries the only unique index (`create unique_index(:book_files,
[:path])`, B4b's migration), so `insert_conflict/3` recognizes "this exact path is already this
target's own row" and returns the existing row rather than erroring (`files.ex`, current
`insert_conflict/3`).

An unconditional `Repo.delete_all(from f in BookFile, where: f.book_target_id == ^id)` before
every replace-flagged insert breaks that guarantee on replay. Traced concretely: attempt 1
deletes the old file (path A) and inserts the new one (path B) — correct, A gets unlinked.
If the process crashes before the grab is deleted, the **next tick re-runs the same import**
(`BookPoller`'s `import_downloaded/0` re-picks up the still-undeleted grab). Attempt 2 (the
replay) unconditionally deletes the target's *current, correct* file (path B — the only row
present now, since A is already gone) and inserts a fresh row at the *same* path B, which looks
like ordinary success. `superseded_paths` now names path B — the file that is actually correct —
and the post-commit best-effort unlink deletes it from disk. A design meant to give operators a
better copy would, on a crash nobody controls, delete the only copy.

**Fixed: recognize a same-path replay as a no-op, exactly like the non-replace path already
does, instead of deleting unconditionally.** `record_import/3` gains a `maybe_supersede/3` step,
run *before* `insert_file/2`, inside the same transaction:

```elixir
defp maybe_supersede(_target, _attrs, false), do: {:ok, []}

defp maybe_supersede(target, %{path: path}, true) do
  existing = Repo.all(from f in BookFile, where: f.book_target_id == ^target.id)

  if Enum.any?(existing, &(&1.path == path)) do
    # The incoming file is already this target's own row — a replay of an already-completed
    # replace. Deleting nothing here means `insert_file/2` below hits the same unique-path
    # conflict `insert_conflict/3` already treats as a no-op success, converging exactly like
    # a plain (non-replace) replay does today.
    {:ok, []}
  else
    {_count, _} = Repo.delete_all(from f in BookFile, where: f.book_target_id == ^target.id)
    {:ok, Enum.map(existing, & &1.path)}
  end
end
```

`record_import/3`'s `with` chain gains this as its first step, threading `superseded_paths`
through to `publish/2`, which returns `{:ok, file, superseded_paths}` when `opts[:replace]` was
set (a tuple-size change scoped to this one call site, not `Files`' whole public contract).
Traced against the same crash: attempt 1 (paths A ≠ B) deletes A, inserts B, `superseded_paths:
[A]` — unchanged from before. Attempt 2, the replay (incoming path is *still* B, since naming is
deterministic from the same target/edition — the same assumption the existing non-replace replay
path already depends on, not a new one): `existing == [B]`, `path == B` is found among them, so
nothing is deleted; `insert_file/2` then hits the pre-existing unique-path conflict on B, and
`insert_conflict/3` returns the existing row as success; `superseded_paths: []`. Nothing is
unlinked. The replay is now a true no-op, matching the property the plain import path already
guarantees.

- `BookPoller.do_import_one/2` (`book_poller.ex:325-344`) reads `grab.replace` and forwards
  `replace: grab.replace` to `BookImport.import_grab/1` → `Files.record_import/3`. On success it
  reads back `superseded_paths` (empty on a fresh import or a same-path replay, per the fix
  above) and best-effort unlinks each one from disk **after** the transaction commits —
  mirroring `Download.remove_after_import/3`'s existing "best-effort, after commit, log and
  continue" pattern for the movie poller's own post-import source cleanup (`poller.ex:387-396`).
  A stale/already-gone path is not an error.
- Trigger: `BookManualSearchComponent`, opened from `/books/:id`'s new **Find a better match**
  button (rendered only when `target.media_kind == :ebook and target.status == :available`), asks
  a one-time confirm ("This replaces the current file — continue?") before forwarding
  `{:manual_grab, :book, target, release}` — reusing the exact confirm-then-forward idiom B4c
  explicitly declined to port from `ManualSearchComponent` because nothing needed it yet
  (`2026-09-01-books-b4c-operator-surface.md:226-228`); it is needed now. `BookDetailLive`'s
  `handle_info({:manual_grab, :book, target, release}, socket)` passes
  `replace: target.status == :available` through a new `Download.grab_book_target/3` (the
  existing 2-arity form becomes `grab_book_target(target, release, opts \\ [])`, backward
  compatible for the one existing production call site the same way `Grabs.create/5` is above)
  into `Books.Grabs.create/5`'s new `replace:` opt. `Download.grab_book_target/3`'s own
  `:ebook`-only / `:unsupported_media_kind` guard is unchanged — replace is a data-flag on the
  grab, not a new media-kind rule.
- Gate: `searchable?/2` still refuses a *second* concurrent search while a `BookGrab` already
  exists for the target (`Books.Grabs.for_target(target.id) == nil`, unchanged from B4c) — an
  `:available` target with an in-flight replace grab shows the same in-flight section B4c already
  renders, not a second Find-a-better-match button.

### 4. The scorer learns the blocklist

`Cinder.Acquisition.BookScorer.evaluate/3` gains a `:release_blocklist` opt (exact, downcased
release-title exclusion — `check_not_blocklisted/2`, run **first**, before `check_blocked/2`'s
substring check, mirroring `Scorer.excluded_title?/2`'s ordering for movies/TV,
`scorer.ex:399-414`). `@reasons` (`book_scorer.ex:132-146`) grows to 13 atoms with `:blocklisted`
appended; `reasons/0`'s existing exhaustiveness test (built B4c-era off `@reasons` itself,
`book_scorer_test.exs`) needs no new test — it already fails if a reason is unreachable.
`BookManualSearchComponent` gets one more `gettext`'d clause in its reason-copy table
(`"already tried and failed"`), following B4c's established one-clause-per-atom rule exactly
(no `to_string`/`inspect` fallback).

Both `BookManualSearchComponent` call sites (fresh search and the new replace path) pass
`Books.blocked_release_titles(target.id)` as `:release_blocklist` into
`Acquisition.Books.candidates/2`'s opts, which forwards to `BookScorer.evaluate_all/3` unchanged.

### 5. Bounded unattended retry — `Cinder.Books.Rehunter`

New module, `lib/cinder/books/rehunter.ex` (the exact path the roadmap's own "Likely files" list
already named). Mirrors `Cinder.Catalog.Rehunter` structurally — `PollerSkeleton`, stateless,
self-rescheduling — but scoped to `book_targets`, and it is the piece of this slice that answers
the roadmap's "**unattended retries are bounded and visible**" Done-when for books specifically.

**Why classifying by the `hold_reason` string is unsafe, verified against every real call site.**
`hold_reason` is free text, not a closed enum — `hold_reason/1` (`books.ex:239-245`) stringifies
whatever it is handed: an atom becomes its name, but a binary is only sanitized
(`HTTPPolicy.sanitize_log/1`), not mapped to a fixed set, and a `{code, detail}` tuple becomes
`"code: sanitized detail"` with `detail` still arbitrary remote text. Tracing every caller that
can reach `hold_target/4` confirms the string space is genuinely open:

- `download.ex:731-735` (`abandon_reserved/2`, a permanently rejected submission) — `reason` is
  always one of `@permanent_submission_errors` (`download.ex:24-29`): `:unsupported_download_url`,
  `:bad_torrent`, `:invalid_intent_release`, `:add_rejected`. Closed and deterministic.
- `book_poller.ex:274-284` (`hold_orphaned_target/2`, download-phase failure via
  `retry_or_fail/2`, past `@max_attempts`) — `reason` is `:missing_content_path`,
  `:download_missing`, `:stalled`, `{:blocked_content, detail}`, **or** whatever the download
  client itself reports as `status.reason` (`Map.get(status, :reason) || :download_failed`,
  `book_poller.ex:107`) — an arbitrary client-supplied string with no fixed vocabulary.
- `book_poller.ex:369-383` (`hold/3`, import-phase failure) — every member of
  `@permanent_import_errors` (`book_poller.ex:55-66`, 10 atoms, closed) reaches here directly via
  `do_import_one/2`'s first clause, **or** any transient import reason (a filesystem/disk error)
  past its own `@max_attempts` via `retry_or_hold/3` — again open-ended.

A fixed string allowlist (an earlier draft of this plan proposed
`~w(stalled download_missing missing_content_path download_failed no_client)`) is fragile in both
directions: `:no_client` turned out not to be reachable at all (`client_status/1`'s `{:error,
:no_client}` is logged and left alone, `book_poller.ex:121-124` — it never reaches `retry_or_fail`
or a hold), and the free-form client-reported `status.reason` string means a real transient blip
can arrive under any spelling, permanently missing an exact-string match. Matching *fuzzily*
instead would risk the opposite failure — auto-retrying a deterministic rejection whose sanitized
text happens to contain a matched substring.

**Fix: the caller states transience explicitly; nothing infers it from text.** `book_targets`
gains `hold_transient :boolean` (nullable; only meaningful while `status == :held`),
migration `priv/repo/migrations/<ts>_add_book_target_hold_transient.exs`. `hold_target/4`'s
signature becomes `hold_target(target, reason, release_title \\ nil, transient \\ false)` (or
equivalently a keyword `opts`) and writes `hold_transient` alongside `hold_reason` in the same
guarded transition. Each real call site states its own fact, not a derived guess:

| Call site | Reason(s) | `transient` |
|---|---|---|
| `abandon_reserved/2` — `@permanent_submission_errors` | `:unsupported_download_url`, `:bad_torrent`, `:invalid_intent_release`, `:add_rejected` | `false` |
| `hold_orphaned_target/2` — client-reported download failure past budget | `:missing_content_path`, `:download_missing`, client `status.reason`/`:download_failed` | `true` — already survived `@max_attempts` retries; worth one more look later |
| `hold_orphaned_target/2` — blocked content | `{:blocked_content, detail}` | `false` — a deterministic fact about the payload |
| `hold_orphaned_target/2` — stall | `:stalled` | `true` — matches movies' own `Rehunter`/`retry_movie` treatment of a stall as retryable |
| `hold/3` — `@permanent_import_errors` (10 atoms) | `:no_book_file`, `:ambiguous_book_files`, `:unsupported_archive`, `:unsafe_source`, `:book_file_exists`, `:archive_entry_limit`, `:archive_size_limit`, `:archive_entry_unsafe`, `:archive_corrupt`, `:archive_timeout` | `false` — by definition permanent |
| `hold/3` — transient import failure past budget | filesystem/disk errors | `true` |

This is more code than a string allowlist, but it is correct by construction: a caller that adds
a new hold reason tomorrow must say whether it is transient at the call site, rather than this
module guessing from spelling.

- Each tick: `Repo.all(from t in BookTarget, where: t.status == :held and t.hold_transient ==
  true and t.updated_at < ^cutoff)`, `isolate/2`-wrapped per target, each calling the **same**
  `Books.retry_target/1` choke-point §2 built for the manual Retry button — no separate write
  path, so the sweep and the button can never disagree about what a valid transition is.
  `retry_target/1` clears `hold_transient` the same way it already clears `hold_reason`
  (`transition_changeset/2`'s existing "leaving `:held` clears the hold fields" branch, extended
  to cover the new column).
- `enabled?/0` / `rehunt_after/0`, config-driven exactly like `Cinder.Catalog.Rehunter`
  (`config :cinder, Cinder.Books.Rehunter, enabled: true, rehunt_after: <ms>`), defaulting **on**
  in `config/config.exs` — safe to default on because, structurally, it can never trigger a
  download: it only flips a target back to `:monitored`, and nothing in Cinder today
  automatically searches a `:monitored` book target (no `best_book_release/2`, no `BookPoller`
  search pass — unchanged by this entire milestone). The retried release stays on the blocklist
  (§1), so the very next manual search — whenever an operator next opens the target — skips it.
- Visibility: no separate notify call in the sweep itself, mirroring
  `Rehunter.rehunt_movie/1`'s reliance on `retry_movie/1`'s own broadcast
  (`rehunter.ex:76-86`) — `retry_target/1`'s `{:book_target_updated, target}` broadcast
  (unchanged, from `transition_target/3`) is what makes the retried-and-still-monitored target
  reappear on B5c's Wanted/Missing filter and drop off the held count.
- Added to `Cinder.Application.poller_child/0`, next to `Cinder.Books.Refresher`.


### Test plan (properties, not function names)

- A held target with `hold_transient: false` (e.g. `:blocked_content`, any
  `@permanent_import_errors` member) is never touched by `Books.Rehunter`, at any cooldown.
- A held target with `hold_transient: true` past cooldown returns to `:monitored` with
  `hold_reason` and `hold_transient` both cleared, and its blocked release is still present (not
  cleared by the sweep).
- `hold_target/4` with a release title writes exactly one blocklist row per hold; a second hold
  on an already-`:held` target (the guarded `:monitored` precondition failing) writes none.
- `BookScorer.evaluate/3` rejects a blocklisted title `:blocklisted` even when every other check
  would accept it, and a title matching only case-insensitively still matches.
- "Find a better match" on an `:available` target with an existing file: after a successful
  import, the target has exactly one `book_files` row (the new one), and the old file's path is
  no longer reachable through `Books.get_target/1`'s preload.
- **Replaying an already-committed replace import is a true no-op** — the property that would
  have failed against this plan's first draft, which deleted every existing `book_files` row for
  the target unconditionally on every replace-flagged call. Simulate the crash directly: call
  `Files.record_import/3` with `replace: true` twice in a row with identical `attrs` (the same
  `path` `BookNaming` would compute twice for the same source), exactly as a replayed import
  tick would. After the second call, the target still has **exactly one** `book_files` row (the
  same row, same `path`, not a new one), and the returned `superseded_paths` on the second call
  is `[]` — nothing is reported as superseded, so `BookPoller`'s post-commit unlink step deletes
  nothing on replay. Contrast with the *first* call, which must still report the truly-superseded
  old path.
- A replace grab that fails on its first attempt (permanent import error) leaves the **original**
  file untouched — the whole `maybe_supersede/3` + insert sequence runs inside one transaction, so
  a rollback undoes the delete along with everything else; the target's pre-existing file is
  never actually removed from `book_files`, let alone unlinked from disk (unlinking is strictly
  post-commit, per the design above).
- Clearing a blocklist removes only that target's rows, leaving a different target's blocked
  titles intact.
- Retry on a target that has already left `:held` (raced by a concurrent import) returns
  `{:error, :stale_status}`, not a crash or a silent no-op flash.
- `mix test` is green.

---

## B5b — Author monitoring policies

### 1. What the contract locks, what the roadmap adds

The parity contract's monitoring semantics ([above](../specs/2026-08-20-books-parity-contract.md#monitoring-semantics))
locks the mechanism: "Author monitoring is only a bulk policy that can seed work-monitor
decisions; it is not a permanent implicit request for every bibliography item," with a
required preview/count and separate confirmation (parity matrix row "Automatic author
monitoring"). The roadmap's B5 Work list supplies the one concrete default the contract itself
does not state: "selected works, future works, or all works. **Default to selected works**."
"Selected works" is not a policy row at all — it is the current B2–B4 behavior (a work is
monitored only because a request approved it), so **no row in the new table means "selected."**

### 2. Where the control lives: `/books/:id`, not a new `/authors/:id`

There is no author browse/search surface anywhere in Cinder today (grep-verified: no
`/author` route). Building one to host a policy toggle would be a change of the same order as
B3's whole Discover-integration slice for a control this milestone needs exactly once per
credited author. `/books/:id` already renders every credited author by name
(`contributor_names/1`, `book_detail_live.ex:179`) and is already admin-gated. The policy control
is added there instead, under the author list — reuse over a new surface, the same judgment call
B4c's §4 made about the manual-search component.

### 3. Data model

`priv/repo/migrations/<ts>_create_book_author_policies.exs`:

```elixir
create table(:book_author_policies) do
  add :author_id, references(:book_authors, on_delete: :delete_all), null: false
  add :policy, :string, null: false,
    check: %{name: "book_author_policies_policy_valid", expr: "policy IN ('future', 'all')"}
  add :profile_id, references(:media_profiles, on_delete: :restrict), null: false
  timestamps(type: :utc_datetime)
end

create unique_index(:book_author_policies, [:author_id])
```

**Corrected from an earlier draft, which named a `profiles` table that does not exist.** The real
table backing `Cinder.Catalog.Profile` is `media_profiles` (`profile.ex:10`); every existing FK to
a profile row, including `book_targets.profile_id` itself, points there
(`priv/repo/migrations/20260815175259_create_named_media_profiles.exs:32,36,40`,
`20260824101744_create_books_catalog_and_targets.exs:112`).

This table **does** therefore reference `media_profiles`, unlike an earlier draft's claim that it
referenced neither `media_profiles` nor `book_targets`. That does not, on its own, trigger B1's
seven-trigger hazard (`2026-08-20-readarr-replacement-roadmap.md:195-199`): that hazard is about
**rebuilding** `media_profiles` itself in SQLite (`ALTER TABLE media_profiles RENAME TO ...`,
which drops and must recreate every trigger whose body references it). This migration only adds a
*new* table with an FK pointing at `media_profiles` — it does not alter, rename, or drop
`media_profiles`, so none of the seven triggers are touched and the hazard does not apply here. A
future migration that *does* rebuild `media_profiles` must still add `book_author_policies` to
nothing, since this table's own FK survives a target-side rebuild unaffected — but it is worth
restating the hazard's exact trigger condition rather than asserting blanket immunity.

`on_delete: :restrict` on
`profile_id` (not `:nilify_all`, unlike `book_targets.profile_id`'s existing FK) because a policy
with no profile to arm new targets with is meaningless — deleting a profile that a live policy
depends on must fail closed, matching how `Cinder.Catalog.Profiles` already refuses to delete an
in-use profile elsewhere in the codebase.


### 4. A new metadata callback: `bibliography/1`

`Cinder.Books.Metadata` gains
`@callback bibliography(foreign_id :: String.t()) :: {:ok, [candidate()]} | {:error, term()}` —
every work credited to the author identified by `foreign_id` **on this provider**, reusing the
existing `candidate()` type unchanged (no new shape for `Identity.resolve/1`-style callers to
learn). Both `Cinder.Books.Metadata.OpenLibrary` and `Cinder.Books.Metadata.Hardcover` implement
it, under the same bounded-payload/timeout/`HTTPPolicy` discipline `search/1`/`get_work/1`
already carry (B2's own contract, unchanged). Test fixtures follow B2b's convention: new Mox
contract cases in `test/cinder/books/metadata_contract_test.exs`.

### 5. Choke-points (`Cinder.Books`)

- `set_author_policy(author, policy, profile)` — `policy in [:specific, :future, :all]`.
  `:specific` deletes the `book_author_policies` row (turns bulk automation off); `:future`/`:all`
  upserts. **No monitoring side effect** — setting a policy alone creates zero targets, matching
  the contract's "not a permanent implicit request" wording literally.
- `preview_author_policy(author, policy)` — **read-only**, but not network-free, and not
  unbounded. Resolves the author's own namespaced provider identity (the same
  `book_identifiers` lookup `Refresher.work_reference/1` already does for works,
  `refresher.ex:48-55`, generalized to an author row), calls `provider.bibliography(foreign_id)`
  (one HTTP call).

  **Two passes, cheap-local-filter first, network-bound-second — order matters.** A first draft
  of this design capped with a plain `Enum.take(50)` straight off the raw bibliography response,
  before checking which candidates were already locally known. That stalls: `bibliography/1`'s
  response order is provider-defined and stable call to call, so a plain positional cap always
  inspects the *same* first 50 candidates every time it runs — once those 50 are all already
  monitored, every later preview (and every later refresher tick, since §6 reuses this function)
  keeps re-resolving the same 50 already-monitored candidates and never reaches candidate 51,
  forever, for any bibliography longer than the cap. Fixed by filtering first: every candidate's
  `(provider, foreign_id)` is looked up in one batched, **local, no-network** call to
  `Books.work_ids_by_reference/1` (`books.ex:50-73`, already exists, built B2b-era for exactly
  this shape), dropping any candidate that already resolves to a local work whose `:ebook` target
  is `:monitored`/`:available`/`:held`. **Only then** is `Enum.take(@max_bibliography_candidates)`
  (50) applied to what remains, and only *that* capped remainder is walked through
  `Identity.resolve/1`. The window of "up to 50 candidates considered" now advances tick over
  tick / preview over preview, because whatever it monitored last time drops out of "remaining"
  on the very next call — no separate cursor or offset to maintain.

  **The cap on `Identity.resolve/1` calls is required, not decorative.** `Identity.resolve/1` is
  not a pure/local function: its `reference/1`+`fetch/2` path calls `provider_module.get_work/1`
  and its `search_providers/3` fallback calls `provider_module.search/1` (`identity.ex:82-146`),
  both real HTTP requests through the same adapters `Cinder.Books.Metadata` already wraps.
  Uncapped, a preview against a 200-work bibliography would issue up to 200 further provider
  requests in one LiveView `start_async` call — exactly the "flood" this design otherwise argues
  cannot happen, just aimed at the metadata provider instead of the download client. The cap
  bounds one preview (or one refresher tick for one author) to at most 51 HTTP requests (1
  bibliography fetch + ≤50 resolves), run sequentially, one at a time — no `Task.async_stream` or
  other concurrent fan-out, matching every existing sequential walk in this codebase
  (`Books.Refresher.do_poll/0`'s `for work <- ..., do: isolate(...)`,
  `Acquisition.Books.run/1`'s query-by-query loop) rather than introducing the first concurrent
  provider-call pattern in the books domain.

  When more candidates remain after local filtering than the cap allows, the preview reports the
  remainder rather than silently dropping it: `{eligible: [...], ambiguous_count: n, remaining:
  m}` — the UI (§7) renders "Showing 50 of %{n} not-yet-monitored works; run Preview again after
  confirming to see more" when `remaining > 0`.


  Partitions the (capped, resolved) candidates into:
  - **eligible** — resolves to exactly one work, not ambiguous, and that work's `:ebook` target
    is not already `:monitored`/`:available`/`:held` (idempotent — re-previewing an already-mostly-
    monitored author reports only what is genuinely new);
  - for `:future` specifically, further restricted to a resolved `first_published_on` that is
    `nil` or later than today — Readarr's own "Future Books" semantics, the nearest prior art,
    and the only reading consistent with "future works" as a *narrower* policy than "all works";
  - **ambiguous/unresolved** — reported as a count only ("N could not be identified — never
    monitored automatically"), never listed as eligible, matching the contract's "never guess."
  Returns `{eligible: [...], ambiguous_count: n, remaining: m}`.
- `apply_author_policy(author, policy, profile, eligible_candidates)` — the confirm/backfill
  choke-point. Takes the **exact** candidate list the caller already has (from a held preview),
  never re-fetches — this is what makes "adds exactly the previewed eligible targets" true rather
  than aspirational. Per candidate, `isolate`-style (one failure does not abort the batch,
  mirroring `Refresher.do_poll/0`): `Identity.resolve/1` → `Books.import_resolution/1` (both
  unchanged, already idempotent) → `Books.monitor_target(work, :ebook, profile)` (unchanged).
  Finally upserts the policy row via `set_author_policy/3`. Returns `{:ok, created_count}`.

**Why this can never flood the download client, structurally, not by convention:** every write
here is `monitor_target/4`, which only flips `BookTarget.status` to `:monitored` — it does not
search, select, or grab anything. There is still no `Cinder.Acquisition.Books.best_book_release/2`
and `BookPoller` still runs no search pass (fact #3 in this plan's brief, unchanged by B5a or
B5b). A confirmed "all works" policy against a 200-title author creates 200 idle `:monitored`
rows and downloads exactly zero of them automatically. The actual flood risk this milestone
guards against is a *future* one (the day `best_book_release/2` ships), and it is guarded by that
function's continued absence, not by anything in this table.

### 6. `Cinder.Books.BibliographyRefresher` — the unattended half

New module, `lib/cinder/books/bibliography_refresher.ex`. Lifecycle: `PollerSkeleton`, stateless,
default interval `:timer.hours(12)` (mirrors `Books.Refresher` exactly), module config
`config :cinder, Cinder.Books.BibliographyRefresher, interval: <ms>`.

- Each tick, for every `book_author_policies` row: `isolate("author policy #{author.id}", fn ->
  refresh_author(author, policy, profile) end)` — same per-unit isolation `Books.Refresher` and
  `Rehunter` already use, so one author's provider outage can't stall the sweep for the rest.
- `refresh_author/3` reuses `preview_author_policy/2` (not a duplicate implementation) to compute
  the current eligible set, then reuses `apply_author_policy/4` on it — the sweep and the admin
  Confirm button run the identical code path, so they can never disagree about what counts as
  "new and unambiguous."
- **The same `@max_bibliography_candidates` (50) cap §5 gave `preview_author_policy/2`** bounds
  `refresh_author/3` too, since it reuses that function unchanged — corrected from an earlier
  draft, which claimed the network cost was already bounded to "one HTTP call per policied author
  per tick" and treated the cap as purely a local-write throttle. That was wrong: `Identity.resolve/1`
  is a real network call per candidate (§5), so without this cap a single author with a very large
  bibliography could issue dozens of provider requests on every 12-hour tick. With it, one sweep
  costs at most 1 + 50 requests per policied author, same as a preview. A bibliography larger than
  the cap is worked through gradually: each tick's `refresh_author/3` calls
  `apply_author_policy/4` only on that tick's `eligible` set, which already excludes anything a
  prior tick monitored, so the "first 50" naturally rotates forward tick over tick without a
  separate cursor to maintain.
- **Never demotes, never deletes.** The refresher only ever calls `monitor_target/4` — it has no
  path that touches an existing target's status, and `import_resolution/1`'s established "only
  write what the provider actually returned" rule (`books.ex:346-360`, unchanged) already means a
  provider that stops listing a work causes **no local write at all**, let alone a delete. "Provider
  deletion or drift never silently deletes local works/files or broadens monitoring" is therefore
  satisfied by *reusing* a B2 guarantee, not by new B5 code.
- Quiet logging: `Logger.info` only when a tick actually creates ≥1 target for an author (mirrors
  `Rehunter.rehunt_episodes/1`'s `0 -> :ok` no-op-is-silent pattern); an ambiguous/unresolved
  bibliography entry logs at `:debug`, matching `Refresher.resolve/1`'s existing `Logger.info` for
  an unresolved work refresh (`refresher.ex:57-66`) rather than inventing a louder level.
- Added to `Cinder.Application.poller_child/0`, next to `Cinder.Books.Refresher`.

### 7. UI (`/books/:id`)

Under the author-credits line, per credited author: a `<select>` (`phx-change="set_author_policy"`)
with the three options, current selection = the stored policy or "Selected works" if no row.
Choosing `Future works`/`All works` (and it differing from what's stored) surfaces a **Preview**
step — `start_async` calling `preview_author_policy/2` (same pattern B4c already established for
`BookManualSearchComponent`'s own search), rendering "%{n} new %{kind} would be monitored" (or
"Nothing new to monitor" for 0) plus an "%{m} could not be identified" note when
`ambiguous_count > 0`, and a **Confirm** button that calls `apply_author_policy/4` with the exact
held `eligible` list. Reverting to `Selected works` calls `set_author_policy(author, :specific,
profile)` immediately — no preview, since turning bulk automation off never removes an
already-monitored target. Admin-gated by `/books/:id`'s existing `:admin` live_session.

### Test plan (properties)

- A `:specific`-policy author (no row) is never touched by `BibliographyRefresher`, at any tick.
- Setting `:future`/`:all` alone (no confirm) creates zero targets.
- Preview's `eligible` count and `apply_author_policy/4`'s `created_count` for the identical held
  list are always equal — no candidate silently drops or duplicates between the two calls.
- An ambiguous bibliography entry is never monitored, by either the preview/confirm path or the
  refresher sweep.
- `:future` policy excludes a work with a past `first_published_on` and includes one with `nil`
  or a future date; `:all` excludes neither.
- A provider outage during a refresher tick leaves every existing target's status byte-identical
  (no partial writes, no demotions).
- A plain per-work request+approval (`Requests.approve_request/3`) still creates exactly one
  target even when the work's author has a live `:all` policy row — the policy sweep is a
  separate, admin-confirmed action that a request never triggers (regression coverage for the
  roadmap's "one requested work causes one target" Done-when, proving B5b did not weaken it).
- `mix test` is green.

---

## B5c — Wanted/Missing, pause/resume, metadata health, and notifier events

### 1. Wanted/Missing: a filter on the existing books tab, not a new route

B4c already recommended this exact placement ("[the books tab] belongs with B5, which already
owns Wanted/Missing and general books operational surfaces — a natural home for a listing view,"
`2026-09-01-books-b4c-operator-surface.md:114-118`), and the tab now exists (§ above). Adding a
`?status=` param is strictly less code than a new LiveView, and keeps one canonical books list
instead of two that could drift.

`library_live.ex`: `parse_status/1` (mirrors `parse_tab/1`'s allowlist discipline exactly, never
`String.to_atom/1` on a client param) accepts `"wanted"` (→ filter `status == :monitored`),
`"held"` (→ `status == :held`), else `nil` (→ unfiltered, today's behavior, unchanged default).
Applied inside the existing `visible_for_tab/1` books pipe, after `book_visible/2`'s text filter
and before `sort_book_items/3` — status narrows the candidate set the same way the text filter
already does, so both compose. A "Wanted" and a "Held" quick-link sit next to the Books tab link,
navigating to `?type=books&status=wanted` / `&status=held` (`navigate`, not `patch`, matching
every other tab link on this page for the same reason: a fresh mount, not stale filter state).

Each books-tab row gains inline actions, cheap/reversible ones only (mirroring why Movies' own
row already carries cancel/delete inline while heavier pipeline decisions live on
`/movies/:id`):

- `status == :monitored and Books.Grabs.for_target(t.id) == nil` → **Pause**
  (`phx-click="pause_target"`), calling `Books.pause_target/1` — B5a's own choke-point (§B5a.1)
  already refuses with `{:error, :grab_in_progress}` if a grab exists, so the `Grabs.for_target/1`
  check here is UX only (hiding a button that would visibly fail), not the actual safety
  boundary; a target that races into a grab between render and click still gets refused server-side.
- `status == :unmonitored` → **Resume** (`phx-click="resume_target"`), calling
  `Books.resume_target/1`.
- `status in [:available, :held]` → no inline action; a `:held` row's Retry/Clear-blocklist stay
  on `/books/:id` (B5a §2), where the hold reason and blocklist are already rendered — duplicating
  them into two surfaces was rejected for the same reason B4c never duplicated the manual-search
  panel.

Both new buttons call the choke-points B5a already added to `books.ex` (`pause_target/1`,
`resume_target/1`) — no new context code in B5c beyond wiring the two `handle_event` clauses and
their `gettext`'d button labels.

### 2. Metadata-provider health

`Cinder.Books.Metadata` gains `@callback health() :: :ok | {:warning, term()} | {:error, term()}`,
matching every existing service behaviour's shape (`Cinder.Catalog.TMDB`, the indexer behaviour).
`OpenLibrary` and `Hardcover` each implement it with a cheap, bounded, unauthenticated probe
(their existing `req_options`/timeout config, unchanged) — no new settings surface, since neither
provider is API-keyed today (confirmed: `config/config.exs:90-91` carries no credentials for
either).

`Cinder.Health` gains `books_metadata_checks/0`, one row per `Metadata.providers()` entry —
structurally identical to `download_checks/0`'s existing per-protocol loop
(`health.ex:91-97`), reusing `check/2`/`run/1` unchanged — appended into `check_all/0` next to
`indexer_check()`. `check_service/1` gains a `{:books_metadata, provider}` clause for the
`/settings` "Test connection" convention, mirroring `{:download, protocol}`.

Book-root health needed no new code (confirmed shipped, §"What B4c left" above).

### 3. Notifier: a held book target finally tells someone

Today a held book target notifies nobody — grep-verified, `Books.hold_target/2`'s three callers
(`download.ex:745`, `book_poller.ex:275,372`) never call `Cinder.Notifier`. `Cinder.Books.hold_target/4`
(B5a's new arity) gains one line in its success branch: `Notifier.notify({:book_target_held,
held})`, placed at the single choke-point every hold already routes through — matching the
moduledoc's own framing of `hold_target/2` as "the one place the acquisition pipeline gives up on
a target" (`books.ex:214-218`), the natural site for the one notify call, same as
`Catalog.reap_stalled_upgrade/1`'s `Notifier.notify({:movie_upgrade_failed, ...})` sitting right
next to its own state write (`catalog.ex:747`).

`Cinder.Notifier.Log` / `Discord` / `Email` each gain a `:book_target_held` clause; `Webhook`
needs none — its `payload/1` already handles any `{type, subject}` two-tuple generically via
`fields(subject)` (`webhook.ex:54-63`), and `:book_available` already posts a `%BookTarget{}`
through that same generic clause today, so `{:book_target_held, target}` is automatically
forwarded once the event exists:

- `Log`: `"book target held: #{book_title(target)} (#{target.hold_reason})"` — ids + title +
  the already-sanitized `hold_reason` (never raw remote text — `hold_reason/1`'s existing
  `sanitize_log`/`inspect` treatment, `books.ex:230-245`, is unchanged and already safe to log).
- `Discord`: an embed mirroring `:book_available`'s existing shape (`discord.ex:129-134`) with a
  warning color, title + media kind + reason.
- `Email`: mirrors `notify_movie/2`'s `{:failed, reason}` branch, calling the **already-existing**
  `Requests.approved_requesters_for_book/2` (`requests.ex:194-202`, shipped B3-era — not new B5
  code, corrected from an earlier draft that implied it needed building) — every approved
  requester of that work/media-kind pair gets told, not just the household-wide channels.


**Deduplication needs no new state.** `hold_target/4`'s own `expect: :monitored` guard already
means a second hold attempt on an already-`:held` target returns `{:error, :stale_status}` and
runs no notify call — the transition itself is the dedup, the same way `Rehunter`'s own cooldown
is what keeps a re-parked movie's notification to "≤1/day at the defaults" rather than per-tick
(`rehunter.ex:24-25`). No new dedup table, timestamp, or counter is added.

### Test plan (properties)

- Pausing a `:monitored` target with no grab succeeds and the target disappears from a "wanted"
  filter view; resuming a paused target reappears there.
- Pausing a target with an in-flight grab is refused at the **context**, not only the UI —
  `Books.pause_target/1` returns `{:error, :grab_in_progress}` and the target's status is
  unchanged, verified directly against `Cinder.Books` with no LiveView involved (the choke-point
  property B5a's own test plan owns); separately, `library_live.ex` never renders a Pause button
  for a target with a live grab (the UI-level property this slice owns).
- **Not claimed, and checked rather than assumed:** `Download.grab_book_target/2` itself has no
  target-status precondition — it dispatches purely on `media_kind`
  (`download.ex:198,211`) — so pausing does not retroactively make grab-creation impossible at the
  context level; it is prevented only because `BookDetailLive.searchable?/2` (B4c) never renders
  a search/Grab affordance for anything but a `:monitored` target with no existing grab. This
  slice does not close that gap at the context level (no test asserts it, and no code enforces
  it) — recorded here rather than silently assumed, since the pause-time `grab_in_progress` guard
  only protects the *reverse* ordering (a grab that already exists when pause runs), not a grab
  submitted by a stale UI/API caller after a target is paused.
- A `?status=wanted` view shows only `:monitored` targets; `?status=held` only `:held`; the
  default view is unfiltered and unchanged from B4c/pre-B5c behavior.
- A held target notifies exactly once (Log/Discord/Email each asserted); re-observing the same
  hold (a duplicate poller tick) notifies zero additional times.
- `Health.check_all/0` includes one row per configured metadata provider, and a simulated
  provider failure reports `{:error, _}` on that row without affecting any other row.
- `mix test` is green.

---

## Roadmap Done-when → slice mapping

| Roadmap criterion | Satisfied by |
|---|---|
| One requested work causes one target, not an author's entire catalogue | Already true (B3/B4, unchanged); regression-tested in **B5b** against a live author policy |
| A confirmed future/all-author policy adds exactly the previewed eligible targets | **B5b** (`apply_author_policy/4` operates on the held preview list, never re-fetches) |
| Provider deletion or drift never silently deletes local works/files or broadens monitoring | **B5b** (refresher only adds; reuses B2's "write only what's returned" rule) + **B5a** (pause/resume/retry never touch a target beyond the one acted on) |
| Unattended retries are bounded and visible | **B5a** (`Books.Rehunter`: reason-filtered, cooldown-gated, structurally cannot trigger a download) + **B5c** (held targets now notify, and appear on the Wanted/Held filters) |

## What stays out

- **Automatic release selection stays absent.** No `best_book_release/2`, no `BookPoller` search
  pass, in any of the three slices — the roadmap's B5 line is explicit ("keep automatic upgrades
  parked"), and §0 records why no B0 threshold could justify adding one even if this plan wanted
  to.
- **Audiobook targets from author policies.** `apply_author_policy/4` only ever creates `:ebook`
  targets. Audiobook acquisition is B7's; an author policy that also armed an audiobook target
  today would monitor a media kind with no downstream pipeline to satisfy it — a silent dead end,
  not a feature. Revisit when B7 ships `grab_book_target/2`'s audiobook clause.
- **A generic `/authors/:id` browse/search page.** The author-policy control lives inline on
  `/books/:id` (§B5b.2) precisely so this milestone does not need to build one.
- **Calibre/Audiobookshelf-specific health rows.** No B5 code publishes through either — the
  contract parks Calibre entirely and assigns Audiobookshelf to B7 — so there is no such
  component to health-check yet. Today's book publisher *is* the filesystem library root, and
  that is already covered (§"What B4c left"); a distinct "publisher" health row only becomes
  meaningful once a non-filesystem publisher adapter exists to diverge from it.
- **A book-side quality-upgrade sweep** (the unattended equivalent of `UpgradeHunter`). "Find a
  better match" (B5a §3) is deliberately manual-only, matching the roadmap's own phrasing exactly
  ("expose a manual... path only after initial acquisition is stable") — an unattended upgrade
  sweep would need automatic selection, which is out of scope for the same reason above.
- **Per-work "unmonitor and forget" (deletion).** Pause (B5a/B5c) only ever changes `status`; it
  never deletes a `book_targets` row, a `book_works` row, or an imported `book_files` row. Deleting
  a book target/file is not named anywhere in B5's Work list and is left for a future milestone if
  ever requested — matching the same restraint B4c applied to metadata-edit controls.

## Constraints carried into execution

- Every new user-facing string (button labels, preview/ambiguous counts, notifier copy, policy
  select options, blocklist/retry flashes) goes through `gettext` and needs a real, non-fuzzy
  French translation in `priv/repo/../priv/gettext/fr/LC_MESSAGES/default.po` before that slice's
  `mix test` is green — `test/cinder_web/translations_complete_test.exs` enforces this, and (per
  B4c's own experience, `2026-09-01-books-b4c-operator-surface.md`'s "Amendments" section) a
  `gettext.extract --merge` fuzzy-match onto an unrelated existing string is not a substitute for
  a reviewed translation.
- No slice runs a project-wide formatter/linter/build pass mid-flight; `mix test` (which already
  runs `compile --warnings-as-errors`, `format --check-formatted`, `credo --strict`, then the
  suite, per `AGENTS.md`) is the sole gate, run once per slice.
