# Plan: Leftover download folders panel

**Spec**: [spec.md](./spec.md). **Operator decision**: report-first panel under `/settings`
(2026-10-12). **Stacked on** the gap-1 fix (`fix/658-empty-job-folder`), which introduces
`Deletion.job_folder_key/1`, the single definition of a Cinder job-folder name.

## Shape

- `Cinder.Download.OrphanFolders` (context, `lib/cinder/download/orphan_folders.ex`)
  - `scan/0` → `{:ok, %{folders: [...], referenced: n}}` or a fail-closed error
    (`:import_roots_not_explicit`, `{:root_unreadable, root, reason}`,
    `{:client_list_failed, protocol, reason}`).
  - `clear(paths, allowed_classes)` → `{:ok, %{cleared: [...], skipped: [{path, reason}]}}` or the
    same errors. Bulk uses `safe_classes/0` (`:empty`, `:library_copy`); a single unmatched folder
    passes `[:unmatched]`.
  - Walks folders with the filesystem behaviour's `ls/1` + `lstat/1` (a symlink must be seen, which
    `PathPolicy.walk/2` hides) and hashes with `Moviehash.of_file/1`. Library files are indexed by
    size (one `lstat` each, only when some folder holds a video) so only same-size files are hashed;
    hashes are cached for the call.
  - Reference test is by `<key>` against client keys, intent keys and every DB path string, so it is
    independent of mount-prefix differences and a superset of "content_path inside the folder".
  - Deletion: `Library.delete_download_source/1`.
- `CinderWeb.DownloadFoldersLive` at `/settings/download-folders` (route in the `:admin` live_session,
  link from `SettingsLive`): `start_async(:scan)` on mount / rescan, `start_async(:clear)` for bulk and
  per-folder clears, `confirm_action` before either, flash with the cleared/skipped counts, rescan
  after every clear.

## Decisions

- Bulk clear covers `empty` and `library_copy`; `unmatched` is single-folder only, behind a confirm.
  A forged event for any other folder/class is a no-op in the LiveView and a skip in the context.
- The client snapshot is taken once per `clear/3` call; DB references, survey and class are re-read per
  folder right before its delete. A later job can only reserve a new key, whose intent row the
  per-folder read sees.
- Book and audiobook files count as references but are not hash candidates: a video is never one.
- Audit: each cleared folder writes an `admin_audit` row (`clear_download_folder`, entity
  `{"DownloadFolder", nil}`, detail `path`/`key`/`class`/`size`) with the acting admin, written after
  the delete like `Catalog.audit_deletion/5`; a failed audit write is logged. Skipped folders write
  none; a failed delete is logged at warning level and reported distinctly in the flash.
- Fail closed also on `client.health/0` returning `{:error, _}` (SABnzbd answers a bad API key with
  HTTP 200, which `list_managed/0` reads as an empty list).

## Tests

- `test/cinder/download/orphan_folders_test.exs` — real tmp dir + `Filesystem.Disk` (the pattern the
  poller/Disk tests use) and Mox clients: classification, holds, each reference kind, client list
  failure/raise, no explicit roots, clear safety, delete-time re-checks.
- `test/cinder_web/live/download_folders_live_test.exs` — admin gate, list, bulk clear with confirm,
  single unmatched delete, forged events, claimed-since-load, client failure, no roots, held folder.

## Done when

`mix test` is green and the spec's "Done when" holds.
