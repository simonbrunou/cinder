# Feature Specification: Book Pipeline Admin Surface, Manual Search, and Grab

**Feature Branch**: `062-books-b4c-operator-surface`

**Created**: 2026-09-01

**Status**: Shipped (v3.0.0)

**Input**: Normalized from historical docs — plan.md (originally `docs/plans/2026-09-01-books-b4c-operator-surface.md`)

This is the third and final slice of the [053 books/Readarr-replacement umbrella](../053-books-readarr-replacement/spec.md)'s B4 milestone. It is the operator surface for e-book acquisition: an admin page that shows what indexers found for a monitored e-book target, why each release was accepted or rejected, a Grab action, and a live view of the target reaching Available or Held. It is also the milestone's product gate — the [B4a search/scoring](../060-books-b4a-ebook-search-scoring/spec.md) and [B4b download/publication](../061-books-b4b-ebook-download-publication/spec.md) layers had no production caller until this slice wires one.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - An admin opens a book's pipeline page from an approved request (Priority: P1)

Why this priority: without a reachable entry point, the acquisition pipeline built in the prior two slices has no way for a human to actually use it — this is the gate that makes the whole B4 milestone deliver a product outcome.

Independent Test: approve a book request, follow the resulting link, and confirm the per-book pipeline page opens showing the work's e-book (and, if present, audiobook) status.

**Acceptance Scenarios**:

1. **Given** an approved e-book request, **When** an admin views it in the request queue, **Then** its title is a link to that book's pipeline page.
2. **Given** a pending or denied book request, **When** an admin views it in the request queue, **Then** its title is plain text with no link, since there is nothing to show yet.
3. **Given** a work with an approved e-book target but no audiobook target, **When** the pipeline page opens, **Then** the e-book section shows its pipeline detail and the audiobook section shows a plain "not yet approved" line with no search entry point.

---

### User Story 2 - An admin searches, reviews accepted and rejected releases, and grabs one (Priority: P1)

Why this priority: this is the core acquisition action the whole slice exists to deliver — turning a ranked, explained candidate list into an actual download, with rejections legible enough that an admin can trust a "no good release" result rather than wondering if something was silently skipped.

Independent Test: open a monitored e-book target's pipeline page, trigger a search, and confirm accepted releases show their supporting detail with a Grab action while rejected releases show a specific, human-readable reason with no Grab action, then confirm clicking Grab starts a download.

**Acceptance Scenarios**:

1. **Given** a monitored e-book target with no download in progress, **When** its pipeline page loads, **Then** a search runs automatically and, once complete, shows accepted releases (each with format, language, retail marker, and size, ranked best-first) with a Grab action, and rejected releases (each with a specific reason) with no Grab action.
2. **Given** an admin clicks Grab on an accepted release, **When** the submission succeeds, **Then** the page shows a "grabbing" confirmation and the search panel is replaced by an in-flight download section on the next render.
3. **Given** a search where some indexers could not be reached, **When** results render, **Then** a distinct banner states results may be incomplete, shown independently of whether either list is empty, and distinct from a genuine zero-result search where every indexer was reachable.

---

### User Story 3 - Grab is only offered where it is safe to act, and every outcome is legible (Priority: P1)

Why this priority: offering Grab on a target that is already downloading, already available, or already held would either double-submit a download or confuse the admin with an error that a correctly gated UI should never surface.

Independent Test: verify the search-and-Grab affordance is hidden for an audiobook target, an available target, a held target, and a target with an in-flight download, and that every reachable Grab outcome (success, permanent failure, transient failure) renders distinct, human-readable feedback.

**Acceptance Scenarios**:

1. **Given** a target that is available, held, an audiobook, or already has an in-flight download, **When** the pipeline page renders, **Then** no search panel or Grab action is offered for it.
2. **Given** a Grab submission that is permanently rejected, **When** the outcome renders, **Then** the target reaches Held synchronously and the page shows that target's own exact hold reason.
3. **Given** a Grab submission that fails for a transient reason, **When** the outcome renders, **Then** the target remains monitored (eligible for a later retry) and the page shows generic failure copy, never a raw internal error code.

### Edge Cases

