# A3 Safe Import and Mapping Recovery Design

**Status:** Design sections approved by the user and spec self-reviewed on 2026-07-13. No council
review has run for A3.

## Objective

Activate the A2 episodic anime selector and import its downloads without guessing. A grab may enter
Library only after every downloaded video is mapped exactly to its authoritative stable Cinder
episode targets or explicitly ignored as an extra. Ambiguous content stops in an actionable
`Needs mapping` state with the download, evidence, ownership, and retry budgets intact.

A3 adds the smallest recovery path that satisfies the Part III safety invariant:

- atomically copy the immutable intent snapshot to the grab;
- inventory and resolve every video before creating an `ImportStage` or writing a library file;
- require exact coverage of the grab's authoritative episode links;
- preserve mapping problems for correction without consuming search, download, or import attempts;
- resume or cancel the same grab through one admin recovery page; and
- reuse the existing staged import journal for same- and cross-season canonical destinations.

Anime remains a profile on the existing TV pipeline. Standard movie and TV acquisition/import keep
their current behavior.

## Current A2 handoff

A2 already provides:

- additive provider-ID, alias, and category `5070` searches;
- context-aware `Cinder.Acquisition.AnimeParser` output;
- `Cinder.Catalog.AnimeResolver` stable-ID resolution;
- stable-ID set cover and immutable version-1 mapping snapshots;
- durable `download_intents` plus authoritative `download_intent_episodes`; and
- explicit guards preventing a snapshot-bearing episodic intent from reaching a downloader or grab.

The current `TvPoller` still groups and searches Standard TV by season, `Catalog.create_grab/5`
creates a grab separately from intent deletion, and `Library.stage_episodes/2` maps only standard
`SxxEyy` filenames. A3 removes the deliberate A2 hold only after the post-grab guarantees below
exist.

## Chosen approach

Use the existing grab row as the durable recovery owner and add one shared LiveView route for
correction. Do not introduce a second workflow table or a general grab status machine.

Alternatives rejected:

- Duplicating inline mapping editors in Activity and series detail creates two stateful recovery
  implementations.
- An Activity-only modal hides the series tree and makes cross-season correction harder to verify.
- A normalized file-decision schema adds joins and lifecycle code for data that is private to one
  transient grab and always read as one versioned document.

## Safety invariants

For a snapshot-bearing episodic grab:

1. The grab's episode associations are the authoritative current target set.
2. The copied acquisition snapshot is immutable evidence of the original reservation. Manual target
   changes are recorded as overrides; they never rewrite the snapshot.
3. Every downloaded video has a durable inventory identity before any staging begins.
4. Every video is either mapped to one or more ordered target IDs or explicitly ignored with
   positive extra evidence.
5. No mapped ID falls outside the authoritative target set.
6. No target ID is claimed by two different videos.
7. The union of mapped IDs equals the authoritative target set exactly.
8. Any failed invariant produces `Needs mapping` before an `ImportStage` row or filesystem write.
9. Inventory identity is revalidated immediately before staging and after every recovery resume.
10. Mapping failure never blocks the release, deletes remote content, or increments a retry counter.

One source may cover multiple episode IDs. A source spanning canonical seasons produces one
destination per season group. The same source may therefore back multiple hardlinks or bounded copy
fallbacks while each stable episode ID is still finalized exactly once.

## Durable grab state

Add five fields to `grabs`:

- `mapping_snapshot :map` — immutable snapshot copied from the intent;
- `mapping_status` — `:resolved | :needs_mapping`, default `:resolved`;
- `automatic_mapping_decisions :map` — versioned inventory and automatic outcomes;
- `manual_mapping_overrides :map` — versioned, admin-owned file decisions; and
- `mapping_issue :map` — versioned blocking reasons and candidate IDs.

Standard grabs retain `mapping_status: :resolved` and nil mapping documents, so their existing
import path does not branch through anime preflight.

Each automatic file decision stores only safe relative display paths and normalized values:

