# Feature Specification: Books B1 — Media-Kind Capability Registry and Profile Foundation

**Feature Branch**: `055-books-b1-media-kind-foundation`

**Created**: 2026-08-24

**Status**: Shipped (v3.0.0)

**Input**: Normalized from historical docs — plan.md (originally `docs/plans/2026-08-24-books-b1-media-kind-foundation.md`)

Second of three sliced specs under the umbrella replacement of the household's Readarr/Bookshelf instances with native Cinder books support (`053-books-readarr-replacement`). B1 makes e-books and audiobooks first-class media kinds with no video assumptions, while leaving every existing movie/TV behavior byte-for-byte identical.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Add book media kinds without inheriting video behavior (Priority: P1)

Why this priority: without a capability registry that separates "media kind" from "video media kind", simply adding two atoms would silently generate video-shaped settings, mandatory setup gates, Plex health checks, subtitle write eligibility, and reconciler crashes for books — the core risk this milestone exists to prevent.

Independent Test: configure a books or audiobooks library root on an otherwise-default install and confirm no resolution/size-band, Anime, Plex-section, subtitle-write, or media-server-scan behavior appears for it, while movies/TV are unaffected.

**Acceptance Scenarios**:

1. **Given** a fresh install with no book roots configured, **When** the status page, setup gate, library roots, Plex section set, and disk telemetry are inspected, **Then** they are identical to an install with the registry unchanged (no book kind appears anywhere movie/TV-only surfaces are rendered).
2. **Given** a books library root is configured, **When** settings and health are evaluated, **Then** the list of library roots includes it, the video-only library roots list does not, and health shows exactly one "Library (Ebooks)" row — with no resolution, size-band, Anime-root, or Plex-section fields generated for it.
3. **Given** the settings form is rendered, **When** an operator looks for book configuration, **Then** exactly two new inputs appear — the Ebooks and Audiobooks library roots, each with its own connectivity test button — and no book row appears under Releases.

### User Story 2 - Create book media profiles safely (Priority: P2)

Why this priority: B2+ acquisition needs a profile system that already understands book media kinds and rejects invalid combinations as ordinary validation errors, not crashes.

Independent Test: create an e-book profile with standard handling and confirm it persists and is listed; attempt Anime handling on the same kind and confirm it is rejected as a changeset error.

**Acceptance Scenarios**:

1. **Given** an operator creates an e-book profile with standard handling, **When** the profile is saved, **Then** it persists as an e-book profile and appears in the e-book profile list.
2. **Given** an operator attempts to save an e-book profile with Anime handling, **When** the profile is saved, **Then** the changeset returns an error on the handling field rather than raising.
3. **Given** a book media kind has exactly one profile, **When** the operator deletes it, **Then** the deletion succeeds (the last-profile guard that protects movie/TV routing does not apply to books, which are seeded with none).

### Edge Cases

- A request must not be able to reference a book profile — the existing profile-integrity restriction to movie-to-movies-profile and series/season/episode-to-TV-profile must continue to reject book profiles.
- An install with book roots unset must show zero book-related health rows; only a configured root produces one.
- The migration that widens the media-profile kind constraint must preserve every existing trigger and foreign key referencing that table verbatim, since SQLite requires a full table rebuild to alter a check constraint.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST expose a media-kind capability registry describing, per kind, whether it is video, its allowed handlings, its display label, and its filesystem root role — covering movies, TV, e-books, and audiobooks, where video-only derivations continue to iterate only the two video kinds.
- **FR-002**: The system MUST support a distinct filesystem "root role" axis from the media-kind key, so e-books map to the books root role and audiobooks map to the audiobooks root role.
- **FR-003**: The system MUST allow media profiles of kind e-book or audiobook, restricted to standard handling only, validated both at the changeset level and by a database check constraint.
- **FR-004**: The system MUST NOT generate video-shaped settings (resolution bands, size min/max, upgrade cutoff, Anime root, Plex section) for non-video media kinds.
- **FR-005**: Users MUST be able to configure independent library root paths for ebooks and audiobooks, each with its own connectivity test control, without those roots being required at first-run setup.
- **FR-006**: The system MUST keep book library roots out of subtitle write/delete destinations, out of the media-server (Plex/Jellyfin) reconciler, and out of any video-only scanning path.
- **FR-007**: Health/status checks MUST show no row for an unconfigured book library root and exactly one row for a configured one, without ever turning an install red for an unconfigured book root.
- **FR-008**: Requests MUST continue to be rejected if they reference a book media profile; this fail-closed behavior must not weaken as book kinds are introduced.
- **FR-009**: The last-remaining-profile deletion guard MUST apply only to video media kinds, since book kinds are seeded with zero profiles by default and a single accidental book profile must remain deletable.
- **FR-010**: The database migration that widens the media-profile kind constraint MUST preserve every dependent trigger and foreign-key reference across the rebuild, leaving foreign-key enforcement re-enabled even when the rebuild fails partway.

### Key Entities

- **Media kind**: The registry key (movies, TV, e-book, audiobook) carrying capability flags (video?, handlings, label) with no video assumptions for book kinds.
- **Root role**: The filesystem-root axis (movies, TV, books, audiobooks) derived from, but distinct from, a media kind.
- **Media profile**: A named quality/handling configuration scoped to one media kind, now extendable to book kinds with standard handling only.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An install with no book roots configured shows a `/status` panel, setup gate, library-roots list, Plex section set, and disk telemetry identical to the pre-existing (movies/TV-only) behavior.
- **SC-002**: Configuring a book root introduces exactly one new health row and zero new resolution, size-band, Anime-root, Plex-section, subtitle-root, or media-server-scan behavior.
- **SC-003**: The settings form gains exactly two new inputs (Ebooks and Audiobooks library roots, each with a test button) and no other book-related UI element.
- **SC-004**: 100% of existing movie/TV regression behavior (Plex sections, size bands, release policy, reconciler, disk telemetry, setup gate) remains byte-for-byte unchanged, verified by a fenced regression test per surface.
- **SC-005**: An e-book profile with standard handling can be created and deleted even as the sole profile of its kind; an Anime handling on a book kind is rejected as a validation error in 100% of attempts, never a raise.

## Assumptions

- This spec covers only the media-kind/profile/settings/health foundation (B1); the book catalog (authors, works, editions) and the (work, media kind) monitoring target explicitly move to B2, since works does not exist yet.
- Poller orchestration extraction and download label/category changes are explicitly deferred (no third caller exists yet to justify the refactor).
- No book media profile is seeded by default; an operator must create one before any book profile exists.
- Only standard handling is supported for book media kinds in this slice; no book equivalent of the video Anime handling exists.
