# Phase 1 — Catalog (discovery + watchlist) — Design

Status: approved 2026-06-18. Complements `ROADMAP.md` Phase 1; this doc records the decisions
and concrete shapes the roadmap leaves open. Movies-only vertical slice.

Council review: 2 rounds (Opus architect + Sonnet impl + Opus contrarian; Fable 5 unavailable,
substituted) — consensus SOUND. R1 surfaced 5 material items (unique_index naming,
runtime-not-compile_env token, pinned cast list, error/empty-state UX, nil year/poster + imdb_id
deferral); all resolved in R2 with no gold-plating. No residual disagreement.

## Decisions (locked)

1. **Home route** — the search + watchlist LiveView replaces `/`. The generated welcome page
   (`PageController` + `page_html` + `home.html.heex` + `page_controller_test`) is removed; it
   existed only to serve `/`.
2. **Search UX** — live, debounced (`phx-change`, ~300ms). No submit button needed.
3. **Status enum** — full known set defined now: `:requested, :searching, :downloading,
   :downloaded, :available`. Only `:requested` is used this phase; stored as a string, so
   listing all up front is free and later phases don't re-touch the schema.
4. **TMDB impl** — build the minimal real Req-based client now. Not live-tested this phase
   (no API key wired); the live smoke test is Phase 5. Tests stay fully mocked.
   - `Cinder.Catalog.TMDB.HTTP` implements **both** behaviour callbacks (`@behaviour` requires
     it — a partial impl is a `warnings-as-errors` failure), sharing one private normalizer.
   - But Phase 1's flow (`search → stash result → add`) only *uses* `search/1`. `get_movie/1`
     is implemented for contract-completeness, not driven by a Phase 1 feature.
   - **`imdb_id` is deferred to Phase 2.** CLAUDE.md (lines 41–42) wants `get_movie/1` to carry
     `imdb_id` for indexer search — that's a Phase 2 concern. Phase 1's normalized shape omits
     it deliberately; Phase 2 adds it via `get_movie/1` (`append_to_response=external_ids`).

## Boundary shape

The TMDB impl (real **and** mock) returns *normalized* maps so the context/LiveView never see
TMDB's raw JSON:

```elixir
%{tmdb_id: integer, title: String.t(), year: integer | nil, poster_path: String.t() | nil}
```

`year` is parsed from TMDB's `release_date` ("YYYY-MM-DD"), which can be absent → `nil`.
`poster_path` is TMDB's relative path (e.g. `/abc.jpg`), which can be `null`/absent → `nil`.
The view builds the full image URL. (`imdb_id` joins this shape in Phase 2; see Decision 4.)

## Modules & files

Every new module carries an `@moduledoc` — there is no `.credo.exs`, so `credo --strict` runs the
default `Readability.ModuleDoc` check and a missing moduledoc is a failure. (Migration modules
are exempt by credo default.)

