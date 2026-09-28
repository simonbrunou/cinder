# A2 Anime Acquisition Design

Council review: 3 rounds - approved; all material findings resolved, no residual disagreement

## Goal

Add anime-aware release discovery and selection without creating a third pipeline or weakening the
existing movie and TV paths. A2 must turn release coordinates into stable Cinder episode IDs, choose
the expected A0 corpus releases, preserve enough immutable evidence in a durable download intent to
survive restart and metadata refresh, and support preferred-group waiting without consuming retry
budgets.

The repository-wide anime safety invariant remains stronger than this phase boundary: episodic anime
must not enter the existing importer until A3 can perform inventory-bound exact preflight. A2 may
activate the anime-movie subset because movies need no episode-coordinate mapping; episodic selection
and reservation APIs land fully tested but are not wired into `Cinder.Download.TvPoller` until A3.
Otherwise an absolute or cross-season release could reach the current importer, be parked as
unmatched, and lose content or retry meaning before mapping recovery exists.

## Phase boundary

A2 includes:

- additive Prowlarr searches using normal provider-ID queries, anime category 5070, stored aliases,
  and bounded coordinate queries;
- retained Prowlarr category IDs, indexer identity, and publication time;
- context-aware anime release parsing with explicit coordinate candidates and file roles;
- resolution of parsed coordinates to stable episode IDs through the A1 resolver;
- greedy set cover over stable IDs, reusing the existing scorer core;
- anime-movie selection through the existing movie pipeline;
- options-driven preferred-group waiting, with persistence and UI deferred to A4;
- an immutable versioned mapping snapshot on episodic `download_intents`;
- corpus, regression, waiting, and restart tests.

A2 does not include:

- episodic anime poller activation or any import behavior;
- snapshot copy to `grabs`, inventory preflight, `Needs mapping`, correction, resume, or cancel UI;
- Season 00 acquisition;
- persisted global or per-title group/audio/subtitle preferences;
- post-download MediaInfo policy enforcement;
- a new metadata provider, anime context, pipeline, or library layout.

Those remain A3/A4 work exactly as recorded in the parent design and roadmap.

## Architecture

Movies and episodic TV retain their existing owners and state machines. `Cinder.Acquisition` remains
the public context. A focused `Cinder.Acquisition.Anime` module owns the new query planning,
deduplication, coordinate resolution, group eligibility, snapshot construction, and stable-ID
selection. It is an acquisition helper, not a new context or pipeline, and performs no Repo writes.

`Cinder.Acquisition.AnimeParser` is pure and handles only anime-context coordinate and role parsing.
The existing `Cinder.Acquisition.Parser.parse/1` continues to produce the standard resolution,
source, codec, group, language, season, and episode fields. Anime parsing augments a normal
`Release`; it does not add anime branches to the legacy parser's standard season precedence.

`Cinder.Catalog` exposes read-only acquisition-context builders for a Movie or Series. Catalog owns
the Repo queries and converts A1 aliases and coordinate memberships into plain maps. Acquisition
never queries Ecto schemas directly.

Existing Indexer callbacks stay unchanged. Two focused free-text callbacks are added rather than
overloading the movie and TV contracts:

```elixir
@callback search_movie_query(query :: String.t(), opts :: keyword()) ::
            {:ok, [map()]} | {:error, term()}

@callback search_tv_query(query :: String.t(), opts :: keyword()) ::
            {:ok, [map()]} | {:error, term()}
```

The only new option in A2 is `categories: [5070]`. `Prowlarr` maps these callbacks to
`type=moviesearch` and `type=tvsearch`, serializing the measured A0 wire contract as the scalar query
parameter `categories=5070` and preserving the locked movie/TV contract split. The existing
`search/1` IMDb path and `search_tv/3` TVDB/season path remain byte-for-byte compatible at their
callers.

## Acquisition contexts

The series context is a plain map containing:

- the canonical title, year, and de-duplicated stored aliases;
- every canonical episode in the series as a generated `standard` mapping such as `S01E03`;
- every persisted A1 coordinate with source, scheme, namespace, canonical value, precedence,
  ordered stable episode IDs, and immutable evidence;
