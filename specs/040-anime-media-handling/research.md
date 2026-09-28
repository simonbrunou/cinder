# Anime-Aware Media Handling Design

## Goal

Make Cinder handle anime releases substantially better than Sonarr without creating a third media
pipeline or sacrificing Jellyfin/Plex compatibility. Anime movies continue through the movie
pipeline, and episodic anime continues through the TV pipeline. An anime profile changes discovery,
release matching, numbering resolution, preferences, and special handling; it never becomes the
canonical media identity or a separate library layout.

The defining safety rule is bidirectional: Cinder must not stage, finalize, delete, or reinterpret a
downloaded anime file until every video is either uniquely mapped or explicitly ignored as an extra,
every mapped episode belongs to the grab's reserved target set, and every reserved target is mapped
exactly once. An ambiguity, unknown file, duplicate claim, missing target, or outside target is an
actionable mapping state, not a guess or a consumed retry.

## Deliberate limits

The first delivery does not add a separate anime discovery page, an anime-specific context, an
anime-only library root, a Jellyfin/Plex plugin, automatic franchise grouping, watch-state sync, or
automatic quality upgrades. AniDB and TheXEM are not mandatory first-release dependencies. Their
services remain candidate sources, and real corpus coverage determines whether either receives a
focused behaviour and integration.

The filesystem contract stays portable:

- movies keep the current movie layout;
- TV episodes use `Season NN/... - SxxEyy.ext`;
- mapped specials use `Season 00/... - S00Eyy.ext`.

Absolute, cour-local, scene, and provider numbering remain searchable and visible metadata. They do
not replace the on-disk coordinate.

## Identity model

`episodes.id` is the canonical episodic identity inside Cinder. `tmdb_episode_id`, AniDB IDs, TVDB
coordinates, scene numbers, absolute numbers, and episode-group entries are provider or release
coordinates attached to that identity. None is universally canonical.

The mapping is genuinely many-to-many. One release coordinate may represent several canonical
episodes, and several coordinates may identify the same canonical episode. Ordered membership is
required so a combined episode remains deterministic.

Mapping precedence is:

1. a manual local correction;
2. a curated provider mapping;
3. a provider-derived or inferred mapping.

When a higher-precedence coordinate resolves, lower tiers cannot introduce ambiguity. Provider
refreshes may replace only rows owned by that provider and namespace. They never overwrite or
delete manual mappings, manual classifications, profile choices, or snapshots attached to durable
work.

## Profile and recognition

Movies and series gain an operator-owned `media_profile` with values `:auto`, `:standard`, and `:anime`.
It defaults to `:auto` and is excluded from metadata and provider-refresh changesets. Explicit
`:standard` and `:anime` choices always win and survive refreshes.

`Auto` resolves to anime behavior only from a strong anime-provider identity. Weaker combinations,
such as Animation plus Japanese origin/language or the presence of an absolute episode group, may
show an explainable anime suggestion but do not silently change acquisition. Until an anime-specific
provider identity is available, these weaker signals require user confirmation. False negatives are
preferable to silently treating Western animation or Japanese live action as anime.

The profile is a handling policy, not ownership of the metadata. Title aliases and episode
coordinates remain attached to their movie, series, or episode even when the profile is Standard.
This lets a user turn Anime off without losing provider data.

The existing discovery pages remain unified. Provider search must find native, romaji, licensed,
and scene-title fixture queries before a title is added; after selection, Cinder fetches and stores
the full alias set. TMDB search is tried first. If it misses the required fixture aliases, A1 must
not begin until A0 has selected an anime title-search provider. The add/edit UI
shows the selected profile, the effective profile, and the evidence behind an anime suggestion.

## Persistent data

### Title aliases

A `title_aliases` table stores:

- nullable `movie_id` and `series_id` foreign keys;
- a database check requiring exactly one owner;
- original and normalized title;
- nullable country/language and a sourced alias kind;
- provider/source namespace;
- precedence: manual, curated provider, or inferred provider.

Providers that expose only an undifferentiated alternative title store kind `:alternative`.
`native`, `romaji`, `licensed`, and `scene` are assigned only when the source explicitly supplies
that meaning. Administrators can add and edit manual aliases from movie and series detail pages.

Separate partial unique indexes for movie-owned and series-owned rows prevent refreshes from
multiplying an identical provider alias despite the nullable foreign keys. Manual rows use the
highest precedence and cannot be removed by provider refresh.

