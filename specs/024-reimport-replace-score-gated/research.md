# Score-gated replace on re-import — design

- **Date:** 2026-06-26
- **Status:** Approved (brainstorming) → council-reviewed (proceed with fixes) → ready for implementation plan
- **Branch:** `feat/import-upgrade-replace`

**Council review:** 1 round, 3 read-only reviewers (architecture/correctness, implementation/testability, contrarian red-team). Outcome: proceed with the score-gated design, folding in all findings below. The contrarian's data-quality caveats are retained as explicit limitations, not blockers (operator's call).

## Problem

`Cinder.Library.link/2` hardlinks a completed download to a `Title (Year)` dest.
A dest that already exists is `:ok` only if it's the **same inode**
(`idempotent_or_collision/2`); a **different inode** returns
`{:error, :dest_exists}`, which the poller treats as transient, retries 10×,
then **parks the item at `:import_failed`**.

The guard exists to stop two *different* titles that sanitize to the same
`Title (Year)` from clobbering each other — but it cannot tell that from the
**same** item being re-grabbed.

**How this is actually reached (verified — important for scoping):**
- `find_or_create_at_requested/1` returns an existing movie **unchanged at its
  current status**, and `set_movie_language/2` re-queues only
  `[:no_match, :search_failed]`. So **re-requesting a still-present `:available`
  movie is a no-op** — it never re-imports. cinder has **no auto-upgrade loop**.
- The collision is reached by (a) **delete-then-re-add**: deleting a movie row
  without removing its on-disk file, then re-adding the same TMDB id → a *new*
  row imports and collides with the leftover file (this is the live "Open Season"
  incident: a fresh French add collided with the prior Hungarian file); and
  (b) **retry of a parked `:import_failed`** row (`retry_movie/1`).

So the replace logic fires on (a) and (b) today, and is forward-compatible with a
future upgrade loop. **Out of scope:** adding an `:available → re-search` upgrade
trigger. Success criteria below are written against (a)/(b), not a hypothetical
re-request-an-available-movie flow.

## Goal & decisions

A re-import that lands on an item already in the library should **replace** the
existing file only when the new release is an **upgrade** per cinder's selection
model; otherwise **keep** the existing file and succeed — never park.

- **Identity via tmdb-tagged folders.** `library_name/3` gains `{tmdb-NNNN}`. Two
  different titles/series can then never share a folder, so a different-inode file
  at an item's own tmdb-unique dest is *provably the same item* → safe to replace.
- **Upgrade rule, language-first**, then resolution, then size (details below).
- **Scope:** movies *and* TV.
- **Non-upgrade:** keep existing file, mark item available, log, drop the
  redundant download. No failure notification.
- **No migration** of existing untagged folders.

### Known limitations (accepted; from council)
- "Quality" is **name-parsed** `resolution` (often nil) + file `size`. Size is a
  weak proxy (no codec/bitrate/HDR model): a larger re-encode can outrank a
  smaller better one. Mitigated by ranking nil-resolution **last** (a nil-new can
  never beat a known-resolution-old) and only replacing on a **strictly better**
  signal; residual mis-ranking on same-resolution size ties is accepted.
- `imported_language` is the **name-parsed** tag, not probed audio (`verify_audio`
  is conservative and skips on missing/unprobeable audio). The comparison is
  name-tag vs name-tag — internally consistent, not ground-truth.
- Existing untagged folders are left on disk (transitional cruft; see Media server).

## Naming change

`library_name/3` appends `{tmdb-<id>}` (the helper is shared by `build_dest`
[movies] and `build_episode_dest` [TV show folder]):

```
library_name(title, year, id) -> "#{title} (#{year}) {tmdb-#{id}}"
library_name(title, nil,  id) -> "#{title} {tmdb-#{id}}"
library_name("",    _yr,  id) -> "tmdb-#{id}"            # already unique; unchanged
```

`{`/`}` are not in `@illegal` (`/[\/\\:*?"<>|]/`) and the tag is appended *after*
`sanitize/1`, so it survives.

## Media server

The deployment uses **Plex** (`MOVIES_PLEX_SECTION=1`/`TV_PLEX_SECTION=2`), though
`Cinder.Library`'s moduledoc still says "Jellyfin" — **update the moduledoc to
Plex** as part of this work. The operator's existing library already uses the
`{tmdb-NNNN}` convention (`Open Season (2006) {tmdb-7484}`), so Plex's explicit-id
folder matching is known to work here. New tmdb-tagged imports and any leftover
untagged folders coexist; the only cost is the orphaned untagged folder/hardlink
remaining on disk until manually cleaned (no auto-migration — cinder never stored
the old path). Document this; optionally a one-off manual cleanup later.

## Schema (two migrations)

Add three nullable fields to **both** `movies` and `episodes`:

| field | type | meaning |
|---|---|---|
| `imported_resolution` | string | resolution label of the file now in the library (name-parsed at import) |
| `imported_size` | integer | byte size of that file (`lstat`) |
| `imported_language` | string | parsed release language of that file |

