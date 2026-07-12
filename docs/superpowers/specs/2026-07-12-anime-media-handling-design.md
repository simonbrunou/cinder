# Anime-Aware Media Handling Design

## Goal

Make Cinder handle anime releases substantially better than Sonarr without creating a third media
pipeline or sacrificing Jellyfin/Plex compatibility. Anime movies continue through the movie
pipeline, and episodic anime continues through the TV pipeline. An anime profile changes discovery,
release matching, numbering resolution, preferences, and special handling; it never becomes the
canonical media identity or a separate library layout.

The defining safety rule is: Cinder must not stage, finalize, delete, or reinterpret a downloaded
anime file until every story-bearing file in that grab maps uniquely to stable Cinder episode IDs.
An ambiguous mapping is an actionable state, not a guess or a consumed retry.

## Deliberate limits

The first delivery does not add a separate anime discovery page, an anime-specific context, an
anime-only library root, a Jellyfin/Plex plugin, automatic franchise grouping, watch-state sync, or
automatic quality upgrades. AniDB and TheXEM are not mandatory first-release dependencies. Their
provider seams remain available, and real corpus coverage determines whether they are required.

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
add an anime title-search provider rather than deferring discovery correctness. The add/edit UI
shows the selected profile, the effective profile, and the evidence behind an anime suggestion.

## Persistent data

### Title aliases

A `title_aliases` table stores:

- nullable `movie_id` and `series_id` foreign keys;
- a database check requiring exactly one owner;
- original and normalized title;
- language and alias kind, such as native, romaji, licensed, or scene;
- provider/source namespace;
- precedence: manual, curated provider, or inferred provider.

Separate partial unique indexes for movie-owned and series-owned rows prevent refreshes from
multiplying an identical provider alias despite the nullable foreign keys. Manual rows use the
highest precedence and cannot be removed by provider refresh.

### Episode coordinates

An `episode_coordinates` table stores a coordinate's `series_id`, source, scheme, required namespace,
and canonical text value. Sources without a distinct external namespace use their source name as the
namespace. The text value avoids SQLite nullable-composite uniqueness traps and can represent
`S02E04`, absolute `28`, a provider group coordinate, or a typed special code without adding one
nullable column per scheme.

An `episode_coordinate_memberships` join table connects coordinates to `episodes.id` and stores an
ordering position. Foreign keys and unique constraints enforce ownership and deterministic ordered
many-to-many results.

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
- automatic per-relative-file decisions, persisted before any file is staged;
- a persisted mapping issue containing relative paths, reasons, and candidate IDs;
- separate manual overrides that supersede, rather than mutate, the automatic snapshot.

This does not replace the current `content_path`-derived download lifecycle with a general status
machine. Downloaded-grab queries exclude `:needs_mapping`. Resolving the issue requeues the same
grab without changing its content path, deleting it, blocking the release, or incrementing download
or search attempts. Cancellation remains an explicit user action.

## Metadata sources

The TMDB behaviour gains callbacks for alternative titles and TV episode groups. Its implementation
normalizes provider data; Catalog owns source-scoped persistence and refresh. Tests update the Mox
behaviour atomically with the concrete implementation.

TMDB is the first mapping source because Cinder already depends on it. A representative fixture
corpus measures its coverage for absolute numbering, split cours, cross-season mappings, and
specials. If it cannot meet that corpus, the same behaviour boundary gains a cached mapping provider
for AniDB, TVDB, or TheXEM. No context calls those services directly.

## Pure resolver

One pure resolver receives parsed coordinates, title context, persisted coordinate memberships,
and optional grab overrides. It performs no Repo or network calls. It returns one of:

- `{:ok, ordered_episode_ids, evidence}`;
- `{:ambiguous, candidates, evidence}`;
- `:unmatched`.

Acquisition and Library remain thin adapters because release-title coordinates and downloaded-file
coordinates differ, but both use the same precedence and identity rules. A manual correction is a
durable, narrowly scoped coordinate mapping and a grab override. Later provider refreshes cannot
erase it.

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
first selection key. When preferred groups are configured, Cinder waits the configured fallback
delay for those groups; after the delay, non-blocked groups become eligible. Within the eligible
pool, explicit audio/subtitle requirements apply before the existing resolution/source/size
ranking. Soft audio, subtitle, and group preferences break ties without defeating a hard quality
constraint.

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