### Episode coordinates

An `episode_coordinates` table stores a coordinate's `series_id`, source, scheme, required namespace,
and canonical text value. Sources without a distinct external namespace use their source name as the
namespace. The text value avoids SQLite nullable-composite uniqueness traps and can represent
`S02E04`, absolute `28`, a provider group coordinate, or a typed special code without adding one
nullable column per scheme.

Coordinates are unique on `(series_id, source, scheme, namespace, canonical_value)`. An
`episode_coordinate_memberships` join table connects coordinates to `episodes.id` and stores an
ordering position. Foreign keys enforce existence; unique indexes on `(coordinate_id, episode_id)`
and `(coordinate_id, position)` enforce deterministic ordered membership. Because an episode reaches
its series through Season, Catalog validates that coordinate and episode belong to the same series
inside the write transaction. The schema does not add a trigger or denormalized series field solely
for that immutable ownership check.

### Episode classification

Episode behavior uses a small classification: `:regular`, `:story_special`, `:recap`, or `:extra`.
The row also records the classification source and any raw provider label. OVA, OAD, ONA, NCOP,
NCED, trailer, and similar provider labels are retained, but they are not hard-coded as the storage
enum. ONA is not inherently a special.

Regular episodes follow the current monitor strategy. Story specials and recaps are individually
monitorable and default unmonitored. Credits, clean openings/endings, trailers, promos, and other
extras default unmonitored and are ignored during story-file completeness checks only when their
classification is unambiguous.

### Durable mapping state

The existing episode-to-intent and episode-to-grab relationships remain the reserved target set;
the new snapshot does not duplicate them.

`download_intents` store an immutable, versioned mapping snapshot containing the chosen release
coordinates and every coordinate membership relevant to the reserved episode IDs, together with the
ordered IDs and evidence used. This is recorded in the same reservation transaction as the target
episode IDs. When the remote download becomes a TV grab, the snapshot is copied to the grab. A
restart or metadata refresh between reservation and submission therefore cannot alter what the
download means or which downloaded-file coordinates are valid for the reserved target set.

Grabs add only the mapping-specific state needed by the existing derived lifecycle:

- `mapping_status`: `:resolved` or `:needs_mapping`, defaulting to `:resolved`;
- the immutable automatic mapping snapshot;
- automatic per-file decisions, bound to relative path, size, device/inode, and modification time,
  persisted before any file is staged;
- a persisted mapping issue containing relative paths, reasons, and candidate IDs;
- separate manual overrides that supersede, rather than mutate, the automatic snapshot.

This does not replace the current `content_path`-derived download lifecycle with a general status
machine. Downloaded-grab queries exclude `:needs_mapping`. Resolving the issue requeues the same
grab without changing its content path, deleting it, blocking the release, or incrementing download
or search attempts. Inventory identity is revalidated immediately before staging and after a
mapping resume; changed content invalidates the affected decisions and reruns the full preflight.
Cancellation remains an explicit user action.

Intent/grab episode links are authoritative ownership. Snapshot episode IDs are duplicated evidence,
not a second ownership model. Snapshot copy occurs inside the same Catalog transaction that creates
the grab and links its episodes, before the durable intent is removed.

## Metadata sources

The TMDB behaviour gains callbacks for alternative titles and TV episode groups. Its implementation
normalizes provider data; Catalog owns source-scoped persistence and refresh. Tests update the Mox
behaviour atomically with the concrete implementation.

TMDB is the first mapping source because Cinder already depends on it. A0 measures its discovery and
mapping coverage for absolute numbering, split cours, cross-season mappings, and specials before any
schema implementation. If TMDB cannot meet the must-support corpus, A0 selects an additional service
and that service receives its own focused behaviour under Catalog. AniDB, TVDB, and TheXEM never
masquerade behind `Cinder.Catalog.TMDB`, and no speculative generic provider interface is added before
a service is selected. Contexts never call a concrete provider directly.

## Pure resolver

One pure resolver receives parsed coordinates, title context, persisted coordinate memberships,
and optional grab overrides. It performs no Repo or network calls. It returns one of:

- `{:ok, ordered_episode_ids, evidence}`;
- `{:ambiguous, candidates, evidence}`;
- `{:ignore, :extra, evidence}` for one positively identified non-story file;
- `:unmatched`.

