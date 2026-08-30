# Cinder Readarr Replacement Roadmap

> **For Hermes:** Treat each milestone as a separate design/implementation unit. Before executing a milestone, write its detailed TDD plan, implement on a branch, run `mix test`, perform one bounded review of the complete diff, and open a PR. Do not implement this roadmap wholesale.

**Goal:** Extend Cinder from a Sonarr/Radarr/Seerr/Bazarr replacement into a dependable Readarr replacement for one household, with e-book parity first and audiobook parity second.

**Architecture:** Add a provider-neutral books domain built around works, editions, authors, and independently managed e-book/audiobook targets. Reuse Cinder's request gate, Prowlarr and download-client adapters, guarded state transitions, import staging, profiles, adoption preview, PubSub, and health surfaces; first remove the video-only assumptions that would make a literal `:books` addition unsafe. Metadata, library publication, and library-server refreshes remain behind behaviours so Cinder does not inherit Readarr's retired metadata dependency or couple itself to Calibre/Audiobookshelf internals.

**Tech stack:** Elixir, Phoenix LiveView, Ecto/SQLite, Req, Mox, Prowlarr, qBittorrent/Transmission/SABnzbd/NZBGet, optional Calibre and Audiobookshelf adapters.

**Repository baseline:** `main` at `7317a4b3`, clean and aligned with `origin/main` on 2026-08-20.

---

## Executive recommendation

Build this as a new media family, not as a cosmetic third value in `Cinder.Library.kinds/0`.

Readarr was archived in June 2025 after its own maintainers described its metadata as unusable and the attempted Open Library transition as stalled.[1] Cinder should therefore reproduce the useful household workflow—discover, request, approve, monitor, acquire, import, adopt, and explain failures—without cloning Readarr's metadata architecture.

Ship in three product gates:

1. **Book MVP after B4:** a household member can request an e-book and an admin can acquire/import it end-to-end.
2. **E-book Readarr cutover after B6:** monitored e-books and the existing Readarr library migrate safely; Readarr can be turned off.
3. **Full replacement after B8:** audiobook targets, operational hardening, documentation, and a production dogfood period are complete.

The same work must be allowed to have both an e-book and an audiobook target in one Cinder instance. This deliberately improves on Readarr's one-format-per-book/instance constraint.

---

## Scope

### Required for e-book cutover

- Search books and authors; view work and edition details.
- Request a specific work as an e-book, with language and edition policy.
- Admin approval, denial, quotas, audit, notifications, and API representation.
- Manual release search before unattended grabbing.
- Prowlarr search with narrowly configured book categories, existing download clients, and Cinder-owned download labels.
- Parse and score by author, title, edition/ISBN evidence, language, format, size, and release provenance.
- Validate, stage, rename, publish, and refresh a supported e-book library.
- Monitor requested works and optionally future/all works by an explicitly monitored author.
- Wanted/missing, downloading, importing, available, and parked states with exact reasons.
- Readarr preview/adoption and cutover without duplicate downloads or file loss.

### Required for full replacement

- Independent audiobook targets for the same work.
- Single-file and multi-track audiobooks, narrator metadata, and audiobook-specific profiles.
- Audiobookshelf publication/scan support, while keeping filesystem publication available.
- Audiobook Readarr adoption if an audiobook instance exists.

### Explicitly out of the first release

- Comics, magazines, academic-paper feeds, and music.
- DRM removal, storefront purchases, lending, reading/streaming clients, and format conversion.
- Automatic quality upgrades; retain Cinder's existing policy of explicit/manual replacement first.
- Writing directly to Calibre's SQLite database.
- Automatically monitoring an author's complete back catalogue merely because one book was requested.
- Guessing an edition or identity when metadata/release evidence is ambiguous.

---

## Product and domain decisions

### 1. Model a work, edition, and managed target separately

- **Author:** a person or organization, many-to-many with works.
- **Work:** the logical title users discover and request.
- **Edition:** a language/publisher/date/identifier-specific manifestation of a work.
- **Book target:** the independently monitored acquisition target, `:ebook` or `:audiobook`.
- **Book file:** one or more validated files attached to a target; audiobooks may be multi-file.

A request targets a work plus a format. The approved target stores an edition policy (`:any_matching`, `:specific_edition`, or equivalent), language, profile, and durable provider identities. ISBN is edition evidence, not the only primary key.

### 2. Use a metadata behaviour with provenance

Create `Cinder.Books.Metadata` with normalized search, work, edition, author, and bibliography callbacks. Start with Open Library as the primary open provider and permit Google Books as optional fallback/enrichment.[2][3] Persist Cinder-owned identities, normalized snapshots, per-field provenance, refresh timestamps, and operator overrides. Provider refreshes must never overwrite explicit operator choices.

The B0 corpus—not API popularity—decides whether this provider pair is sufficient. If it is not, B2 may add another adapter without changing the domain model.

