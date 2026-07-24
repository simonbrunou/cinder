# People & collections discovery — design (2026-07-23)

Council review: 2 rounds (Claude correctness seat, Codex blast-radius seat, Sonnet
contrarian seat) — consensus: sound. Round 1 restructured the plan (WP1 purely additive,
card-uniform shapes, one parameterized drill-in LiveView, new DiscoverComponents /
RequestHelpers homes, concurrent search sides, cap caption + full department gettext map).
Round 2 blockers folded in: `Task.yield_many`+`shutdown` instead of the caller-crashing
`await_many`, chronological `Date`-comparator part sort instead of the term-order tuple
key, RequestHelpers' Gettext/LiveHelpers imports, `attr :type values:` update. Residual
(accepted, named): round-robin dilution on dominant-type queries; SeriesDiscoveryLive's
season-flavored flash copy stays duplicated.

Extend Discover so a search can find a **person** (actor, director, …) or a **franchise**
(TMDB "collection"), and each gets a drill-in page whose grid reuses the existing
request/badge machinery. Additive only: the movie/TV pipelines and trending are untouched.

## Decisions (locked; council round 1 folded in)

- **Separate TMDB endpoints, not `/search/multi`** — additive beats churning the existing
  movie/TV callbacks. (`/search/multi` is the upgrade path if relevance ordering ever bites.)
- **Card-uniform result shapes.** Every search/list map a grid can receive carries
  `tmdb_id`, `title`, `year`, `poster_path` (person: `title` = name, `poster_path` =
  profile_path, `year: nil`; collection: `year: nil`) so `media_card` needs no
  per-type special-casing and no shape can crash the grid.
- **WP1 is purely additive** — new callbacks + Catalog one-liners only. `search_discover`
  is NOT touched in WP1 (council: changing it before the UI knows the new types is a
  test-green-but-crashes-in-prod phase boundary). The 4-side flip lands in WP2 atomically
  with the card/type support and the test-stub backfill.
- **One drill-in LiveView, two routes** — `CinderWeb.EntityDiscoveryLive` mounted at
  `/person/tmdb/:tmdb_id` (live_action `:person`) and `/collection/tmdb/:tmdb_id`
  (live_action `:collection`). The two pages are structurally identical (parse id → fetch
  one entity → header + grid + same add/request flow); they differ only in fetch fn,
  list field, header, and whether TV cards can appear. Mirrors `SeriesDiscoveryLive`'s
  defensive param parse and sync-fetch-in-mount with the 404-vs-outage flash split.