The per-file decision also records role `:story`, `:extra`, or `:unknown`. Only explicit provider
classification, a bounded typed filename marker covered by fixtures, or an administrator's
file-specific decision may produce `:extra`; `:unknown` and `:unmatched` block preflight. Episode
classification alone cannot prove that an arbitrary unmatched file is safe to ignore.

Acquisition and Library remain thin adapters because release-title coordinates and downloaded-file
coordinates differ, but both use the same precedence and identity rules. A manual correction is
grab-local by default and cannot affect future downloads. Promoting it to a durable per-series
coordinate mapping is a separate explicit administrator action. Later provider refreshes cannot
erase promoted local mappings or grab overrides.

## Search, parsing, and scoring

Anime search expands rather than replaces normal search. Cinder runs the supported combination of:

- provider-ID and standard season/episode queries;
- anime indexer categories;
- native, romaji, licensed, and scene-title aliases;
- absolute or mapped episode coordinates.

Results are deduplicated by protocol and download URL, with normalized title and size as a fallback.
Prowlarr normalization retains the category/indexer and publication metadata needed for anime
category selection and fallback delay.

The parser keeps standard `SxxEyy` output separate from anime coordinate candidates. Anime parsing
is enabled only with title/profile context; a generic bare number must not mistake a year,
resolution, CRC, version, or group tag for an episode. The fixture set covers prefix groups such as
`[SubsPlease]`, absolute singles and ranges, cross-season batches, `v2`, CRC suffixes, dual-audio
markers, subtitles, and typed specials.

The resolver converts release coordinates to stable episode IDs before selection. Anime set-cover
therefore operates on episode IDs and can select a batch spanning TMDB seasons or cours. The
standard TV path keeps its current behavior unless sharing a pure set-cover core makes the final
implementation smaller without changing results.

Hard constraints reject blocked releases and explicitly required languages. Coverage remains the
first selection key. When preferred groups are configured, a non-preferred release becomes eligible
at `published_at + fallback_delay`; before that instant Acquisition returns a distinct
`waiting_for_preferred_group` result. The poller continues normal searches but does not increment
search attempts or park episodes for intentional waiting. A fallback with missing or invalid
publication time remains manual-only instead of bypassing or waiting forever. Within the eligible
pool, explicit audio/subtitle requirements apply before the existing resolution/source/size ranking.
Soft audio, subtitle, and group preferences break ties without defeating a hard quality constraint.

The preference inputs are:

- trusted or blocked release groups;
- audio mode: original, dub, dual, or any;
- desired subtitle languages and embedded-subtitle preference;
- a fallback delay before accepting a non-preferred group.

Current per-title `preferred_language`, global subtitle languages, release blocklist, and
resolution/source settings remain the underlying controls. New persisted settings are limited to
the missing concepts: audio mode, group preferences, per-title subtitle-language override,
embedded-subtitle preference, and fallback delay. `:dub` and `:dual` audio modes require a concrete
target in the existing `preferred_language` field; `:dual` means original audio plus that target.
Global defaults are overridable per title; an Anime profile never overwrites an explicit
preference. With no preferred groups, the fallback delay has no effect.

Anime movies use the alias, query, parser, group/audio/subtitle scoring, and post-download stream
verification subset. They never enter episode numbering or special handling and otherwise retain
the current movie pipeline.

Release-name traits are advisory. Before staging either a movie or TV file, MediaInfo verifies hard
audio requirements and any subtitle requirement explicitly marked embedded. A verified policy
mismatch is not a mapping or filesystem failure: Cinder stages nothing, blocks that exact release
through the existing scoped release blocklist, releases its targets for acquisition without attempt
increments, and removes the rejected remote content through durable cleanup. Subtitle languages that
are not required embedded continue through the existing post-import subtitle fallback.

## Download and import flow

1. The poller derives wanted stable episode IDs.
2. Acquisition runs additive queries, parses results, resolves coordinates, and scores episode-ID
   coverage.
3. Reservation atomically writes the durable intent, target episode IDs, release data, and mapping
   snapshot before any external download-client call.
4. Remote submission reconciles the durable intent exactly as today. Grab creation copies the
   snapshot.
5. When the client reports completion, Library inventories every video before staging any file and
   captures each file's relative path, size, device/inode, and modification time.