```elixir
%{
  "version" => 1,
  "files" => [
    %{
      "relative_path" => "Show - 25.mkv",
      "size" => 1_234,
      "major_device" => 1,
      "inode" => 99,
      "mtime" => 1_783_900_800,
      "role" => "story",
      "verdict" => "mapped",
      "episode_ids" => [25],
      "evidence" => %{}
    }
  ]
}
```

Manual overrides use the same file identity, not a pathname alone. An override action is either
`assign` with a non-empty ordered episode-ID list or `ignore` with administrator evidence. Mapping
issues contain stable reason codes, affected relative paths, and candidate IDs; they never persist
absolute download paths or decrypted URLs.

General grab changesets do not cast the mapping documents. Focused trusted Catalog changesets own
snapshot copy, preflight results, override save/resume, and the `Needs mapping` transition.

## Frozen parser context

Downloaded absolute-number filenames need the same title guard used during acquisition. Consulting
mutable provider aliases after reservation would allow a metadata refresh to change the meaning of
an already-selected download.

New A3 version-2 snapshots therefore add a bounded frozen parser context containing the canonical
title, aliases used by the anime parser, and year. The intent validator accepts versions 1 and 2 so
existing durable evidence is readable, but automatic import requires the version-2 frozen context.
A version-1 intent/grab stops safely in `Needs mapping`; it may be resolved through manual file
assignments. It never falls back to mutable provider metadata for an automatic decision.

## Atomic intent-to-grab ownership

Snapshot-bearing reconciliation uses one Catalog transaction that:

1. re-reads the submitted intent;
2. inserts the grab with remote ID, protocol, release title, snapshot, and resolved mapping status;
3. links every intended episode only when it is monitored, missing, and not owned elsewhere;
4. requires the linked row count to equal the complete intent episode set; and
5. deletes the intent, cascading its intent-episode reservations.

Any mismatch rolls back the grab, links, and intent deletion together. The still-present intent can
then enter the existing durable remote-cleanup path. Broadcasting happens only after the transaction
commits.

The existing standard `Catalog.create_grab/5` behavior remains compatible. The exact snapshot path
must not silently keep a partial episode set. A crash after the transaction commits leaves a complete
grab and no intent; a crash before commit leaves the complete intent and no grab.

## Activating episodic anime acquisition

`TvPoller` keeps the current season-grouped Standard branch. For a series whose effective profile is
Anime, it groups wanted stable IDs by series and calls the A2 anime selector so one selected release
may span canonical seasons. A2's existing query and range bounds remain the limits; A3 adds no wider
search fan-out.

Each selected assignment passes its release, exact episode IDs, and matching snapshot through the
existing durable reservation path. The A2 side-effect guards are removed only at the shared episodic
submission/reconciliation choke-points after atomic grab ownership is available. Nil-snapshot
standard releases still use the same public API and result shapes.

Preferred-group waiting remains options-only. A3 supplies no new setting or UI; A4 owns preference
persistence and fallback-delay UX. Any intentional waiting result consumes no search attempt.

## Inventory and pure preflight

Add one focused pure component, `Cinder.Library.AnimePreflight`. It receives plain data:

- the immutable grab snapshot;
- the complete video inventory;
- manual overrides;
- the authoritative grab episode IDs; and
- stable episode metadata needed for canonical output.

It performs no Repo, filesystem, network, or media-server calls. It adapts snapshot mappings to the
existing `AnimeResolver` shape and reuses `AnimeParser`; it does not create another resolver.

Library inventories all videos through the existing bounded, symlink-safe `PathPolicy` walk. A
single-file download is represented identically to a file inside a directory. Each inventory entry
contains relative path, size, major device, inode, and normalized modification time. Absolute paths
remain inside the Library adapter and are never accepted from the browser.

For each file, preflight applies a matching manual override first. Otherwise it parses the basename
with the frozen context and resolves its coordinates only against the immutable snapshot mappings.
It returns one of:

```elixir
{:ok, %{decisions: decisions, assignments: assignments}}
{:needs_mapping, %{decisions: decisions, issue: issue}}
```

