# Feature Specification: Leftover download folders panel

**Feature Branch**: `068-orphan-download-folders`

**Created**: 2026-10-12

**Status**: Implemented

**Input**: Forgejo issue #658, gap 2 — "nothing sweeps on-disk leftovers once the client has forgotten
the job". Gap 1 (the empty `<title>.cinder-<key>` folder a single-file import leaves behind) is fixed
separately in `Cinder.Library.Deletion`.

## Problem

Cinder names every usenet job `<title>.cinder-<key>` (`key` is an `Ecto.UUID`) and the client delivers
it into a folder of that name inside the import root. When an import fails, a grab is rejected or the
client evicts the job from its history, nothing refers to the folder any more and nothing ever removes
it. On the reporting install that was ~2 TB of full copies of library files, 600+ empty folders and a
few hundred GB of downloads that never imported. `Cinder.Download.Cleaner` only reaps what the client
still lists in `list_managed/0`, so these folders cannot be reached by any existing sweep.

## Operator decision (2026-10-12)

A **report-first admin maintenance panel under `/settings`**, not an automatic sweep. The operator
lists the unreferenced folders, sees what each one is, and clears them from the browser. Byte-identical
library copies and empty folders may be cleared in bulk; folders that match no library file are
cleared one at a time after an explicit confirmation.

## Behaviour

`/settings/download-folders` (`CinderWeb.DownloadFoldersLive`, inside the admin-gated `:admin`
live_session, linked from `/settings`) shows every `<title>.cinder-<key>` folder **directly inside an
explicit import root** (`Settings.explicit_import_roots/0`, the "Download folders" setting) that
nothing references, with its size and a class. A count says how many job folders were left out because
they are still in use.

### Classes

| Class | Meaning | Clearing |
|---|---|---|
| `empty` | no regular file anywhere in the folder | bulk |
| `library_copy` | at least one video, and every video has the same size and OpenSubtitles moviehash (`Cinder.Subtitles.Moviehash.of_file/1`) as a library file the database knows (movie `file_path`/`part_file_paths`, episode `file_path`/`part_file_paths`) | bulk |
| `unmatched` | anything else (a video matching no library file, only non-video files, a video too small to hash) | one folder at a time, explicit confirm |
| *held* (no class) | a symlink or special file inside, any file or subfolder modified in the last hour, unreadable, or too many entries to check | never offered |

### Referenced (left out of the list)

A folder is referenced — and so neither listed nor ever deleted — when its `<key>`:

- is the operation key of a job listed by any configured download client's `list_managed/0`;
- is the `operation_key` of a `download_intents` row;
- appears in a grab, movie or book-grab `content_path`, or in a library file path (movie, episode,
  book/audiobook file).

If **any** configured client fails to list its jobs (error or raise), the scan fails closed: the page
shows the error and offers no clearing.

### Safety rules

- Only explicit import roots are scanned; with none configured the page explains why it cannot scan.
- Every clear **re-surveys and re-classifies the folder and re-reads the database references
  immediately before deleting it**; a folder that was claimed, gained a file, changed class or was
  touched since the scan is skipped and reported.
- Deletion goes through `Library.delete_download_source/1` (`Deletion.delete_download_source/1`): strictly
  inside an explicit import root, no symlink anywhere in the path, never a root itself.
- The page only ever sends back the key of a folder it listed; the context additionally requires the
  path to be a direct child of an explicit root named `<title>.cinder-<key>`.
- The scan and every clear run in `start_async` tasks, off the request path. All filesystem access
  goes through the configured `Cinder.Library.Filesystem`.

## Non-goals

- No automatic or scheduled sweep; nothing is removed unless an admin clears it.
- No attempt to import an `unmatched` folder, to re-grab, or to decide it was a rejected download.
- No scanning of inferred import roots, of subfolders deeper than the root's direct children, or of
  folders not named `<title>.cinder-<key>` (category folders, hand-added downloads).
- No change to the Cleaner, the client behaviours or the import pipeline.

## Done when

- An admin can list and clear unreferenced `.cinder-<key>` folders from the browser, without shell
  access.
- Tests cover classification, "still referenced → kept" for each reference kind, a client listing
  failure → no clearing, the re-check at delete time, admin-only access, and a LiveView test of list +
  clear.