6. Each file receives a role and resolves against the immutable grab snapshot plus grab-local manual
   overrides. Automatic decisions and their file identities are persisted before staging. Only a
   positively identified extra may be ignored.
7. Preflight succeeds only when every video is resolved or explicitly ignored, each resolved file
   maps to one or more ordered IDs, no ID is outside the authoritative reserved target set, no target
   is claimed by conflicting files, and the union of mapped IDs equals the reserved set. Any other
   result enters `:needs_mapping` before an ImportStage row or filesystem write exists.
8. Library revalidates inventory identity, stages the complete import set, commits episode paths
   through the existing guarded transaction, scans the media server, and removes the remote download
   through durable cleanup. Same-season IDs retain the existing multi-episode filename. A source
   spanning canonical seasons produces one destination per season group, hardlinking or using the
   existing copy fallback for each canonical season-local `SxxEyy` path; rollback covers every
   destination.
9. A mapping problem preserves the grab, content, candidates, and counters and publishes an
   actionable UI event.
10. An administrator corrects the grab-local assignment and reruns the same full preflight. Changing
    the reserved target set is one Catalog transaction: every added episode must belong to the same
    series, be missing, and not be reserved elsewhere; adding an unmonitored episode requires an
    explicit opt-in that also monitors it. Removed targets return to wanted without attempt bumps.
    The transaction updates authoritative episode links and records the override before resolving the
    grab.

Mapping ambiguity never calls the current terminal `park_grab` path. Filesystem errors remain
ordinary import failures with the current bounded retry behavior; provider and search failures use
the existing bounded backoff. Distinguishing these failures prevents a metadata problem from
consuming a transport or filesystem retry budget.

## User experience

Movie and series pages expose Profile with Auto/Standard/Anime and explain Auto suggestions.
Administrators control the stored profile, manual aliases, and mapping corrections. A requester may
propose Anime on a request, but manual approval requires the administrator to confirm the effective
profile before acquisition. An administrator's own request applies their explicit profile choice.
When the household enables the existing `auto_approve_all` trust policy, a requester's explicit
Anime proposal is accepted; without a proposal, weak Auto evidence remains Standard until an
administrator changes it. Anime series show the media-server coordinate plus sourced alternatives,
for example
`S02E01 · Absolute 25 · Part 2 #1`. Cour labels appear only when supplied by a provider or a user;
Cinder never derives them mechanically.

Activity and series detail views show `Needs mapping` with the release, downloaded files, candidate
episodes, provenance, and actions to resolve or cancel. Correction operates on the existing
download; it never asks the user to grab the release again. Mapping provenance and coverage remain
visible so users can distinguish provider data from a local correction.

No dedicated anime landing page ships initially. A filter or seasonal discovery page is justified
only by real navigation demand; it does not improve matching correctness.

## Testing

The primary evidence is a sanitized release-name and mapping corpus drawn from the user's real
indexers. It includes:

- ordinary one-cour anime and anime movies;
- long-running absolute numbering above 99 and 999;
- split cours and absolute numbering across TMDB season boundaries;
- cross-season and multi-episode batches;
- native, romaji, licensed, and scene title aliases;
- prefix release groups, `v2`, CRCs, dual audio, dubs, embedded ASS subtitles, and sidecars;
- OVA/OAD/ONA provider labels, recaps, episode zero, NCOP/NCED, trailers, and extras;
- one coordinate to several episodes and several coordinates to one episode;
- provider renumbering while an intent or grab is active.

Focused tests prove:

- database checks reject aliases with zero or two owners;
- coordinate/membership uniqueness, transactional same-series validation, mapping precedence, and
  ordered many-to-many resolution;
- refresh replaces only provider-owned rows and preserves manual/profile/classification choices;
- profile suggestion false-positive/negative cases, requester proposals, manual approval, and
  auto-approval behavior, including movies;
- additive Prowlarr searches, deduplication, parser context, and episode-ID set cover;
- preferred-group waiting uses `published_at + fallback_delay` without incrementing search attempts;
- an intent snapshot survives restart and provider refresh before grab creation;
- snapshot copy and authoritative episode linking are atomic with grab creation;
- a grab snapshot survives episode renumbering;
- exact reserved-set coverage rejects missing, outside, duplicate, unknown, ambiguous, and partially
  matched files before staging;