### 3. Replace media-kind conditionals with capabilities

The repository already hints that `Cinder.Library.kinds/0` should grow, but the current implementation is only partly generic:

- `lib/cinder/library.ex` lists only `:movies` and `:tv` and assumes video files in core import helpers.
- `lib/cinder/catalog/profile.ex` hard-codes profile kinds to `[:movies, :tv]`.
- `lib/cinder/requests.ex` maps every non-movie request to a TV profile.
- `lib/cinder/catalog/media_server_reconciliation.ex`, `lib/cinder/library/post_import.ex`, subtitles, Discover, and the two pollers encode movie/TV-specific behavior.

Introduce a small media-kind/capability registry instead of scattering new `books` clauses. Relevant capabilities include `video?`, `subtitles?`, `multi_file?`, `has_media_server_scan?`, `supports_author_monitoring?`, valid profiles, accepted extensions, and publication adapter. E-books and audiobooks should be separate profile/destination kinds even though they share the books catalog.

### 4. Publish through an adapter; never mutate a consumer database directly

Create a `Cinder.Library.Publisher` behaviour:

- **Filesystem:** Cinder-owned hardlink/copy publication and deterministic naming.
- **Calibre:** optional adapter using the supported `calibredb` interface, locally or against a configured Content Server; never direct SQLite writes.[4]
- **Audiobookshelf:** publish files to its library root and request a scan through its documented API.[5]

B0 determines which publisher is mandatory for the first real cutover. A consumer refresh failure must be reported but must not roll back a correctly committed Cinder import, matching current movie/TV behavior.

### 5. Default to explicit monitoring

A single requested work is the safe default. Author monitoring is an admin-only follow-up with explicit policies such as `specific works`, `future works`, or `all works`. Initial back-catalogue automation must require a preview/count and a separate confirmation.

---

## Milestone roadmap

## B0 — Readarr inventory, parity contract, and labeled corpus

**Estimate:** 2–4 developer-days

**Objective:** Turn “replace Readarr” into a finite acceptance contract grounded in the actual deployment, without changing production.

### Work

- Read the active Readarr instance through its API and export a secret-free inventory of authors, works, editions, book files, monitored state, profiles, root folders, and relevant naming/download settings. Readarr's published API exposes the author/book/edition/file-shaped surfaces needed for this discovery.[6]
- Determine whether the current instance manages e-books, audiobooks, or both; which extensions are actually present; whether Calibre integration is in use; and which library application consumes the result.
- Build a parity matrix with four dispositions: `required for cutover`, `required later`, `already provided by Cinder`, and `deliberately parked`.
- Select a labeled 30–50 title corpus covering co-authors, pen names, translations, multiple editions, series/position, omnibus/anthology, missing ISBN, duplicate titles, punctuation/Unicode, future releases, one already-correct file, and at least one irreconcilable identity.
- Produce frozen provider and Readarr API fixtures with credentials and personal paths removed.
- Count current items/files and measure representative metadata/search latency before making a rollout estimate.

### Likely files

- Create: `docs/specs/<date>-readarr-parity-and-scope.md`
- Create: `test/support/fixtures/books/metadata-*.json`
- Create: `test/support/fixtures/migration-readarr-*.json`
- Create later during execution, not during this roadmap: a redacted inventory artifact outside source control if it contains household data.

### Done when

- Every currently relied-on Readarr behavior has a disposition and acceptance criterion.
- E-book/audiobook order, accepted formats, publisher adapter, naming contract, and author-monitoring policy are explicit.
- Corpus examples have expected outcomes supplied or confirmed by the operator; inferred metadata is not treated as ground truth.

---

## B1 — Media-kind and lifecycle foundation

**Estimate:** 8–12 developer-days

**Objective:** Make books additive without regressing movie, TV, subtitle, or existing profile behavior.

### Work

- Introduce a capability registry and replace binary movie/TV profile dispatch.
- Extend profile persistence for `:ebooks` and `:audiobooks`; `:standard` is the only initial handling mode.
- Keep video-only settings (resolution/source, subtitles, media-info expectations, Plex/Jellyfin reconciliation) away from book kinds unless an adapter explicitly supports them.
- Generalize request target/profile mapping, library-root validation, health checks, path policy, download labels, and application supervision.
- Add book-target lifecycle states and guarded transitions without copying an entire third poller prematurely.
- Decide whether common poller orchestration can be extracted safely; leave movie/TV internals untouched when extraction would increase risk.

### Likely files

