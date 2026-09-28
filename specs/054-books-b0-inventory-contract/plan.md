# Books B0 — inventory, parity contract, and labeled corpus

**Date:** 2026-08-20
**Roadmap item:** Part V, B0
**Branch:** `feat/books-b0-inventory-contract`

## Goal

Freeze the current Bookshelf/Readarr deployment contract before any books production code lands. Preserve household privacy while giving later milestones executable, versioned evidence for authors, works, editions, files, search identity, monitoring, quality, import naming, and consumer handoff.

## Confirmed scope and decisions

- Inventory both live `pennydreadful/bookshelf:hardcover` instances through read-only API calls.
- Keep raw responses outside git under a private local directory; commit only aggregate inventory and sanitized representative fixtures.
- Use the operator-confirmed recommended option: a curated public corpus of exactly 40 titles covering every B0 edge-case family.
- Evaluate Open Library plus optional Google Books against the corpus, compare that pair with the live `https://api.bookinfo.pro`/Hardcover evidence, and let coverage decide the B2 adapter set. Keep live Bookshelf `/api/v1` as the Readarr-compatible migration baseline.
- Lock current consumer handoff: ebooks to Booklore via the shared books root; audiobooks to Audiobookshelf via the shared audiobooks root.
- Preserve current import behavior as parity: move/hardlink into the configured root, preserve release filenames (`renameBooks=false`), and let consumers rescan shared storage.
- Model contributors as many-to-many in Cinder even though Bookshelf projects one primary author; this is required for co-authored works and avoids inheriting a known parity gap.

## Evidence already collected privately

- Ebooks: 2 authors, 842 works, 2,391 editions, 188 files.
- Audiobooks: 2 authors, 170 works, 651 editions, 1 file.
- Both instances report Readarr `0.4.20.129`, branch `develop`, with Bookshelf image revision `c21c4134fdb710481ed69db05bf943b0acdbbf60`.
- Ebooks currently use EPUB/AZW3/MOBI; audiobooks currently use M4B.
- Both instances have qBittorrent and SABnzbd enabled and share roots with the downstream consumers.

## TDD sequence

### RED

Add `test/cinder/books_b0_contract_test.exs` first. It must fail while B0 artifacts do not exist and will assert:

1. the corpus is versioned and has exactly 40 uniquely identified cases;
2. every roadmap edge-case family is represented;
3. each case has explicit, operator-confirmed expectations and a frozen provider fixture reference;
4. provider and Bookshelf fixture IDs resolve and contain no credentials or household paths;
5. the aggregate inventory totals match the captured live evidence;
6. every parity-matrix row has a locked Cinder decision and migration consequence;
7. current import naming and both consumer handoffs are explicit.

Run only this test and retain the failing output as RED evidence.

### GREEN

Create the smallest artifacts that satisfy the contract:

- `docs/specs/2026-08-20-books-parity-contract.md`
- `docs/audits/2026-08-20-bookshelf-inventory.md`
- `docs/audits/data/books-parity-matrix-v1.json`
- `docs/audits/data/bookshelf-inventory-v1.json`
- `test/support/books_b0_inventory.py`
- `test/support/fixtures/books/corpus-v1.json`
- `test/support/fixtures/books/metadata-provider-pair-v1.json`
- `test/support/fixtures/books/provider-v1.json`
- `test/support/fixtures/books/bookshelf-api-v1.json`

Provider fixtures contain only the response fields needed by later discovery/model tests, frozen from live public responses. The Bookshelf fixture preserves API shape while deterministically synthesizing all identities, paths, timestamps, sizes, ratings, release dates, page counts, statistics, and audio measurements.

Run the focused test until green.

### REFACTOR / verification

- Validate every JSON file with the runtime decoder and formatting checks.
- Run formatter, compile with warnings-as-errors, lint, static analysis, and the full test suite.
- Search the complete diff for API keys, local IPs, private roots, real inventory titles/authors, and private raw-data paths.
- Perform one bounded independent review of the complete diff, fix concrete findings, then re-review the final diff once.
- Commit, push, open the PR, verify base/head/files/body, and wait for required CI.

## Acceptance criteria

- [ ] Raw live inventory exists only outside git.
- [ ] Aggregate inventory is reproducible from the private snapshot and records source versions/timestamps.
- [ ] Exactly 40 public corpus titles cover co-authors, pen names, translations, multiple editions, series/position, omnibus/anthology, missing ISBN, duplicate titles, punctuation/Unicode, future releases, one already-correct file, one irreconcilable identity, ebooks, and audiobooks.
- [ ] Open Library plus optional Google Books has a corpus-backed sufficiency decision and any required additional adapter is explicit.
- [ ] Expected outcomes are explicit and operator-confirmed.
- [ ] Provider and Bookshelf fixtures are frozen, structurally representative, secret-free, and path-safe.
- [ ] Parity boundaries and migration consequences are decision-complete.
- [ ] Focused and canonical repository gates pass.
- [ ] PR is open with required CI complete; no merge is performed.