- positive extra evidence is ignorable while an unmatched extra-looking file remains blocking;
- a file changed between preflight and resume invalidates its stored decision;
- a cross-season combined file creates canonical destinations in each affected season;
- a hard MediaInfo policy mismatch blocks only that release, performs no staging, and requeues
  targets without mapping/filesystem retry increments;
- a manual correction resumes the same grab and imports to canonical `SxxEyy`/`S00Eyy` paths;
- grab-local correction does not change later grabs unless explicitly promoted;
- cancellation from `Needs mapping` is explicit and safe;
- standard movie and TV behavior remains unchanged.

The corpus is versioned with expected discovery results, effective profiles, parsed coordinates,
resolved episode IDs, selection verdicts, and import outcomes. Every designated must-support fixture
must pass, and automatic wrong imports must remain zero. Unsupported fixtures are listed explicitly
and must stop safely in search or `Needs mapping`; they never count as a correct automatic result.

Every implementation milestone ends with the repository `mix test` alias and `graphify update .`.
Live validation uses the configured indexer, download client, and Jellyfin/Plex instance. Cinder does
not claim excellent anime support until live single, range, batch, special, cross-season, and
dual-audio paths pass against the expected outputs.

## Delivery milestones

### A0 — Corpus and provider contracts

Create the versioned, sanitized fixture corpus and probe TMDB discovery/alternative titles/episode
groups plus Prowlarr query and normalized-result fields. Record expected profiles, coordinates, and
provider coverage before schema implementation. If TMDB misses must-support discovery or mapping
fixtures, select and design one additional focused provider behaviour now, before A1.

Done when all must-support fixtures have expected outputs, automatic provider mappings contain zero
known incorrect assignments, Prowlarr's required category/index/publication fields are verified, and
the provider decision and unsupported safe-stop fixtures are documented.

### A1 — Identity foundation

Land profiles, request/approval profile proposals, manual/title-provider aliases, coordinates,
classifications, selected provider callbacks, source-scoped refresh, constraints, and the pure
resolver. Do not change download acquisition yet.

Done when discovery aliases, many-to-many mapping, same-series validation, precedence, profile
preservation, request approval, and refresh behavior pass the A0 corpus plus focused tests and
`mix test` is green.

### A2 — Anime acquisition

Land additive searches, retained Prowlarr metadata, context-aware parsing, stable-ID set cover, the
anime movie subset, preferred-group waiting, and durable intent snapshots. Keep detailed preference
UX and post-download hard-policy enforcement for A4.

Done when the corpus selects the expected release and stable episode set without changing standard
movie/TV selection, intentional waiting never bumps attempts, restart loses no reservation meaning,
and `mix test` is green.

### A3 — Safe import and mapping recovery

Land atomic intent-to-grab snapshot copy, inventory-bound decisions, exact reserved-set preflight,
file roles, `Needs mapping`, grab-local correction/promotion, resume/cancel UI, MediaInfo integration
points, and same-/cross-season canonical import naming. Do not enable specials acquisition yet.

Done when single, range, batch, many-to-many, changed-inventory, and cross-season fixtures import or
stop exactly as expected; ambiguity preserves content and counters until corrected; standard imports
stay green; and `mix test` passes.

### A4 — Specials and release preferences

Land sourced special classification and monitoring, Season 00 acquisition/import, global and
per-title audio/subtitle/group preferences, trusted-group fallback UX, and post-download MediaInfo
hard-policy enforcement for movies and TV.

Done when story specials are individually controllable, extras never bypass the exact preflight,
hard mismatches block/requeue only the exact release without retry corruption, preference fixtures
select the expected release, and `mix test` is green.

### A5 — Live dogfood and provider sign-off

Run the versioned corpus and live Jellyfin/Plex paths against the household's real indexers and
download clients. Add another service-specific mapping provider only if new must-support failures
cannot stop safely or be corrected locally. Finish operator documentation for profiles, preferences,
provider limits, and mapping recovery.

Done when every designated fixture passes, automatic wrong imports remain zero, unsupported cases
are recorded and stop safely, live single/range/batch/special/cross-season/dual-audio paths match
expected library output, the provider decision is recorded with evidence, and the standard suite is
green.

Each milestone is one bounded phase with its own design/plan and commit boundary. Later milestones
do not start until the previous milestone's Done-when block is green.
