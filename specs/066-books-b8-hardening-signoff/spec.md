# Feature Specification: Books Hardening, Documentation, and Production Sign-off

**Feature Branch**: `066-books-b8-hardening-signoff`

**Created**: 2026-09-02

**Status**: Shipped (v3.0.0)

**Input**: Normalized from historical docs — plan.md (originally `docs/plans/2026-09-02-books-b8-hardening-and-signoff.md`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Confirm no cutover requirement was silently missed (Priority: P1)

Before a household stops relying on the legacy system, an admin needs assurance that every
parity requirement locked earlier in the project actually has working, tested code behind it, not
just a plan that once said so.

**Why this priority**: This is the one criterion the whole hardening milestone exists to make
verifiable rather than a manual claim.

**Independent Test**: Run the automated test suite and confirm it fails if a required parity-matrix
row's covering test is ever removed.

**Acceptance Scenarios**:

1. **Given** every parity-matrix row marked required-for-cutover or required-later, **When** the
   automated check runs, **Then** each such row's named behavior has at least one passing test
   proving it exists.
2. **Given** a future change removes a test a required row depends on, **When** the suite runs,
   **Then** it fails rather than silently losing coverage.

### User Story 2 - Recover automatically from a crash during acquisition (Priority: P1)

An admin's household deployment restarts unexpectedly (crash, deploy, host reboot) mid-download;
book/audiobook acquisition needs to resume on its own, exactly as movies and TV already do.

**Why this priority**: An acquisition pipeline that cannot survive a restart cannot be trusted
unattended for a two-week dogfood window, let alone production.

**Independent Test**: Kill the book acquisition process mid-cycle and confirm it restarts and
resumes work automatically.

**Acceptance Scenarios**:

1. **Given** the book acquisition process is killed mid-tick, **When** the supervisor restarts it,
   **Then** the next cycle still advances the in-progress work.
2. **Given** every outbound provider call, archive extraction, and subprocess invocation touching
   books, **When** reviewed, **Then** each carries an explicit size/time/count bound and no
   database transaction performs network, subprocess, or filesystem-extraction work inside it.

### User Story 3 - Track operational signals during unattended operation (Priority: P2)

An admin running the dogfood window wants a durable, queryable record of the events that indicate
something went wrong unattended, rather than relying purely on memory or scattered logs.

**Why this priority**: A two-week unattended window is only useful if its problems are legible
afterward.

**Independent Test**: Trigger a duplicate grab attempt and a metadata drift on refresh; confirm
both are durably logged and visible on an admin read surface.

**Acceptance Scenarios**:

1. **Given** a duplicate download attempt for an already-in-progress target, **When** it is
   refused, **Then** the refusal is durably recorded.
2. **Given** an unattended metadata refresh changes a work's title or contributor set, **When** the
   refresh completes, **Then** the change is durably recorded with what specifically changed.
3. **Given** the audiobook-server scan transitions from failing to succeeding, **When** it
   recovers, **Then** exactly one recovery record is written, not one per retry attempt.

### User Story 4 - Understand and configure books/audiobooks from the product surface (Priority: P2)

A new or existing operator reads the product's own documentation and setup flow to learn about, and
correctly configure, book and audiobook support.

**Why this priority**: Feature-complete code that the documentation and setup flow never mention is
not actually shippable to a real household.

**Independent Test**: Run first-run setup with an unwritable audiobook root and confirm setup
cannot complete; grep the product documentation for book/audiobook terms and confirm real coverage.

**Acceptance Scenarios**:

1. **Given** a fresh install with an unwritable or unset book or audiobook library root, **When**
   the operator attempts to finish setup, **Then** setup is blocked exactly as it already is for
   missing movie/TV roots.
2. **Given** the product's README, product description, and operating documentation, **When** an
   operator reads them, **Then** book/audiobook request, acquisition, and publication behavior is
   described accurately, including that release selection is a manual action.

### Edge Cases

- A log-write failure for an operational signal must never block or roll back the operation it was
  recording.
- A continuously failing audiobook-server connection across the full dogfood window must not
  produce unbounded log growth — only state-transition events are recorded.
- Categories with no code-observable signal (missed releases the indexer never returned; an
  operator's subjective "wrong match" judgment) are explicitly acknowledged as untracked by any
  mechanism, not silently assumed covered.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST verify, via an automated check, that every parity-matrix requirement
  marked required-for-cutover or required-later has at least one passing test covering it, and MUST
  fail that check if such coverage is later removed.
- **FR-002**: Book acquisition MUST recover automatically from a process crash and resume work on
  restart, matching the guarantee already provided for movies and TV.
- **FR-003**: Every book/audiobook-related outbound provider or service call, archive extraction,
  and external subprocess invocation MUST be bounded by an explicit size, time, or count limit.
- **FR-004**: No book-related database transaction MUST perform network, subprocess, or
  filesystem-extraction work inside its transaction body.
- **FR-005**: System MUST durably record refused duplicate download attempts, detected metadata
  drift (title or contributor-set changes) on unattended refresh, and audiobook-server scan
  failure/recovery transitions.
- **FR-006**: A failure to write an operational log record MUST NOT block or roll back the
  operation it was recording.
- **FR-007**: An admin-visible read surface MUST show recent operational log entries, updating
  live as new entries are recorded.
- **FR-008**: Database backup MUST cover every book/audiobook catalog row; documentation MUST
  state explicitly that on-disk book/audiobook files are outside the database backup's coverage.
- **FR-009**: First-run setup validation MUST require a writable e-book and audiobook library root
  before setup can be completed, exactly as it already requires for movie/TV roots.
- **FR-010**: Product documentation (README, product description, operating documentation, example
  deployment configuration) MUST describe book/audiobook request, acquisition, and publication
  behavior accurately, including that release selection is a manual, not automatic, action.
- **FR-011**: System MUST provide an operator-usable checklist covering pre-window and
  post-window steps for running the dogfood window and deciding sign-off across the roadmap's
  tracked outcome categories.
- **FR-012**: System MUST document the steps required to decommission the legacy Readarr-protocol
  system after an operator's explicit sign-off decision.
- **FR-013**: A security, privacy, and accessibility review of the accumulated books feature set
  MUST be completed, with each finding either fixed in the same change or explicitly filed as
  deferred work.

### Key Entities *(include if feature involves data)*

- **Book operations log entry**: a durable record of a duplicate-grab refusal, a metadata-drift
  detection, or an audiobook-server scan failure/recovery transition.
- **Parity-matrix requirement**: a locked contract row with a disposition and an acceptance
  criterion traced to covering test code.
- **Dogfood checklist**: the documented pre- and post-window operator procedure and its tracked
  outcome categories.
- **Decommission runbook**: the documented steps for retiring the legacy system after sign-off.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Every parity-matrix required row has automated test coverage, verified by an
  automated check rather than manual review.
- **SC-002**: A killed book-acquisition process resumes work automatically after restart with no
  operator intervention.
- **SC-003**: An operator following the dogfood checklist can determine sign-off status, from
  durable records plus direct observation, across every roadmap-tracked outcome category at the end
  of the window.
- **SC-004**: A fresh install cannot complete first-run setup without a writable book and audiobook
  library root.
- **SC-005**: Grepping the product documentation for book/audiobook terms returns real coverage
  across every listed file, where previously it returned none.

## Assumptions

- This is the final slice (B8) of the umbrella books/Readarr-replacement track (see
  `053-books-readarr-replacement`), sequenced strictly after audiobook acquisition; it adds no new
  catalog behavior beyond what earlier slices already locked, and its job is verification,
  targeted gap-closure, and documentation rather than new feature scope.
- The milestone explicitly does not claim to close two of the roadmap's own Done-when criteria: a
  two-week Readarr-stopped dogfood window (elapsed wall-clock time plus operator observation) and
  Readarr's eventual decommission (a deployment action). What ships instead is the tooling that
  makes that window and decision legible — the operations log and the dogfood/decommission
  documentation — not a substitute for either.
- Two of the roadmap's seven tracked dogfood outcome categories (missed releases the indexer never
  returned; an operator's subjective "wrong match" judgment) have no code-observable signal and
  remain explicitly untracked by any mechanism, by design, rather than covered by an invented
  proxy.
- A pre-existing, video-shared timeout gap in the shared media-inspection subprocess call was
  identified during this milestone's audit but deliberately left unfixed here as out of scope (not
  book-specific); it was closed in a subsequent patch release (CHANGELOG 3.0.1: "Bounded
  `ffprobe`/`ffmpeg` media-inspection calls (#447)"), tracked separately from this feature's own
  scope.
- No general book-target deletion feature is introduced; a held target's payload remaining on disk,
  recoverable via the existing retry path, is treated as the complete recovery story.
- No automated dogfood-window analysis or alerting is built; the operations log is a passive read
  surface, and sign-off remains an explicit manual operator decision at the end of the window.