- enough season placement to group wanted stable IDs for bounded query planning.

All memberships of a coordinate are retained, even when only one member is currently wanted. This
lets selection reject a combined coordinate that would claim an episode outside the wanted set
rather than silently truncating its meaning.

A generated standard mapping is authoritative canonical placement, with source `cinder`, namespace
`canonical`, precedence `manual`, and evidence `%{"kind" => "canonical_standard"}`. For an explicit
standard release coordinate, only this generated mapping participates in release-title resolution;
persisted alternative-coordinate rows remain available to the snapshot closure described below but
cannot override what `SxxEyy` means inside Cinder. This avoids an indeterminate tie between canonical
season placement and provider or operator aliases.

The movie context contains the canonical title, year, aliases, and profile summary. Movie contexts
carry no episode mappings or mapping snapshot.

Coordinate mappings passed to `Cinder.Catalog.AnimeResolver` use an internal unique key that includes
source, scheme, namespace, and canonical value. A parsed release coordinate contains only its scheme
and value. Acquisition expands that candidate to every persisted mapping with the same scheme/value,
then lets the A1 precedence rules resolve or report ambiguity. This preserves namespace evidence and
correctly exposes conflicting provider groups instead of pretending a release name identified one.

## Search planning and normalization

Anime search expands the standard search; it never replaces it.

For episodic anime, the query plan contains:

1. the existing TVDB/season search once for each canonical season containing wanted IDs;
2. one category-5070 query for the canonical title and each distinct stored alias;
3. for each wanted canonical season, one canonical-title query for the earliest wanted coordinate
   in each A2-queryable scheme (`standard`, `absolute`, or `scene`).

This is bounded by aliases plus `wanted seasons × coordinate schemes`; it deliberately avoids the
`aliases × episodes × schemes` Cartesian product. A pass considers at most four wanted canonical
seasons, the canonical title plus seven aliases, three explicitly queryable schemes (`standard`,
`absolute`, and `scene`), and 24 total requests. Ordering is deterministic: earliest wanted season;
then alias precedence `manual > curated > inferred`, alias kind `scene > licensed > romaji > native
> alternative`, and normalized title. Provider-ID queries and the canonical category query are
planned before alias and coordinate queries. Set cover may satisfy more than the queried coordinate;
after successful reservations a later pass advances to the remaining IDs.

Query titles are capped at 200 Unicode codepoints and coordinate scalars at 32. A parsed coordinate
range expands to at most 100 values; a wider, descending, overflowing, or malformed range is
unmatched rather than allocated. These are acquisition trust-boundary limits, not database schema
limits.

For anime movies, Acquisition combines the existing IMDb search with category-5070 movie queries for
the canonical title/year and the same deterministically ordered maximum of seven stored aliases/year.
A movie pass therefore makes at most nine requests: one IMDb request, one canonical free-text
request, and seven alias requests.

Every result retains all query origins, including whether any origin was ID-scoped or free-text.
Every candidate available only through an additive free-text query, movie or episodic and regardless
of coordinate syntax, must pass the title identity guard before automatic selection. After stripping
an optional leading bracketed group, one canonical title or stored alias must match the leading title
segment under Unicode NFKC normalization and Unicode case folding. The trailing boundary must be the
end of the title segment, a target year, an explicit episode/season separator, or a recognized
technical tag—not another title word. Native-script aliases are never reduced to ASCII. Additive
anime-movie candidates must also contain the target year exactly; a missing or conflicting year
fails closed. Existing provider-ID-scoped results keep their current trust model and may bypass this
guard.

Prowlarr normalization adds these optional fields to its existing release map:

- `category_ids` as a list of integer category IDs;
- `indexer_id` as the integer Prowlarr indexer ID;
- `published_at` as a parsed UTC `DateTime` or `nil` when absent/invalid.