They describe the **physical library file**: set on every successful import,
**persist across a re-request** (`retry_movie/1` must NOT clear them — it already
doesn't cast them), and are cleared **only when the file is removed**.

Cast them in `Movie.transition_changeset/2` and `Episode.transition_changeset/2`.
Note `finish_grab/2` writes episodes via raw `Repo.update_all` (not the
changeset), so its `set:` list must include the three columns directly.

**Clearing sites (enumerate — easy to miss):**
- `do_delete_episode_file_txn/3` (catalog.ex ~L687) — `Episode.transition_changeset(%{file_path: nil})` → add `imported_*: nil`.
- `do_delete_season_files_txn/4` (catalog.ex ~L747) — raw `update_all set: [file_path: nil, …]` → add `imported_*: nil`.
- Verify the movie file-delete path: if a movie's file is deleted without deleting
  the row, clear there too; if movie deletion always removes the row, clearing is
  implicit.

## New module — `Cinder.Library.Upgrade`

Pure, no IO. `attrs :: %{resolution: String.t() | nil, size: integer | nil, language: String.t() | nil}`.

```
@spec better?(new :: attrs, old :: attrs, target :: String.t() | nil,
              preferred_resolutions :: [String.t()] | nil) :: boolean
```

Logic:
1. **nil baseline** — if `old` is entirely nil (no recorded quality), return
   `true` (treat as upgrade). Note: post-deploy, pre-existing `:available` rows
   have nil quality, so the first re-import replaces; steady-state is normal.
2. **Language first** — if `target` is non-nil:
   - `old` fails and `new` satisfies → `true`;
   - `old` satisfies and `new` fails → `false`.
   - **Limitation:** when `target` is nil (a movie on `"original"` whose
     `original_language` is blank/unknown), the language branch is **skipped** and
     only quality is compared — so language is *not* discriminating in that case.
     Documented, not fixed here.
3. **Quality** — `rank(new.resolution) < rank(old.resolution)`, or equal rank and
   `(new.size || 0) > (old.size || 0)`. `rank(nil)` sorts **last**, so a
   nil-resolution new file never out-ranks a known-resolution old file.

Supporting changes:
- **`Scorer.resolution_rank/2` must take a resolution STRING** (the current
  private fn takes `%Release{}` and reads `.resolution`). Add a public
  `resolution_rank(resolution :: String.t() | nil, preferred)` (overload, with the
  `%Release{}` clause delegating to it). The spec's earlier "just expose it" was
  wrong.
- **`preferred_resolutions` nil-guard.** `movies_preferred_resolutions` /
  `tv_preferred_resolutions` may be unset → nil; `Upgrade`/`resolution_rank` must
  fall back to `Scorer`'s `@default_preferred` (else `Enum.find_index(nil, …)`
  crashes).
- **`Language.satisfies_lang?(language_code, target)`** — the `satisfies?/2` rule
  without a `%Release{}`, with an explicit truth table (load-bearing):
  - `"MULTI"` → `true` (any target);
  - `nil` / `""` → `true` iff `target == "en"` (untagged = English by convention);
  - otherwise → `language_code == tag(target)`.
  Unit-test every row.

## Replace mechanic

Add to the `Cinder.Library.Filesystem` behaviour:
`@callback rename(source, dest) :: :ok | {:error, term()}` (Disk: `File.rename/2`;
Mox auto-picks it up).

`replace(source, dest)`:
1. **Sweep** stale `*.cinder-tmp-*` in `Path.dirname(dest)` (best-effort) — a host
   crash between `ln` and `rename` leaks a temp hardlink; this host crashes on I/O
   stalls, so clean defensively.
2. hardlink `source` → `dest <> ".cinder-tmp-#{System.unique_integer([:positive])}"`
   (same dir → `rename` is atomic on the same fs);
3. `rename(temp, dest)` (atomic overwrite, no missing-file window);
4. on error: best-effort `rm` temp, return `{:error, _}` (poller retries; old file
   remains, so the item stays importable). A persistent `replace` error rides the
   normal 10-attempt bound (it is *not* added to `@permanent_import_errors`).

## Import-flow changes

### Movies — `import_movie/1` + `Cinder.Download.Poller`

Quality sourcing: `resolution`/`language` from
`Parser.parse(Path.basename(movie.file_path))` (the **release** dir/file name,
available before `resolve_source`); `size` from `fs().lstat(source)` on the picked
video (`resolve_source` discards size, so re-`lstat`). Keep `verify_audio/2` ahead
of the dest decision (a wrong-audio new release still parks; existing untouched).