- Create: `lib/cinder/media_kind.ex`
- Create: `lib/cinder/books/book_target.ex`
- Create: `lib/cinder/books/book_target_transition.ex`
- Modify: `lib/cinder/library.ex`
- Modify: `lib/cinder/catalog/profile.ex`
- Modify: `lib/cinder/catalog/profiles.ex`
- Modify: `lib/cinder/requests.ex`
- Modify: `lib/cinder/settings/registry.ex`
- Modify: `lib/cinder/settings.ex`
- Modify: `lib/cinder/health.ex`
- Modify: `lib/cinder/application.ex`
- Create: `priv/repo/migrations/<timestamp>_add_book_profile_kinds_and_targets.exs`
- Test: `test/cinder/media_kind_test.exs`
- Test/modify: profile, settings, health, request, and application tests under `test/cinder/`.

### Done when

- Existing movie/TV behavior remains byte-for-byte compatible at external boundaries.
- Creating an e-book or audiobook profile/root does not generate subtitle, ffprobe-video, Plex section, or TV assumptions.
- Invalid target/profile combinations fail closed in changesets and context functions.
- `mix test` is green.

### Amendments during execution (2026-08-24)

Two items in the Work list above moved out of B1. Both are recorded here rather than silently
dropped; see [`the B1 plan`](2026-08-24-books-b1-media-kind-foundation.md) for the reasoning.

- **`lib/cinder/books/book_target.ex` and its guarded transition move to B2.** The parity contract
  locks monitoring at `(work, media_kind)`, and `works` does not exist until B2. A `book_targets`
  table with no work to point at is scaffolding B2 would rewrite, and its guarded transition could
  not be exercised. B1 ships the media-kind, profile, settings, and health foundation; B2 adds the
  catalog and the target lifecycle together.
- **Poller orchestration is not extracted.** B1 asked for a decision; the decision is no.
  `Download.Poller` and `Download.TvPoller` are race-sensitive and have no book caller until B4.
  Refactoring two working modules with zero third consumer to justify it trades real risk for no
  gain. Revisit in B4, when the third consumer actually exists.

One correction was also found in B1's own plan and is worth carrying forward: rebuilding
`media_profiles` in SQLite requires dropping and recreating **all seven** triggers whose bodies
reference it, not just the one attached to it. The `movies`, `series`, and `requests`
profile-integrity triggers break at `ALTER TABLE ... RENAME TO` otherwise. Any later milestone
that rebuilds a table referenced by a trigger inherits this hazard.

---

## B2 — Books catalog, metadata adapters, and identity resolution

**Estimate:** 8–12 developer-days

**Objective:** Establish durable author/work/edition identity before acquisition automation.

### Work

- Add authors, works, work-author credits/order, editions, identifiers, series memberships/positions, cached covers, metadata provenance, and operator overrides.
- Define `Cinder.Books.Metadata`; implement bounded HTTP clients, payload limits, timeout policy, normalization, caching, and Mox contracts.
- Implement Open Library search/details and optional Google Books fallback/enrichment.
- Resolve by durable provider identity first, ISBN second, and conservative title/author evidence last.
- Represent ambiguous, stale, incomplete, and provider-unreachable outcomes explicitly; never choose the first fuzzy result silently.
- Add periodic metadata refresh that preserves local monitoring, files, chosen editions, and manual fields.

### Likely files

- Create: `lib/cinder/books.ex`
- Create: `lib/cinder/books/{author,work,edition,identifier,credit,series_membership}.ex`
- Create: `lib/cinder/books/metadata.ex`
- Create: `lib/cinder/books/metadata/open_library.ex`
- Create: `lib/cinder/books/metadata/google_books.ex`
- Create: `lib/cinder/books/identity.ex`
- Create: `lib/cinder/books/refresher.ex`
- Create: `priv/repo/migrations/<timestamp>_create_books_catalog.exs`
- Create: `lib/cinder/books/book_target.ex` (deferred from B1 — needs `works` to reference)
- Create: `lib/cinder/books/book_target_transition.ex` (deferred from B1)
- Create: `test/cinder/books/metadata_contract_test.exs`
- Create: `test/cinder/books/identity_test.exs`
- Create: `test/cinder/books/refresher_test.exs`

### Done when

- The labeled B0 corpus resolves to the expected work/edition or an explicit ambiguity.
- A book target's lifecycle states (`unmonitored`, `monitored`, `available`, `held`) and their guarded transition land with the catalog, and a work can monitor e-book, audiobook, both, or neither independently.
- Repeated imports are idempotent across provider aliases and ISBN variants.
- A provider outage retains the last valid snapshot and never strips acquisition identity.
- Manual corrections survive refresh.

### Shipped as two slices

