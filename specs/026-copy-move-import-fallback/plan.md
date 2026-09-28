# Copy/Move Import Fallback (Cross-Filesystem) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make import work when the download directory and the library root live on **different filesystems** — an
extremely common self-host layout. Today every import hardlinks via `fs().ln(source, dest)` at the single
`Cinder.Library.place/6` choke point (shared by movie and episode imports) and hard-fails with `{:error, :exdev}` across
filesystems, with no fallback. Fix it with **zero-config auto-detection**: on `:exdev`, fall back to a byte copy —
**atomically**, via the existing `replace/2` temp-then-rename pattern so a media scan never sees a half-copied file.

**Architecture (decisions locked):**

- **Auto-detect, no setting.** Catch `{:error, :exdev}` and copy. An operator on one filesystem keeps instant hardlinks;
  one on split filesystems just works. An explicit hardlink/copy mode would touch the whole settings + wizard UI and adds a
  foot-gun (picking "hardlink" on a cross-fs box reintroduces the failure). Debuggability comes from a log line + an
  `operating.md` note, not a knob.
- **Global by construction.** `place/6` and `replace/2` are shared by `import_movie/1` and `place_episode_file/4`. Putting
  the fallback there means the fix lands **once** and both movies and TV inherit it.
- **Atomicity via `replace/2`.** Reuse the existing crash-safe pattern: sweep stale temps, copy into a unique
  `.cinder-tmp-<n>` in the **dest** dir, then `rename` over dest. The temp lives on the library filesystem, so the rename is
  same-fs and atomic — a crash mid-copy leaves only a swept-next-run dotfile, never a truncated file at the real path.
- **Only `:exdev` triggers fallback.** `:eacces`/`:enoent`/`:enospc`/etc. propagate unchanged — they're real failures
  (permissions, source gone, disk full) that should park for retry, not be masked behind a copy that would fail the same way.
- **Copy never deletes the source.** Deletion stays the job of the existing `move_on_import` post-import step (the
  2026-06-25 move-on-import design rules out delete-during-import: data-loss / truncation / seeding-break risk). Copy +
  deletion stay separate concerns, so a torrent keeps seeding and a failed import never strands a half-moved file.
