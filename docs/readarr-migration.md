# Migrating an existing Bookshelf e-book library into Cinder

This is the operator runbook for the B6 Readarr/Bookshelf cutover. It assumes a
`pennydreadful/bookshelf:hardcover`-style deployment reachable over its Readarr v3-compatible
`/api/v1`, and Cinder's own `Cinder.Books.Adoption` write choke-point
(`docs/plans/2026-09-01-books-b6-migration-and-cutover.md`, §B6c).

**Read before running:** adoption is **in place**. Cinder never moves, renames, hardlinks, copies,
or deletes a Bookshelf-managed file — it only inserts a `book_files` row pointing at the
unchanged, existing path. The entire rollback plan (step 6 below) depends on this: the source
library is byte-identical before and after every adopt.

## Precondition: the books root

Cinder's configured `books` library root and Bookshelf's own library path must be the **same
filesystem path** before you run Preview. If they differ, every candidate classifies
`:blocked, :outside_library_root` and nothing is adoptable — this is Cinder failing closed on a
misconfiguration, not a bug to work around.

If Cinder already has independently-acquired e-books under a *different*, older `books` root
(plausible — Book MVP has been shipping since B4), that is **not** a blocker: `book_files.path` is
an absolute path stored once at import time, independent of whatever the `books` root setting
currently points at, so repointing it does not move or reinterpret those existing rows. The real
precondition is narrower: **whatever consumer already scans e-books (Booklore) must cover every
root Cinder's `book_files` rows actually reference, old and new** — check this explicitly at step 3
below, alongside repointing the setting.

## The six steps

### 1. Disable Bookshelf automation

In Bookshelf's own settings, disable RSS sync and automatic search for the eBook instance. (The
audiobook instance is out of scope for B6 — leaving its automation running is safe; Cinder never
touches it.)

This is an operator action inside Bookshelf, not a Cinder feature — there is nothing to configure
in Cinder for this step.

### 2. Back up

- Bookshelf's own SQLite database and config directory.
- Cinder's SQLite database — this should already be covered by whatever backup the household runs;
  this step is a precondition, not new tooling B6 introduces.

Do this before step 3, so a misconfigured root or a bad `readarr_*` setting can be reverted without
touching Bookshelf.

### 3. Point Cinder at Bookshelf, and check the consumer scan coverage

In `/settings`:

- Set the `books` library root to Bookshelf's existing library path (the precondition above).
- Configure the four Readarr-source settings with the household's real values — shown in
  `/settings` as **Readarr URL**, **Readarr API key** (stored Cloak-encrypted, never echoed back
  to the form), **Readarr remote path prefix**, and **Readarr local path prefix** (the two path
  prefixes are only needed if Bookshelf and Cinder see the library under different mount paths;
  leave both blank if they see the same path).

Before moving on: confirm Booklore's own library scan configuration already covers **every** root
Cinder's `book_files` rows reference — the prior `books` root (if any) as well as Bookshelf's path
you just pointed Cinder at. This is a real check against Booklore's own settings, not an assumption.

### 4. Run Preview

Open `/library/adopt` (admin-only) and click **Preview Readarr**. Cinder classifies every
file-bearing work into one of four buckets:

- **Ready** — pre-selected; adopts as-is.
- **Needs decision** — a work has more than one accepted-format file (EPUB/AZW3/MOBI). Choose
  **Preferred format** (adopts EPUB, falling back to AZW3 then MOBI; the other files are left
  untouched on disk, never adopted, never deleted) or **All formats** (adopts every accepted file
  as its own `book_files` row under the same target).
- **Blocked** — never force-adoptable. Investigate before proceeding:
  - `:unsupported_format` — no accepted-format file exists for this work; nothing to adopt.
  - `:path_conflict` / `:identity_conflict` — a real duplicate against something Cinder already
    manages; resolve the duplicate rather than forcing it through.
  - `:target_held` — this work's `:ebook` target is already `:held` (an operator's or the
    poller's own more recent decision). Open the work's `/books/:id` page and clear the hold
    before re-running Preview; Cinder will never silently override a hold to force an adopt
    through.
  - `:outside_library_root` — the books-root precondition (above) is not actually satisfied for
    this specific file; fix the root/path-prefix settings, not the candidate.
  - `:unresolved_identity` — the configured metadata providers (Open Library primary, Hardcover
    secondary) could not confirm a reliable identity for this work; per the parity contract, this
    is an explained refusal, not a guess Cinder will ever make automatically.
