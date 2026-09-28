# Feature Specification: SABnzbd (Usenet) Download Client Support

**Feature Branch**: `006-sabnzbd-support`

**Created**: 2026-06-19

**Status**: Shipped

**Input**: Normalized from historical docs — research.md (originally `docs/superpowers/specs/2026-06-19-sabnzbd-support-design.md`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Download from either torrent or Usenet indexers (Priority: P1)

An operator configures both a torrent client (qBittorrent) and a Usenet client (SABnzbd). When
the system finds the best release for a wanted movie, it downloads it from whichever protocol won
— torrents go to qBittorrent, NZBs go to SABnzbd — without the operator having to pick a single
"download client" for the whole instance.

**Why this priority**: This is the entire point of the feature — a single Cinder instance
downloading from both protocols at once, the real-world Prowlarr setup where both torrent and
Usenet indexers are aggregated.

**Independent Test**: Configure both a torrent client and a Usenet client, trigger a search that
returns both torrent and NZB candidates, and confirm the winning release is added to the client
matching its own protocol.

**Acceptance Scenarios**:

1. **Given** both a torrent and a Usenet client are configured, **When** the best release found is
   an NZB, **Then** it is added to SABnzbd's download queue and the movie is marked downloading with
   its download id and protocol recorded.
2. **Given** a movie is downloading via SABnzbd, **When** the system polls for status, **Then** it
   polls the same client (SABnzbd) that the download was added to, using the protocol recorded at
   add time.
3. **Given** a SABnzbd job completes, **When** status is polled, **Then** the system reports the
   completed folder as the content ready for import.

---

### User Story 2 - Graceful degradation to a single protocol (Priority: P2)

An operator who only has a torrent indexer (or only a Usenet indexer/client) configures just that
one client. The system then only considers releases of the protocol it can actually download,
instead of picking a release it has no client for.

**Why this priority**: Without this, configuring only one client type could still surface releases
of the other protocol and fail to download them — a confusing, silent failure mode.

**Independent Test**: Configure only a torrent client (no Usenet client) and confirm a search that
returns both torrent and NZB candidates only considers the torrent ones when picking the winner.

**Acceptance Scenarios**:

1. **Given** only a torrent client is configured, **When** the best-release search runs, **Then**
   NZB-only candidates are excluded from consideration and a torrent release is chosen if one
   exists.
2. **Given** only a Usenet client is configured, **When** the best-release search runs, **Then**
   only NZB candidates are considered.

---

### User Story 3 - Safe handling of SABnzbd-specific failure modes (Priority: P3)

When SABnzbd rejects a duplicate add, reports a failed download, or a configured client is removed
mid-download, the movie fails loudly and terminally rather than hanging or silently stalling
forever.

**Why this priority**: Usenet-specific failure surfaces (duplicate rejection, asynchronous add,
pagination hiding a job) are distinct enough from the torrent path that without explicit handling
they could leave a movie stuck indefinitely.

**Independent Test**: Simulate SABnzbd returning an empty list of queued job identifiers on add (its
duplicate-rejection signal) and confirm the movie fails through the existing bounded-retry path
rather than hanging.

**Acceptance Scenarios**:

1. **Given** SABnzbd rejects an add as a duplicate, **When** the system attempts the add, **Then**
   it is treated as a failed add and flows through the existing bounded retry to a terminal
   failed state.
2. **Given** a movie's download client has been removed from configuration mid-download, **When**
   status is polled, **Then** the movie is retried a bounded number of times and then parked at a
   terminal failed state instead of polling forever.
3. **Given** a completed SABnzbd job, **When** status is polled, **Then** the job is found by its
   download id even if SABnzbd's default queue/history page would otherwise hide it.

---

### Edge Cases

- A Usenet indexer that mis-reports or omits the protocol field defaults its NZBs to the torrent
  protocol, which fails cleanly (not silently) when the qBittorrent client rejects a non-torrent
  URL, terminally parking the movie.
- SABnzbd's add succeeding only confirms the job was queued, not that the NZB URL was
  retrievable — a bad URL surfaces later as a failed history entry, handled by status polling, not
  by the add call.
- A completed SABnzbd job whose final storage path is momentarily empty is held safely rather than
  imported prematurely.
- Running SABnzbd with "Pause on Duplicates" changes the job's id when it materializes, so the
  originally recorded download id becomes permanently unfindable — a configuration requirement
  (disable duplicate-pause), not a code path, and it still fails safely via the existing bounded
  retry.
- Pre-upgrade movies with no recorded protocol default to the torrent client for backward
  compatibility.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST support SABnzbd as a Usenet download client running alongside the
  existing torrent client, both usable at once.
- **FR-002**: System MUST route each release to the download client matching its own protocol
  (torrent vs. Usenet) both when starting a download and when checking its status.
- **FR-003**: System MUST persist which protocol a given download used so that status checks
  always query the correct client, even without inspecting the raw download identifier.
- **FR-004**: System MUST select the best release using the same quality rules (resolution, size,
  blocklist) regardless of protocol — no built-in preference for torrent over Usenet or vice versa.
- **FR-005**: System MUST only consider releases whose protocol has a configured, available
  client — if only one protocol's client is configured, releases requiring the other protocol are
  excluded from selection.
- **FR-006**: System MUST treat a SABnzbd duplicate-add rejection as a failed add, flowing through
  the same bounded-retry failure handling as any other add failure.
- **FR-007**: System MUST detect a SABnzbd job as downloading, completed, or failed by checking
  both the active queue and the completed history, scoped explicitly to that job's identifier so
  pagination cannot hide it.
- **FR-008**: System MUST NOT advance a completed SABnzbd download to import until its final
  storage location is actually populated.
- **FR-009**: System MUST bound retries and terminally fail a download whose configured client can
  no longer be resolved (e.g., removed from configuration mid-download), rather than retrying
  indefinitely.
- **FR-010**: System MUST default any download whose protocol was never recorded (pre-existing
  data) to the torrent client.

### Key Entities

- **Release**: A candidate download found by searching indexers; carries which protocol (torrent
  or Usenet) it requires.
- **Download client**: A configured backend (qBittorrent or SABnzbd) capable of adding and
  reporting the status of a download for one protocol.
- **Movie**: Tracks, among its pipeline state, which client protocol its active or most recent
  download used.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: With both a torrent and a Usenet client configured, a movie whose best release is an
  NZB downloads and imports successfully end to end, exactly as a torrent-sourced movie does.
- **SC-002**: With only one protocol's client configured, no download is ever attempted against a
  release of the other, unconfigured protocol.
- **SC-003**: A duplicate or failed SABnzbd job never leaves a movie stuck retrying forever — it
  reaches a terminal failed state within the existing bounded-retry limit.
- **SC-004**: A completed SABnzbd download is never imported before its files are actually present
  in the reported storage location.

## Assumptions

- SABnzbd version is assumed to be ≥ 0.8.0, the version since which adding a download reliably
  returns a usable job identifier; no fallback for older versions is provided.
- The scorer remains protocol-blind by design in this feature; any future protocol-aware
  preference (e.g., preferring Usenet for size reasons) is explicitly out of scope here.
- SABnzbd's "Pause on Duplicates" setting is expected to be disabled by the operator; the system
  documents this as a setup requirement rather than working around it in code.
- SABnzbd is reached via its API key as a query parameter, with no stateful login/session flow
  required (unlike the torrent client).
