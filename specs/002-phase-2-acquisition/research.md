# Phase 2 — Acquisition (find the best release) — Design

Status: approved 2026-06-18. Complements `ROADMAP.md` Phase 2; this doc records the decisions
and concrete shapes the roadmap leaves open. Movies-only vertical slice.

Council review: 2 rounds (model-diverse Claude tiers — Opus correctness + Sonnet
implementation/Prowlarr-API + Opus contrarian; Fable 5 seat unavailable, substituted on Opus).
Consensus **SOUND**. R1 surfaced 5 material items: (1) `nil` seeders inverted the scorer tie-break
via Elixir's `number < atom` ordering; (2) the `resolution_rank` "negative index" was
undefined/crash-prone for unlisted/`nil` resolutions; (3) "substring after last `-`" group
extraction mis-parsed hyphen-in-title / source-hyphen names and could break the blocklist;
(4) the Prowlarr request was guessed wrong (`type:"search"` + bare imdb query → corrected to
`type:"movie"` + `{ImdbId:…}` token, `downloadUrl||magnetUrl`, verified against the Servarr wiki);
(5) `test.exs` was missing the Prowlarr `Req.Test`/`api_key` seam. All resolved in R2 (correctness
fixes verified empirically by running the actual key + regex). R2 added 3 minor items (a
`WEB-DL`-terminated parser-fixture edge, the `search/1` exact-equality assertion needing
`imdb_id: nil`, and dotted-suffix group limits) — all folded in. Residual: the contrarian accepts
`best_release/2` (Decision 3) only because the user explicitly approved it; the `language`-parsing
and `["1080p","720p"]`-default pushbacks were conceded once `ROADMAP.md` Phase 2 was checked
(it names "language"; "prefer 1080p" allows a 720p fallback rank). No NEEDS-REWORK.

## Decisions (locked)

1. **Indexer transport — Prowlarr JSON API, not Torznab XML.** The roadmap says "Torznab query,"
   which is XML. Prowlarr also exposes `GET /api/v1/search`, which returns JSON that `Req` handles
   natively — no XML parser dependency, and it reuses the `TMDB.HTTP` skeleton exactly. The slice
   targets Prowlarr specifically, so the loss of Torznab portability is acceptable. Behind the
   `Indexer` behaviour the transport is invisible; swapping to Torznab later touches one module.
2. **Scope — pure library slice + a one-line `imdb_id` enabler.** Build the indexer impl, parser,
   and scorer with unit tests. No LiveView, no GenServer, no status transitions, no auto-trigger
   from `:requested` — all of that is Phase 5. The one addition beyond the modules: `TMDB.HTTP`'s
   `get_movie/1` starts carrying `imdb_id` (see Decision 5).
3. **`best_release/2` is in scope (user-approved).** This is **extra work the "Done when" does not
   require** — that bar exercises the scorer directly, and `best_release/2`'s only caller is born in
   Phase 5. It composes `indexer.search → Release.new → Scorer.select` (about five lines + one Mox
   integration test) and is *not* pipeline wiring: no process, no DB, no status change. The council
   contrarian argued for deferring it; the user explicitly chose to keep it when this tradeoff was
   surfaced. So it stays — recorded plainly as a deliberate, knowingly-taken scope deviation, not a
   "free" seam.
4. **`size` comes from the indexer, not the parser.** The roadmap lists "size" among the fields
   "extract[ed] … from a release name," but sizes embedded in names are unreliable and Prowlarr
   reports exact bytes. The parser does only the name-derived fields (resolution, codec, group,
   language); `size` is the indexer's reported `size` field.
