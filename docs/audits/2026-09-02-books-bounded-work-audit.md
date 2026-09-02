# Books bounded-work audit

Produced for B8a (`docs/plans/2026-09-02-books-b8-hardening-and-signoff.md`, `## B8a`, §3).
Every claim below was checked by reading the named file at the cited line, on the current
`feat/books-b8ab-hardening` branch, not copied from the plan's own prose. Where the plan's
prediction and the actual source diverge, that is called out explicitly in the closing section
rather than silently corrected.

## 1. Provider HTTP calls

Every outbound HTTP client touching book/audiobook metadata or the audiobook filesystem handoff
goes through `Cinder.HTTPPolicy.bounded_request/2` (or `/3`), which enforces a streaming
response-size ceiling and a total request deadline independent of any per-call `Req` option:
`@default_request_timeout_ms 60_000` (`lib/cinder/http_policy.ex:15`), applied by
`bounded_request/2` (`:198-199`), with the actual streaming enforcement in `collect_chunk/5`
(`:504-521`) checking both the elapsed-time deadline and the cumulative byte count after every
chunk (`:506-510`).

- **Hardcover** (`lib/cinder/books/metadata/hardcover.ex`): `@max_response_bytes 4 * 1024 * 1024`
  (`:24`). `request/1` (`:261-283`) sets `receive_timeout: 15_000` (`:268`),
  `pool_timeout: 5_000` (`:269`), `connect_options: [timeout: 5_000]` (`:270`), `retry: false`
  (`:271`), then pipes through `HTTPPolicy.bounded_request/2` (`:278`).
- **OpenLibrary** (`lib/cinder/books/metadata/open_library.ex`): `@max_response_bytes 4 * 1024 *
  1024` (`:21`). `request/1` (`:213-230`) sets the identical `receive_timeout: 15_000` (`:220`),
  `pool_timeout: 5_000` (`:221`), `connect_options: [timeout: 5_000]` (`:222`), `retry: false`
  (`:223`), then `HTTPPolicy.bounded_request/2` (`:229`).
- **Audiobookshelf** (`lib/cinder/library/audiobook_server/audiobookshelf.ex`, B7c, the
  audiobook filesystem-scan HTTP client, not part of the B0 corpus, added since this plan's own
  earlier drafts): `@max_response_bytes 4 * 1024 * 1024` (`:24`). `req/1` (`:74-85`) sets the same
  `receive_timeout: 15_000` (`:77`), `pool_timeout: 5_000` (`:78`), `connect_options: [timeout:
  5_000]` (`:79`); `request/4` (`:92-97`) pipes through `HTTPPolicy.bounded_request/2` (`:96`).

All three provider/scan clients share one bound shape: 4 MB response ceiling, 15s receive
timeout, 5s pool timeout, 5s connect timeout, no automatic retry, and the shared 60s hard total
deadline from `HTTPPolicy`. No book-related HTTP client was found that bypasses `HTTPPolicy`.

## 2. Archive extraction bounds

- **`Cinder.Library.BookArchive.Zip`** (`lib/cinder/library/book_archive/zip.ex`): `@max_entries
  500` (`:53`), `@max_expanded_size 1_000_000_000` (`:59`, 1 GB), `@read_chunk 4096` (`:64`,
  bounds compressed input per `:zlib` inflate call). `extract/3` (`:92-119`) resolves
  `max_entries`/`max_expanded_size` from `opts` with those defaults (`:98-99`), checks the entry
  count before touching any entry data (`check_entry_count/2`, `:121-123`), then streams each
  entry through `extract_entries/3` -> `extract_entry/4` -> `stream_entry/5` (`:294-390`).
  `inflate_stream/8` (`:428-449`) decompresses in `@read_chunk`-sized pieces and calls
  `charge_budget/3` (`:465-468`) after every chunk, which returns `{:error,
  :archive_size_limit}` the instant the running decompressed total exceeds `max_expanded_size`,
  a live ceiling checked during inflation, not after it completes, matching the module's own
  documented development-time proof (`:24-28`).