- `lib/cinder/catalog.ex` — context:
  - `search_movies(query)` → configured TMDB impl; **blank/whitespace query short-circuits to
    `{:ok, []}`** (no API call). Returns `{:ok, [normalized_map]} | {:error, term}` (passes the
    impl's error through; the LiveView decides UX).
  - `add_to_watchlist(attrs)` → inserts a `:requested` movie; `{:ok, movie} | {:error, changeset}`.
  - `list_watchlist/0` → all movies, newest first (`order_by` desc inserted_at/id).
- `lib/cinder/catalog/movie.ex` — Ecto schema `Movie`:
  - Fields: `tmdb_id :integer`, `title :string`, `year :integer` (**nilable — no `null: false`**),
    `poster_path :string` (nilable), `status Ecto.Enum, values: [:requested, :searching,
    :downloading, :downloaded, :available], default: :requested`, timestamps.
  - Changeset: `cast(attrs, [:tmdb_id, :title, :year, :poster_path])` — **`status` is NOT cast**
    (it relies on the field-level default; nothing should set it from the search boundary map).
    `validate_required([:tmdb_id, :title])`, `unique_constraint(:tmdb_id)`.
  - *Deviation from ROADMAP wording:* column is `poster_path`, not `poster`.
- `priv/repo/migrations/*_create_movies.exs` — table + **`create unique_index(:movies,
  [:tmdb_id])`** (named index; its default name `movies_tmdb_id_index` must match
  `unique_constraint(:tmdb_id)`'s default, or SQLite raises `Ecto.ConstraintError` instead of
  returning `{:error, changeset}`). `year`/`poster_path` columns are nullable.
- `lib/cinder/catalog/tmdb/http.ex` — `Cinder.Catalog.TMDB.HTTP`, implements the behaviour with
  `Req`. `search/1` → `GET /3/search/movie`; `get_movie/1` → `GET /3/movie/:id`. Both pipe
  through one private `normalize/1`.
  - Config read at **runtime, nil-tolerant**: `Application.get_env(:cinder,
    Cinder.Catalog.TMDB.HTTP, [])` yields `:base_url`, `:token`, and optional `:req_options`.
    **Never `compile_env!`** for these — the token isn't present at compile time in dev/test.
  - Auth: bearer token — `Req.new(base_url: base_url, auth: {:bearer, token})`.
  - **`Req.Test` seam:** the client merges `req_options` (a keyword list, may contain
    `plug: {Req.Test, Cinder.TMDBStub}`) into the request, so tests stub without network.
- `lib/cinder_web/live/watchlist_live.ex` — single LiveView (no LiveComponents). `mount` loads
  the watchlist. `phx-change="search"` (debounced ~300ms) assigns results; `phx-click="add"`
  carries `tmdb_id`, looked up from the stashed results assign, inserts, prepends to the
  watchlist assign, flashes. daisyUI cards. **No PubSub** — one process owns reads+writes this
  phase (PubSub arrives Phase 3 with the poller).
  - Poster URL: a module constant `@poster_base "https://image.tmdb.org/t/p/w342"` (TMDB's image
    base is hardcoded rather than fetched from `/configuration`). `nil` poster_path → a text
    placeholder card, not a broken `<img>`. `nil` year → render the title without `(year)`.
- `config.exs`: `config :cinder, tmdb: Cinder.Catalog.TMDB.HTTP` (compile-time impl selection —
  safe, set in all envs). `runtime.exs`: reads `TMDB_API_TOKEN` into `config :cinder,
  Cinder.Catalog.TMDB.HTTP, base_url: ..., token: ...`. `test.exs`: `:tmdb` already → mock, and
  adds `config :cinder, Cinder.Catalog.TMDB.HTTP, req_options: [plug: {Req.Test, Cinder.TMDBStub}]`
  for the HTTP client's own test.
- `router.ex`: `live "/", WatchlistLive` replaces `get "/", PageController, :home`.

## States & runtime behavior (LiveView)

The handlers must cover these — each is cheap and is the actual first-run experience:

- **Search error** — `search_movies/1` returns `{:error, _}` (TMDB down, 401, rate-limited):
  flash an error, keep prior results, **do not crash** (handler matches both `{:ok, _}` and
  `{:error, _}`; no bare `{:ok, r} =`).
- **Blank/cleared query** — assign `results: []` so stale results disappear.
- **No results** — valid query, empty list: render a "No matches" line, not a blank gap.
- **Empty watchlist** — fresh install (the default home view): render empty-state copy below
  the search box.
- **Duplicate add** — Add is shown for every result (search results don't cross-reference the
  watchlist — YAGNI for a single household). Adding an already-watchlisted movie hits the unique
  index → `{:error, changeset}` → flash "already on your watchlist". The unique index also makes
  a fast double-click safe (second insert fails the constraint, no duplicate row).
- **Add lookup miss** — if the clicked `tmdb_id` isn't in the stashed results (e.g. results were
  cleared/replaced mid-click), the handler is a no-op.

## Tests (the "Done when")

- `test/cinder/catalog_test.exs` (`async: true`, Mox private mode, `DataCase`) — mocked TMDB
  search returns fixtures; `add_to_watchlist` persists a `:requested` movie; `list_watchlist`
  returns it; duplicate `tmdb_id` → `{:error, changeset}`; blank query → `{:ok, []}` with no mock
  call.
- `test/cinder_web/live/watchlist_live_test.exs` (`async: false`, `ConnCase`, **Mox global mode**
  via `Mox.set_mox_global`) — typing a query (mocked TMDB) renders results; clicking **Add**
  persists and the movie shows in the rendered watchlist; a `{:error, _}` from search renders a
  flash without crashing. `async: false` + `ConnCase` puts the sandbox in **shared mode**, so the
  separately-spawned LiveView process gets DB access automatically — no manual `Sandbox.allow/3`.
- `test/cinder/catalog/tmdb/http_test.exs` (`async: true`) — `Req.Test` stub proves
  JSON → normalized-map mapping for `search/1`, including `release_date → year` and `nil`
  year/poster_path. No network. (`get_movie/1` shares the same `normalize/1`, so it's covered
  transitively; no separate Phase 1 feature test for it.)
- Built test-first.

## Out of scope (deferred, not silent)

Quality upgrades, TV, multi-user, PubSub, `overview`/extra TMDB fields, search pagination,
`imdb_id` carry-through (Phase 2), and a `/configuration`-driven image base URL.