B2a (#353) landed the catalog schemas and `book_targets`; B2b landed `Cinder.Books.Metadata`, the
Open Library and Hardcover adapters, `Cinder.Books.Identity`, and `Cinder.Books.Refresher`. Two
corrections to this milestone's plan, both recorded in
[`the B2b plan`](2026-08-24-books-b2b-metadata-and-identity.md):

- **No Google Books adapter, in either slice.** The parity contract supersedes "optional Google
  Books fallback": keyless evaluation returned 40/40 HTTP 429, so it has no acceptance criterion.
- **"Manual corrections survive refresh" moves to B3.** B2a shipped no operator-override columns
  and nothing in B2 can create a manual correction, so the criterion would be vacuous here. What
  B2b does enforce is that a refresh only writes fields the provider actually returned.

Two items deferred *out* of B2b for want of a caller: author aliases (they need local author
search, which is B3) and a provider-side ISBN fetch (an edition-level signal for B5/B6).

---

## B3 — Discover, request, approval, and book library UI

**Estimate:** 7–10 developer-days

**Objective:** Give household requesters the same calm request flow for books that Cinder already provides for movies and TV.

### Work

- Add books to unified Discover with a Books filter, cover cards, authors, year, and format availability.
- Add a work detail route with editions, series position, language, existing/pending/available state, and e-book/audiobook request choices.
- Extend requests with a stable book target key and requested format; do not overload the current integer TMDB field with provider-specific strings.
- Add pending approval, profile selection, denial/reopen/cancel, quota, audit, notifications, personal export, and `/api/v1` projection.
- Keep indexer, format, ISBN-scoring, and import jargon off requester surfaces.
- Add all copy through gettext and preserve WCAG 2.2 AA conventions.

### Likely files

- Create: `lib/cinder_web/live/book_detail_live.ex`
- Create: `lib/cinder_web/components/book_components.ex`
- Modify: `lib/cinder_web/live/discover_live.ex`
- Modify: `lib/cinder_web/components/discover_components.ex`
- Modify: `lib/cinder_web/live/requests_live.ex`
- Modify: `lib/cinder_web/live/pending_approval_live.ex`
- Modify: `lib/cinder_web/live/my_requests_live.ex`
- Modify: `lib/cinder_web/live/library_live.ex`
- Modify: `lib/cinder_web/request_helpers.ex`
- Modify: `lib/cinder_web/router.ex`
- Modify: `lib/cinder_web/controllers/api_controller.ex`
- Modify: `lib/cinder/requests.ex`
- Modify: `lib/cinder/requests/request.ex`
- Create: `priv/repo/migrations/<timestamp>_add_book_request_targets.exs`
- Test: corresponding LiveView, request-context, API, authorization, quota, export, and audit tests.

### Done when

- A normal user can request an e-book but cannot create a managed target before approval.
- An admin request follows current auto-approval rules.
- Concurrent approve/deny remains race-safe.
- Request badges update live and all administrative controls remain role-gated.

### Shipped as two slices

B3a landed the request data model, the approval path, and `/api/v1`; B3b owns Discover, the work
detail route, and the shared request components. See
[`the B3a plan`](2026-08-25-books-b3a-requests-and-approval.md). One correction to this
milestone's plan:

- **The "stable book target key" is `target_type: "book"` plus `target_id: <book_works.id>` and a
  new `media_kind` column** — not a provider-specific string in a new field. The roadmap's warning
  was about overloading the integer TMDB field with an Open Library key; Cinder's own work id is
  an integer, and B2 already stores the provider identity in `book_identifiers`. The genuinely new
  axis is `media_kind`, without which `requests_pending_unique` would collide an eBook and an
  audiobook request for one work.

Two items deferred *out* of B3a for want of a caller: author aliases and local author search (they
belong to the search surface), and operator metadata overrides — B2b moved "manual corrections
survive refresh" here, but nothing in B3a creates a manual correction either, so the criterion
moves again to B3b with the detail page that does.

### Amendments during execution (2026-08-25)

B3b shipped Discover, `/book/:provider/:foreign_id`, and the shared request components. See
[`the B3b plan`](2026-08-25-books-b3b-discovery-and-request-ui.md). Corrections to this
milestone's entry:

- **`book_detail_live.ex` was not created; `book_discovery_live.ex` was.** The roadmap's name
  describes the admin pipeline view of a work Cinder already tracks — the books analogue of
  `/movies/:id`. That view has nothing to render until B4 gives it files and a running target, so
  B3b built the *discovery* analogue of `/movie/tmdb/:tmdb_id` instead and left `/books/:id`
  unclaimed for B4.
- **Discovery needed a new `Books.search/1`, not `Identity.resolve/1`.** Resolve collapses
  candidates to one work in order to authorize a grab; a search grid exists to show the operator
  the ambiguity. The two cannot be the same function.
- **`library_live.ex` was not modified.** Nothing can appear in a books library listing until B4
  imports a `book_files` row.
- **The two orphans stay parked.** Author aliases and local author search move to B5, where
  author monitoring gives them a caller. Operator metadata overrides move again — B3b's work page
  is read-only, so it does not create a manual correction either. They belong to whichever
  milestone first ships an edit control.

B4 inherits two obligations from B3b: `:held` book targets currently fall through to the request
status on both badge surfaces, because nothing creates a hold yet — B4 owns the states that
produce one and the copy that explains it; and `/books/:id` is still free for the pipeline view.

Two defects surfaced by B3b's review are filed rather than fixed: a double-fired request creating
duplicate approved rows (#364, pre-existing across all target types) and Hardcover reporting an
all-fetches-failed search as no results instead of an outage (#365, a B2b adapter bug).

---

## B4 — E-book search, scoring, download, validation, and publication

**Estimate:** 10–15 developer-days

**Objective:** Complete the first end-to-end vertical slice from approved request to available e-book.

### Work

- Extend the indexer behaviour and Prowlarr adapter with book queries using configurable, narrow categories; begin with e-book category evidence and do not use an unrestricted parent category by default.
- Search in descending evidence quality: edition ISBN, work identifiers where supported, then bounded `title + author + year/language` queries.
- Build a book release parser/scorer for author/title match, edition evidence, language, accepted format, size band, protocol, age, indexer provenance, and blocklist.
- Ship manual release search/selection first; enable automatic choice only after corpus precision meets the B0 threshold.
- Reuse existing download clients and path mapping, with a book-target download intent and bounded retry budget.
- Validate downloaded files/archives before publication: allowlisted extensions, regular files only, bounded entry count and expanded size, no traversal/symlink escapes, no executable substitution, and no mixed unrelated release.
- Support at least EPUB in the first slice; add AZW3/PDF only if B0 marks them cutover-critical.
- Publish with filesystem or Calibre adapter selected in B0; use hardlink where safe and copy fallback where required. Record all resulting files atomically before post-import refresh.
- Preserve the failed artifact in a safe parked/staging state with an exact reason; never import a guessed match.

### Likely files

- Create: `lib/cinder/acquisition/book_release.ex`
- Create: `lib/cinder/acquisition/book_parser.ex`
- Create: `lib/cinder/acquisition/book_scorer.ex`
- Create: `lib/cinder/download/book_poller.ex`
- Create: `lib/cinder/download/intent_book_target.ex`
- Create: `lib/cinder/library/book_import.ex`
- Create: `lib/cinder/library/book_naming.ex`
- Create: `lib/cinder/library/book_content_policy.ex`
- Create: `lib/cinder/library/publisher.ex`
- Create: `lib/cinder/library/publisher/filesystem.ex`
- Create if required by B0: `lib/cinder/library/publisher/calibre.ex`
- Modify: `lib/cinder/acquisition/indexer.ex`
- Modify: `lib/cinder/acquisition/indexer/prowlarr.ex`
- Modify: `lib/cinder/application.ex`
- Create/modify: intent, file, blocklist, and lifecycle migrations.
- Test: parser/scorer fixtures, malicious archive/path cases, client routing, poller races/retries, import rollback, publisher contract, and full LiveView slice.

### Done when

- An approved corpus e-book is discovered, downloaded, validated, published, and shown as Available.
- Wrong title/author/language/format and ambiguous edition releases are rejected with deterministic reasons.
- Repeated poll ticks cannot double-grab or double-import.
- A consumer refresh failure does not corrupt or misreport a committed import.
- `mix test` is green.

**Product gate:** Book MVP.

### Shipped as two slices

B4a landed the decision layer: book indexer queries, the release parser, and the scorer. B4b owns
the download intent, the poller, archive validation, and publication. See
[`the B4a plan`](2026-08-30-books-b4a-ebook-release-search-and-scoring.md).

Two notes from executing B4a:

- **Automatic selection is gated by the absence of a function, not a flag.** This milestone's
  "enable automatic choice only after corpus precision meets the B0 threshold" is enforced by
  `Cinder.Acquisition.Books` exporting no `best_book_release/2`: there is no boolean a caller can
  flip to reach automatic grabbing, and the slice that adds it is the one that must show the
  measurement.
- **The book scorer fails closed where the video scorer fails open.** `Cinder.Acquisition.Scorer`
  deliberately lets an untagged source through ("a parser miss must never strand a grab"), because
  an untagged video release is still playable. A book release of unknown format may be a PDF scan
  or a DRM'd AZW, indistinguishable from an EPUB by size — so unknown format is a rejection
  (`:format_unknown`), matching the contract's "unknown or contradictory formats fail closed to
  manual review". This is the one place the books pipeline deliberately contradicts its video
  sibling's rule.

---

## B5 — Monitoring, wanted state, author policies, and operations

**Estimate:** 8–12 developer-days

**Objective:** Replace Readarr's unattended monitoring behavior without flooding the download client.

### Work

- Add Wanted/Missing and manual search surfaces for book targets.
- Add explicit author monitoring policies: selected works, future works, or all works. Default to selected works.
- Preview the number of targets an author-policy change would add before confirming an initial backfill.
- Refresh monitored author bibliographies on a bounded schedule and add only identities that resolve unambiguously.
- Add pause/resume, retry, blocklist clearing, and exact parked reasons.
- Add health for metadata provider, publisher, book roots, and audiobook/e-book-specific dependencies.
- Add book-target notifier events and quiet, deduplicated operational logging.
- Keep automatic upgrades parked; expose a manual “Find a better match” path only after initial acquisition is stable.

### Likely files

- Create: `lib/cinder/books/monitoring.ex`
- Create: `lib/cinder/books/bibliography_refresher.ex`
- Create: `lib/cinder/books/rehunter.ex`
- Create/modify: `lib/cinder_web/live/book_detail_live.ex`
- Modify: `lib/cinder_web/live/issues_live.ex`
- Modify: `lib/cinder_web/live/activity_live.ex`
- Modify: `lib/cinder/health.ex`
- Modify: `lib/cinder/notifier.ex` and notifier adapters.
- Modify: `lib/cinder/application.ex`
- Test: scheduling, no-flood defaults, bibliography diffing, source disappearance, retries, blocklist, health, and notifier dedupe.

### Done when

- One requested work causes one target, not an author's entire catalogue.
- A confirmed future/all-author policy adds exactly the previewed eligible targets.
- Provider deletion or drift never silently deletes local works/files or broadens monitoring.
- Unattended retries are bounded and visible.

---

## B6 — Readarr migration, adoption preview, and e-book cutover

**Estimate:** 7–10 developer-days

**Objective:** Adopt the current Readarr e-book library and retire Readarr without moving or losing files.

### Work

- Add a Readarr migration source that snapshots authors, books, editions, files, monitoring, profiles, roots, and diagnostics into an expanded provider-neutral contract.
- Generalize `MigrationAdoption` source dispatch instead of extending more `source in [:radarr, :sonarr]` guards.
- Resolve work/edition identity through B2, then preview `ready`, `needs decision`, `blocked`, and `already managed` candidates.
- Detect identity conflicts, duplicate paths, missing files, unsupported formats, multi-format files, and edition ambiguity. Require explicit decisions; never pick silently.
- Adopt in place where possible. If publication into a managed root is required, stage and verify it through the normal B4 import path.
- Map Readarr profiles/monitoring only where semantics are exact; surface unmapped policies rather than inventing defaults.
- Cut over with a short dual-read/single-writer procedure:
  1. Disable Readarr automatic search/RSS/write actions.
  2. Take database/config backups.
  3. Run Cinder preview and resolve all blocked/decision rows.
  4. Adopt and compare counts, paths, sizes, and representative file hashes.
  5. Enable Cinder monitoring.
  6. Keep Readarr stopped but recoverable through the dogfood window.
- Rollback is re-enabling Readarr from the backup; Cinder adoption must never delete source files.

### Likely files

- Create: `lib/cinder/library/migration_source/readarr.ex`
- Modify: `lib/cinder/library/migration_source.ex`
- Modify: `lib/cinder/library/migration_adoption.ex`
- Modify: `lib/cinder/library/migration_reconciler.ex`
- Modify: `lib/cinder_web/live/library_adoption_live.ex`
- Modify: settings/setup migration-source fields and runtime configuration.
- Create: `test/cinder/library/migration_source/readarr_test.exs`
- Modify/create: migration reconciliation/adoption and LiveView tests.
- Create: `docs/readarr-migration.md`

### Done when

- Every source file is classified and every adopted file has a durable work/edition/target association.
- A dry run changes nothing; a repeated adoption is idempotent.
- Missing/ambiguous/conflicting rows block rather than guess.
- Source files remain untouched, no duplicate download starts, and the operator can restore Readarr.
- The migrated inventory and request/monitoring expectations match the B0 parity contract.

**Product gate:** E-book Readarr replacement and cutover candidate.

---

## B7 — Audiobook acquisition and Audiobookshelf publication

**Estimate:** 12–18 developer-days

**Objective:** Add audiobook parity without compromising the simpler e-book path.

### Work

- Enable `:audiobook` targets independently of e-book targets for the same work.
- Add audiobook profiles for accepted containers/codecs, language, chapter expectations, size/duration ranges, and single-file versus multi-track preference.
- Search narrowly in audiobook categories; parse author/title/narrator/edition/part evidence.
- Validate M4B/MP3 and any B0-required formats with bounded ffprobe calls; support directories/multi-track sets with deterministic ordering and no mixed-book imports.
- Add narrator, duration, track/disc, and chapter metadata where available without making it part of work identity.
- Publish deterministic audiobook folders and request an Audiobookshelf scan through its API.[5]
- Extend Readarr adoption for an audiobook instance if present.
- Add audiobook-specific manual search, parked reasons, health, deletion, and recovery.

### Likely files

- Extend: books catalog/target/file schemas from B2/B4.
- Create: `lib/cinder/library/audiobook_import.ex`
- Create: `lib/cinder/library/audiobook_naming.ex`
- Create: `lib/cinder/library/publisher/audiobookshelf.ex`
- Create/extend: audiobook parser/scorer and profile modules.
- Modify: `lib/cinder/library/media_info.ex` or add a book-specific bounded audio probe adapter.
- Test: single M4B, multi-track MP3, disc ordering, duplicate tracks, wrong duration/title, malicious layout, scan failure, and dual e-book+audiobook state.

### Done when

- The same work can be Available as e-book, audiobook, both, or neither independently.
- A multi-track audiobook is imported atomically as one target.
- Audiobookshelf sees the item after refresh, and refresh failure is recoverable without re-downloading.
- An audiobook migration dry run and repeat adoption are safe.

---

## B8 — Hardening, documentation, and production sign-off

**Estimate:** 5–8 developer-days plus a two-week elapsed dogfood window

**Objective:** Turn feature-complete book support into a trustworthy replacement.

### Work

- Exercise deletion, replacement, backup/restore, interrupted staging, out-of-space, permission, provider outage, indexer outage, client outage, publisher outage, and restart recovery.
- Verify database backup coverage for all new rows and document how files are or are not covered.
- Run accessibility, gettext extraction, light/dark theme, requester/admin authorization, API privacy, secret redaction, and SSRF/path-policy reviews.
- Bound provider, archive, command, ffprobe, and library-scan work; verify no unbounded work runs inside Ecto transactions.
- Update setup/settings/status/operating docs and first-run validation.
- Update product wording in `README.md`, `PRODUCT.md`, `ROADMAP.md`, `docs/operating.md`, `mix.exs`, release notes, and container docs.
- Dogfood with Readarr stopped for two weeks. Track missed releases, wrong matches, parked causes, duplicate attempts, metadata drift, scan failures, and recovery actions.
- Fix only concrete sign-off blockers; defer speculative parity.

### Verification

Run at each PR boundary:

```bash
mix test
```

If `mix` is unavailable:

```bash
nix develop --command mix test
```

Before release also run the repository's production asset build, container build, migration/rollback rehearsal against a copy of the production database, and the B0 corpus end-to-end suite.

### Done when

- `mix test` is green and all new provider/client/publisher calls are mocked in tests.
- The complete post-fix diff receives one fresh bounded review with no unresolved correctness/security finding.
- The B0 parity matrix has no unacknowledged cutover requirement.
- Two weeks of dogfood produce no unexplained missing acquisition, wrong import, duplicate grab, unrecoverable parked state, or file loss.
- Readarr remains recoverable until sign-off, then can be decommissioned explicitly.

**Product gate:** Full Readarr replacement.

---

## Dependency order and release slices

```text
B0 inventory/corpus
  └─ B1 media-kind foundation
       └─ B2 books identity + metadata
            └─ B3 request UX
                 └─ B4 e-book vertical slice  ← Book MVP
                      ├─ B5 monitoring
                      │    └─ B6 migration/cutover  ← E-book replacement
                      └─ B7 audiobooks
                           └─ B8 hardening/dogfood  ← Full replacement
```

Rough one-engineer implementation range: **67–101 focused developer-days (13.4–20.2 five-day weeks), plus a two-week elapsed dogfood window**. This is a planning range, not a commitment; B0 may narrow it substantially once the real inventory, required formats, and Calibre/Audiobookshelf topology are known.

---

## Test strategy

### Contract and unit tests

- Metadata behaviour normalization and bounded HTTP failures.
- Work/edition/provider identity, aliases, ambiguity, and refresh preservation.
- Profile/target compatibility and changeset constraints.
- Book parser/scorer positive and adversarial fixtures.
- Book-target state transition table and race-safe expected-state writes.
- Naming, path policy, archive extraction, file validation, and publisher adapters.
- Readarr snapshot normalization, reconciliation, adoption, and idempotency.

### Integration tests

- Discover → request → approve → target creation.
- Approved target → Prowlarr → download client → completion → import → publication → Available.
- Repeated ticks, concurrent admin actions, restart in each lifecycle state, and exhausted retries.
- E-book and audiobook targets for the same work remain independent.
- Request/API/audit/notifier/privacy and role-gating coverage.

### Corpus acceptance tests

For every B0 title, assert one of:

- exact expected work/edition/format and accepted release;
- explicit “no match”;
- explicit ambiguity requiring operator choice;
- already-correct no-op during adoption.

No corpus test may treat the provider's first search result as expected truth.

### Operational rehearsal

- Preview and adopt from frozen Readarr fixtures.
- Rehearse on a copy of the real database and library metadata.
- Verify counts, normalized paths, sizes, and bounded sample hashes before and after adoption.
- Stop/start Cinder during download, staging, publication, and post-import refresh.
- Restore database/config and re-enable Readarr to prove rollback before cutover.

---

## Main risks and mitigations

| Risk | Why it matters | Mitigation / gate |
|---|---|---|
| Metadata identity and edition quality | This is the reason Readarr itself retired.[1] | B0 labeled corpus; provider abstraction; local identity/provenance; manual overrides; fail closed. |
| Existing video-only assumptions | A naive `:books` addition could invoke subtitle, video, Plex, or TV logic. | B1 capability registry and full regression suite before book UI. |
| Poor indexer titles/categories | Books often lack reliable IDs in release names. | Narrow categories; ISBN-first search; author/title/language guard; manual search first; corpus precision gate. |
| Malicious or malformed archives | Book releases may arrive as archives or mixed file sets. | Bounded extraction, path/symlink policy, extension/content validation, staged publication, no partial commit. |
| Calibre write semantics | Directly writing its library database risks corruption. | Supported `calibredb` adapter only; filesystem fallback; contract/integration tests.[4] |
| Multi-file audiobook atomicity | Partial track imports create misleading availability. | Target owns multiple files; validate complete set and commit/publish atomically. |
| Dual writers during migration | Readarr and Cinder could grab/import the same work. | Single-writer cutover, Readarr automation disabled before adoption, idempotent Cinder intent keys. |
| Author monitoring floods | One author can have hundreds of works/editions. | Selected-work default; preview/count; explicit admin confirmation; bounded batches. |
| Scope growth into a full reader/library manager | It would dilute Cinder's acquisition purpose. | Keep reading/streaming, DRM, conversion, comics, and magazines out of scope. |

---

## Files most likely to change

### Existing cross-cutting files

- `lib/cinder/library.ex`
- `lib/cinder/catalog/profile.ex`
- `lib/cinder/catalog/profiles.ex`
- `lib/cinder/requests.ex`
- `lib/cinder/requests/request.ex`
- `lib/cinder/acquisition/indexer.ex`
- `lib/cinder/acquisition/indexer/prowlarr.ex`
- `lib/cinder/settings.ex`
- `lib/cinder/settings/registry.ex`
- `lib/cinder/health.ex`
- `lib/cinder/application.ex`
- `lib/cinder/library/migration_source.ex`
- `lib/cinder/library/migration_adoption.ex`
- `lib/cinder/library/migration_reconciler.ex`
- `lib/cinder_web/live/discover_live.ex`
- `lib/cinder_web/live/library_live.ex`
- `lib/cinder_web/live/library_adoption_live.ex`
- `lib/cinder_web/live/pending_approval_live.ex`
- `lib/cinder_web/live/requests_live.ex`
- `lib/cinder_web/controllers/api_controller.ex`
- `lib/cinder_web/router.ex`
- `config/runtime.exs`

### New domains/adapters

- `lib/cinder/media_kind.ex`
- `lib/cinder/books.ex`
- `lib/cinder/books/**`
- `lib/cinder/download/book_poller.ex`
- `lib/cinder/download/intent_book_target.ex`
- `lib/cinder/library/book_*.ex`
- `lib/cinder/library/audiobook_*.ex`
- `lib/cinder/library/publisher*.ex`
- `lib/cinder/library/migration_source/readarr.ex`
- `lib/cinder_web/live/book_detail_live.ex`
- `lib/cinder_web/components/book_components.ex`
- corresponding migrations and mirrored tests under `test/`.

---

## Open decisions to close in B0

1. Is the active Readarr instance e-book, audiobook, or both?
2. Which formats are truly cutover-critical: EPUB, AZW3, PDF, MOBI, M4B, MP3, or others?
3. Which consumer is authoritative after import: plain filesystem, Calibre/Calibre-Web, Kavita, Audiobookshelf, Plex/Jellyfin, or a combination?
4. Must Cinder preserve the current folder/naming layout, or may it normalize new imports while adopting old files in place?
5. Which languages and edition policies are required?
6. Is monitoring requested works sufficient for first cutover, or is future/all-author monitoring mandatory?
7. Does the current deployment use one or multiple Readarr instances?
8. What minimum corpus precision and maximum manual-review rate are acceptable before automatic grabbing is enabled?

None of these blocks presenting or approving the roadmap. They intentionally block only the milestone whose implementation depends on the answer.

## Sources

[1] https://github.com/Readarr/Readarr — Readarr retirement announcement
[2] https://openlibrary.org/developers/api — Open Library APIs
[3] https://developers.google.com/books/docs/v1/using — Google Books API
[4] https://manual.calibre-ebook.com/generated/en/calibredb.html — calibredb documentation
[5] https://api.audiobookshelf.org — Audiobookshelf API
[6] https://readarr.com/docs/api — Readarr API documentation