Normalization is per result, not all-or-nothing. A list element that is not a map, lacks a non-empty
binary title, or has no non-empty binary download/magnet URL is dropped while valid siblings survive.
Non-numeric sizes are normalized to `nil` for the existing scorer to reject safely. Protocol keeps
the existing conservative behavior (`"usenet"` becomes `:usenet`; absent, unknown, or malformed
values become `:torrent`). Malformed optional metadata never crashes or discards an otherwise usable
release. Missing or invalid `published_at` makes a non-preferred fallback manual-only; it cannot
bypass or wait forever. Malformed optional container shapes are normalized to empty/nil values at
the trust boundary.

Results are de-duplicated first by `{protocol, download_url}` when a URL exists, otherwise by
`{protocol, normalized_title, size}`. A merged result unions category IDs and query origins, ORs
ID-scoped provenance, and fills optional metadata deterministically from the first non-nil value in
query-plan order; de-duplication may not discard the evidence that permits a title-guard bypass. A
failed additive query does not erase successful sibling results. If every query fails, Acquisition
returns the underlying error. If some query fails, the successful results are scored, but no
complete selectable movie or complete episodic assignment/waiting coverage returns
`{:error, :incomplete_search}` rather than a false `:no_match`; active anime movies treat that as the
existing bounded transient failure. A complete result may proceed despite a failed sibling.

## Context-aware parsing

`AnimeParser.parse/2` receives the release title plus a context containing media kind, known titles,
and year. It returns:

```elixir
%{
  coordinates: [%{scheme: "absolute", values: ["25", "26"]}],
  role: :story | :extra | :unknown,
  group: String.t() | nil
}
```

Parsing precedence is:

1. explicit standard coordinates, including cross-season `SxxEyy` batches;
2. bounded typed-special markers (`OVA`, `OAD`, `ONA`, `RECAP`, `EPISODE:0`);
3. absolute singles/ranges after a known title match;
4. unmatched.

Years, resolutions, CRCs, version suffixes, and group tags are excluded before accepting a bare
number. Thus `[Group] 86 - 2024 [1080p] [ABCDEF01]` is unmatched, while One Piece `1122v2` remains an
absolute candidate. Prefix `[Group]` syntax fills `Release.group` when the legacy trailing-group
parser did not already provide one.

`NCOP`, `NCED`, and `TRAILER` are positive `:extra` evidence. Typed specials remain `:unknown` in A2;
they are parser candidates but cannot be selected while Season 00 activation is deferred to A4.
Ordinary standard/absolute releases and movies are `:story`. No filename that merely looks unusual
is silently ignored.

The A0 `phase == "A2"` release contracts are executable parser tests and must all match exactly.
Because those locked A0 rows do not contain parser context or selection pools, A2 adds
`test/support/fixtures/anime/acquisition-v1.json`. It supplies explicit media kind, known titles, and
year for every referenced A0 A2 parser case, plus versioned end-to-end candidate pools, mappings,
wanted stable IDs, expected selected title(s), and expected assignment IDs. Tests join by fixture ID;
they do not infer missing context from expected output.

The shared `Release` struct gains only the data that crosses acquisition stages:
`category_ids`, `indexer_id`, `published_at`, `query_origins`, `coordinates`, `role`,
`resolved_episode_ids`, `resolution_evidence`, and `mapping_snapshot`. Standard construction leaves
the anime-only fields empty and preserves every existing field and parser result.

## Stable-ID resolution and set cover

Parser precedence produces one coordinate interpretation. For each parsed story release, Anime
resolves every canonical value in that interpretation independently. A standard value is passed to
`Cinder.Catalog.AnimeResolver` with its one generated canonical mapping. A non-standard value is
expanded to all persisted mappings with the same scheme/value across namespaces and passed to the
resolver as one alternative-evidence set. Any unmatched or ambiguous value rejects the whole
release. Successful per-value ID lists are concatenated in filename order and de-duplicated on first
occurrence, preserving each mapping's internal membership order; one coordinate mapping to several
episodes therefore stays ordered. Per-value evidence is retained. This is the required behavior for
absolute ranges and cross-season standard batches; multiple values are never sent to one resolver
call as competing alternatives.

