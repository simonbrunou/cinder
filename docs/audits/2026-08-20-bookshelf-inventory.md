# Bookshelf inventory audit — 2026-08-20

## Scope

This audit is the human-readable companion to
[`bookshelf-inventory-v1.json`](data/bookshelf-inventory-v1.json). It records the B0 evidence used
to replace the active `pennydreadful/bookshelf:hardcover` deployment without committing household
titles, authors, paths, addresses, provider IDs, or credentials.

## Capture method

- Connected read-only to both active Bookshelf instances and queried `/api/v1`.
- Captured system status, authors, works, per-work editions, book files, monitored flags, quality
  profiles, root folders, naming/media-management configuration, and protocol classes for download
  clients and indexers.
- Inspected consumer mount topology separately to verify Booklore and Audiobookshelf handoff roles.
- Retained 30 raw JSON endpoint responses outside source control with owner-only permissions.
- Added private `deployment-v1.json` evidence for the image/provider source and `latency-v1.json`
  evidence for the measured timings. The transformer validates API status version/branch against
  the deployment evidence instead of hard-coding source values.
- Froze the sorted 32-input private manifest as SHA-256
  `32b26e0484f4b188f51d57d495eb6c784b85049d7d696164b9fe37fab5956859`; this identifies every input
  consumed by the aggregate without exposing its records.
- Generated the committed API fixture from live response shapes, then replaced every identity,
  path, timestamp, file size, rating, release date, page count, statistic, and audio measurement
  with deterministic synthetic values. Only response keys/types, enum semantics, profile/quality
  names, and relevant policy settings remain live-derived.

## Regeneration

The staged transformer is [`books_b0_inventory.py`](../../test/support/books_b0_inventory.py). Given
the private snapshot whose manifest is recorded above, it rebuilds both the aggregate and the
synthetic API fixture deterministically:

```bash
python3 test/support/books_b0_inventory.py \
  --snapshot-dir /path/to/private/b0-snapshot \
  --output-root .
python3 test/support/books_b0_inventory.py \
  --snapshot-dir /path/to/private/b0-snapshot \
  --output-root . \
  --check
```

`--check` exits non-zero if either committed artifact differs. The raw snapshot is intentionally not
staged; reproducibility means the operator holding the manifest-matched private input can rerun and
verify the documented transformation without exposing household records.

## Aggregate inventory

| Surface | eBooks | Audiobooks |
|---|---:|---:|
| Authors | 2 (2 monitored) | 2 (1 monitored) |
| Works | 842 (842 monitored; 181 with files) | 170 (1 monitored; 1 with files) |
| Editions | 2,391 (841 monitored) | 651 (169 monitored) |
| Files | 188 | 1 |
| Formats | 159 EPUB, 25 AZW3, 4 MOBI | 1 M4B |
| Quality profile | eBook | Spoken |
| Download clients | 1 torrent, 1 Usenet | 1 torrent, 1 Usenet |
| Indexers | 3 torrent, 3 Usenet | 3 torrent, 3 Usenet |
| Consumer | Booklore | Audiobookshelf |

Both instances use completed-download handling, prefer hardlinks, reserve 100 MB before import, and
have automatic renaming disabled. No Calibre consumer or `calibredb` handoff is present in the
observed topology.

## Representative latency

Ten public-title searches through the active eBook Bookshelf API all succeeded. With the existing
mixed cache state they measured 272.3 ms minimum, 2,701.6 ms p50, 4,686.8 ms p95, and 5,167.7 ms
maximum. Ten accepted public-corpus work lookups against the configured metadata proxy all succeeded
at 60.6 ms minimum, 63.4 ms p50, 78.6 ms p95, and 84.8 ms maximum.

These figures are a deployment snapshot, not a load benchmark. They require asynchronous, cached,
visibly loading discovery with a timeout budget above five seconds; direct proxy latency must not be
used as the user-visible search estimate.

## Cutover implications

1. Monitoring counts cannot be imported as active acquisition intent: the eBook source monitors an
   entire bibliography while only 181 works have files, and the audiobook source has 169 monitored
   editions but one monitored work/file.
2. B6 adoption must preview work/media targets and require confirmation before scheduling anything.
3. Existing files and release filenames are preserved; the already-correct fixture is an adoption
   no-op rather than a move or download.
4. Cinder publishes to role-based `books` and `audiobooks` roots. It never mutates Booklore or
   Audiobookshelf databases.
5. Raw inventory remains private. The aggregate and deterministic fixture are the only deployment
   evidence committed to git.
