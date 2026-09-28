# A4 Anime Specials and Release Preferences Design

**Status:** Design sections approved by the user and spec self-reviewed on 2026-07-13. No council
review has run for A4.

## Objective

Finish the buildable anime behavior before live dogfood: make sourced story specials individually
acquirable, persist Anime-only release preferences globally and per title, wait safely for preferred
groups, and reject downloaded releases that provably violate a hard audio or embedded-subtitle
policy before any library staging.

A4 extends the existing movie and TV pipelines. It does not create an anime pipeline, a general
policy framework, or another cleanup lifecycle. Standard-profile behavior remains unchanged.

## Current A3 handoff

A3 already provides:

- effective Standard/Anime profiles for movies and series;
- sourced episode classifications (`regular`, `story_special`, `recap`, `extra`);
- alias/category searches, context-aware parsing, stable-ID set cover, and preferred-group waiting
  as options-level acquisition behavior;
- immutable anime mapping snapshots and authoritative intent/grab episode ownership;
- exact inventory-bound preflight with positive-extra evidence;
- durable `Needs mapping` recovery and cancellation; and
- same- and cross-season staged import, including canonical Season 00 destinations.

The remaining gaps are behavioral and persisted-policy gaps. `Catalog.wanted_episodes/0` still
excludes Season 00, no preference settings feed the A2 selection options, and the existing
MediaInfo language guard either parks or skips a file rather than performing exact-release
rejection and target requeue.

## Chosen approach

Extend the seams already present:

1. Store typed Anime defaults through `Cinder.Settings` and typed nullable overrides on `Movie` and
   `Series`.
2. Resolve those values in one small pure `Cinder.Acquisition.AnimePreferences` module.
3. Pass the resolved policy to the existing anime search/selection functions.
4. Freeze the hard portion of the policy when the release is reserved.
5. Verify that frozen policy through the existing MediaInfo behavior before staging.
6. Reuse the existing blocked-release and durable cleanup fences for confirmed rejection.

Alternatives rejected:

- A JSON preference blob saves migration columns but loses Ecto enum/list validation and makes
  inheritance ambiguous.
- A normalized preferences table adds joins and lifecycle code for one global-default plus
  per-title-override model.
- A new download-policy state machine duplicates the existing intent cleanup fence and grab/movie
  ownership transitions.

## Compatibility boundary

The new defaults and overrides are active only when `Catalog.media_profile_summary/1` returns an
effective profile of `:anime`. Standard movie and TV queries, scoring, MediaInfo behavior, retry
semantics, and import paths remain unchanged.

Preference values survive profile changes but are dormant while a title is Standard. Auto remains
Standard under the A1 rules, so adding A4 settings cannot silently change an existing title.

Anime movie behavior uses the group/audio/subtitle and verification subset only. Specials and
stable episode coordinates remain TV concepts.

## Persisted preference model

### Global Anime defaults

Add non-secret settings in the existing registry and `/settings` form:

- `anime_audio_mode`: `original | dub | dual | any`, default `original`;
- `anime_embedded_subtitle_mode`: `allow | prefer | require`, default `prefer`;
- `anime_preferred_groups`: normalized comma-separated group names, default empty;
- `anime_blocked_groups`: normalized comma-separated group names, default empty; and
- `anime_group_fallback_delay`: non-negative hours, default `24`.

The existing `subtitle_languages` setting remains the global desired-language list. Standard
subtitle fetching continues to read it as today; Anime policy merely uses the same value as its
inherited language list.

An empty preferred-group list disables fallback waiting regardless of the configured delay. An
empty blocked-group list disables group rejection. Group comparison is trimmed, case-insensitive,
and based on the parser's release-group output.

### Per-title overrides

Add nullable typed fields to both `movies` and `series`:

- `audio_mode` enum;
- `subtitle_languages` string array;
- `embedded_subtitle_mode` enum;
- `preferred_release_groups` string array;
- `blocked_release_groups` string array; and
- `group_fallback_delay` integer seconds.

`nil` means inherit the current Anime default. An explicit empty array disables the inherited list
for that title. Delay must be non-negative. List values are normalized on write and deduplicated in
first-seen order.

The existing `preferred_language` remains the concrete dub target. `dub` and `dual` require an
explicit language choice and are invalid when `preferred_language` is `original` or `any`.
`original` mode requires the title's known original language; if that metadata is absent, the
policy has no hard audio target and the UI explains that verification is unavailable.

One focused preference changeset per schema owns these fields. TMDB refresh and general admin
changesets never cast them, so provider refresh cannot erase operator choices.

## Effective policy

`Cinder.Acquisition.AnimePreferences.resolve/1` is pure apart from receiving already-read defaults.
It returns a normalized policy map containing:

- ordered required audio languages for `original`, `dub`, or `dual`;
- desired subtitle languages;
- embedded subtitle mode;
- preferred and blocked release groups;
- fallback delay in seconds; and
- whether each value was inherited or overridden for display.