Automatic `ignore` is allowed only when the parser identifies role `extra` with explicit evidence.
Typed specials remain unknown in A3 unless an existing snapshot mapping resolves them; specials
acquisition and monitoring remain A4. An administrator's explicit file-specific ignore is positive
manual evidence.

Preflight rejects rather than truncates a mapping whose full membership includes an ID outside the
current grab targets. Ambiguous, unmatched, unknown-role, missing-target, outside-target, and
duplicate-target outcomes all stop safely.

## Persist-before-stage flow

For a downloaded snapshot-bearing grab, the poller follows this order:

1. Inventory every video.
2. Run pure preflight.
3. Persist the complete automatic decisions.
4. On failure, persist the issue and set `mapping_status: :needs_mapping`; stop.
5. On success, re-inventory and compare every identity before creating a stage.
6. If identity changed, discard the stale outcome and restart full preflight without staging.
7. Stage every canonical destination through the existing `ImportStage` journal.
8. Finalize episode paths and delete the grab through the existing guarded Catalog transaction.
9. Commit stages, scan, fetch subtitles, and perform configured source cleanup as today.

`Catalog.list_grabs_downloaded/0` (or a narrowly renamed sibling) excludes
`:needs_mapping`, so the poller does not repeatedly revisit a blocked grab. Activity still lists it.
Restart behavior remains DB-derived: persisted resolved decisions are always identity-checked before
use, and persisted issues remain idle until an administrator resumes or cancels them.

Filesystem inventory failures remain transient poller failures. Mapping failures are not filesystem
failures and never call the current terminal `park/2` path.

## Canonical import and cross-season files

Standard grabs continue calling `Library.stage_episodes/2`. Anime grabs supply preflight assignments
to a narrow staged-import entry point rather than reparsing filenames inside the standard mapper.

Assignments are grouped first by source and then by canonical season. Same-season IDs retain the
existing portable multi-episode filename. A source spanning seasons creates one destination in each
affected `Season NN` directory, using only the IDs belonging to that season in its filename. Example:

```text
Show (Year) {tmdb-id}/Season 01/Show (Year) {tmdb-id} - S01E12.ext
Show (Year) {tmdb-id}/Season 02/Show (Year) {tmdb-id} - S02E01.ext
```

Every destination uses the current hardlink-first, cross-filesystem exclusive-copy fallback and
path containment checks. The existing stage journal owns rollback material for every destination.
If any destination fails to stage or Catalog finalization fails, all destinations from that attempt
roll back; no episode path commits partially.

MediaInfo capture may populate the existing imported media fields during staging. A3 adds no new
audio/subtitle/group policy decisions. A4 owns hard preference enforcement and exact-release
requeue behavior.

## Recovery transaction

The recovery page saves grab-local overrides through one Catalog transaction. It may also change the
grab's authoritative episode links, but only under these rules:

- every target belongs to the same series;
- every added episode is missing and not owned by another grab or intent;
- an unmonitored addition requires an explicit form opt-in that also monitors it;
- removed episodes are unlinked and return to wanted without attempt increments; and
- the override and complete target-link change commit together.

The immutable snapshot remains the original reservation evidence. Manual overrides explain every
post-reservation target change.

`Save and retry` stores the overrides and target changes, clears the blocking issue, sets the grab
back to `:resolved`, and lets the poller rerun inventory and full preflight. It does not perform
filesystem writes in the web request. A concurrent import, cancel, or stale page submission fails
the guarded transaction and reloads current state.

`Cancel download` delegates to the existing `Catalog.cancel_grab/1` cleanup fence. It deletes the
grab, unlinks targets, and removes remote content through the existing retryable cleanup behavior.

## Promotion

Corrections are grab-local by default. `Promote to series` is a separate explicit admin action and
is available only when the file decision contains a reusable parsed coordinate. It writes a manual
coordinate through the existing Catalog identity API after validating same-series episode IDs.

Promotion never mutates the grab snapshot or its local override. A later provider refresh preserves
the manual coordinate under the A1 ownership rules. A filename with no reusable coordinate can be
assigned locally but cannot be promoted.

## Recovery UI