- **`Cinder.Library.BookArchive.Rar`** (`lib/cinder/library/book_archive/rar.ex`): shares the
  same `@max_entries 500` / `@max_expanded_size 1_000_000_000` values (`:55-56`). `unrar` runs as
  a monitored `Port` (`do_extract_and_supervise/6`, `Port.open/2` at `:187`), polled by
  `supervise/6` (`:201-231`) every `@poll_interval 200`ms (`:60`); each poll measures the
  destination directory's actual on-disk size and kills the OS process
  (`kill_and_reap/2`, `:239-247`, using `Port.info(port, :os_pid)` + `kill -KILL`, `:250-260`) the
  moment either `elapsed > max_duration_ms` (`@max_duration_ms 60_000`, `:64`) or `dir_size(...)
  > max_expanded_size` (`:215-220`). `@reap_wait_ms 200` (`:68`) bounds how long the kill waits
  for the process to actually exit before giving up on it (`:239-247`).

Both archive extractors carry a real, currently-in-force size ceiling and entry-count ceiling;
`Rar` additionally carries the wall-clock ceiling `Zip` doesn't need (it isn't shelling out to a
subprocess it can't see inside).

## 3. `System.cmd`/subprocess invocations reachable from book code

- **`unrar`** (`lib/cinder/library/book_archive/rar.ex`): `list_entries/2` runs `System.cmd(bin,
  ["lb", "-p-", "--", archive_path], ...)` (`:152-161`) with no separate timeout of its own (a
  metadata-listing call, not the extraction itself); the actual extraction
  (`do_extract_and_supervise/6`, `:184-199`) runs through the `Port` plus poll-loop bound
  described in §2 above (`@max_duration_ms 60_000`), which is the real ceiling on `unrar`'s total
  wall-clock cost.
- **`Ffprobe`** (`lib/cinder/library/media_info/ffprobe.ex`, shared with video): read directly to
  check the plan's prediction of "no explicit timeout." **Confirmed accurate for the paths that
  matter at import time.** `probe/1` (`:30`) and `probe_policy/1` (`:33`) both delegate to
  `run_probe/2` (`:60-67`), which calls `System.cmd(bin(), args(path), ...)` (`:61`) with no
  `Task`/timeout wrapper at all: a hung `ffprobe` process on a pathological file blocks that
  call indefinitely. `subtitle_tracks/1` (`:70-82`, `System.cmd` at `:71`) and
  `extract_subtitle/2` (`:85-108`, `System.cmd` at `:90`) are the same: no explicit timeout.
  **One exception the plan's blanket framing doesn't mention**: `health/0` (`:41-58`) *is*
  explicitly bounded, wrapping its `System.cmd(bin(), ["-version"], ...)` call (`:45`) in
  `Task.async/Task.yield(@health_timeout)/Task.shutdown(:brutal_kill)` (`@health_timeout 3_000`,
  `:27`; wrapper at `:42-57`), but `health/0` is only the `/status` reachability probe, never
  called on a downloaded media file, so it does not change the real gap: every call that actually
  inspects book/movie/TV file bytes (`probe/1`, `probe_policy/1`, `subtitle_tracks/1`,
  `extract_subtitle/2`) has no Elixir-side timeout. This is a real, pre-existing,
  video-and-books-shared limitation, out of scope to fix in B8a.

## 4. ffprobe/audio-probe calls specifically for books

**Correction to the plan's own framing**: the plan's item 4 pointed at `lib/cinder/library/
media_info.ex` for audiobook audio-language/policy verification. Reading the actual call graph
shows that module is not used for books at all: its sibling `Cinder.Library.PolicyVerifier`
states in its own moduledoc that it "verifies frozen **Anime** audio and embedded-subtitle
requirements" (`lib/cinder/library/policy_verifier.ex:1-3`), and neither `MediaInfo` nor
`PolicyVerifier` is referenced anywhere in `lib/cinder/download/book_poller.ex` or
`lib/cinder/library/audiobook_sources.ex` (grepped directly, zero hits). Books use a wholly
separate, purpose-built probe pipeline:

- **`Cinder.Library.AudioProbe.Ffprobe`** (`lib/cinder/library/audio_probe/ffprobe.ex`):
  `@probe_timeout 10_000` (`:26`). Unlike the shared `MediaInfo.Ffprobe` in §3, `probe/1`
  (`:30-38`) wraps its `System.cmd` call in the identical `Task.async/Task.yield(@probe_timeout)/
  Task.shutdown(:brutal_kill)` pattern `MediaInfo.Ffprobe.health/0` uses (the module's own
  moduledoc, `:5-11`, names this reuse explicitly), so the book-specific probe genuinely is
  bounded per call, in contrast to the shared video probe.