A resolved episodic candidate is rejected when any resolved ID is outside the current wanted stable
ID set. This is intentionally stricter than intersecting coverage: the snapshot and later preflight
must not reinterpret a combined coordinate as a partial release.

`Cinder.Acquisition.Scorer` gains a stable-ID entry point that reuses its existing hard filters,
per-episode size band, ranking, and greedy set-cover core. The internal cover function accepts a
coverage function:

- existing `select_for/4` supplies standard season/episode-number coverage and retains all current
  behavior;
- anime selection supplies `release.resolved_episode_ids` coverage.

The standard public result type remains unchanged. Anime episodic assignments are explicit maps:

```elixir
%{
  release: %Cinder.Acquisition.Release{mapping_snapshot: snapshot},
  episode_ids: [stable_id, ...],
  mapping_snapshot: snapshot
}
```

The snapshot builder sets both fields from the same immutable term and validates exact equality;
callers cannot receive an anime assignment whose `release` has lost its safety marker. No assignment
type or scorer abstraction is added beyond this map and one shared pure cover core.

## Preferred-group waiting

A2 implements group preference as call options only:

- `preferred_groups: [String.t()]`;
- `fallback_delay: non_neg_integer()` seconds;
- `now: DateTime.t()` for deterministic tests, defaulting to current UTC time.

No A2 setting, migration column, or UI exposes these options. A4 supplies global/per-title
persistence and forms.

Group comparisons are trimmed and case-insensitive. With no preferred groups, the option layer is a
no-op. Preferred releases are immediately eligible. A non-preferred release becomes eligible only
at `published_at + fallback_delay`. Missing/invalid publication time is manual-only. Waiting is
computed after the existing hard filters so an unusable release cannot hold wanted IDs hostage.

Waiting is coverage-component aware. After hard filtering, eligible and time-delayed candidates form
an overlap graph whose nodes are wanted stable IDs and whose candidate coverages are hyperedges. A
component is assigned now only when eligible candidates can cover the whole component. If an
eligible partial overlaps a delayed candidate needed by an uncovered ID, the whole component waits;
the partial is not submitted and cannot make a later pack fail the outside-wanted guard. Components
with no overlap remain independent.

Anime episodic selection has these exact result shapes:

```elixir
{:ok,
 %{
   assignments: [%{release: release, episode_ids: ids, mapping_snapshot: snapshot}, ...],
   waiting: nil | %{episode_ids: protected_component_ids, retry_at: earliest_datetime}
 }}
```

When there are no assignments but one or more hard-valid delayed components exist, it returns:

```elixir
{:waiting_for_preferred_group,
 %{episode_ids: protected_component_ids, retry_at: earliest_datetime}}
```

`protected_component_ids` includes the presently eligible IDs in any held overlap component, not
only IDs covered by delayed releases. `retry_at` is the earliest eligibility instant among delayed
candidates touching a protected component; the next pass recalculates all components. A delayed
candidate with invalid publication time is manual-only and creates no waiting component.

Movie selection returns
`{:waiting_for_preferred_group, %{retry_at: earliest_datetime}}`. In A2 preferred-group options are
an Acquisition API contract only: production `Download.start/1` supplies no preferred groups because
persistence and fallback-delay scheduling belong to A4. Therefore A2 does not create a zero-attempt
movie that is polled every five seconds, and `retry_at` is advisory to the future A4 scheduler.
Focused selection tests prove waiting performs no Catalog write and cannot consume a search attempt.
Episodic waiting likewise remains an Acquisition result until A3 activates the anime TV path.

## Durable intent snapshot

`download_intents` gains one nullable `mapping_snapshot :map` column. Standard movie and TV intents
continue to store `nil`; no existing callback or caller must fabricate a snapshot.

An episodic anime snapshot is JSON-safe and contains:

```elixir
%{
  "version" => 1,
  "reserved_episode_ids" => [stable_id, ...],
  "release" => %{
    "title" => title,
    "coordinates" => [%{"scheme" => scheme, "values" => values}],
    "group" => group,
    "category_ids" => category_ids,
    "indexer_id" => indexer_id,
    "published_at" => iso8601_or_nil
  },
  "mappings" => [
    %{
      "identity" => %{
        "source" => source,
        "scheme" => scheme,
        "namespace" => namespace,
        "canonical_value" => value
      },
      "precedence" => precedence,
      "episode_ids" => ordered_ids,
      "evidence" => json_safe_evidence
    }
  ],
  "selected_resolution" => %{
    "episode_ids" => [stable_id, ...],
    "values" => [
      %{
        "scheme" => scheme,
        "canonical_value" => value,
        "episode_ids" => ordered_ids,
        "precedence" => precedence,
        "mapping_identities" => [
          %{
            "source" => source,
            "scheme" => scheme,
            "namespace" => namespace,
            "canonical_value" => value
          }
        ]
      }
    ]
  }
}
```

The encrypted download URL remains solely in the existing intent `release` field and is not
duplicated in the snapshot.

The pure snapshot builder receives the complete Catalog-built acquisition context and constructs the
full closure of every coordinate whose membership intersects a reserved ID, including canonical
standard and alternative absolute/scene/provider forms. A focused builder test compares its output
against that complete input universe; `reserve_intent/1` cannot infer an omitted Catalog mapping from
snapshot data alone and does not claim to. Full membership order is retained even when a mapping also
contains an outside ID; A3 needs that evidence to reject an internal file that expands beyond the
reservation. The structured `identity` map avoids delimiter-dependent keys.

`Download.reserve_intent/1` accepts `mapping_snapshot` in trusted internal attrs. Before insertion it
validates version 1; non-empty positive-integer `reserved_episode_ids`; exact ordered equality with
the episodic intent's `episode_ids` and `selected_resolution.episode_ids`; positive-integer,
non-empty mapping memberships; exact per-value scheme/value/ordered-ID data; existence of every
structured `mapping_identities` reference in `mappings`; intersection of every stored mapping with
the reserved set; and coverage of every reserved ID by the frozen mapping closure. Outside members
are retained, not rejected. Movie intents reject a mapping snapshot. Invalid snapshots fail before
any client call.

The snapshot is inserted in the same transaction as the intent and its authoritative
`download_intent_episodes` links. General and retry/submission changesets do not cast the field, and a
dedicated validation rejects a replacement with different data. The episode links remain ownership;
snapshot IDs are immutable evidence. A3 will copy the snapshot atomically to a grab before deleting
the intent.

A restart test reserves an anime intent, reloads it from SQLite after changing provider coordinates,
and proves the stored mapping and reserved IDs retain their original meaning. A2 does not claim
post-grab durability; atomic snapshot copy is explicitly A3.

## Movie activation and episodic safety hold

`Download.start/1` reads the effective movie profile. Standard movies call the unchanged
`best_release/2`. Anime movies call the additive anime-movie selector, then use the existing
`grab_movie/2`, downloader reconciliation, import, and portable movie naming. They never enter
episode mapping.

`TvPoller` continues calling the existing `best_releases/4` in A2, even for a series whose effective
profile is Anime. A2 exposes the pure episodic selector, snapshot builder, and reservation operation,
but no API both reserves and submits an anime intent.

The phase seam is enforced at every public side-effect entry point as well as at the caller. A
non-cleanup episodic intent with a non-nil `mapping_snapshot` is excluded from
`reconcile_pending_intents/1`; both direct `submit_intent/1` and `reconcile_intent/1` return
`{:error, :anime_import_not_ready}` before client lookup, remote add, or grab creation. The shared
private submission choke-point performs the same guard so no public wrapper can bypass it. The intent
and its episode links remain reserved unchanged.

