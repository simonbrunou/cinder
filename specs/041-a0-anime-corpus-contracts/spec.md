# Feature Specification: A0 — Anime Corpus and Provider Contracts

**Feature Branch**: `041-a0-anime-corpus-contracts`

**Created**: 2026-07-12

**Status**: Shipped (v1.1.0)

**Input**: Normalized from historical docs — plan.md (originally `docs/superpowers/plans/2026-07-12-a0-anime-corpus-provider-contracts.md`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Decide the anime metadata provider before writing any anime code (Priority: P1)

Before any anime-specific schema, parsing, or acquisition behavior exists, the project needs a
fixed, versioned corpus of well-known anime titles and a read-only probe against the already
configured TMDB and Prowlarr to measure whether TMDB alone is sufficient, or whether a second
provider (e.g. AniDB) must be added.

**Why this priority**: Per plan.md, "A1 cannot begin until the generated report records
`a0_status: pass`"; no anime schema, parsing, or acquisition work may begin before that gate.

**Independent Test**: Run the probe against the fixed corpus and confirm it emits a pass/fail gate
plus evidence for each required title without touching production anime code.

**Acceptance Scenarios**:

1. **Given** the versioned corpus of must-support titles, **When** the probe runs against TMDB,
   **Then** it records discovery hits, absolute-entry counts, episode-group integrity, and specials
   presence for each title.
2. **Given** the same corpus, **When** the probe runs against the configured Prowlarr, **Then** it
   records anime-category and uncategorized result samples with sanitized fields only.
3. **Given** the generated report, **When** every required check passes, **Then** the report records
   `a0_status: pass` and the metadata-provider decision (TMDB alone vs. TMDB+AniDB) with evidence.

### User Story 2 - Keep the probe read-only and its output free of secrets (Priority: P1)

The probe must never mutate application state or leak credentials, download URLs, or raw response
bodies into its generated evidence artifacts.

**Why this priority**: The probe runs against real, operator-configured TMDB and Prowlarr
services and commits its evidence to the repository; per plan.md, generated artifacts "must
never contain credentials, request headers, provider-returned download/magnet/source URLs,
indexer IDs/names, cookies, or raw response bodies."

**Independent Test**: Inspect the generated JSON/Markdown evidence and confirm it contains only the
explicit allowlisted fields (titles, sizes, protocols, category ids/names, publication timestamps,
a derived indexer-identity boolean, fixed documentation links).

**Acceptance Scenarios**:

1. **Given** the probe calls TMDB/Prowlarr, **When** it issues requests, **Then** only read-only
   search/details/alternative-title/episode-group/search GETs are made, with disabled redirects, a
   bounded response size, and bounded timeouts.
2. **Given** a completed probe run, **When** the evidence artifact is inspected, **Then** it contains
   no credentials, headers, cookies, provider-returned download/magnet/source URLs, indexer ids/
   names, or raw response bodies.
3. **Given** the probe's tests, **When** the test suite runs, **Then** no test call reaches the
   network — every provider call is routed through a deterministic stub.

### User Story 3 - Pre-record expected future anime behavior as data, not code (Priority: P2)

The corpus records exact expected outcomes for release parsing, resolver, preflight, and snapshot
behaviors that later milestones (A1–A3) will implement, so each future phase turns a pre-agreed
expectation into a passing test rather than inventing new behavior mid-implementation.

**Why this priority**: Per plan.md, these contracts are "expectation data, not executable anime
logic in A0"; later phases consume the relevant phase subset and turn each record into a passing
test rather than inventing new behavior mid-implementation.

**Independent Test**: Confirm the corpus contains every named behavior contract (e.g. an unknown
video must require mapping, a provider renumbering must not disturb already-active work) and that
loading validates their presence.

**Acceptance Scenarios**:

1. **Given** the corpus file, **When** it is loaded, **Then** every required behavior contract id is
   present, each tagged with its target phase (A1/A2/A3) and expected outcome.
2. **Given** a corpus missing a required behavior contract, **When** it is loaded, **Then** loading
   raises an explicit validation error rather than silently proceeding.
3. **Given** a corpus with a duplicate title slug, **When** it is loaded, **Then** loading raises an
   explicit validation error.

### Edge Cases

- A malformed, incomplete, or duplicate corpus entry must fail loading with an explicit error rather
  than a generic crash.
- A gap in Prowlarr's contract (missing category or field) blocks the pass gate even if TMDB fully
  satisfies discovery — a metadata-provider choice alone is not sufficient to pass.
- The probe must be safely re-runnable without side effects, since it only reads.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST provide a versioned, source-controlled corpus of must-support anime
  titles, each with discovery queries, Prowlarr queries, and explicit capability expectations
  (minimum discovery hits, required episode-group types, minimum absolute-entry count, specials
  requirement).
- **FR-002**: The system MUST provide a versioned set of future-behavior contracts covering release
  parsing, coordinate resolution, import preflight, and mapping-snapshot scenarios, each with an id,
  target phase, and expected outcome.
- **FR-003**: The corpus loader MUST reject malformed, duplicate-slug, or incomplete-behavior-
  contract input with an explicit validation error.
- **FR-004**: The system MUST run a read-only probe against the already-configured TMDB and Prowlarr
  clients using only search/details/alternative-title/episode-group/search GET calls.
- **FR-005**: The probe MUST apply bounded timeouts, a bounded response size, and disabled redirects
  to every provider call.
- **FR-006**: The probe MUST reduce every provider response to an explicit field allowlist before
  persisting it, excluding credentials, headers, cookies, download/magnet/source URLs, indexer ids/
  names, and raw response bodies.
- **FR-007**: The system MUST evaluate, for each corpus title, whether TMDB discovery, episode-group,
  and specials requirements are met, and whether Prowlarr returns the required anime-category and
  metadata fields.
- **FR-008**: The system MUST produce a deterministic JSON and human-readable Markdown report
  recording per-title results, Prowlarr field coverage, and an overall pass/fail gate.
- **FR-009**: The report MUST record the metadata-provider decision (TMDB alone vs. adding a second
  provider) with its supporting evidence.
- **FR-010**: Tests covering the probe MUST NOT make real network calls; every provider interaction
  MUST be exercised through a deterministic stub.
- **FR-011**: Later anime milestones MUST NOT begin schema, parsing, or acquisition implementation
  until the report records a pass gate.

### Key Entities

- **Anime corpus**: the versioned set of must-support titles and their discovery/mapping
  expectations.
- **Behavior contract**: a pre-recorded expected outcome for a specific future release-parsing,
  resolver, preflight, or snapshot scenario, tagged to the milestone that will implement it.
- **Provider contract report**: the generated evidence and pass/fail gate for TMDB and Prowlarr
  against the corpus.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Every must-support corpus title is found under its native, romaji, and English-
  licensed name via TMDB search.
- **SC-002**: Zero corpus cases would have produced an automatic wrong episode mapping, per the
  generated evidence.
- **SC-003**: The generated report records a definitive metadata-provider decision with supporting
  evidence, unblocking or blocking the next milestone.
- **SC-004**: The committed evidence artifacts contain zero secrets or provider-returned download
  URLs.

## Assumptions

- Per `docs/audits/2026-07-12-anime-provider-contracts.md`, the corpus v1 probe run against the live
  configured TMDB and Prowlarr passed every must-support title check (discovery hits, absolute-entry
  counts, episode-group integrity, specials presence) and every Prowlarr field-coverage check
  (categories, indexer identity, published-at, anime-category sample).
- Per ROADMAP.md, A0 concluded with **TMDB chosen as the sole metadata provider for A1–A4** — no
  anime-identity signal was judged strong enough on its own to justify adding a second provider at
  that time (the later A6 milestone closed the remaining alternate-numbering gap using TMDB's own
  episode groups rather than a second provider).
- The one-shot `mix cinder.anime.probe` research tool and its raw evidence dump were deliberately
  deleted in a later cleanup pass (A4.5) once the decision was permanently recorded in the audit
  document and git history; the corpus fixtures themselves were kept and continue to run as
  regression coverage. This is a documented post-ship removal, not a gap in what A0 delivered.
- CHANGELOG.md does not have a dedicated line item for A0 (it is an internal research/decision
  milestone, not a user-facing change); its shipped-with version is inferred from ROADMAP.md's
  overall Part III status placing A0 within the same v1.1.0 program as the other anime milestones.
