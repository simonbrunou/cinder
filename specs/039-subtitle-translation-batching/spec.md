# Feature Specification: Subtitle Translation Batching

**Feature Branch**: `039-subtitle-translation-batching`

**Created**: 2026-07-11

**Status**: Shipped

**Input**: Normalized from historical docs — research.md (originally `docs/superpowers/specs/2026-07-11-subtitle-translation-batching-design.md`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A full-length movie's subtitles actually get translated (Priority: P1)

A household member has a movie with a foreign-language subtitle track and expects Cinder's
translation fallback to produce a translated sidecar, not silently fail because the file is long.

**Why this priority**: Before this change, translation of any real-length subtitle file (a movie
has roughly 1000-1500 cues) reliably timed out and produced no sidecar at all — the feature could
not do its job for real inputs, only for trivial test inputs.

**Independent Test**: Run translation against a full-length movie subtitle file and confirm a
complete, correctly-ordered translated sidecar is produced.

**Acceptance Scenarios**:

1. **Given** a movie subtitle file with roughly 1000-1500 cues, **When** translation runs,
   **Then** it completes and produces a translated sidecar containing every cue in its original
   order.
2. **Given** a translation request for a large file, **When** the underlying translation calls
   are made, **Then** no single call is allowed to run long enough to trip the previous 15-second
   timeout, because each call now covers only a bounded batch of cues.
3. **Given** an empty cue list, **When** translation runs, **Then** it succeeds immediately with
   an empty result and makes no outbound translation call.

### User Story 2 - A mid-file translation failure never produces a broken sidecar (Priority: P2)

An operator relies on translated subtitles being all-or-nothing: either a complete, correctly
ordered sidecar, or no sidecar at all — never a partial or corrupted one.

**Why this priority**: Splitting one request into many batches introduces a new failure mode (a
batch partway through the file failing) that must not silently produce a truncated or
out-of-order sidecar.

**Independent Test**: Force a failure on a batch partway through a multi-batch file and confirm
the whole translation call fails with no sidecar written.

**Acceptance Scenarios**:

1. **Given** a file large enough to require multiple batches, **When** a batch in the middle of
   the sequence fails, **Then** the overall translation call fails and no partial sidecar is
   written.
2. **Given** a file large enough to require multiple batches, **When** all batches succeed,
   **Then** the translated cues are concatenated back together in their original order.

### Edge Cases

- A single-batch (small) file continues to work exactly as before, with one request.
- Batches are translated one after another, not concurrently, because the translation engine is
  CPU-bound with limited parallelism and concurrent requests would only contend for the same
  resource or risk a rate limit.
- Batch size and per-batch timeout are tunable without a code change, since real-world translation
  throughput varies by the hardware running the translation service.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST split a subtitle file's cues into bounded batches before submitting
  them for translation, rather than submitting the entire file as one request.
- **FR-002**: The system MUST translate batches sequentially, not concurrently.
- **FR-003**: The system MUST concatenate successfully translated batches back together in their
  original cue order.
- **FR-004**: The system MUST fail the entire translation call, producing no sidecar, if any
  batch fails partway through.
- **FR-005**: The system MUST return an immediate success with no outbound call for an empty cue
  list.
- **FR-006**: The system MUST apply its request timeout per batch rather than to the whole file,
  and MUST raise that per-batch timeout since a batch is now small enough to safely allow more
  time per call.
- **FR-007**: The system MUST allow the batch size and per-batch timeout to be configured, with
  sensible defaults, so throughput can be tuned to the deployed translation service's hardware
  without a code change.
- **FR-008**: The system MUST preserve the existing translation contract: same number of cues in
  as out, and either a complete translated result or a failure — never a partial result.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A full-length movie or episode subtitle file can be translated end-to-end and
  produces a complete, correctly-ordered sidecar, where it previously failed every time.
- **SC-002**: No individual translation request is large enough to require a timeout anywhere
  near the file's total translation time.
- **SC-003**: A failure in any single batch never results in a partial or out-of-order sidecar
  being written.
- **SC-004**: An empty subtitle file never triggers an outbound translation request.

## Assumptions

- The translation service itself (the self-hosted instance this feature talks to) is deployed and
  operated separately; this feature only changes how Cinder shapes its requests to it.
- Because subtitle translation runs off the import path inside an asynchronous, best-effort
  background sweep, a translation taking several minutes for a full movie is an acceptable
  trade-off for reliability.
- Cue content formatted as HTML is handled the same as before; this feature does not change how
  individual cue text is interpreted, only how many cues are sent per request.