The existing public reserve-and-submit shortcut is guarded before it can erase the marker:
`grab_episodes/2` returns `{:error, :anime_import_not_ready}` before intent lookup or reservation when
given `%Release{mapping_snapshot: snapshot}`. It never reconstructs snapshot-free attrs from an anime
assignment in A2. Standard manual TV grabs have a nil marker and remain unchanged. Cleanup remains
operable. A3 replaces this rejection with snapshot-preserving reservation only after grabs can
atomically own snapshots and downloaded content can stop in `Needs mapping` without staging or
deletion.

This hold is not a hidden setting or long-lived feature flag. It is the explicit A2/A3 phase seam and
is removed by wiring the selector in A3.

## Error handling and safety

- Additive free-text results that fail the Unicode title guard—or the movie title/year guard—cannot
  become automatic candidates regardless of coordinate syntax.
- Ambiguous, unmatched, typed-special, and extra releases are not automatically selected in A2.
- A resolved release claiming any non-wanted stable ID is rejected rather than truncated.
- Additive-query partial failures may use successful sibling results only when they yield a complete
  result; otherwise `:incomplete_search` follows existing bounded transient retry behavior at the
  active anime-movie caller. Total failure remains an error.
- `waiting_for_preferred_group` is not `:no_match` and never increments search attempts.
- Missing publication metadata cannot bypass the delay or wait forever; the release is manual-only.
- Invalid mapping snapshots fail before the downloader side effect.
- Snapshot-bearing episodic intents remain reserved and produce no downloader, grab, import,
  deletion, or counter side effect until A3.
- Standard intents, standard parser behavior, standard scorer outputs, and standard poller grouping
  remain unchanged.
- Episodic anime does not reach Library until A3 exact preflight exists.

## Testing

Focused tests cover:

1. every A0 A2 parser fixture joined to explicit context in the A2 acquisition fixture, including
   standard, absolute >99/>999, bounded range, cross-season, typed special, positive extra,
   ambiguous year, prefix group, dual-audio markers, anime movie, native-script title matching, and
   huge-range fail-closed behavior;
2. Prowlarr free-text params plus category/indexer/publication normalization and malformed optional
   metadata;
3. additive TV and movie query construction and worst-case request bounds; Unicode leading-title
   guards including embedded-title/spinoff and movie missing/wrong-year negatives;
   provenance-preserving URL/fallback deduplication; per-entry malformed core/optional Prowlarr data;
   and partial/total search failure;
4. versioned acquisition pools select expected release titles and stable IDs; per-value stable-ID
   resolution covers standard, absolute range, one-to-many, cross-season, ambiguity, and outside-
   wanted rejection;
5. stable-ID greedy set cover while every existing `Scorer.select_for/4` test remains unchanged;
6. preferred-group boundaries, case-insensitive groups, missing timestamps, mixed eligible/waiting
   coverage, the overlapping eligible-single/delayed-pack hold, no Catalog writes for advisory movie
   waiting, and exact protected TV component IDs/retry time;
7. anime-movie alias/category selection through `Download.start`, with a regression proving a
   Standard movie invokes only the existing IMDb path;
8. full-closure snapshot construction from a complete context, structural snapshot validation,
   transactional intent/episode reservation, no client call on invalid input, changeset-level
   immutability across retry, restart/reload, and provider-coordinate refresh;
9. `grab_episodes/2`, direct submission, direct reconciliation, and a real `TvPoller` pass proving
   the standard TV selector remains active while an anime release/intent is rejected or held with no
   client call, snapshot-free reservation, grab, import, deletion, or counter bump;
10. the full repository `mix test` alias.

Tests use Mox and never contact TMDB, Prowlarr, or a downloader. The A2 gate ends with
`graphify update .`, `mix test`, and a roadmap update recording the phase boundary.

## Done when

A2 is complete when every A0 A2 parser contract passes with explicit context and the versioned A2
acquisition fixture selects the expected releases and stable episode sets, anime movies use additive
alias/category selection safely, standard movie/TV parser and selection behavior is unchanged,
preferred-group waiting performs no attempt write, an episodic mapping snapshot survives restart and
provider refresh without changing reservation meaning, episodic anime remains held out of Library
until A3, and the full `mix test` alias passes.