- **New homes, not overloaded ones.** Shared markup goes to a new
  `CinderWeb.DiscoverComponents` (`use CinderWeb, :html` — brings VerifiedRoutes + gettext,
  which `CoreComponents` lacks, and doesn't grow the CoreComponents god node). Shared
  socket-effectful helpers go to a new `CinderWeb.RequestHelpers` — `LiveHelpers` stays
  "pure functions only" per its moduledoc.
- **Round-robin interleave of all four result types**, generalizing `interleave/2` to a
  list of lists. Named tradeoff: for dominant-type queries ("john") this halves top-grid
  movie/TV density vs today; accepted for a household tool because the filter chips recover
  it, and swapping to a weighted variant later is a one-function change.
- **Search sides run concurrently** in WP2 (`Task.async` + **`Task.yield_many` +
  `Task.shutdown`**, mapping a timed-out/dead side to `{:error, :timeout}`; timeout 30s —
  above the HTTP client's ~25s worst case of connect+pool+receive). NOT `Task.await_many`:
  it exits the caller on timeout, crashing the LiveView where today's path degrades to a
  flash. Each side keeps its `{:ok, list} | {:error, reason}` contract. Update the
  `search_discover` docstring's ponytail note accordingly.
- **Failure signal keeps today's strength**: movies AND tv both failing →
  `{:error, :search_failed}` regardless of the person/collection sides; any other partial
  failure is logged and omitted. (The naive "all four must fail" rule would show a
  misleading "No matches" when both primary sides are down.)
- **Credits are capped** at 60 after dedup, with a visible muted "Showing top 60 of N"
  caption when truncated (no silent caps). Collection parts sort by release date asc,
  nils last.

## WP1 — backend seam (executor: codex)

Four new `Cinder.Catalog.TMDB` callbacks, impl + adapter tests, atomic with the behaviour
(Mox `defmock for:` auto-covers them):

- `search_person(query, locale)` → `GET /3/search/person` →
  `{:ok, [%{tmdb_id, title, year: nil, poster_path, department}]}` — `title` = `name`,
  `poster_path` = `profile_path`, `department` = `known_for_department` (may be nil).
- `search_collection(query, locale)` → `GET /3/search/collection` →
  `{:ok, [%{tmdb_id, title, year: nil, poster_path}]}` (`name` → `:title`).
- `get_person(tmdb_id, locale)` → `GET /3/person/{id}?append_to_response=combined_credits`
  → `{:ok, %{tmdb_id, name, profile_path, department, credits: [...],
  total_credits: n}}`. Credits: cast ++ crew entries with `media_type` "movie"/"tv"
  (drop others), **sorted by `entry["popularity"] || 0` desc on the raw entries** (nil
  ranks above numbers in Erlang term order — the `|| 0` is load-bearing), deduped by
  `{media_type, id}` (first wins), capped at 60, then normalized via the existing
  `normalize/1` / `normalize_tv/1` plus `type: :movie | :tv`. `total_credits` = the
  post-dedup pre-cap count (drives the truncation caption).
- `get_collection(tmdb_id, locale)` → `GET /3/collection/{id}` →
  `{:ok, %{tmdb_id, title, poster_path, parts: [...]}}`; parts normalized as movie search
  maps plus `type: :movie`, sorted chronologically asc with nils last via
  `Enum.sort_by(parts, &(&1.release_date || ~D[9999-12-31]), Date)`. Do NOT use a
  `{is_nil(date), date}` tuple key — tuple keys compare `%Date{}` structs in Erlang term
  order (fields alphabetically: day before year), wrong chronology; and a bare
  `sort_by(&.release_date, Date)` raises on nil. The happy-path fixture must include a
  term-order-exposing pair (e.g. `2009-12-31` vs `2010-01-05`) so a wrong key fails.

All requests carry `language: @tmdb_tags[locale]`; reuse `request/1`, `error/1`. Page 1
only for the two searches (matches `search`/`search_tv`); `combined_credits` and `parts`
are not paginated.

Catalog additions (one-liners through the seam, like `trending/1`): `search_person/2`,
`search_collection/2`, `get_person/2`, `get_collection/2`, all
`locale \\ Locales.canonical()`. **`search_discover/2` and `interleave/2` are untouched
in WP1.**

Tests: adapter 3-pack per endpoint (happy incl. locale param + normalization, non-200,
malformed 200) mirroring the trending tests in `test/cinder/catalog/tmdb/http_test.exs`
(`Req.Test.stub(Cinder.TMDBStub, ...)`; `%{"results" => [...]}` wrapper for searches,
unwrapped body for the two detail endpoints per `get_movie/1`'s pattern); the `get_person`
happy path covers dedup + nil-popularity ordering + cap + `total_credits`; the
`get_collection` happy path covers nil-date sort. No UI changes, no existing test edits —
the suite must stay green with zero stub backfills.

## WP2 — UI + discover flip (executor: sonnet, after WP1)

1. **Extraction (code motion + new homes, no behavior change):** create
   `CinderWeb.DiscoverComponents` (`use CinderWeb, :html`) holding `media_grid`,
   `result_action`, `tv_result_action`, **`original_option_label/1`** (it's called from
   `result_action`'s HEEx — forgetting it is a compile error), and the pure
   `title_state/3` / `tv_title_state/3` (private — `media_grid` computes per-card state
   from its map attrs). Create `CinderWeb.RequestHelpers` (imports `Phoenix.Component` +
   `Phoenix.LiveView`, plus `use Gettext, backend: CinderWeb.Gettext` for the flash
   messages, plus `import CinderWeb.LiveHelpers` — the moved code calls the pure
   `duplicate_request?/1` and `latest_status_by/2`) holding the movie-add machinery: attrs build + `start_async`,
   `request_result/3` flash branching, and the request/movie/series status-map assigns
   (`assign_request_state`, `assign_movie_status`, `assign_available_series`,
   `patch_movie_status`). The `handle_event("add")` / `handle_async({:add,…})` /
   `handle_info` **callback clauses stay as thin per-view delegates** (callbacks can't
   live in a helper module). `DiscoverLive` becomes the first consumer; its tests pass
   untouched before anything else lands. Known residual (intentional, note in the PR):
   `SeriesDiscoveryLive`'s season-flavored copy of the flash branching stays as-is.
2. **Discover flip (atomic with 3):** `search_discover` gains the person/collection sides —
   concurrent `Task.async`/`await_many` for all four, tag `:person` / `:collection`,
   generalized round-robin `interleave([movies, tv, persons, collections])`, failure rule
   per Decisions. Blast radius (from council): add permissive
   `search_person`/`search_collection` `{:ok, []}` stubs to
   `test/cinder/catalog_discover_test.exs` setup and
   `test/cinder_web/live/discover_live_test.exs` setup (17 tests otherwise raise
   `Mox.UnexpectedCallError`), and extend the existing "both endpoints error →
   search_failed" test to force all four callbacks to error. The other four
   trending-stub test files are unaffected (they never submit `#search-form`).
3. **Discover grid:** `media_card` learns `:person` / `:collection` — both the
   `type_icon`/`type_label` clauses (an unknown type is a FunctionClauseError) and the
   `attr :type ... values:` declaration in `core_components.ex` (a stale values list fails
   `--warnings-as-errors` on any literal `type={:person}`); person cards show the department as subtitle via a **full
   gettext map over TMDB's ~12 department values** (Acting→Actor, Directing→Director,
   Writing→Writer, … raw passthrough only for a genuinely unknown value) — the app is
   bilingual, a 2-case map ships English into the FR locale. Card action: View button
   navigating to the drill-in route. Filter chips: All / Movies / TV / People /
   Collections.
4. **`EntityDiscoveryLive`** (one module, two routes in the `:authenticated`
   live_session next to `SeriesDiscoveryLive`): branch on `socket.assigns.live_action`.
   `:person` — fetch `Catalog.get_person/2`; header name + department; grid = credits
   (movie add forms + TV season-picker links + badges); shows "Showing top 60 of N"
   (gettext, pluralized) when `total_credits > 60`. `:collection` — fetch
   `Catalog.get_collection/2`; header title; grid = parts (movies only).
   Subscriptions: person needs **all three** topics (`Catalog.subscribe/0`,
   `Catalog.subscribe_series/0`, `Requests.subscribe/0`) — TV credit badges go stale
   without `series_updated` — collection needs movies + requests only; simplest is to
   subscribe all three unconditionally and reuse Discover's handle_info shapes.
5. Tests: `EntityDiscoveryLive` per action (renders credits/parts, add-from-page creates
   the request/movie, defensive bad-id param, badge reflects an existing request,
   truncation caption at >60), Discover chip + person/collection card tests. Stub the new
   callbacks in any test file that mounts the new routes.
6. `mix gettext.extract --merge` **last**, fill all new FR msgstrs.

Gate for both WPs: `mix test` (the alias — compile --warnings-as-errors, format, credo
--strict, suite) fully green.