`any` produces no hard audio languages. `dual` requires both original and target language. `dub`
requires the target language only. `prefer` affects ranking but permits the current post-import
subtitle fetcher; `require` is a hard embedded-stream requirement; `allow` applies no embedded
ranking or hard constraint. `require` is invalid when the effective subtitle-language list is
empty; `prefer` with an empty list is a no-op.

This module reuses `Cinder.Acquisition.Language` for language normalization and matching. It does
not parse release names, query the Repo, or call MediaInfo.

## Settings and title UI

Add the global controls to the existing `/settings` groups. Use the existing text/select inputs;
no new settings page or component layer is needed. The delay is entered in hours and stored as
seconds.

Movie and series detail pages gain one compact `Anime preferences` section when the effective or
selected profile is Anime. Each control offers `Use Anime default` plus its typed values. The
subtitle language and group list inputs explain that a blank explicit override disables the global
list.

The form rejects invalid dub/dual language combinations and negative delays. Standard-profile
pages do not render active controls, but a title switching back to Anime recovers its stored values.

## Specials and monitoring

Season 00 is not enabled wholesale. The wanted query adds only episodes that satisfy all of:

- the series' effective profile is Anime;
- the episode classification is `story_special` or `recap`;
- the episode is explicitly monitored;
- it has no file and no active grab;
- it has aired (`air_date <= today`); and
- it has not exhausted the existing search budget.

Season 00 episode number zero is valid because stable Cinder episode IDs, not a positive-number
predicate, own acquisition identity. Regular episodes keep the existing positive season/episode
query. `extra` never enters the wanted set, and `unknown` is not a stored classification.

New provider-classified story specials and recaps default unmonitored. A provider refresh never
unmonitors an existing operator choice. Manual classification changes classification only; they do
not silently change monitoring. The existing per-episode monitor control is the explicit opt-in.

The series detail search affordances mirror the Catalog query exactly, so a monitored aired special
can be searched and an extra cannot display a nonfunctional Search action. Calendar behavior stays
unchanged; A4 does not add special scheduling UX.

Anime acquisition groups wanted stable IDs by series, so a release may cover regular episodes and
specials together. A2 query bounds and exact intent reservation remain in force. The A3 preflight
continues to require exact authoritative target coverage and may ignore an extra only with positive
evidence.

## Acquisition policy

The movie downloader and TV poller resolve one effective policy per Anime title and pass it to the
existing anime selector.

Selection applies rules in this order:

1. Existing protocol, exact-release blocklist, size, resolution, and source hard filters.
2. Parsed blocked release groups.
3. Explicitly contradictory release-name audio or embedded-subtitle traits.
4. Stable-ID coverage for episodic releases.
5. Preferred-group eligibility and fallback waiting.
6. Soft audio, subtitle, group, resolution, source, and size ranking.

Release-name traits remain advisory: only an explicit contradiction can reject early. A missing
marker, an incomplete parsed language list, or any unknown trait may proceed to post-download
verification; absence of a name marker never proves absence of a stream. Soft preferences never
defeat a hard quality constraint or stable-ID coverage.

A non-preferred release becomes eligible at `published_at + fallback_delay`. Before then the
selector returns the existing `{:waiting_for_preferred_group, %{retry_at: ...}}` result. Missing or
invalid publication time remains manual-only rather than bypassing a preferred group or waiting
forever. Waiting never increments search attempts or parks targets.

## Frozen verification policy

Changing preferences while a release downloads must not change what that reservation means.
Persist a small versioned `release_policy_snapshot` on:

- an Anime movie when its download is started;
- an Anime `download_intent` in the same transaction as episode reservation; and
- the resulting grab when intent ownership is reconciled.

The snapshot contains only normalized hard requirements and the selected release group/title
evidence needed for rejection. It contains no settings provenance, secrets, or mutable provider
metadata. Standard rows keep it nil.

Intent-to-grab reconciliation copies the policy snapshot atomically with the mapping snapshot and
authoritative episode links. Retry/requeue clears the old snapshot; a new reservation writes a new
one. Restart therefore cannot replace selection-time requirements with current settings.

## Post-download verification

Before `Library.stage_movie/1`, `Library.stage_episodes/2`, or the A3 assignment-based staging entry
point creates an `ImportStage`, verify every unique source video against the frozen hard policy
through `Cinder.Library.MediaInfo`.

For each source:

- audio requirements are satisfied only when every required language is present;
- `embedded_subtitle_mode: require` is satisfied only when at least one desired subtitle language
  is present in an embedded subtitle stream;
- `prefer` and `allow` never block staging; and
- sidecars do not satisfy an explicitly embedded requirement.

A multi-file grab passes only when every story source satisfies the policy. Files positively
ignored as extras are not policy targets. Probe each unique source once and share the result across
multi-episode/cross-season destinations.

## Rejection and retry semantics

A confirmed hard mismatch is a release-policy failure, not a mapping or filesystem failure.

For an Anime movie, one guarded Catalog transaction:

1. re-reads the expected downloaded/upgrading row;
2. inserts the exact release title into the existing movie-scoped blocklist;
3. writes a durable movie cleanup intent for the tracked remote ID;
4. returns the movie to `:requested` (or reverts an upgrade to `:available`);
5. clears download fields and the frozen policy; and
6. preserves search/import attempt counters.

For an Anime grab, one guarded Catalog transaction blocklists the exact release for the series,
deletes the grab, releases only its authoritative episode links, and writes the existing episode
cleanup fence. Cleanup runs after commit and retries from the durable intent on failure.

No staging, mapping issue, release-wide group block, or retry increment occurs. The release title
block prevents the next sweep from selecting the same artifact while leaving sibling releases from
the same group eligible.

MediaInfo absence, an execution error, or unprobeable stream metadata is not a confirmed mismatch.
When a hard policy exists, preserve the download and use the existing bounded import retry path; do
not stage, blocklist, or clean up a possibly valid release. A movie reaches the existing
`import_failed` hold after the bound without adding the release to the blocklist. A TV grab extends
the existing import gate with `mapping_status: :verification_blocked` after the bound; downloaded
queries leave it idle, Activity shows `Needs verification`, and the existing cancel cleanup remains
available. A small `Retry verification` action clears the hold and attempt counter after the
operator repairs MediaInfo. It performs no filesystem work in the web request.

This is not a second recovery editor: verification has no user-editable mapping or policy evidence.
The only actions are retry the frozen policy or cancel the preserved grab. When no hard policy
exists, the current best-effort metadata capture behavior remains.

| Condition | Result |
| --- | --- |
| Preferred group still within delay | Wait; no attempt increment |
| Preferred-group result has no valid publication time | Manual-only candidate |
| Positive release-name hard mismatch | Reject before download |
| Confirmed MediaInfo hard mismatch | Block exact release, durable cleanup, requeue exact targets |
| MediaInfo unavailable or errors under hard policy | Preserve content; bounded retry, then durable verification hold |
| Soft embedded preference not met | Import; existing subtitle fallback continues |
| Mapping ambiguity or unknown file role | Existing `Needs mapping`; no policy rejection |
| Positively identified extra | Existing exact preflight may ignore it |

## Test evidence

Extend the versioned anime corpus with explicit cases for:

- monitored and unmonitored story specials, recaps, extras, and episode zero;
- preferred, fallback, blocked, and unknown release groups;
- original, dub, dual, any, and unknown audio traits;
- embedded desired subtitles, missing embedded subtitles, and sidecar-only subtitles;
- group fallback boundaries and missing publication time; and
- Anime movies as well as episodic releases.

Required tests:

1. Pure preference tests prove default/override inheritance, explicit empty lists, language-mode
   validation, normalization, and Standard-profile inactivity.
2. Catalog tests prove only explicitly monitored Anime story specials/recaps enter the wanted set;
   extras and Standard Season 00 remain excluded; provider refresh preserves manual monitoring.
3. Acquisition tests prove blocked groups, stable-ID coverage, soft ordering, fallback boundaries,
   and no-attempt waiting for movies and episodes.
4. Snapshot tests prove policy writes are atomic with movie start or episode intent reservation and
   survive preference changes and restart through grab reconciliation.
5. Movie and TV import tests prove hard mismatches create no `ImportStage` or filesystem write,
   block only the exact release, requeue only owned targets, preserve counters, and leave durable
   cleanup evidence.
6. Probe-error tests prove hard-policy content is preserved for bounded retry, then held visibly;
   Retry verification and cancel are guarded, and no unconfirmed result is imported or blocklisted.
7. LiveView tests prove settings and per-title forms validate combinations, expose inheritance, and
   keep Standard pages behaviorally unchanged.
8. Existing A2/A3 corpus, mapping recovery, Standard movie/TV, subtitle fallback, retry, upgrade,
   and cleanup tests remain green.

The phase gate is the focused corpus/policy/poller/import slice, the repository `mix test` alias,
`graphify update .`, and a clean diff review. Only after that gate passes may ROADMAP mark A4 done.

## Out of scope

A4 does not add:

- a new metadata or subtitle provider;
- automatic monitoring of specials;
- a special-specific calendar or landing page;
- fuzzy release-group aliases or tracker-specific group rules;
- automatic preference learning;
- a generalized preferences table or policy engine;
- a MediaInfo health panel;
- live Jellyfin/Plex dogfood evidence; or
- A5 provider sign-off and operator documentation.

Those require live evidence or belong to A5. The A4 implementation stops at the tested buildable
phase boundary.

## Done when

A4 is complete only when sourced story specials are individually controllable and selectable,
extras cannot bypass A3 exact preflight, Anime defaults and per-title overrides produce the expected
movie/episode selections, preferred-group waiting consumes no attempts, confirmed hard mismatches
stage nothing and durably requeue only the exact targets while blocklisting only the exact release,
probe failures preserve content for bounded retry, Standard movie/TV behavior is unchanged,
`mix test` is green, and the knowledge graph is updated.