- **Already managed** — idempotent re-preview of something already adopted; informational only.

For a large library (181 file-bearing works in the reference deployment), Preview auto-advances
through bounded batches of at most `Cinder.Books.max_bibliography_candidates/0` (50) newly-resolved
works at a time, with a live progress readout and a **Cancel** control that stops the auto-advance
without discarding candidates already resolved that session.

Preview performs **zero** database writes — rerunning it, or navigating away mid-batch and coming
back, changes nothing; the next Preview simply re-pays whatever batches were not reached.

### 5. Adopt, then verify

Resolve every needs-decision item and clear every investigable blocked item, then click **Adopt
selected**. Adoption is `isolate`-style per candidate — one candidate's failure never aborts the
batch — and re-validates each selected candidate against current state immediately before writing,
since preview and adopt are not atomic with each other.

Verify afterward:

- Candidate counts match the audit's known inventory (181 works / 188 files: 159 EPUB, 25 AZW3,
  4 MOBI in the reference deployment) minus whatever legitimately blocked.
- Spot-check a handful of `book_files.path` rows resolve to the same bytes on disk as before —
  compare file size and a checksum (`sha256sum`) against Bookshelf's own listing for the same
  files. At 188 files total, a full sweep is cheap enough to do instead of sampling if you prefer:

  ```sh
  sqlite3 /path/to/cinder.db "select path from book_files;" | xargs sha256sum
  ```

  Nothing here should differ from what Bookshelf itself reports for the same paths — adoption
  never rewrites bytes.

### 6. Enable Cinder monitoring

Nothing is automatic here on purpose. Every newly-adopted target lands `:available` with no active
search. From here, Cinder's normal per-work and per-author controls apply exactly as they do for
anything else already in the catalog:

- Monitor an individual work's `:ebook` target from its `/books/:id` page for upgrades.
- Use B5b's per-author monitoring policy (`Set author policy` on `/books/:id`, for any author
  credited to an already-adopted work) to opt into future or full back-catalogue monitoring — this
  is also how the operator handles the migration's own `deferred_bibliography_count`: works that
  were monitored in Bookshelf but had no file, and were therefore never imported as adoption
  candidates (see below).

**Monitoring flags are evidence, not automation.** The Preview banner reports how many additional
monitored-but-fileless works exist in Bookshelf (661 in the reference deployment, split across two
authors) that were **not** imported — importing every Bookshelf-monitored row as an active
acquisition request would be exactly the back-catalogue flood the parity contract warns against.
Those flags are preserved as evidence only; opt into them deliberately, per author, via the policy
control above.

## Rollback

Re-enable Bookshelf's automation from the step-2 backup. Cinder never deleted, moved, or rewrote a
Bookshelf-managed file — every adopted `book_files.path` is byte-identical to what Bookshelf
already had — so rollback is purely "start Bookshelf's automation again," not a data migration in
reverse. Cinder's own adopted rows can simply be left in place (harmless, read-only from
Bookshelf's perspective) or removed via normal `/books` admin actions if you want a clean split.

## What this migration does not do

- **Audiobooks.** Every B6 candidate is `:ebook`. The audiobook Bookshelf instance is untouched —
  no target, no import, no automation change. That is a later milestone's scope.
- **Calibre.** No B6 code path writes a Calibre database or invokes `calibredb`.
- **Format conversion or automatic quality upgrades during adoption.** Every accepted file is
  adopted exactly as found. "Find a better match" (already shipped) is the only upgrade path, and
  it works unmodified against a migration-adopted `:available` target.
- **Renaming.** Automatic renaming stays off; existing filenames are preserved verbatim.