- A non-integer or nonexistent id in the pipeline page's URL redirects to the request queue with an explanatory message, never a server error.
- A non-admin session that reaches the pipeline page's URL is denied access and redirected, identically to every other admin pipeline detail page.
- Every rejection reason the scorer can produce renders distinct, non-empty, human-readable copy; a rejection reason the UI does not recognize renders a generic fallback rather than a raw internal code.
- In-flight download progress updates live on the page without a manual refresh or a client-side polling timer, driven by the same terminal-status broadcast mechanism every other pipeline detail page already uses.
- Navigating away from the pipeline page while a search is still running cleanly cancels that search rather than leaving orphaned work.
- No automatic release-selection capability or automatic search pass is introduced by adding this UI — the pipeline still requires a human to pick a release.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST provide a per-work admin pipeline page reachable from an approved book request's link in the request queue; a pending or denied request MUST NOT link anywhere.
- **FR-002**: System MUST render a section per book media kind (e-book, audiobook) on the pipeline page, showing pipeline detail for a kind with an existing target and a plain "not yet approved" line for a kind with none.
- **FR-003**: System MUST display each target's status using the existing shared book status badge, covering monitored, available, and held states.
- **FR-004**: System MUST offer the search-and-Grab affordance only for a target that is an e-book kind, is monitored, and has no in-flight download already recorded against it.
- **FR-005**: System MUST run a release search automatically when the search panel is shown, display a loading state while it runs, and render an error state with a retry affordance if every indexer query fails.
- **FR-006**: System MUST render accepted releases (ranked best-first, each with format, language, retail marker, and size) with a Grab action, and rejected releases (each with one specific, human-readable reason) with no Grab action — both lists always shown together.
- **FR-007**: System MUST distinguish, in its rendering, an incomplete search (at least one indexer unreachable) from a genuinely complete search that found nothing, independent of whether either result list is empty.
- **FR-008**: System MUST map every scorer rejection reason to distinct, non-empty, human-readable copy, and MUST render a generic fallback (never the internal reason's own raw name) for any reason it does not recognize.
- **FR-009**: System MUST submit a Grab action for the chosen release and MUST NOT perform any other write from the pipeline page beyond that single submission.
- **FR-010**: System MUST render a "grabbing" confirmation on a successful submission and replace the search panel with an in-flight download section once a download is in progress.
- **FR-011**: System MUST render the target's own exact hold reason when a Grab submission is permanently rejected and the target reaches held; System MUST render generic failure copy (never a raw internal error code) when a Grab submission fails for a reason that leaves the target still monitored.
- **FR-012**: System MUST update in-flight download progress, and the target's terminal status (available or held), live on the pipeline page without a manual page reload, using the same broadcast-driven mechanism used elsewhere in the admin pipeline surfaces.
- **FR-013**: System MUST redirect to the request queue with an explanatory message for a malformed or nonexistent pipeline page id, never raising an unhandled error.
- **FR-014**: System MUST restrict the pipeline page to admin sessions, denying and redirecting any other session exactly as every other admin pipeline detail page does.
- **FR-015**: System MUST NOT introduce any automatic release-selection capability or any automatic search pass as part of this slice — every release choice remains a human action.
- **FR-016**: System MUST NOT offer any edit, retry, blocklist-clearing, or "find a better match" control on this page — those remain out of scope for this slice.

### Key Entities

- **Book pipeline page**: the per-work admin view showing e-book (and read-only audiobook) acquisition status, search results, and Grab action.
- **Accepted / rejected release row**: a search result rendered with either supporting evidence and a Grab action, or a specific rejection reason and no Grab action.
- **In-flight download section**: the live progress view shown in place of the search panel once a download has been submitted for a target.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An admin can reach the pipeline page from an approved book request, review accepted and rejected releases with their reasons, press Grab, and watch the target reach Available or Held without a manual page reload.
- **SC-002**: Every rejection reason the scorer can produce renders real, distinct, human-readable copy on the page; no internal reason code is ever shown verbatim to an admin.
- **SC-003**: The search-and-Grab affordance is never shown for an audiobook target, an available target, a held target, or a target with an in-flight download already present.
- **SC-004**: A malformed or nonexistent pipeline page request never produces a server error — it always redirects with an explanatory message.
- **SC-005**: A non-admin session is denied access to the pipeline page under the same rule as every other admin pipeline detail page.
- **SC-006**: After this slice ships, an approved corpus e-book can be discovered, downloaded, validated, published, and shown as Available entirely through this admin surface, with no direct database or code intervention required.

## Assumptions

- This is slice three of three (B4a/B4b/B4c) of the B4 milestone within the [053 books/Readarr-replacement umbrella](../053-books-readarr-replacement/spec.md); it is also this milestone's product-completion gate, since it gives the prior two slices' pipeline its first production caller.
- Automatic release selection remains explicitly out of scope: this slice adds a human-operated caller for the search/scoring layer, but no automatic-selection function is introduced and the download poller still runs no search pass — the same settled no-automatic-selection decision preserved unchanged from the two prior slices.
- Audiobooks render read-only, with no search or Grab entry point, pending a later milestone.
- A dedicated books tab on the general library listing surface, retry/blocklist-clearing for a held target, "find a better match" on an available target, extending the activity feed to books, and any author-alias or metadata-edit control are explicitly deferred to later work, not part of this slice.
- Adoption/migration of an existing Readarr-protocol library is untouched by this slice.