Decision at the dest (replaces `link`):
- dest absent → first import → set `new_quality`.
- dest exists, **same inode** → idempotent → return existing quality, **no rename**
  (short-circuit *before* the nil-baseline rule, so a transition-failure re-run
  doesn't redundantly replace).
- dest exists, **different inode** (same item via tmdb folder):
  `Upgrade.better?(new_quality, old_quality, target, movies_prefs)` →
  **replace** + return `new_quality`; else **keep** (no fs change, log
  `kept existing <res>; new not an upgrade`) + return `old_quality`.

Contract: `import_movie/1` returns **`{:ok, dest, quality}`** (was `{:ok, dest}`;
update `@spec`). `Poller.import_one/1` matches the new shape and writes quality in
the `:available` transition (`Catalog.transition(movie, %{status: :available,
imported_resolution: q.resolution, imported_size: q.size, imported_language:
q.language})`). `movies_prefs` from `movies_preferred_resolutions` (nil-guarded).

### TV — `import_episodes/2` + `link_all/2` + `Catalog.finish_grab/2`

Per `(episode, source)` in `link_all`: tmdb-tagged `build_episode_dest`, same
absent / same-inode / replace / keep decision using the episode's `imported_*` and
the source file's parsed attrs (`Parser.parse(Path.basename(source))` +
`lstat(source)` for size). Language `target` is series-level (existing
`episode_target/1`); `prefs = tv_preferred_resolutions` (nil-guarded). A **kept**
(non-upgrade) episode is **still included** in `imported` (with its existing
dest/quality) so the grab finalizes and the episode stays available.

- `import_episodes/2` returns **`{:ok, [{ep_id, dest, quality}], unmatched}`**.
- `link_all/2` accumulates `{ep.id, dest, quality}`.

### Contract ripple — explicit sites (all must change together)
- `import_movie/1` body + `@spec`; `Poller.import_one/1` match `{:ok, _dest}`.
- `import_episodes/2` body + `@spec`; `do_import_episodes/3` `{:ok, imported}`.
- `Catalog.finish_grab/2` (catalog.ex:994): the `for {episode_id, dest} <- imported`
  is a **2-tuple pattern → must become `{episode_id, dest, quality}`**, and its
  `set:` list gains `imported_*`. (`imported_ids = Enum.map(&elem(&1,0))` already
  works.)
- `TvPoller.notify_available/2` (tv_poller.ex:261): `fn {id, _dest} -> id end`
  **→ `{id, _dest, _q}`** (silent `MatchError` otherwise).
- Tests: rewrite the `:dest_exists` case (library_test.exs ~L84-95 — now
  replaces/keeps, never `:dest_exists`); update every `{:ok, dest}` / 2-tuple /
  path assertion (now `{tmdb}`-suffixed) across `library_test.exs`,
  `poller_test.exs`, `tv_poller_test.exs`, `catalog_tv_pipeline_test.exs`,
  `m3_pipeline_test.exs`. **`poller_test.exs`'s success-import stub must also stub
  `lstat` for size** (else Mox "unexpected call").

## Tests (TDD; Mox FS + media_server + media_info + indexer, no disk/network)

- `Upgrade.better?/4` unit table: nil baseline; language upgrade; language-downgrade
  blocked; **nil-target → quality-only** (the documented limitation); resolution
  better/worse/equal; nil-resolution ranks last; size tiebreak.
- `Language.satisfies_lang?/2` truth table (MULTI / nil / "" / exact tag).
- Movie `library_test`: first import sets quality + `{tmdb}` dest; replace by
  language (asserts `rename`); replace by resolution; not-better keeps (no
  `rename`); same-inode idempotent; wrong-audio new parks, existing untouched.
- Naming: `library_name`/`build_dest`/`build_episode_dest` include `{tmdb}`.
- TV `import_episodes`: per-episode replace/keep; kept episodes included so the
  grab finalizes; `finish_grab` persists per-episode quality; `notify_available`
  handles 3-tuples.
- `Filesystem.Disk.rename/2` + Mox `rename`; temp sweep behavior.
- `Poller`/`TvPoller`: quality persisted; clearing sites null `imported_*`.

## Build order

1. Naming (`library_name` `{tmdb}`) + Plex moduledoc + update all path assertions
   across the test suite (grep hardcoded dest strings). (Green.)
2. Schema migrations (movies + episodes) + changeset casts + clearing sites.
3. `Filesystem.rename` + `Disk` + Mox + temp sweep.
4. `Cinder.Library.Upgrade` + public string `Scorer.resolution_rank/2` +
   `Language.satisfies_lang?/2` + nil-guards + unit tests.
5. Movie path: decision + `import_movie` contract + poller persistence + tests.
6. TV path: `link_all`/`import_episodes`/`finish_grab`/`notify_available` +
   tv_poller + tests.
7. Full suite + `mix credo --strict` + `mix format`.

## Deliberate simplifications (ponytail)

- Resolution name-parsed (consistent with `Scorer`), not video-probed.
- No migration of existing untagged folders.
- No `:available → re-search` upgrade loop (replace fires only on delete+re-add and
  parked-retry today).
- ext-mismatch double-file not deduped (pre-existing).

## Success criteria / Done when

- A re-add (or parked-retry) of a movie whose file is already on disk: replaces
  when the new release is a better/language-preferred upgrade, keeps it otherwise,
  and **never parks**. Same for TV episodes.
- New imports land in `{tmdb}`-tagged folders.
- Full suite green; `credo --strict` + `format` clean.
- The live "Open Season" recurrence no longer parks.
