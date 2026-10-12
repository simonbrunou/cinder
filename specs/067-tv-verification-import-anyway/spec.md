# Feature Specification: TV Verification Hold — Import Anyway

**Feature Branch**: `feat/gh630-tv-verification-import-anyway`

**Created**: 2026-10-12

**Status**: Implemented

**Input**: GitHub #630 (untagged audio track holds an anime grab forever).

## Problem

An anime grab is verified before import against its frozen release policy
(`required_audio_languages`, `required_embedded_subtitle_languages`). When the file's only audio
track carries no language tag, the verifier cannot decide: `PolicyVerifier` returns
`{:unavailable, {:unprobeable_audio, _}}`. That is treated as transient, so the TV poller retries
ten times and then holds the grab as **Needs verification**.

Nothing on the operator side clears that hold. **Retry verification** re-probes the same bytes and
holds again; **Cancel download** returns the episodes to the wanted queue (and, since #629,
blocklists the release). Seen on prod (2026-10-11, "86 EIGHTY-SIX" S01E08): a full Japanese fansub
whose audio stream had a title but no `language` tag could only be imported by remuxing it by hand.

## Operator decision

The issue listed three options. On **2026-10-12** the operator chose **option 1**: an
**Import anyway** action on a TV verification hold that records the override and imports the held
files. Options 2 (treat "untagged" as its own non-transient outcome) and 3 (infer the original
language for a single untagged track) are explicitly not part of this work.

## Behaviour

- `/activity` (admin-only, like every other grab action) shows **Import anyway** next to
  **Retry verification** and **Cancel download** on a grab whose `mapping_status` is
  `:verification_blocked`. It asks for confirmation first; the confirm text says the checks Cinder
  could not run are skipped and that a file that clearly fails them is still rejected.
- Confirming calls `Catalog.import_grab_anyway(grab, actor)`, one `Cinder.Catalog.ReleaseVerification`
  transaction: a guarded update on `mapping_status == :verification_blocked` flips the grab back to
  `:resolved`, resets `download_attempts`, and sets `verification_waived = true`; an
  `import_grab_anyway` row in `Cinder.Audit` (entity: the grab, actor, release title) commits with
  it or not at all (`Audit.log_or_rollback`). One series broadcast follows the commit. A grab that
  is no longer held (a concurrent Retry, or the poller) yields `{:error, :verification_not_held}`
  and changes nothing.
- The TV poller then imports the held files through its normal path. `Library.verify_grab_policy/2`
  passes `waive_unavailable: grab.verification_waived` to `PolicyVerifier`, which **skips only the
  checks whose outcome was unknown or unavailable** (an untagged or unprobeable track, a failed
  probe, no media-info backend). A decidable mismatch (a known audio language that is not the
  required one) still rejects the release exactly as before: blocklist, discard, re-search.
- The waiver is a column on the grab row (`grabs.verification_waived`, default `false`), which is
  deleted when the import finishes or the grab is discarded. It never carries to another grab: a
  re-grab of the same release title is a new row and is verified normally.

## Non-goals

- Option 2 and option 3 from the issue (see above).
- Movie verification holds. Movies keep their existing hold actions.
- Any change to what counts as `:unavailable` or to the ten-attempt retry bound.

## Done when

- A held grab with an untagged audio track plus **Import anyway** imports its episodes
  (`file_path` set), leaves an `import_grab_anyway` audit row naming the grab, release and actor,
  and no longer needs the file edited by hand.
- The waiver does not apply to a different grab of the same release, and does not hide a decidable
  mismatch.
- A LiveView test shows an admin seeing the button on a held grab only, confirming the action, and
  a stale confirm after a concurrent Retry being refused.
- `mix test` is green.