5. **`imdb_id` enabler.** TMDB's `/3/movie/:id` details body already returns `"imdb_id"` directly
   — no `append_to_response` needed (this is simpler than the Phase 1 spec anticipated). So the
   enabler is a single line in `TMDB.HTTP`'s shared `normalize/1` plus one assertion in its
   `get_movie/1` test. Search results omit `imdb_id` (TMDB doesn't return it there), so only
   `get_movie/1` carries it — matching the CLAUDE.md note that `Catalog.get_movie/1` carries
   `imdb_id` through for indexer search.

### Decisions deliberately NOT changed (council pushback, overruled with reason)

- **`language` is parsed this phase, though nothing scores on it yet.** The contrarian flagged
  this as gold-plating. Overruled: the ROADMAP's Phase 2 "Build" list *explicitly* names
  "language" among the parser's outputs, and the project treats `ROADMAP.md` as authoritative. The
  apparent contradiction with "Out of scope" is only apparent — language *scoring* is deferred;
  language *parsing* is a named deliverable. Per the project's own "anything explicitly requested"
  rule, it stays. (It is a single token set + one struct field — cheap.)
- **`preferred_resolutions` default stays `["1080p", "720p"]`.** The contrarian argued for
  `["1080p"]` to be roadmap-literal. Overruled: the user approved this default when it was
  surfaced. It is configurable per the roadmap's "configurable rules" requirement.

## Verified Prowlarr API facts (checked June 2026 against the Servarr wiki + Prowlarr issues)

These were the council's highest-risk unknowns; verified so the impl + test fixture aren't built
on a guess:

- **Endpoint:** `GET /api/v1/search`, params `query`, `type`, optional `indexerIds`, `categories`,
  `limit`, `offset`.
- **IMDb search:** pass `query: "{ImdbId:#{imdb_id}}"` (the `tt…` prefix is kept) with
  `type: "movie"`. This is Prowlarr's unified-search ID-token syntax; `type: "movie"` routes it
  through movie categories. (The bare-`tt…`-as-free-text form the first draft assumed was wrong.)
- **Auth:** `X-Api-Key` request header (Prowlarr also accepts an `apikey` query param; we use the
  header, mirroring `TMDB.HTTP`).
- **Response:** a top-level JSON **array** of release objects. Relevant camelCase fields: `title`,
  `size` (bytes, integer), `downloadUrl`, `magnetUrl`, `seeders`, `guid`, `imdbId`, `protocol`.
- **Download field:** prefer `downloadUrl`; fall back to `magnetUrl` (magnet-only trackers leave
  `downloadUrl` null). So `download_url = result["downloadUrl"] || result["magnetUrl"]`.
- **Still Phase-5-verify:** exact per-indexer behavior (some indexers ignore ID search) and live
  field population are only confirmable against a running Prowlarr — that's the Phase 5 smoke test.
  The fixture below encodes the verified shape; if a live response differs, `prowlarr_test`'s
  fixture is the one place to correct.

## Boundary shapes

**Indexer impl → context** — `search/1` returns *normalized* raw maps so the parser/scorer never
see Prowlarr's JSON:

```elixir
%{title: String.t(), size: integer, download_url: String.t() | nil, seeders: integer | nil}
```

**`%Cinder.Acquisition.Release{}`** — the shared currency between parser, scorer, and context.
A struct (not loose maps) so each unit has a clear, testable interface and a fixed shape under
`--warnings-as-errors`:

```elixir
%Release{
  title:        String.t(),
  size:         integer,                 # bytes, from the indexer
  download_url: String.t() | nil,        # from the indexer (downloadUrl || magnetUrl)
  seeders:      integer | nil,           # from the indexer; CARRIED, not scored on this phase
  resolution:   String.t() | nil,        # parsed: "2160p" | "1080p" | "720p" | "480p" | nil
  codec:        String.t() | nil,        # parsed: "x265" | "x264" | "h265" | "h264" | "av1" | ...
  group:        String.t() | nil,        # parsed: trailing "-GROUP" (guarded; see Parser)
  language:     String.t() | nil         # parsed: "MULTI" | "FRENCH" | ... | nil (nil ⇒ English assumed)
}
```

`Release.new(indexer_map)` merges the indexer fields with `Parser.parse(indexer_map.title)`.

## Modules & files

Every new module carries an `@moduledoc` — `credo --strict` runs the default `Readability.ModuleDoc`
check and a missing moduledoc is a failure.

- `lib/cinder/acquisition.ex` — context:
  - `best_release(imdb_id, opts \\ [])` → resolves the impl with
    `Application.fetch_env!(:cinder, :indexer)` (runtime, matching `Catalog`; **never
    `compile_env!`**, or the test mock module warns under `--warnings-as-errors`), calls
    `search/1`, maps results through `Release.new/1`, hands them to `Scorer.select/2`. Returns
    `{:ok, %Release{}} | :no_match | {:error, term}`. **`opts` flows only to `Scorer.select/2`**
    (the indexer takes the bare `imdb_id`, no opts). Passthrough: an indexer `{:error, term}` and a
    scorer `:no_match` both return unchanged; an empty indexer list (`{:ok, []}`) yields `:no_match`
    (via the scorer's empty-input guard), never a crash.
- `lib/cinder/acquisition/release.ex` — the `Release` struct + `new/1`.
- `lib/cinder/acquisition/parser.ex` — `parse(name) → %{resolution, codec, group, language}`.
  Pure, regex/string based, no deps. Case-insensitive matching; unknown field → `nil`. To stay
  under credo's `CyclomaticComplexity`, implement each field as a table of `{pattern, value}`
  matched with `Enum.find` rather than nested conditionals.
  - **`group` (guarded):** take the segment after the **final** `-` only when it looks like a
    release group — `~r/-([A-Za-z0-9]+)$/` after stripping any trailing container extension
    (`.mkv`/`.mp4`/…), i.e. the tail must be a single alphanumeric token, no dots/spaces. Otherwise
    `nil`. This deliberately yields `nil` for hyphen-in-title names (`Spider-Man…`), for
    source-hyphen names with a trailing token (`…WEB-DL.H264`), and for groupless scene releases —
    preventing a title fragment from being mistaken for a group (which would silently break the
    blocklist).
    - **Known, bounded limits (accepted, not silent):** (a) a name ending *exactly* on a
      source-hyphen token, e.g. `…1080p.WEB-DL` with no following token, parses `group: "DL"`; (b) a
      dotted-suffix group, e.g. `…x264-YTS.AG`, parses to `nil` (the `.` breaks the single-token
      rule). Both are low-incidence and don't break the blocklist in practice — `"DL"` is never a
      blocklist entry, and dotted groups are rare — so a denylist of source tokens is *not* worth
      it this phase. A source-token denylist / dotted-group support is deferred to whenever the
      blocklist proves leaky in real use.
  - `resolution`/`codec`/`language`: first match against known token sets wins; no match → `nil`.
- `lib/cinder/acquisition/scorer.ex` — `select(releases, opts \\ []) → {:ok, %Release{}} |
  :no_match`.
  - Rules resolved at runtime: `opts` merged over `Application.get_env(:cinder,
    Cinder.Acquisition.Scorer, [])` defaults. Keys:
    - `min_size` / `max_size` (bytes) — the accepted band, **inclusive**. An absent key means
      **unbounded on that side** (so with neither set — the bare `config.exs` state — the size
      filter is a no-op). A release with no size is treated as `0` bytes.
    - `blocklist` — list of group names, compared **case-insensitively**. A release whose parsed
      `group` is `nil` can never match the blocklist.
    - `preferred_resolutions` — ordered list, default `["1080p", "720p"]`. Listed = preferred (in
      order); anything else (incl. `2160p`, `nil`/unknown) ranks **last** but is **not** rejected
      ("prefer" ≠ "require").
  - Algorithm: `filter` by size band → `reject` blocklisted groups → if no survivors, `:no_match`;
    else `{:ok, Enum.min_by(survivors, fn r -> {res_rank(r), -(r.size || 0)} end)}`, where
    `res_rank(r) = Enum.find_index(preferred_resolutions, &(&1 == r.resolution)) ||
    length(preferred_resolutions)`. Smallest tuple wins: best (lowest-index) resolution first, then
    largest size. **`res_rank` is always an integer and `size` is coalesced**, so the comparison
    never hits Elixir's `number < atom` ordering — there is no `nil`-in-the-key footgun, and the
    unlisted/`nil` resolution path can't raise. **Seeders are not in the key** (the roadmap's scorer
    is resolution + size-band + blocklist only); they ride along on the struct for Phase-5 use.
- `lib/cinder/acquisition/indexer/prowlarr.ex` — `Cinder.Acquisition.Indexer.Prowlarr`,
  `@behaviour Cinder.Acquisition.Indexer`, implements `search/1` with `Req`. Same skeleton as
  `TMDB.HTTP`:
  - `GET /api/v1/search` with params `query: "{ImdbId:#{imdb_id}}"`, `type: "movie"` (see verified
    facts above).
  - Config read at **runtime, nil-tolerant**: `Application.get_env(:cinder,
    Cinder.Acquisition.Indexer.Prowlarr, [])` yields `:base_url`, `:api_key`, and optional
    `:req_options` (the `Req.Test` seam). Auth: `X-Api-Key` header via `Req.new(headers: ...)`,
    omitted when `api_key` is nil (mirroring `TMDB.HTTP`'s nil-tolerant `auth`).
  - Normalizes each JSON result to the boundary map (`download_url = downloadUrl || magnetUrl`);
    `{:ok, [map]}` on a 200 with a **list** body, `{:error, :unexpected_response}` on a 200 that
    isn't a list, `{:error, {:prowlarr_status, s}}` / `{:error, reason}` otherwise — symmetric with
    `TMDB.HTTP.error/1`.
- `lib/cinder/catalog/tmdb/http.ex` — add `imdb_id: movie["imdb_id"]` to the shared `normalize/1`
  (one line). No request change — the details endpoint already returns it; `search/1` results
  simply have it as `nil`.
- `config/config.exs` — add `config :cinder, indexer: Cinder.Acquisition.Indexer.Prowlarr`
  (compile-time impl selection, safe in all envs; mirrors the `tmdb:` line). Real
  `base_url`/`api_key` wiring (via `runtime.exs`) is Phase 5, consistent with TMDB not being
  live-wired until then. **`fetch_env!(:cinder, :indexer)` is only reached when `best_release/2`
  is called, so dev/prod won't crash at boot with the band/keys unset.**
- `config/test.exs` — already points `:indexer` at the mock. **Add the `Req.Test` seam for the real
  client's own test:** `config :cinder, Cinder.Acquisition.Indexer.Prowlarr, req_options: [plug:
  {Req.Test, Cinder.ProwlarrStub}], api_key: "test-key"` (a non-nil `api_key` so the test can
  assert the `X-Api-Key` header is actually sent). Mirrors the existing TMDB `req_options` line.

## Tests (the "Done when")

All offline. No network, no real service.

- `test/cinder/acquisition/parser_test.exs` (`async: true`) — a table of real-world release names
  → expected `%{resolution, codec, group, language}`. Must include: a `-GROUP` name (group
  extracted); a **hyphen-in-title** name like `Spider-Man.2002.1080p.BluRay.x264` (group → `nil`,
  not `Man…`); a source-hyphen name **with a trailing token** like `Movie.2010.1080p.WEB-DL.H264`
  (group → `nil` — pick this deliberately: a name ending *exactly* on `WEB-DL` would instead give
  `"DL"`); a groupless scene name (group → `nil`); and mixed casing.
- `test/cinder/acquisition/scorer_test.exs` (`async: true`) — over `%Release{}` fixtures with
  explicit `opts` rules:
  - **happy** — a mixed list including a band-fitting 1080p → that release is chosen.
  - **all-too-large** — every release exceeds `max_size` → `:no_match`.
  - **blocklisted-group** — the blocklisted release would otherwise **win** (it out-ranks the
    runner-up on `{res_rank, -size}`) → it is excluded and the runner-up is chosen. Include a
    **negative control**: the same fixtures with an empty blocklist select the blocklisted release,
    proving the test depends on the blocklist filter and not on incidental ordering.
  - **preference-ordering** — with no 1080p present, assert ordering holds across `720p`, an
    *unlisted* `2160p`, and a `nil`-resolution release (exercises the `res_rank` sentinel and the
    size tie-break), plus a `1080p`-beats-equal-`720p` case.
- `test/cinder/acquisition/indexer/prowlarr_test.exs` (`async: true`) — `Req.Test` stub returns a
  fixture Prowlarr JSON **array** → asserts the normalized maps (incl. `magnetUrl`→`download_url`
  fallback for a magnet-only entry). Asserts the request: `query == "{ImdbId:tt…}"`, `type ==
  "movie"`, and the `x-api-key` header (via `Plug.Conn.get_req_header(conn, "x-api-key")` —
  lowercase, Plug-normalized). `{:error, _}` on a non-200.
- `test/cinder/acquisition_test.exs` (`async: true`, Mox private mode, `verify_on_exit!`) —
  `IndexerMock` returns fixture raw maps; `best_release/2` composes parse + score and returns the
  expected `%Release{}`. Also: `:no_match` from the scorer passes through; an `{:error, _}` from
  the indexer passes through; an **empty** indexer list (`{:ok, []}`) → `:no_match`.
- `test/cinder/catalog/tmdb/http_test.exs` — extend the existing `get_movie/1` test to assert the
  stubbed body's `imdb_id` appears in the normalized map. **Also update the `search/1`
  exact-equality assertion** to include `imdb_id: nil` on each result — the shared `normalize/1`
  now adds the key to *every* result, and `search/1`'s TMDB body omits it, so the existing
  `results == [%{tmdb_id: …, …}]` assertion would otherwise fail under `--warnings-as-errors`.
- Built test-first.

## Out of scope (deferred, not silent)

Torznab XML transport, multi-indexer per-tracker quirks, quality upgrades/cutoffs, **language
preference scoring** (language is *parsed* per the roadmap, but not yet a scoring axis),
seeders/health thresholds (carried on the struct, not scored), the live Prowlarr smoke test
(Phase 5), and all pipeline wiring — auto-triggering acquisition from a `:requested` movie,
persisting the chosen release, and status transitions (Phase 3 / Phase 5).