- **Remote/container path mappings are out of scope** — a separate gap (the download path the Cinder host can't `stat`).

**Tech Stack:** Elixir/Phoenix 1.8, ExUnit, Mox. No new deps, no migration, no settings change.

## Global Constraints

- `mix test` (the alias) is the source of truth: `compile --warnings-as-errors`, `format --check-formatted`,
  `credo --strict`, suite. "Green" = this passes.
- **No behaviour change on the same-filesystem path.** When `ln` succeeds (the overwhelmingly common case), the import path
  is byte-identical to today — instant hardlink, no copy. Prove it by keeping the existing `library_test.exs` green.
- **The fs behaviour seam is the only I/O.** Every filesystem op goes through `Cinder.Library.Filesystem` (mocked by
  `Cinder.Library.FilesystemMock`); tests never touch real disk. The media server goes through `MediaServerMock`.
- **🔴 The inode idempotency short-circuit must become device-aware** (see Task 3) — this is the review-caught correctness
  fix; do not skip it.
- Adding `cp/2` to the behaviour auto-covers the Mox mock (generated from the behaviour). Grep confirms only `Disk`
  implements `Filesystem`, so no hand-rolled fake needs updating.
- Work on branch `copy-move-import-fallback`. Commit per task locally. **Do not push or open a PR until the user asks.** End
  every commit message with the repo's standard trailers. Run `graphify update .` after code changes.

---

### Task 1: Add the `cp/2` callback to the `Filesystem` behaviour + Disk impl

**Files:** `lib/cinder/library/filesystem.ex`, `lib/cinder/library/filesystem/disk.ex`

- [ ] **Step 1:** Branch. `git checkout -b copy-move-import-fallback`
- [ ] **Step 2:** Add `@callback cp(source :: String.t(), dest :: String.t()) :: :ok | {:error, term()}` mirroring the
  existing `ln/2` contract.
- [ ] **Step 3:** Disk impl: `@impl true def cp(source, dest), do: File.cp(source, dest)` (copies content + mode bits, not
  mtime — irrelevant to a path+content media scan). Update the `@moduledoc` note that `ln` is a hardlink to mention the
  cross-filesystem copy fallback.

---

### Task 2: `link_or_copy/2` helper + wire into `replace/2`

**Files:** `lib/cinder/library.ex`

**Interfaces:** `defp link_or_copy(source, target)` returns `fs().ln`'s result, except it maps `{:error, :exdev}` to
`fs().cp(source, target)`. `replace/2` becomes the universal atomic "place source content at dest" primitive (fresh copy or
upgrade-replace).

- [ ] **Step 1:** Add
  `defp link_or_copy(source, target) do case fs().ln(source, target) do {:error, :exdev} -> fs().cp(source, target); other -> other end end`.
- [ ] **Step 2:** In `replace/2`, swap the inner `fs().ln(source, tmp)` for `link_or_copy(source, tmp)`, then `rename(tmp, dest)`
  as today. Broaden the function's comment to note it now links **or copies** into the temp.

---

### Task 3: `:exdev` clause in `place/6` + device-aware inode short-circuit (🔴 correctness fix)

**Files:** `lib/cinder/library.ex`

**Interfaces:** source lstat now also yields the device id; the `si == di` short-circuit becomes `si == di and sdev == ddev`.

- [ ] **Step 1 — the `:exdev` fresh-copy clause.** In `place/6`, between the `:ok` and `{:error, :eexist}` cases add:
  ```elixir
  {:error, :exdev} ->
    Logger.info("hardlink crossed filesystems; copying #{source} -> #{dest}")
    with :ok <- replace(source, dest), do: {:ok, new_q}
  ```
  This routes the fresh cross-fs case through the now-copy-aware `replace/2` (link-or-copy into a unique temp, then rename
  over the not-yet-existing dest). Both `import_movie/1` and `place_episode_file/4` inherit it. Use `Logger.info` (not
  `debug`) — a silent switch from instant hardlinks to full copies is a notable operational event an operator should see.
- [ ] **Step 2 — device-aware short-circuit (the review blocker).** `place/6`'s existing `si == di` idempotency check
  compares the **source-fs** inode against the **dest-fs** inode. Inode numbers are unique only *within* one filesystem;
  across two filesystems they collide freely. Once cross-fs imports exist, a re-import where the two inodes coincidentally
  match would take the short-circuit and **silently skip a genuine quality upgrade**. Fix: capture `major_device` (st_dev)
  alongside `inode` in **both** lstats —
  - the **source** lstat in `import_movie/1` (currently `%{size: size, inode: si}`) and `place_episode_file/4`
    (`%{size: size, inode: si}`), and
  - the **dest** lstat in `place/6` —
  then gate the short-circuit on **`si == di and sdev == ddev`**. Across filesystems the devices differ, so the
  short-circuit correctly does **not** fire and the code falls through to the upgrade/keep comparison. Same-fs hardlink fast
  path is unchanged. (Note: this short-circuit branch is silent today; if any inode-equality path remains, add a one-line
  `Logger.debug` so a rare misfire is diagnosable.)
- [ ] **Step 3:** Confirm the `:eexist` branch and `do_resolve`/keep/upgrade logic are otherwise unchanged — a cross-fs
  collision still surfaces via `:eexist` (link(2) returns EEXIST before EXDEV when dest exists) and resolves through the
  existing upgrade/keep path.

---

### Task 4: Test stubs

**Files:** `test/support/library_stubs.ex`

- [ ] Add `stub_import_exdev(size \\ 1)` mirroring `stub_import_ok/1` but stubbing `:ln` → `{:error, :exdev}`,
  `:find_files` → `{:ok, []}` (sweep_temps), `:cp` → `:ok`, `:rename` → `:ok` (plus `dir?`/`lstat`/`mkdir_p`/`scan` as in
  `stub_import_ok`). Keep the cross-fs happy-path expectations in one place for both movie and TV poller tests.

---

### Task 5: Cross-filesystem import tests

**Files:** `test/cinder/library_test.exs` (next to the existing collision/transient cases)

- [ ] **Movie `:exdev` → atomic copy (happy path):** `import_movie/1` returns `{:ok, dest, quality}` and the scan fires.
- [ ] **Atomicity:** `:cp` is called with a target matching `~r/\.cinder-tmp-/` in `Path.dirname(dest)`, and `:rename` is
  called with that same temp as source and the real dest as target — **no** `cp`/`rename` ever names dest directly.
- [ ] **Copy failure cleans up:** `:ln` → `:exdev`, `:cp` → `{:error, :enospc}` → `import_movie/1` returns `{:error, :enospc}`
  and `:rm` is called once on the temp (no rename attempted).
- [ ] **Non-`:exdev` ln error does not copy:** `:ln` → `{:error, :eacces}` → returns `{:error, :eacces}`, `:cp` never called.
  ⚠️ Use a setup with **no** `cp` stub/expectation (do **not** pull in `stub_import_exdev`, which stubs `:cp -> :ok`) so an
  unexpected `cp` call raises and the "never called" assertion is real.
- [ ] **Device-aware short-circuit (the regression for the review fix):** a cross-fs re-import where source and dest report
  the **same inode number** but **different devices** must still reach the upgrade comparison — `replace` on a better
  quality, **keep** on equal — **not** the `do_resolve(true)` short-circuit. (The naive "differing inode" fixture never
  exercises the dangerous equal-inode-across-fs case, so pin it explicitly.)
- [ ] **Cross-fs collision keep:** existing dest with **populated `imported_*`** fields (a post-`:available` collision),
  `:ln` → `:eexist`, differing inode, **equal** quality → existing file kept, no `cp`/`rename`. (Fixture must have populated
  `imported_*`; a nil baseline makes `Upgrade.better?` return true and would re-copy, testing the wrong branch.)
- [ ] **TV parallel:** drive `import_episodes/2` with a single matched episode via `stub_import_exdev` → the episode is
  imported through `place_episode_file/4`'s `place/6`, the imported list contains it with its `Season NN/...` dest, and
  `:scan` fires once.
- [ ] No disk/network: all I/O through `FilesystemMock`/`MediaServerMock`, `async` with `verify_on_exit`.

---

### Task 6: Update operating docs

**Files:** `docs/operating.md`

- [ ] Rewrite the "library and downloads MUST be on the same filesystem" hardlink section (and the troubleshooting note):
  Cinder hardlinks when possible and **automatically falls back to an atomic copy** when the download and library are on
  different filesystems. Note the cost: a copy uses **extra disk** (the source is not deleted unless `move_on_import` is
  enabled, so a cross-fs import without it permanently consumes 2×) and takes time **proportional to file size**, briefly
  serializing the poller tick. Note that remote/container path mismatches remain a separate, unaddressed gap.

---

## Done when

`mix test` is green (`compile --warnings-as-errors`, `format --check-formatted`, `credo --strict`, suite) **and**:

- A movie import whose `ln` returns `{:error, :exdev}` falls back to an **atomic** copy (cp into a `.cinder-tmp-*` in the
  dest dir, then rename onto dest — never cp/rename straight to dest), fires the scan, and returns `{:ok, dest, quality}`.
- A TV episode import takes the identical `:exdev` → copy path through `place_episode_file/4`, and `import_episodes/2`
  returns the imported episode and fires the scan.
- A non-`:exdev` `ln` error (e.g. `:eacces`) still returns `{:error, reason}` with **no** copy attempted.
- A copy failure (`cp` → `{:error, :enospc}`) removes the temp and returns `{:error, :enospc}`.
- A cross-filesystem re-import with the **same inode number but different device** reaches the upgrade/keep comparison (not
  the inode short-circuit): replaces on a better quality, keeps on equal with no re-copy.
- All tests run through `Cinder.Library.FilesystemMock`/`MediaServerMock` — no disk, no network.
- `docs/operating.md` no longer claims the library and downloads must share a filesystem and documents the automatic
  hardlink → copy fallback and its disk/throughput cost.

## Accepted limitations (documented, not built)

- **2× disk on cross-fs without `move_on_import`** — copy keeps both source and library copy. Documented.
- **Throughput** — a copy is O(file size) inside the single poller tick; a large file or serially-copied season pack
  briefly serializes the poller. Acceptable at single-household scale; `operating.md` notes it.
- **Pre-persistence crash window** — if the file is copied + renamed but the `{:ok}` transition hasn't committed
  (`imported_*` still nil), a retry sees a nil baseline (`Upgrade.better?` true) and re-copies the whole file via `replace`.
  Safe (atomic, self-heals once quality is persisted) and bounded to a rare crash window — noted, not optimized.
- **EEXIST-before-EXDEV ordering** (the cross-fs collision guarantee) is correct on Linux/Docker, the only target, but is
  pinned only by the mocked test, not validated against a real syscall.
- **Remote/container path mappings** — separate gap, out of scope.
