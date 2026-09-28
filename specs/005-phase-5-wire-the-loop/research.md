# Phase 5 — Wire the loop + status dashboard (design)

Date: 2026-06-19
Roadmap phase: 5 (final phase of the movies-only vertical slice)

Council review: 3 rounds — consensus the design is sound to implement; all flaws fixed.
Post-review: user pulled `.torrent`-URL handling into scope, implemented via a self-computed
v1 infohash (§3.3); infohash approach verified by execution.

## 1. Context: what's already done, and the one real gap

A read of all four contexts (Catalog, Acquisition, Download, Library) plus the web
layer, supervision tree, and config showed Phase 5 is **much smaller than the
roadmap implies**:

- **The back half is already fully automatic.** The supervised `Cinder.Download.Poller`
  (5 s sweep) drives `:downloading → :downloaded → :available`, **including the import
  call** (`poller.ex` → `Library.import_movie/1`). Crash recovery is proven by an
  existing test. The roadmap's "on `:downloaded`, hardlink + rename + scan" work was
  finished in Phase 4 — there is **no new import call site to add**.
- **Dev config already points at the real impls.** `config/config.exs` selects
  `TMDB.HTTP`, `Indexer.Prowlarr`, `Client.QBittorrent`, `MediaServer.Jellyfin`,
  `Filesystem.Disk`; `config/dev.exs` adds no overrides. Only `config/test.exs` swaps in
  mocks. The roadmap's "replace mock configs with real impls in dev" is a **no-op at the
  config layer** — only real *credentials* (already read from env by `runtime.exs`) are
  missing.

**The one real gap: the front half is unwired.** `Cinder.Download.start/1`
(`:requested → :searching → :downloading`, or terminal) is implemented and tested but
**has zero callers in `lib/`** — today you must call it from IEx. Wiring that single
trigger so it runs automatically is the heart of Phase 5's "no manual steps."

Two supporting gaps fall out of that: there is **no recovery** for a movie stranded in
`:searching`/`:requested` by a transient indexer/TMDB/client error, and the **status
dashboard LiveView does not exist** (though `/` already renders a basic status badge — see
§3.4).

## 2. Goals / non-goals

**Goals (this session, all verified with mocks):**

1. A `:requested` movie flows automatically through search → download → import to
   `:available`, with no manual steps, under the supervision tree.
2. Transient search/handoff failures are **backed-off and bounded-retried**, then parked at
   a terminal state — never stranded, never looping every 5 s, never falsely declared
   "unavailable."
3. A status dashboard LiveView at `/status` shows every movie with its live state via
   PubSub.
4. `mix test` (the alias: compile-as-errors, format, credo --strict, suite) is green;
   every new behaviour has a test.

**Non-goals (deferred / parked):**

- Running the live smoke test this session (services may not be up). We deliver the
  env-var setup + a smoke-test checklist instead; the live run is the user's to execute.
- BitTorrent v2 / hybrid (SHA-256) infohashes — v1 SHA-1 only (§3.3).
- A manual "retry" UI for parked movies (see §3.2 note on `search_attempts`).
- Periodic re-search of `:no_match`, quality upgrades, TV, multi-user — parked per roadmap.

## 3. Design

### 3.1 Orchestration — extend the Poller, don't add a process

The Poller already re-derives all of its work from the DB each tick (the stateless
property that gives crash recovery) and already sweeps two statuses. Add a third sweep,
ordered **last** (rationale below):

```
do_poll:  advance_downloading()  →  import_downloaded()  →  search_requested()
          [exists]                  [exists]                 [NEW]
```

`search_requested/0` sweeps the **needs-search set** — `:requested` ∪ `:searching` —
filters it to movies that are *due* (§3.2 backoff), and runs each through
`Download.start/1` (wrapped in the existing `isolate/2` so one movie's raise can't crash
the tick):

```elixir
defp search_requested do
  due = Enum.filter(
    Catalog.list_by_status(:requested) ++ Catalog.list_by_status(:searching),
    &search_due?/1
  )
  for movie <- due, do: isolate(movie, &search_one/1)
end
```