Add one admin-only LiveView route:

```text
/activity/grabs/:id/mapping
```

The page re-reads the grab and shows:

- series and release title;
- original snapshot targets and current authoritative targets;
- downloaded relative paths and inventory identities;
- automatic verdicts, candidate episode IDs, and provenance;
- per-file assign/ignore controls;
- the target-set additions/removals implied by the form; and
- `Save and retry`, `Promote to series`, and confirmed `Cancel download` actions.

Episode choices come from a server-side same-series tree. Client-submitted grab, file, and episode
IDs are all revalidated; the form cannot submit absolute paths or arbitrary mapping evidence.

Activity and series detail only display `Needs mapping` plus a link to the shared route. They do not
duplicate correction forms. Mapping changes broadcast the existing series update so open pages
refresh. If the grab was already finalized or cancelled, the recovery page navigates back with a
stale-state message and performs no cleanup against the old rendered struct.

## Error and retry semantics

| Condition | Result |
| --- | --- |
| Missing library/download-root configuration | Hold as today; no bump |
| Inventory or stat I/O failure | Existing bounded import retry |
| Ambiguous/unmatched/unknown/outside/duplicate/missing coverage | `Needs mapping`; no bump |
| Inventory changed before staging | Rerun full preflight; no stage |
| Stage or Catalog finalization failure | Existing rollback and bounded import retry |
| Admin resume with unresolved coverage | Return to `Needs mapping`; no bump |
| Admin cancel | Existing durable remote cleanup; targets return to wanted |
| Hard media preference mismatch | Out of scope until A4 |

Mapping issues never blocklist the release: the release may be valid while its provider mapping is
incomplete. While a grab remains in `Needs mapping`, only an explicit cancel removes its preserved
download. After successful recovery and import, the normal configured source cleanup applies.

## Test evidence

Add `test/support/fixtures/anime/import-v1.json` with expected inventory, decisions, assignments,
destinations, and safe-stop reasons for:

- standard single and multi-episode files under an Anime profile;
- absolute single and range releases;
- multi-file batches;
- many-to-many coordinate membership;
- one source spanning canonical seasons;
- positively identified and manually ignored extras;
- ambiguous, unmatched, unknown-role, missing-target, outside-target, and duplicate-target cases;
- inventory mutation between decision and staging; and
- version-1 snapshot evidence without frozen parser context.

Required tests:

1. Pure corpus tests prove every exact preflight result without Repo or filesystem access.
2. Transaction tests prove snapshot copy, complete linking, and intent deletion are atomic; partial
   ownership rolls back and leaves cleanup evidence.
3. Restart tests prove provider refresh and process restart cannot change snapshot meaning.
4. Library tests prove no `ImportStage` or filesystem write exists before successful preflight.
5. Cross-season tests prove every canonical destination commits or all roll back.
6. Recovery tests prove local assignment, explicit ignore, target-set edits, monitor opt-in, resume,
   promotion, stale-grab handling, and cancel semantics.
7. LiveView tests use stable element IDs for the shared recovery route and both linking views.
8. Existing standard movie/TV acquisition, import, retry, cleanup, and LiveView tests remain green.

Implementation follows red-green-refactor for every behavior slice. The phase gate is the repository
`mix test` alias followed by `graphify update .` and a clean diff review.

## Out of scope

A3 does not add:

- specials acquisition or new Season 00 monitor behavior;
- persisted audio, subtitle, or preferred-group settings;
- fallback-delay UX or post-download hard preference rejection;
- a new metadata provider;
- a dedicated anime landing page;
- a general workflow/event-sourcing framework;
- a new dependency; or
- automatic promotion of local corrections.

Those remain A4/A5 work or require evidence beyond the current roadmap.

## Done when

A3 is complete only when single, range, batch, many-to-many, mutated-inventory, and cross-season
fixtures import or stop exactly as specified; ambiguity preserves content and counters until
corrected; the same grab resumes or cancels safely; snapshot ownership survives restart; standard
movie/TV behavior is unchanged; `mix test` is green; and the knowledge graph is updated.
