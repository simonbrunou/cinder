# Feature Specification: Books metadata providers, identity resolution, and refresh

**Feature Branch**: `057-books-b2b-metadata-identity`

**Created**: 2026-08-24

**Status**: Shipped (v3.0.0)

**Input**: Normalized from historical docs — plan.md (originally `docs/plans/2026-08-24-books-b2b-metadata-and-identity.md`)

Part of the umbrella books/Readarr-replacement effort (see `053-books-readarr-replacement`); this
slice is B2b of that roadmap, filling the B2a catalog with real provider data and a conservative
identity resolver.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Reliable work identification from a provider query (Priority: P1)

Why this priority: the resolver must be deliberately conservative, returning an explained
non-answer rather than a guess.

Independent Test: feed the resolver a durable-identity query and a free-text query and confirm the
correct work is returned, or an explained non-answer, entirely through `mix test` — no LiveView
required.

**Acceptance Scenarios**:

1. **Given** a query naming a provider and a durable foreign id, **When** the resolver runs, **Then**
   it performs an exact fetch and returns that work.
2. **Given** a free-text query whose contributor and title tokens match exactly one candidate,
   **When** the resolver runs, **Then** it returns that candidate with recorded evidence.
3. **Given** a free-text query with no contributor evidence in any candidate, **When** the resolver
   runs, **Then** it returns an explained unresolved outcome rather than guessing.

### User Story 2 - Resilient metadata refresh (Priority: P2)

Why this priority: a household's book metadata must stay current without a provider outage
corrupting or erasing what is already known.

Independent Test: run the refresher against a mocked provider that errors, then one that returns a
partial payload, and inspect the stored work/edition rows for each.

**Acceptance Scenarios**:

1. **Given** a work with a stored provider identifier, **When** the refresher's periodic pass runs
   and the provider responds normally, **Then** the work's fields are re-upserted from the response.
2. **Given** a provider that errors during a refresh pass, **When** the pass completes, **Then**
   every work, edition, and identifier is byte-identical to before, and the pass logs no rescued
   exception.
3. **Given** a provider response missing a field the work previously had populated, **When** the
   refresh applies it, **Then** the existing value is left untouched rather than cleared.

### User Story 3 - Provider-neutral import without identity merging (Priority: P3)

Why this priority: provider identities must never be equated without recorded evidence — a work
resolved through two providers is recorded as two identifier rows, never merged.

Independent Test: import the same book resolved separately through two providers and confirm two
distinct identifier rows are created, never a merge.

**Acceptance Scenarios**:

1. **Given** a work resolved once via the primary provider and once via the secondary provider,
   **When** both are imported, **Then** the catalog records two identifier rows rather than one
   merged identity.
2. **Given** an ISBN variant of an edition already imported, **When** it is imported again,
   **Then** it resolves to the same edition and one normalized identifier row, not a duplicate.

### Edge Cases

- The secondary metadata provider is unconfigured: the resolver still answers using the primary
  provider alone.
- Both providers error outright: the resolver reports "providers unavailable," distinct from
  "searched and found nothing."
- A contributor the provider named but did not fully identify: the credit is dropped, not invented,
  and the work is marked as having incomplete contributor data.
- A non-Latin-script title with a partial Latin residue: matching still proceeds on the residue
  rather than rejecting the candidate outright, as long as some Latin content survives the fold.
- An identifier (ISBN/ASIN) already recorded against a different edition is left where it is;
  re-pointing it is treated as an identity change requiring separate evidence, not silently done
  here.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST resolve a durable "provider:work:id"-shaped query via an exact fetch
  against that provider, bypassing free-text search.
- **FR-002**: System MUST reject a free-text candidate that has no contributor name evidence
  present in the query, however well its title matches.
- **FR-003**: System MUST require an exact or trailing-annotation-trimmed title match (after
  contributor tokens are subtracted) before accepting a free-text candidate, never a fuzzy or
  partial match.
- **FR-004**: System MUST return an explained "unresolved" outcome, distinguishable from a
  transport/provider failure, when no candidate survives matching.
- **FR-005**: System MUST distinguish "all configured providers errored" from "providers answered
  with no result," and surface these as different outcomes.
- **FR-006**: System MUST walk configured providers in the operator-declared order and accept the
  first reliable answer, never merging or re-ranking across providers.
- **FR-007**: System MUST never equate identities discovered through different providers; each
  provider match is recorded as a distinct identifier against the same or a different work.
- **FR-008**: System MUST normalize ISBN/ASIN identifiers on write so that equivalent representations
  (hyphenated vs. unhyphenated) collapse to one identifier row.
- **FR-009**: System MUST leave an identifier already recorded against a different edition where it
  is, rather than silently re-pointing it during import.
- **FR-010**: System MUST replace a work's contributor credits and series memberships wholesale on
  each successful import, reflecting only the most recent import's data.
- **FR-011**: System MUST mark a work as having incomplete contributor data when a provider returns
  zero credited contributors, or a credit references an author the payload does not describe.
- **FR-012**: System MUST periodically refresh previously-imported works from their recorded
  provider identifiers without requiring operator action.
- **FR-013**: System MUST write only the fields a refresh response actually returned, never clearing
  an existing field value because a later response omitted it.
- **FR-014**: System MUST continue refreshing remaining works when one work's refresh fails, without
  raising an unhandled exception, and MUST log the failure.
- **FR-015**: System MUST degrade to a single configured provider's results when another configured
  provider is unavailable or unconfigured, rather than failing entirely.
- **FR-016**: Operators MUST be able to configure the base URL and, where applicable, a secret API
  key for each metadata provider through the application's settings surface.

### Key Entities

- **Author**: a person or organization credited on one or more works.
- **Work**: the logical title a household discovers and requests, identified by one or more
  provider identifiers.
- **Edition**: a language/publisher/date/identifier-specific manifestation of a work.
- **Metadata provider**: an external service supplying search and per-work lookups, ranked by
  configured order.
- **Provider identifier**: a durable, provider-scoped reference tying a local work/edition to an
  external record; never shared or merged across providers.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Across the project's labeled evaluation corpus, the configured provider pair resolves
  at least 90% of cases correctly, with zero silent first-result selections.
- **SC-002**: A candidate lacking contributor evidence in the query is never selected, regardless of
  title similarity.
- **SC-003**: A metadata refresh that encounters a provider failure leaves all previously stored
  work, edition, and identifier data unchanged and reports the failure rather than raising.
- **SC-004**: Importing the same book through two different providers always yields two distinct
  identity records, never one merged record.
- **SC-005**: An ISBN variant of an already-imported edition always resolves to the same edition and
  a single normalized identifier row.

## Assumptions

- Scope excludes LiveView UI, acquisition, and book files — those are later slices in the umbrella
  books/Readarr-replacement effort (see `053-books-readarr-replacement`).
- A Google Books adapter was evaluated and explicitly not built: keyless access failed uniformly in
  evaluation, leaving no acceptance criterion to build against.
- Author aliases are deferred out of this slice; they only become useful once local author search
  exists, which is a later slice.
- Operator-initiated manual metadata corrections are deferred; no override mechanism exists yet for
  this slice to preserve across a refresh.
- Provider health/status reporting on an operational dashboard is out of scope absent an operator
  need.
- A provider-side ISBN-only fetch is deferred; nothing in this slice resolves from a bare ISBN.
- Edition-level contributor data (e.g., audiobook narrators) is deferred; nothing in this slice
  acquires audiobooks yet.