**Why sweep both `:requested` and `:searching`:** `Download.start/1` writes `:searching`
*after* it resolves the IMDb id, so the two transient-failure modes rest at different
statuses — a TMDB-resolution failure leaves the movie at **`:requested`**, while an
indexer/client failure (which happens after the `:searching` write) leaves it at
**`:searching`** (preserved across retries by `search_one`'s re-read — §3.2, not relied on as
a dashboard signal). Sweeping both picks up either, and a crash mid-search recovers cleanly.
Within one tick a movie can't be double-processed: it is in exactly one status list at the
instant each list is read, and `start/1`'s synchronous status write completes before
`search_one` returns.

**Why search runs *last* in the tick:** searching first would let a movie go
`:requested → :downloading` and then be immediately status-polled by `advance_downloading`
in the *same* tick — a wasted qBittorrent call against a torrent registered milliseconds
ago. Running search last means a freshly-handed-off torrent is first polled on the *next*
tick. (There is therefore **no single-tick `:requested → :available` cascade**; a fresh
movie needs at least two ticks, and a real download takes minutes regardless. The e2e test
in §7 drives multiple polls accordingly.)

This satisfies CLAUDE.md ("background work under the supervision tree, not the request
path") — `Download.start/1` does synchronous indexer + client HTTP, which must not run in a
LiveView event. Options (a) trigger on watchlist-add and (c) a separate orchestrator
GenServer were rejected for that reason and for added moving parts. **Adding to the
watchlist = requesting a download** (the watchlist is the request queue), per the roadmap's
"no manual steps."

### 3.2 Error handling — backoff + bounded retry; honest terminal states

`Download.start/1` stays a pure "attempt once" function returning `{:ok, movie}` /
`{:error, reason}` (its existing `{:error, reason}` contract is unchanged — it does **not**
return the in-flight movie); all retry/counter logic lives in the Poller (symmetric with how
import logic already lives in the Poller, not in `Library`). `search_one/1` classifies on the
**tuple**, not the status:

| `Download.start/1` returns | Meaning | Action |
|---|---|---|
| `{:ok, _movie}` (status `:downloading` or `:no_match`) | handed off, or scorer found nothing acceptable | **done** — never retried, regardless of status |
| `{:error, :no_imdb_id}` | TMDB has no IMDb id for this movie (permanent, *not* operator-actionable) | transition `:no_match` immediately |
| `{:error, :unsupported_download_url}` | a release was chosen but its URL form (`.torrent`/base32-we-can't-parse) isn't supported (permanent, **operator-actionable**) | transition `:search_failed` immediately |
| `{:error, _other}` (indexer/client/TMDB network error — transient) | retryable | `retry_or_fail(movie, reason, :search_attempts, :search_failed)` |

**Two terminal failure states, deliberately distinct** (this reverses the first draft's
"reuse `:no_match`"; see §9): 

- **`:no_match`** — the honest "no release we can use exists": the scorer evaluated real
  releases and none qualified (or zero results), or the movie has no resolvable IMDb id.
  Passive; nothing for the operator to do.
- **`:search_failed`** — operator-actionable: a release existed but couldn't be handed off
  (`:unsupported_download_url`), or transient search/handoff errors exhausted the retry
  budget (Prowlarr/qBittorrent/TMDB was down). On the dashboard this tells the operator
  *go check your indexers/credentials*, instead of misreporting the movie as unavailable.

This mirrors the existing back-half split (`:import_failed` is a distinct terminal, not
folded into `:available`). `:search_failed` is a new `Ecto.Enum` value — no DB migration
needed (the enum is validated in the schema; SQLite stores it as a string).

**`search_one/1` body — spelled out (the re-read fixes a stale-write bug).**
`Download.start/1` writes `:searching` as its first step, then on a transient failure returns
`{:error, reason}` **without** returning the now-`:searching` movie. So the struct
`search_one` holds is the one loaded by the sweep — its `status` is stale (still `:requested`
for a fresh movie). If `retry_or_fail` wrote `%{status: movie.status, …}` from that stale
struct it would **revert `:searching → :requested`** (a lost-update). To avoid that, the
transient branch re-reads the movie so the counter write preserves the *current* DB status:

```elixir
defp search_one(movie) do
  case Download.start(movie) do
    {:ok, _movie} -> :ok                                  # :downloading or :no_match — terminal/done
    {:error, :no_imdb_id} -> Catalog.transition(movie, %{status: :no_match})
    {:error, :unsupported_download_url} -> Catalog.transition(movie, %{status: :search_failed})
    {:error, reason} ->
      fresh = Catalog.get_movie_by_id(movie.id)            # reflect start/1's :searching write
      retry_or_fail(fresh, reason, :search_attempts, :search_failed)
  end
end
```

So a movie that reached `:searching` (indexer/client failure) stays `:searching` across
retries; one that failed at id-resolution (transient TMDB) stays `:requested`. Both are in
the swept set; the dashboard simply shows whichever the movie actually holds — we do **not**
rely on the rest-status to encode the failure stage (the failure reason is logged). This
needs a thin `Catalog.get_movie_by_id/1` (`Repo.get(Movie, id)`).

**Backoff (not every-5s), test-injectable.** A transient search failure must not re-hit
external services on every 5 s tick, and a fixed 10×5 s = 50 s window falsely parks movies
during real multi-minute outages. Note the asymmetry with the import retry: **import retries
hit local services (Jellyfin/FS) so every-tick is harmless; search retries hit external,
rate-limited services (Prowlarr→trackers, TMDB).** So `search_due?/1` gates retries on
`updated_at` age:

```elixir
# retry interval is read from poller state (default 60 s), so tests can inject 0
defp search_due?(_movie, _retry_after = 0), do: true
defp search_due?(%{search_attempts: 0}, _retry_after), do: true
defp search_due?(movie, retry_after),
  do: DateTime.diff(DateTime.utc_now(), movie.updated_at) >= retry_after
```

Fresh movies (`search_attempts == 0`) are attempted on the next tick; a failed movie is
re-attempted at most once per `retry_after`. `updated_at` is DB-backed (every `retry_or_fail`
transition bumps it), so the schedule survives a poller crash — consistent with the
stateless-poller design (no in-memory tick counter, which would reset on restart). The
interval is a `start_link`/config option exactly like the existing `interval` (`poller.ex`),
defaulting to `@search_retry_after 60`; **tests pass `0` so a `Poller.poll()` loop exercises
the full 10-attempt bound without wall-clock waits** (and one focused test back-dates
`updated_at` via `Repo.update_all` to prove the gating itself). Cap stays `@max_attempts = 10`
→ a ~10-minute window in production, comfortably outlasting a transient outage before parking
`:search_failed`. `DateTime.diff/2` accepts the `:utc_datetime` `updated_at` directly.

**Generalized retry helper.** Today's `retry_or_fail/2` is parameterized to a counter field
+ terminal status so both paths share it. Note the **dynamic key comes first** in the map
literal — Elixir rejects `key: v` pairs *before* `k => v` pairs (a compile error):

```elixir
defp retry_or_fail(movie, reason, attempts_field, terminal_status) do
  attempts = (Map.get(movie, attempts_field) || 0) + 1
  if attempts >= @max_attempts do
    Logger.warning("movie #{movie.id} #{attempts_field} exhausted (#{inspect(reason)})")
    Catalog.transition(movie, %{status: terminal_status})
  else
    Logger.info("movie #{movie.id} #{attempts_field} #{attempts}/#{@max_attempts} (#{inspect(reason)}); will retry")
    Catalog.transition(movie, %{attempts_field => attempts, status: movie.status})
  end
end
```

- `import_one` → `retry_or_fail(movie, reason, :import_attempts, :import_failed)`.
- `search_one` → `retry_or_fail(fresh, reason, :search_attempts, :search_failed)`.

The dynamic key `%{attempts_field => attempts, ...}` is valid Elixir, **but only persists if
`:search_attempts` is in `transition_changeset`'s `cast` list** — Ecto silently drops
uncast keys, which would turn the bound into an infinite loop. This single cast-list line
(§3.5) is the highest-risk implementation step; §7 tests it directly.

**Counter persistence is correct as designed:** `Download.start/1` never casts
`search_attempts`, and `retry_or_fail` is its sole writer (once per due tick), so Ecto's
partial-update semantics preserve the counter across the `:requested → :searching` rewrite.
No reset is needed on the forward path. *Known limitation:* a parked movie manually
re-requested from IEx keeps `search_attempts: 10` and would re-park on the first attempt; a
"retry" UI is parked, so the operator must reset the counter manually for now (documented in
the smoke-test doc).

**The `ensure_imdb_id` fix.** Today `ensure_imdb_id/1` collapses a genuinely-missing IMDb id
and a transient TMDB outage into one `:no_imdb_id` (the catch-all `_ ->` swallows both
`{:ok, %{imdb_id: nil}}` and `{:error, _}`). Split it so the transient case can retry:

```elixir
case Catalog.get_movie(tmdb_id) do
  {:ok, %{imdb_id: id}} when is_binary(id) and id != "" -> {:ok, id}
  {:ok, _} -> :no_imdb_id                  # 200 OK, movie truly has no imdb → permanent → :no_match
  {:error, _} -> {:error, :tmdb_unavailable}  # outage → transient → backoff/retry → :search_failed
end
```

`Download.start/1`'s `else` then returns `{:error, :no_imdb_id}` (was: park `:no_match`
directly) and propagates `{:error, :tmdb_unavailable}`; the Poller's `search_one` maps them
per the table above. Scorer `:no_match` stays immediate-terminal (`start/1` already returns
`{:ok, %{status: :no_match}}`; `search_one` sees `{:ok, _}` → done).

This is **one coherent contract shift — apply all three together**: (1) `ensure_imdb_id`
split, (2) `start/1`'s `else` stops parking `:no_match` and returns `{:error, :no_imdb_id}`,
(3) `search_one` now owns the `:no_match`/`:search_failed` parking. Updating `start/1` without
its test, or the table without `start/1`, leaves the pipeline half-wired.

**Idempotency:** single GenServer, sequential `do_poll`, synchronous status-claim write +
DB-backed counter — no intra-tick concurrency, no extra lock needed.

**Timeouts (resilience).** `search_requested` adds synchronous indexer + TMDB HTTP to the
same sequential tick that drives download-tracking and import; a hung indexer connection
would otherwise wedge the entire pipeline. None of the three clients (Prowlarr, TMDB.HTTP,
qBittorrent) currently sets a `Req` timeout (confirmed) — each relies on Req defaults. Add an
explicit `receive_timeout` default (15_000 ms) to each client's Req base options, still
overridable via the existing `req_options`/config. This is a correctness requirement of
putting search in the shared tick, not an optimization.

### 3.3 qBittorrent — accept base32 magnets; `.torrent` deferred (flagged)

`QBittorrent.add/1` today extracts only a **40-char-hex** btih and returns
`:unsupported_download_url` for everything else (`qbittorrent.ex:25-40`).

- **base32 magnets → supported now.** Extend `btih/1`: run the existing hex regex first
  (early return), then try a **boundary-anchored, exactly-32-char** base32 btih,
  `[A-Za-z2-7]`, upcased, decoded with the **non-raising** `Base.decode32/2`:

  ```elixir
  # mixed-case class on the capture; the btih: prefix is matched as-is, NOT upcased
  @hex_btih ~r/xt=urn:btih:([a-fA-F0-9]{40})(?:&|$)/
  @b32_btih ~r/xt=urn:btih:([a-zA-Z2-7]{32})(?:&|$)/

  defp btih("magnet:" <> _ = magnet) do
    case Regex.run(@hex_btih, magnet) do
      [_, hex] ->
        {:ok, String.downcase(hex)}

      nil ->
        case Regex.run(@b32_btih, magnet) do
          [_, b32] ->
            # upcase ONLY the captured hash for decode (Base.decode32 default is :upper)
            case Base.decode32(String.upcase(b32), padding: false) do
              {:ok, raw} -> {:ok, Base.encode16(raw, case: :lower)}
              :error -> :error
            end

          nil ->
            :error
        end
    end
  end
  ```

  `Regex.run/2` returns `nil` on no-match, so this must be a `case` (a bare `[_, x] =
  Regex.run(...)` inside a `cond` would raise `MatchError`, not fall through — and that raise
  would escape through `isolate/2` and strand the movie). Match the magnet verbatim (don't
  upcase the whole string — that would break the lowercase `xt=urn:btih:` literal); upcase only
  the captured base32 hash before decoding. The original magnet is POSTed to qBittorrent
  verbatim (it accepts base32); only our stored `download_id` is normalized to the lowercase
  hex form qBittorrent expects when we later `status(hash)`. The non-raising `Base.decode32/2`
  (`padding: false`, since a 32-char base32 string needs none) means a malformed magnet returns
  `:error` → `{:error, :unsupported_download_url}` rather than raising.

- **HTTP(S) `.torrent` URLs → IN SCOPE, via self-computed infohash.** Most Torznab
  `download_url`s are an HTTP link that *returns* a `.torrent` file (not necessarily ending
  in `.torrent`), with no magnet. We can't poll qBittorrent status without the infohash, and
  qBittorrent's add endpoint returns only `"Ok."`/`"Fails."` — so the robust, *mock-testable*
  approach is to compute the v1 infohash ourselves rather than scrape it back from
  `/torrents/info` after adding (which is racy and only verifiable against a live instance —
  exactly what we can't prove with mocks this session):

  1. New tiny module `Cinder.Download.Torrent` with `infohash(bytes) :: {:ok, hex} |
     {:error, :bad_torrent}`. The v1 infohash is **SHA-1 of the bencoded `info` value exactly
     as it appears in the file** (byte-for-byte — *not* a re-encode). So the parser is a
     minimal bencode value-walker (the 4 types: `i…e`, `<len>:<bytes>`, `l…e`, `d…e`) whose
     only job is to locate the **byte span** of the top-level `info` value, then
     `Base.encode16(:crypto.hash(:sha, span), case: :lower)`. ~40-50 lines, pure, deterministic,
     unit-testable with a constructed fixture (no network). Malformed/non-bencode input (e.g.
     an HTML error page) → `{:error, :bad_torrent}`.
  2. `QBittorrent.add/1` gains an HTTP(S) clause: `Req.get` the URL (with the §3.2
     `receive_timeout`) → `Torrent.infohash/1` → POST the **fetched bytes** to
     `/api/v2/torrents/add` as `form_multipart: [torrents: {bytes, filename: "t.torrent",
     content_type: "application/x-bittorrent"}]` → return the computed hex hash (which
     `status/1` then queries — qBittorrent stores v1 hashes as lowercase hex, matching).

  Error classification (feeds §3.2): a fetch failure (indexer/CDN down) → transient
  `{:error, reason}` → backoff/retry; `{:error, :bad_torrent}` → permanent → `:search_failed`;
  `"Fails."` from qBittorrent → `{:error, :add_rejected}` (transient).

`add/1` dispatch becomes: `magnet:` → magnet path (§ above); `http://`/`https://` → fetch +
infohash path; anything else / nil `download_url` → `:unsupported_download_url`
(`:search_failed`). (BitTorrent v2 / hybrid torrents, whose infohash is SHA-256, are out of
scope — v1 SHA-1 covers essentially all current public/private movie releases; a v2-only
torrent would mis-hash and surface as a stuck `:downloading` → bounded to `:import_failed`,
or simply not be found by `status/1`. Noted, not handled.)

### 3.4 Status dashboard — `CinderWeb.StatusLive` at `/status`

`/` (`WatchlistLive`) already subscribes to PubSub, handles `{:movie_updated, movie}`, and
renders a *single neutral* status badge per movie — so `/status` is **not** net-new
real-time plumbing; it's a denser, operations-focused board (table + colour-coded badges)
distinct from `/`'s search-and-add view, per the user's explicit choice of a separate route.
To avoid two divergent badge renderings, extract a shared function component
`movie_status_badge/1` (in `core_components` or a small shared module) and use it from
**both** views.

`StatusLive`:

- `mount/3` (connected): `Catalog.subscribe()`; assign `movies = Catalog.list_watchlist/0`
  (newest first).
- `handle_info({:movie_updated, movie}, socket)`: replace the movie in the list by `id`; if
  absent, prepend it (covers a movie whose first transition arrives after mount).
- `render/1`: daisyUI table — poster thumbnail, `Title (Year)`, `movie_status_badge/1`
  coloured by state (`:requested`→neutral, `:searching`→info, `:downloading`→primary,
  `:downloaded`→accent, `:available`→success, `:no_match`→warning, `:search_failed`→error,
  `:import_failed`→error).
- Route: `live "/status", StatusLive` in the `:browser` scope; a small nav link between `/`
  and `/status`.

New movies appear on an already-open dashboard within one tick via their first transition's
broadcast; the mount seed shows everything on load. We therefore **skip** an add-time
broadcast in `add_to_watchlist/1` (the existing `transition/2` choke-point stays the only
broadcaster).

### 3.5 Schema / migration

Add `search_attempts` (mirrors `import_attempts`):

- Migration: `add :search_attempts, :integer, default: 0, null: false`.
- `Movie` schema: `field :search_attempts, :integer, default: 0`.
- `Movie.transition_changeset/2`: **add `:search_attempts` to the `cast` list** (load-bearing
  — see §3.2). Update `Catalog.transition/2`'s docstring to list the new castable field.
- Add `:search_failed` to the `@statuses` enum list (no DB migration).

## 4. State machine (after Phase 5)

| From | To | Trigger | Auto? |
|---|---|---|---|
| — | `:requested` | `add_to_watchlist/1` | user UI |
| `:requested` | `:searching` | Poller → `Download.start/1` resolves imdb + claims | **yes (new)** |
| `:requested`/`:searching` | same (retry, ++`search_attempts`) | transient error, due per backoff, attempts < 10 | **yes (new)** |
| `:requested`/`:searching` | `:no_match` | scorer `:no_match`/zero results, or `:no_imdb_id` | **yes (new)** |
| `:requested`/`:searching` | `:search_failed` | `:unsupported_download_url`, or `search_attempts` ≥ 10 | **yes (new)** |
| `:searching` | `:downloading` | client `add/1` `{:ok, id}` | **yes (new)** |
| `:downloading` | `:downloaded` | client status `:completed` + non-blank `content_path` | yes (exists) |
| `:downloaded` | `:available` | `Library.import_movie/1` `{:ok, dest}` | yes (exists) |
| `:downloaded`/`:downloading` | `:import_failed` | permanent import error or `import_attempts` ≥ 10 | yes (exists) |

Terminal: `:available`, `:no_match`, `:search_failed`, `:import_failed`.

## 5. Files

**Change:**
- `priv/repo/migrations/<ts>_add_search_attempts_to_movies.exs` — new migration.
- `lib/cinder/catalog/movie.ex` — add `:search_attempts` field + cast; add `:search_failed`
  to `@statuses`; refresh the `transition_changeset/2` docstring (it omits the attempts fields).
- `lib/cinder/catalog.ex` — add `get_movie_by_id/1` (`Repo.get(Movie, id)`, for `search_one`'s
  re-read); update `transition/2` docstring (castable fields).
- `lib/cinder/download.ex` — split `ensure_imdb_id/1`; `:no_imdb_id` → `{:error, :no_imdb_id}`;
  propagate `{:error, :tmdb_unavailable}`; update moduledoc ("Phase 5 wires it" → wired via
  the Poller). (Apply with the test update as one unit — §3.2.)
- `lib/cinder/download/poller.ex` — `search_requested/0`, `search_one/1`, `search_due?/2`;
  search-retry interval as a `start_link`/config option (default `@search_retry_after 60`,
  tests inject `0`); generalize `retry_or_fail`; add the search sweep last in `do_poll`;
  update moduledoc.
- `lib/cinder/download/client/qbittorrent.ex` — base32 btih in `btih/1` (non-raising,
  anchored, hex-first); HTTP(S) `.torrent` clause in `add/1` (fetch → `Torrent.infohash/1` →
  multipart upload → return hex hash).
- the indexer / TMDB / qBittorrent clients — explicit `receive_timeout` if missing (§3.2).
- `lib/cinder_web/components/core_components.ex` (or a small shared module) —
  `movie_status_badge/1`; use it from `WatchlistLive` too.
- `lib/cinder_web/router.ex` — `live "/status", StatusLive`.
- a layout/page nav link between `/` and `/status`.

**Create:**
- `lib/cinder/download/torrent.ex` — `Cinder.Download.Torrent.infohash/1` (bencode `info`-span
  → SHA-1 → hex).
- `lib/cinder_web/live/status_live.ex` — the dashboard.
- `test/support/fixtures/` (or inline-constructed) — a small valid `.torrent` byte fixture for
  the infohash test.
- `docs/phase-5-smoke-test.md` — env vars + checklist + hazards (§6).

## 6. Live smoke test (the user runs this when services are up)

`runtime.exs` already reads these env vars in **all** environments, applying config only when
present:

| Var | For |
|---|---|
| `TMDB_API_TOKEN` | TMDB bearer token |
| `QBITTORRENT_URL` / `QBITTORRENT_USERNAME` / `QBITTORRENT_PASSWORD` | qBittorrent Web API |
| `JELLYFIN_URL` / `JELLYFIN_API_KEY` | Jellyfin scan |
| `LIBRARY_PATH` | hardlink destination (Jellyfin library root) |

Prowlarr (`base_url`, `api_key`) is configured under
`config :cinder, Cinder.Acquisition.Indexer.Prowlarr`; the doc notes how to set it (an
env-var addition to `runtime.exs` if not already present).

**Checklist / known hazards to verify during the live run:**

1. **Release handoff** (§3.3). magnet (hex + base32) and HTTP `.torrent` URLs are handled; a
   movie parking `:search_failed` despite a release existing means either a malformed/HTML
   "torrent" response or a v2-only (SHA-256) torrent — `:search_failed` is visibly *distinct*
   from `:no_match`, and the logged reason says which.
2. **Hardlink requires the same filesystem.** `Filesystem.Disk.ln` is `File.ln` (a hard
   link). `LIBRARY_PATH` must be on the same filesystem as qBittorrent's download dir, or
   every import fails transiently and burns all 10 retries before parking `:import_failed`.
3. **Jellyfin scan is unvalidated against a real instance.** `MediaServer.Jellyfin.scan/0`
   (POST `/Library/Refresh`, `x-emby-token` header) is mock-tested only; the live run is the
   first real call — endpoint/auth header may need adjustment.
4. **Manually re-requesting a parked movie** needs its `search_attempts`/`import_attempts`
   reset (no retry UI yet — §3.2).

**Done (live):** request one real movie in the UI, watch it reach `:available` on `/status`
and land in Jellyfin.

## 7. Testing strategy (this session — all mocked, no network)

- **End-to-end auto-loop** (core proof): insert a `:requested` movie (with `imdb_id` set, to
  skip TMDB resolution); stub Indexer/Client/MediaServer/Filesystem for success; call
  `Poller.poll()` **repeatedly** until `:available` (search runs last, so ≥2 ticks) and assert
  the movie reaches `:available` **with no manual `Download.start/1` call** — proving the
  wiring. (`set_mox_global`, `async: false`, mirroring `poller_test.exs`.) Assert
  `search_attempts` stays 0 on the happy path.
- **`search_one` happy/terminal classification:** `{:ok, %{status: :downloading}}` → no
  retry; scorer no-match (indexer `{:ok, []}`) → `:no_match` with `search_attempts == 0` (no
  retry).
- **Backoff gating** (interval > 0): a movie that just failed (`search_attempts > 0`, fresh
  `updated_at`) is **not** re-attempted on the next `Poller.poll()`; after back-dating its
  `updated_at` past the interval (`Repo.update_all(..., set: [updated_at: <61 s ago>])`), the
  next poll **does** re-attempt it. This proves `search_due?/2`.
- **Bounded search retry** (start the Poller with search interval `0`, so every poll is due):
  a persistently transient indexer/client error climbs `search_attempts` across 10
  `Poller.poll()` calls and parks **`:search_failed`** on the 10th — mirroring the existing
  import-bound test (`poller_test.exs`), no wall-clock waits. This test also proves the
  `:search_attempts` cast-list line (without it the counter never persists and the loop never
  parks).
- **Permanent search errors:** `{:error, :unsupported_download_url}` → `:search_failed`
  immediately; genuinely-missing imdb (`get_movie` → `{:ok, %{imdb_id: nil}}`) → `:no_match`
  immediately; transient TMDB (`get_movie` → `{:error, _}`) → retried (stays `:requested`,
  `search_attempts` climbs).
- **base32 magnet round-trip:** `QBittorrent.add/1` (via `Req.Test`) returns the correct
  **lowercase-hex** hash for a base32 magnet; a separate assertion that `status/1` queries
  with that same hash. Include a lowercase-base32 fixture (must not raise).
- **`Torrent.infohash/1`:** construct bencode bytes `d…4:info<info-bytes>…e` in the test and
  assert the result equals `Base.encode16(:crypto.hash(:sha, <info-bytes>), case: :lower)` —
  proving it SHA-1s the *original* info span, not a re-encode; plus malformed input →
  `{:error, :bad_torrent}` (no raise).
- **`.torrent` add round-trip:** stub two `Req.Test` calls — the GET returning the fixture
  `.torrent` bytes and the qBittorrent add returning `"Ok."` — and assert `add/1` returns the
  infohash that `Torrent.infohash/1` computes for that fixture; a fetch error → `{:error, _}`
  (transient); an HTML body → `{:error, :bad_torrent}`.
- **StatusLive:** renders seeded movies with colour-coded badges; a `{:movie_updated, movie}`
  broadcast updates an existing row (insert before mount → seed → transition → assert) and
  prepends a not-yet-present movie (add after mount → transition → assert), following
  `watchlist_live_test.exs`'s pattern (the LiveView subscribes in its own `mount`; the test
  triggers via `Catalog.transition/2`).
- **Update existing tests:**
  - `download_test.exs`: the "parks at `:no_match` when imdb can't be resolved" test now
    asserts `{:error, :no_imdb_id}` from `start/1` **and** the movie remains `:requested`
    (the `:searching` write never happens); add a transient-TMDB case asserting
    `{:error, :tmdb_unavailable}`.
  - `poller_test.exs` "full state machine" test: drop the manual `Download.start/1` call — the
    new auto-loop test covers the trigger; keep a focused `Download.start/1` unit test in
    `download_test.exs`.

## 8. Done when (this session)

`mix test` is green (conventions + all new/updated tests above pass), the four behaviours
remain mocked in test, and the smoke-test doc is delivered. The live smoke run is handed to
the user as the final, out-of-session step that closes Phase 5.

## 9. Changes from the first-draft (approved) design, post-council

The council (architecture/correctness, implementation/testability, contrarian red-team)
surfaced these; each traces to a concrete finding:

1. **New `:search_failed` terminal** instead of reusing `:no_match` (§3.2). Reusing
   `:no_match` made an operator-actionable failure (bad creds, unsupported URL, exhausted
   outage retries) indistinguishable from "no release exists" — defeating the dashboard's
   purpose. *Reverses an approved decision; flagged for the user.*
2. **Backoff on search retries** (§3.2) instead of literal every-5s "mirror Phase 4."
   Search hits external rate-limited services and a 50 s window false-parks during real
   outages. *Diverges from the approved "mirror Phase 4 exactly"; flagged.*
3. **`ensure_imdb_id` transient/permanent split** (§3.2) — fixes a latent bug where a TMDB
   outage permanently parked a movie.
4. **Search sweep runs last; no one-tick cascade claim** (§3.1) — avoids add-then-poll waste
   and makes the e2e test honest (multi-poll).
5. **base32 decode hardened** (§3.3) — non-raising + anchored + exact-length, or a bad magnet
   raises through `isolate/2` and strands the movie.
6. **HTTP timeouts required on the search path** (§3.2) — a hung indexer would otherwise wedge
   the shared tick that also drives import.
7. **Shared `movie_status_badge/1`** (§3.4) — `/` already renders status; don't ship two
   divergent badge renderings.
8. **`.torrent` URLs pulled INTO scope** (§3.3) — the red-team argued `.torrent`-only
   indexers are common enough to fail the live smoke test. The user opted in. Implemented via
   a self-computed v1 infohash (`Cinder.Download.Torrent`, bencode `info`-span → SHA-1) +
   multipart upload — chosen over the council's post-add `/torrents/info` scan because it is
   deterministic and unit-testable with mocks, whereas the scan only proves out live.

**Round 2** (re-review of the revised spec) caught four implementation-level defects, now
fixed: the generalized `retry_or_fail` map literal had keyword-before-`=>` order (a compile
error) → dynamic key first; `search_one`'s stale struct would revert `:searching → :requested`
→ spelled out `search_one/1` with a re-read (`Catalog.get_movie_by_id/1`); the wall-clock
backoff made the bounded-retry test impossible → the retry interval is now an injectable
option (tests use `0`); and the illustrative base32 `cond` would raise → replaced with a
compiling `case`. Also: no client sets a `receive_timeout` today → added a 15 s default.