## Download and import flow

1. The poller derives wanted stable episode IDs.
2. Acquisition runs additive queries, parses results, resolves coordinates, and scores episode-ID
   coverage.
3. Reservation atomically writes the durable intent, target episode IDs, release data, and mapping
   snapshot before any external download-client call.
4. Remote submission reconciles the durable intent exactly as today. Grab creation copies the
   snapshot.
5. When the client reports completion, Library inventories every video before staging any file.
6. Each file resolves against the grab snapshot and manual overrides. Automatic relative-file
   decisions are persisted before staging. Only positively classified extras may be ignored; an
   uncertain file participates in the story-file completeness gate.
7. If every story-bearing file maps uniquely, Library stages the complete import set, commits the
   episode paths through the existing guarded transaction, scans the media server, and removes the
   remote download through the current durable cleanup flow.
8. If any story-bearing file is ambiguous or unmatched, no file is staged. The grab becomes
   `:needs_mapping`, retains its content and counters, and publishes an actionable UI event.
9. An administrator selects one or more candidate episodes. Catalog atomically records the manual
   correction and override, marks the grab resolved, and re-runs the same complete preflight.

Mapping ambiguity never calls the current terminal `park_grab` path. Filesystem errors remain
ordinary import failures with the current bounded retry behavior; provider and search failures use
the existing bounded backoff. Distinguishing these failures prevents a metadata problem from
consuming a transport or filesystem retry budget.

## User experience

Movie and series pages expose Profile with Auto/Standard/Anime and explain Auto suggestions.
Administrators control the stored profile and mapping corrections; requesters may see the suggestion
but cannot change household acquisition policy. Anime series show the media-server coordinate plus
sourced alternatives, for example
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
- mapping precedence and ordered many-to-many resolution;
- refresh replaces only provider-owned rows and preserves manual/profile/classification choices;
- profile suggestion false-positive and false-negative cases, including movies;
- additive Prowlarr searches, deduplication, parser context, and episode-ID set cover;
- an intent snapshot survives restart and provider refresh before grab creation;
- a grab snapshot survives episode renumbering;
- an ambiguous or partially matched pack performs no staging, finalization, remote removal, or
  retry increment;
- a manual correction resumes the same grab and imports to canonical `SxxEyy`/`S00Eyy` paths;
- cancellation from `Needs mapping` is explicit and safe;
- standard movie and TV behavior remains unchanged.

Every milestone ends with the repository `mix test` alias and `graphify update .`. Live validation
uses the configured indexer, download client, and Jellyfin/Plex instance. Cinder does not claim
excellent anime support until the real corpus searches, downloads, maps, and imports correctly.

## Delivery milestones

### A1 — Identity foundation

Land profiles, aliases, coordinates, classifications, TMDB alternate-title/episode-group support,
source-scoped refresh, and the pure resolver. Do not change acquisition behavior yet.

Done when many-to-many mapping, precedence, profile preservation, and refresh behavior pass focused
tests and `mix test` is green.

### A2 — Anime acquisition

Land additive searches, retained Prowlarr metadata, context-aware parsing, stable-ID set cover,
anime preferences, and durable intent snapshots. Include the anime movie subset.

Done when the fixture corpus selects the expected release and stable episode set without changing
standard movie/TV selection, restart loses no reservation meaning, and `mix test` is green.

### A3 — Safe import and specials

Land grab snapshots, all-files preflight, `Needs mapping`, correction/resume/cancel UI, sourced
special classification, Season 00 monitoring, and canonical import naming.

Done when single episodes, batches, one-to-many files, and story specials import correctly; an
ambiguous or partial pack preserves all content and counters until corrected; standard imports stay
green; and `mix test` passes.

### A4 — Preferences and dogfood

Calibrate global/per-title defaults and trusted-group fallback delay against the real indexer corpus,
finish the preference and mapping-recovery UX, and run live Jellyfin/Plex validation. Measure
missing/incorrect mappings and add a cached AniDB, TVDB, or TheXEM source only when the corpus
demonstrates the need.

Done when the corpus and live smoke paths pass, the provider decision is recorded with evidence,
the standard regression suite is green, and the documentation explains profiles, preferences,
mapping recovery, and known provider limits.

Each milestone is one bounded implementation phase with its own plan and commit boundary. Later
milestones do not start until the previous milestone's Done-when block is green.
