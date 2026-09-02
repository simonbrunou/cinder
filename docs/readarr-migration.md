# Migrating an existing Bookshelf e-book or audiobook library into Cinder

This is the operator runbook for the B6 Readarr/Bookshelf cutover, covering both a Bookshelf
e-book instance and a Bookshelf audiobook instance (B7e widened classification/adoption to the
audiobook case; see the addendum near the end). It assumes a `pennydreadful/bookshelf:hardcover`-
style deployment reachable over its Readarr v3-compatible `/api/v1`, and Cinder's own
`Cinder.Books.Adoption` write choke-point (`docs/plans/2026-09-01-books-b6-migration-and-cutover.md`,
§B6c; `docs/plans/2026-09-02-books-b7-audiobooks.md`, §B7e).

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

In Bookshelf's own settings, disable RSS sync and automatic search for the instance you are about
to migrate. If the household runs a second Bookshelf instance for the other media kind, leave it
running until you run this same runbook against it separately (see the addendum near the end) —
migrating one instance never touches the other.

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
  - `:unsupported_format` — no accepted-format file exists for this work (EPUB/AZW3/MOBI for an
    e-book instance, M4B/MP3 for an audiobook one); nothing to adopt.
  - `:path_conflict` / `:identity_conflict` — a real duplicate against something Cinder already
    manages; resolve the duplicate rather than forcing it through.
  - `:target_held` — this work's target for the classified media kind (e-book or audiobook) is
    already `:held` (an operator's or the poller's own more recent decision). Open the work's
    `/books/:id` page and clear the hold before re-running Preview; Cinder will never silently
    override a hold to force an adopt through.
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

- Monitor an individual work's e-book or audiobook target (whichever kind this runbook just
  adopted) from its `/books/:id` page for upgrades.
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

- **Migrating two instances in one Preview/Adopt pass.** Classification and adoption are
  media-kind-generic (both `:ebook` and `:audiobook` candidates classify and adopt correctly),
  but the four Readarr-source settings are one configured value each — only one Bookshelf
  instance is reachable at a time. Migrating a second, separately-deployed instance for the other
  media kind is two full runs of this runbook, not one combined pass; see the addendum below.
- **Calibre.** No B6 code path writes a Calibre database or invokes `calibredb`.
- **Format conversion or automatic quality upgrades during adoption.** Every accepted file is
  adopted exactly as found. "Find a better match" (already shipped) is the only upgrade path, and
  it works unmodified against a migration-adopted `:available` target.
- **Renaming.** Automatic renaming stays off; existing filenames are preserved verbatim.

## Migrating both an e-book and an audiobook Bookshelf instance

The classification/adoption code is media-kind-generic (B7e): a file whose format resolves to
M4B/MP3 classifies and adopts as an `:audiobook` target, an EPUB/AZW3/MOBI file as an `:ebook`
one, and neither can be mistaken for the other's target. What is **not** built is per-instance
settings — `readarr_url`/`readarr_api_key`/the two path prefixes are one configured value each,
covering whichever single Bookshelf instance they currently point at (deliberately not built;
see the B7 plan's §0.3 for why per-instance config was judged out of scope). A household running
**two** separate Bookshelf deployments — one per media kind, the real-world shape the B0 audit
captured — migrates them with **two runs of this exact six-step runbook**, not a new procedure:

1. Run steps 1–6 once with `readarr_url`/`readarr_api_key`/the path prefixes pointed at the
   e-book instance, adopting its EPUB/AZW3/MOBI candidates as `:ebook` targets.
2. Repoint those same four settings at the audiobook instance in `/settings`, and run steps 1–6
   again. Its M4B/MP3 candidates classify and adopt as `:audiobook` targets — a distinct target
   per work, never colliding with or overwriting the `:ebook` target the first run created for the
   same work.
3. Repeating a Preview against the SAME instance you already adopted is always safe and
   idempotent regardless of which instance you point at when: an already-adopted work's cached
   `"readarr"` identifier short-circuits it straight to `:already_managed` (this is the exact
   guarantee B6c's own test plan already establishes for one instance, unaffected by re-pointing
   the settings to a different instance in between).

This is the identical shape the operator already uses for Radarr vs. Sonarr — two different
services, one settings block each — applied here to Bookshelf-ebook vs. Bookshelf-audiobook.

## Decommissioning Bookshelf after sign-off

Adoption is in-place and read-only against Bookshelf (this document's first line), so Bookshelf
stays a harmless, redundant reader of the same files for as long as you leave it running — there
is no forced cutover deadline in the code. The B8 milestone's own dogfood window (see
[`docs/books-dogfood-checklist.md`](books-dogfood-checklist.md)) is the recommended gate before
you actually turn Bookshelf off: keep it running and reachable for the length of that window so
the operator has a working fallback (search, monitoring flags, and its own database) if the B8
dogfood surfaces an unexplained problem. Do not decommission before that sign-off decision is
made explicitly.

Once you decide to decommission, per instance:

1. Disable Bookshelf's own automation (already done in step 1 of the runbook above, if you
   followed it) and stop the Bookshelf container/service.
2. Remove the `readarr_url`/`readarr_api_key`/path-prefix settings for that instance from
   `/settings` (optional — an unreachable, unconfigured migration source is otherwise inert and
   costs nothing left in place, but clearing the credential is good hygiene once it is no longer
   needed).
3. Keep the Bookshelf container image and its own database/config volume backed up separately,
   until you are confident Cinder's adoption was complete and correct (the verification steps in
   step 5 of the runbook above). Cinder never wrote to or deleted from Bookshelf's own state, so
   restoring it later — should you need to re-check something — is exactly as safe as restoring
   any other stopped container.

This does not delete or move a single file: every adopted `book_files.path` is byte-identical to
what Bookshelf already had, and remains exactly where it is after Bookshelf itself is gone.