- **`Cinder.Library.AudiobookSources`** (`lib/cinder/library/audiobook_sources.ex`): bounds the
  *aggregate* cost of probing a multi-track set so `track_count * per-call timeout` cannot stall
  the single-tick `BookPoller` GenServer (moduledoc, `:40-61`). `@max_tracks 200` (`:81`) refuses
  an oversized set outright (`{:error, :too_many_tracks}`) before any probing starts;
  `@max_probe_budget_ms 60_000` (`:82`) bounds the whole set's wall-clock probing cost: the
  deadline is computed once in `build_tracks/1` (`:301-303`) and every remaining track's probe is
  skipped once it is spent. Both are overridable via `config :cinder, :audiobook_max_tracks` /
  `:audiobook_probe_budget_ms` (`:341,344`), production always falling back to the stated
  defaults.
- **Degrade-on-failure**: `Cinder.Library.AudioProbe`'s moduledoc ("Degradation, not failure",
  `lib/cinder/library/audio_probe.ex:21-27`) states a `nil` probe module, a probe timeout, and a
  probe error are all treated identically: "can't verify the stronger (tag) signal," never
  "can't import." `duration_seconds`/`chapter_count`/`track_number`/`disc_number` simply stay
  `nil` on the imported `book_files` row, and mixed-book detection falls back to filename-only
  evidence (`AudiobookSources.check_mixed_tags/1`, `:372`, only runs the embedded-tag check "when
  `AudioProbe` is configured and answers," `:370-371`). `lib/cinder/download/book_poller.ex:65-68`
  states the same contract from the poller side: an unavailable `AudioProbe` is deliberately
  **not** one of `@permanent_import_errors`, it degrades the ordering signal, never blocks or
  fails the import.

## 5. Library scans

No book-side polling scan process exists beyond the `BookPoller` tick itself. `Cinder.Download.
BookPoller` (`lib/cinder/download/book_poller.ex:39`) sets `@default_interval 5_000`; the actual
interval resolution is `Cinder.Download.PollerSkeleton`'s shared `config_interval/0`
(`lib/cinder/download/poller_skeleton.ex:281-285`), which reads `config :cinder,
Cinder.Download.BookPoller, interval: <ms>` and falls back to that module attribute, an
operator-configurable value, not a per-call bound, so there is nothing further to add here.

The one book-related "scan" that reaches an external service, requesting an Audiobookshelf
library rescan, is not a separate scan loop either: `request_audiobookshelf_scans/0`
(`lib/cinder/download/book_poller.ex:379-396`) runs once per `BookPoller` tick, issues at most one
whole-library `AudiobookServer.impl().scan()` HTTP call regardless of how many targets are
pending (`scan_pending/1`, `:391-396`, comment at `:371-378` explains the one-call-per-tick
design explicitly to avoid N sequential requests for a backlog of N), and that one call is bounded
by the same `HTTPPolicy` deadline documented in §1. A failed scan retries on the next tick
(`:398-410`) rather than looping within the same tick.

## 6. `Repo.transaction` audit: `lib/cinder/books/`, `lib/cinder/library/` (book-adjacent), `lib/cinder/download/` (book-adjacent)

Grepped exhaustively across the three directories (not a curated subset). Five call sites exist
in total; `lib/cinder/download/` has none.

| Site | What runs inside |
|---|---|
| `lib/cinder/books/adoption.ex:97` (`adopt_work/4`) | `do_import/1` -> `Books.import_work_in_tx/2` + `Books.stamp_identifier_in_tx/3` (DB upserts), `Books.ensure_target/2` (DB), `refuse_grab_in_progress/1` (`Repo.exists?`), `refuse_held/1` (pure), `insert_files/2` looping `Files.insert_or_existing/2` (DB inserts), `arm_available/1` (`Repo.update_all`, `:142-150`). DB reads/writes only. |
| `lib/cinder/books/book_target_transition.ex:44` (`do_guarded_update/3`) | One `Repo.update_all` on `book_targets` with a status guard, `Repo.rollback(:stale_status)` on a zero-row update. DB only. |
| `lib/cinder/books/files.ex:43` (`record_import/3`) | `maybe_supersede/3` (`Repo.all`/`Repo.delete_all`, `:59-74`), `insert_or_existing/2` (DB insert), `arm_target/1` (`Repo.update_all`, `:221-230`), `ImportStage.mark_committed!/1` (`Repo.update_all`, `lib/cinder/library/import_stage.ex:80-`). DB only. |
| `lib/cinder/books/files.ex:95` (`record_import_set/3`) | The multi-file/audiobook generalization of the row above: `maybe_supersede_set/3`, `insert_all_or_existing/2` (looped `insert_or_existing/2`), `arm_target/1`, `ImportStage.mark_committed!/1`. Same shape, DB only. **Not individually line-cited in the plan's own §3 bullet, which named only `files.ex:43`**, see closing section. |
| `lib/cinder/library/migration_adoption.ex:684` (`revalidate_selected/2`) | Dispatches `revalidate_catalog/2` by source (`:radarr`/`:sonarr`/`:readarr`). The book-relevant clause is `:readarr` (`:737`), which calls `Readarr.revalidate/1` (`lib/cinder/library/migration_adoption/readarr.ex:595-611`) -> `catalog_state/2` (`:281-291`), which runs only `Repo.all` queries against `BookTarget`/`BookFile` (`:304-318`). DB reads only for the book path; the `:radarr`/`:sonarr` clauses cover movie/TV catalog reads under the same shared transaction and are out of this audit's scope. |

`lib/cinder/download/`: grepped directly, zero `Repo.transaction` calls. `BookPoller` and
`Cinder.Download`'s book-adjacent code hold no `Repo` writes of their own by design
(`Cinder.Books.Grabs`'s own moduledoc, `lib/cinder/books/grabs.ex:5-7`, states the choke-point
explicitly), so there is nothing to audit here beyond confirming the absence.

**No site above performs HTTP, `System.cmd`, or filesystem extraction inside its transaction
body.** Every one is `Repo` reads/writes (`Repo.all`, `Repo.update_all`, `Repo.delete_all`,
`Repo.insert`-family calls, `Repo.exists?`, `Repo.rollback`) or a further DB-only helper.

**Scope note**: `lib/cinder/books.ex` (the top-level context module, a sibling *file* to the
`lib/cinder/books/` *directory* and therefore outside the three directories this section audits
literally) holds three more `Repo.transaction` sites the table above nests beneath or is called
from: `pause_target/1` (`:392`), `import_resolution/1` (`:826`, which `adoption.ex`'s own
comments at `:20-22` explicitly name as "itself a `Repo.transaction`"), and
`upsert_by_identifier/5` (`:1007`). Read for context; not required by, and not counted toward,
this section's exhaustiveness claim, which is scoped exactly to the three named directories.

## Findings that differ from the plan's prediction

Two findings genuinely differ from a literal reading of the plan's §3 bullet list; everything
else (provider bounds, archive ceilings, the `unrar` wall-clock/size supervision, the video-shared
`Ffprobe`'s missing timeout, the poller interval being config not a per-call bound, and every
audited transaction being DB-only) matches exactly what the plan predicted, verified against
current source rather than assumed:

1. **`lib/cinder/books/files.ex` has two `Repo.transaction` call sites, not one.** The plan's §3
   bullet names only `files.ex:43` (`record_import/3`). `record_import_set/3` at `files.ex:95`,
   the multi-file generalization used for audiobook multi-track imports, is a second, separate
   `Repo.transaction` call with the identical DB-only shape. This does not change the audit's
   conclusion (both are DB-only), but the plan's own enumeration was not exhaustive on this one
   site; §6 above lists both.
2. **The plan's item 4 pointed at the wrong module for audiobook audio verification.** `lib/
   cinder/library/media_info.ex`/`PolicyVerifier` is Anime/video-specific (confirmed by
   `PolicyVerifier`'s own moduledoc and by grepping `book_poller.ex`/`audiobook_sources.ex` for
   any reference to either, which returns nothing). Audiobooks are probed through a separate,
   book-only pipeline (`Cinder.Library.AudioProbe`/`AudioProbe.Ffprobe`/`AudiobookSources`,
   §4 above) that, unlike the shared `Ffprobe`, **does** carry an explicit per-call Elixir-side
   timeout (`@probe_timeout 10_000`) plus an aggregate per-import track-count cap and wall-clock
   probe budget. This is a more favorable finding than the plan's item 4 wording implies, not a
   gap: the book-specific probe path is more tightly bounded than its video-shared sibling, not
   less.
