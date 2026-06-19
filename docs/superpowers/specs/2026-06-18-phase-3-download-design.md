# Phase 3 — Download (hand off + track) — Design

Status: approved 2026-06-18. Complements `ROADMAP.md` Phase 3; this doc records the decisions and
concrete shapes the roadmap leaves open. Movies-only vertical slice.

Council review: 2 rounds (Claude-only harness — perspective-diverse seats across Claude tiers:
R1 = Opus architect/correctness + Sonnet implementation/qBit-API + Opus contrarian; R2 = Opus
correctness-verify + Sonnet qBit-verify). Consensus **SOUND-WITH-FIXES**, all folded in. R1 found
1 blocker — the `start/1` `with`/`else` was non-exhaustive (a failed `:searching` transition would
raise `WithClauseError`) — plus majors: the "full state machine" was split into two half-tests that
never crossed the `start/1 → Poller` `download_id` seam (added a cross-seam test); and several qBit
Web API v2 facts were wrong (`/torrents/add` needs `multipart/form-data` not urlencoded; the `SID`
cookie isn't auto-threaded by Req — must be extracted from `set-cookie` and re-sent; login needs a
`Referer`; the magnet hash must be lowercased; `moving` belongs in the completed bucket; Prowlarr
prefers `.torrent` `downloadUrl`s the magnet-hash path can't handle). Minors: dropped a redundant
`validate_inclusion` (Ecto.Enum enforces it), pinned the poller test to `use Cinder.DataCase,
async: false` + `set_mox_global` with the shared-Sandbox/global-Mox rationale, specified the
crash-recovery wait (`GenServer.whereis` for a new pid). R2 verified every fix against the actual
source and cleared them, leaving only three prose tightenings (full-machine test must
`start_supervised!(Poller)`; `ensure_imdb_id/1` swallows TMDB errors into `:no_imdb_id`; the qBit
status third bucket is a catch-all) — all applied. No NEEDS-REWORK. Residual (deferred to Phase 5,
correctly): live qBit validation — Referer enforcement on localhost installs, base32 magnet hashes,
`.torrent`-URL→hash resolution, `pausedUP`-as-final-state.

## Summary

Phase 3 delivers the **download half** of the pipeline as two independently-testable pieces that
mirror the roadmap's title, "hand off + track":

- **`Cinder.Download.start/1`** — the *hand-off* (a plain function): `:requested → :searching →
  :downloading` (or `:no_match`), composing `Acquisition.best_release` + `Download.Client.add`.
- **`Cinder.Download.Poller`** — the *tracker* (a supervised `GenServer`): polls active downloads
  and advances `:downloading → :downloaded`, broadcasting every change over PubSub.

Plus the real **`Cinder.Download.Client.QBittorrent`** impl, the `Movie` schema additions the
pipeline needs, and a one-line `WatchlistLive` subscription so the status badge updates live.

Neither `start/1` nor the poller is auto-triggered from `:requested` yet. That wiring — "a
`:requested` movie flows automatically … with no manual steps" — is **Phase 5**, consistent with
how Phase 2's `Acquisition.best_release/1` was built and unit-tested but left un-wired.

## Decisions (locked — user-approved 2026-06-18)

1. **Split build; auto-trigger deferred to Phase 5.** Build and fully test both `start/1` (hand-off)
   and `Poller` (tracking) — including crash recovery and PubSub — but do **not** auto-call them
   from a `:requested` movie. Phase 5 connects the trigger + import + dashboard + real service
   configs. This matches the established repo pattern (Phase 2 mechanics built, wired in Phase 5).

2. **`:no_match` is a terminal status.** When `Acquisition.best_release` returns `:no_match` (no
   result survives the scorer), the movie parks in a new `:no_match` status — visible in the
   watchlist badge, not retried automatically. Added to the `Movie` status enum; no migration
   (Ecto.Enum is string-backed). Re-search is a deliberate later concern, out of scope here.

3. **`imdb_id` is persisted on `Movie` and lazy-resolved by `start/1`.** Add an `imdb_id` column.
   `start/1` uses `movie.imdb_id`; if nil, it calls a new thin `Catalog.get_movie/1` (wraps the
   `TMDB.get_movie` behaviour) to fetch it, and persists it as part of the `→ :searching`
   transition (one write, no extra broadcast). Phase 1's add flow is **untouched**. `start/1` is
   self-sufficient when called (one Download test path mocks TMDB). If no imdb_id can be resolved,
   the movie goes to `:no_match` (can't search ⇒ no match).

## Architecture

The pipeline-flow dependency direction is respected: `Download` depends on its upstreams
`Acquisition` (release search) and `Catalog` (the `Movie` system of record). Nothing upstream
depends on `Download`.

### `Cinder.Download` (new context — the hand-off)

```elixir
@doc "Hand off a :requested movie to the download client. Returns {:ok, movie} | {:error, reason}."
def start(%Movie{} = movie) do
  with {:ok, imdb_id} <- ensure_imdb_id(movie),
       {:ok, movie}   <- Catalog.transition(movie, %{status: :searching, imdb_id: imdb_id}) do
    case Acquisition.best_release(imdb_id) do
      {:ok, release} ->
        case client().add(release) do
          {:ok, download_id} ->
            Catalog.transition(movie, %{status: :downloading, download_id: download_id})
          {:error, _} = err ->
            err                       # release found but hand-off failed; movie stays :searching
        end

      :no_match ->
        Catalog.transition(movie, %{status: :no_match})

      {:error, _} = err ->
        err                           # indexer failure; movie stays :searching
    end
  else
    :no_imdb_id        -> Catalog.transition(movie, %{status: :no_match})
    {:error, _} = err  -> err         # a failed :searching transition propagates — never falls through
  end
end

defp client, do: Application.fetch_env!(:cinder, :download_client)
```

- `ensure_imdb_id/1`: present ⇒ `{:ok, id}`; nil ⇒ `Catalog.get_movie(movie.tmdb_id)`. It
  **collapses both** a TMDB `{:error, _}` **and** an `{:ok, %{imdb_id: nil}}` into the bare
  `:no_imdb_id` atom — TMDB errors are swallowed here, not propagated, so per Decision 3 the movie
  parks at `:no_match` rather than returning `{:error, _}` to the caller.
- Runtime client resolution via `Application.fetch_env!/2` (mirrors `Acquisition.indexer/0`; using
  `compile_env!` would inline the runtime-defined Mox module and warn under `--warnings-as-errors`).
- **Error handling (deliberate, slice-scoped):** indexer error or `Client.add` error leaves the
  movie in `:searching` and returns `{:error, reason}` to the caller. No "download-failed" state
  and no retry/backoff — single-household, manual intervention is acceptable; revisit if it bites.
  `// ponytail:` comment notes this ceiling.

### `Cinder.Download.Poller` (new — the tracker, supervised GenServer)

Stateless w.r.t. the work itself: each tick re-derives the active set from the DB. **That is the
crash-recovery story** — restart ⇒ re-read DB ⇒ continue; no in-flight state is lost.

```elixir
def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)

def poll(server \\ __MODULE__), do: GenServer.call(server, :poll)   # synchronous tick, for tests

@impl true
def init(opts) do
  {:ok, %{interval: opts[:interval] || config_interval()}, {:continue, :schedule}}
end

# handle_info(:poll, …)  -> do_poll(); schedule(); {:noreply, state}
# handle_call(:poll, _, …) -> do_poll(); {:reply, :ok, state}   # no reschedule; deterministic in tests

defp do_poll do
  Catalog.list_by_status(:downloading)
  |> Enum.each(fn movie ->
    case client().status(movie.download_id) do
      {:ok, %{state: :completed}} -> Catalog.transition(movie, %{status: :downloaded})
      _ -> :ok       # still downloading / stalled / error: leave it; retried next tick
    end
  end)
end
```

- **Interval** from `config :cinder, Cinder.Download.Poller, interval: …` (dev default 5_000 ms);
  overridable per-instance via `start_link` opt (tests pass a large interval so the background timer
  never races the synchronous `poll/1`).
- `do_poll/0` is the single pass shared by the scheduled `handle_info(:poll, …)` (which reschedules)
  and the test-facing `handle_call(:poll, …)` (which does not).
- A non-`:completed` status (`:downloading`/`:error`/stalled) is left as-is and retried next tick;
  no download-failure state (see slice-scoped error handling above).

### Supervision / test isolation

- `Poller` is added to `Cinder.Application`'s tree, **gated** so it does not start under `:test`:

  ```elixir
  children = base_children() ++ poller_child()
  defp poller_child do
    if Application.get_env(:cinder, :start_poller, true), do: [Cinder.Download.Poller], else: []
  end
  ```

  `config/test.exs` sets `config :cinder, start_poller: false` — the app-level poller must not run
  in tests (it would race Mox/Sandbox). Mirrors the endpoint's `server: false` idiom.
- Poller tests **`use Cinder.DataCase, async: false`** (not `ExUnit.Case`): `async: false` makes
  `DataCase.setup_sandbox` start the Sandbox owner in **shared** mode (`shared: not async`), and the
  test adds `setup :set_mox_global`. Shared Sandbox = the test process owns the one connection and
  every other process (including a *restarted* poller pid with no allowance of its own) falls
  through to it; Mox global = expectations are visible from any pid. Together they give the poller —
  original **and** restarted — both DB access and the mock. Both require `async: false`; that's why
  it's pinned. (Single SQLite writer: the synchronous `Poller.poll/1` `GenServer.call` blocks the
  test until the poller's write completes, so the poller's and test's writes never interleave.)
- The crash-recovery test starts its **own** supervised instance via `start_supervised!(Poller)`
  (default `restart: :permanent`, so a killed child is restarted under ExUnit's supervisor). After
  `Process.exit(pid, :kill)`, wait deterministically by polling `GenServer.whereis(Poller)` until it
  returns a pid `!= pid` (the restart re-registers the same name) — not a blind sleep.

### `Cinder.Catalog` additions (owns `Movie`)

- `Movie`: add `field :imdb_id, :string` and `field :download_id, :string`; add `:no_match` to the
  status enum (and update the moduledoc's status-progression line to name the `:no_match` off-ramp);
  add `transition_changeset/2` casting `[:status, :download_id, :imdb_id]` with
  `validate_required([:status])`. **No `validate_inclusion(:status, …)`** — `Ecto.Enum` already
  rejects out-of-enum atoms at cast time, so the extra validation is dead code (council MINOR). The
  create `changeset/2` is unchanged except it may also cast `:imdb_id` (harmless; search adds carry
  nil).
- `Catalog.list_by_status/1` — `Repo.all(from m in Movie, where: m.status == ^status)`.
- `Catalog.transition/2` — applies `transition_changeset`, `Repo.update`, and on success
  **broadcasts** `{:movie_updated, movie}` on topic `"movies"`. Single choke-point so every state
  change (from `start/1` or the poller) emits exactly once. Returns `{:ok, movie} | {:error, cs}`.
- `Catalog.get_movie/1` — `tmdb().get_movie(tmdb_id)` (thin wrapper; the CLAUDE.md note that
  "`Catalog.get_movie/1` carries `imdb_id` through" finally has its function).
- `Catalog.subscribe/0` — `Phoenix.PubSub.subscribe(Cinder.PubSub, "movies")`.

### Live UI — `CinderWeb.WatchlistLive`

- `mount/3`: `if connected?(socket), do: Catalog.subscribe()` **before** the
  `Catalog.list_watchlist()` read (subscribe-then-read, so a transition firing between read and
  subscribe isn't lost). `// ponytail: subscribe-before-read closes the gap; full reconciliation is
  Phase 5's dashboard concern`.
- `handle_info({:movie_updated, movie}, socket)`: replace the matching movie in the `watchlist`
  assign (`Enum.map`, match on `id`); the existing `{m.status}` badge re-renders. If the movie
  isn't in the current list, ignore. No markup change beyond the badge already present.

### Real client — `Cinder.Download.Client.QBittorrent`

Implements `Cinder.Download.Client` (`add/1`, `status/1`), backed by `Req`, config-read
`base_url`/`username`/`password`/`req_options` like `Indexer.Prowlarr` — but the auth flow is
**stateful** (login → cookie → action), unlike anything in the codebase so far. The council
corrected several qBit facts the first draft got wrong; they're pinned here:

- **Auth (`login/0 → {:ok, sid} | {:error, term}`):** `POST /api/v2/auth/login` with
  `form: [username: …, password: …]` **and a `Referer: <base_url>` header** (qBit's CSRF guard
  rejects logins whose `Referer`/`Origin` doesn't match the host — default installs return body
  `"Fails."` without it). The `SID` is **not** auto-threaded: Req has no persistent cookie jar and
  `add/1`/`status/1` each build a fresh `Req`. So `login/0` extracts `SID` from the response
  `set-cookie` header and returns it; the action request then passes `Cookie: SID=<sid>` explicitly.
  Login **per call** — `// ponytail: re-login each call; add a cached cookie jar if volume matters`.
- **`add/1`:** `POST /api/v2/torrents/add` as **`form_multipart: [urls: download_url]`** — this
  endpoint requires `multipart/form-data`; Req's `form:` (urlencoded) is rejected. qBit's add does
  **not** return a hash. The hash is parsed from a **magnet** `download_url`
  (`xt=urn:btih:<hash>`), **lowercased** (qBit's `?hashes=` lookup is case-sensitive lowercase hex),
  and returned as `{:ok, hash}`. **Non-magnet `download_url`s** (Prowlarr's `normalize/1` returns
  `downloadUrl || magnetUrl`, so a `.torrent` URL is the *common* case) cannot be hashed this way:
  `add/1` returns `{:error, :unsupported_download_url}` for them in Phase 3.
  `// ponytail: magnet-only hash extraction; base32 btih and .torrent-URL→hash (info-by-name
  lookup) are Phase-5 live concerns`. Non-200 / `"Fails."` ⇒ `{:error, …}`.
- **`status/1`:** `GET /api/v2/torrents/info?hashes=<hash>` ⇒ first torrent's raw `state`/`progress`
  normalized to `{:ok, %{state: :downloading | :completed | :error, progress: float}}`. Mapping:
  `uploading|stalledUP|pausedUP|forcedUP|queuedUP|checkingUP|moving` (or `progress == 1.0`) ⇒
  `:completed` (**`moving`** = post-download relocation, included per council so a completed torrent
  isn't read as still-downloading); `error|missingFiles` ⇒ `:error`; everything else
  (`downloading|metaDL|stalledDL|queuedDL|forcedDL|checkingDL|checkingResumeData|allocating|paused
  DL`) ⇒ `:downloading`. Implement the third bucket as a **catch-all `_ -> :downloading`**, not an
  explicit enumeration, so unlisted/future qBit states (e.g. `forcedMetaDL`, `unknownState`) bucket
  safely instead of falling through. Empty result ⇒ `{:error, :not_found}`. The poller only depends
  on `state`; `progress` is carried for the UI later.

These qBit Web API v2 facts are asserted from documentation, not a live instance; the unit test
below is a **shape sanity-check** (does the impl match our model of qBit), **re-validated live in
Phase 5** (the live-smoke landmines: Referer enforcement on a localhost install, `pausedUP`-as-final
state, base32 magnet hashes, `.torrent`-URL hashing).

## Config

- `config/config.exs`: `config :cinder, download_client: Cinder.Download.Client.QBittorrent` (the
  `:test` override to `Cinder.Download.ClientMock` already exists).
- `config/config.exs`: `config :cinder, Cinder.Download.Poller, interval: 5_000`.
- `config/test.exs`: `config :cinder, start_poller: false` and a `Req.Test` stub seam for the
  QBittorrent impl (`config :cinder, Cinder.Download.Client.QBittorrent, req_options: [plug:
  {Req.Test, Cinder.QBittorrentStub}], username: "test", password: "test"`).
- `config/runtime.exs`: real qBit `base_url`/`username`/`password` from env (placeholders now;
  exercised in Phase 5). No real network in dev/test.

## Migration

`alter table(:movies)` — `add :imdb_id, :string` and `add :download_id, :string` (both nullable).
`:no_match` enum value needs no migration (string-backed).

## Tests (every new behaviour gets one; no network — Req.Test / Mox only)

- **`test/cinder/download_test.exs`** — `start/1`:
  - happy path: `:requested` (with imdb_id) → `:downloading` + `download_id` set (IndexerMock +
    ClientMock); asserts the two transitions.
  - lazy imdb resolution: `:requested` with `imdb_id == nil` → TMDBMock `get_movie` supplies it →
    persisted on the `:searching` transition → proceeds.
  - `:no_match`: IndexerMock yields no surviving release → movie ends `:no_match`.
  - `Client.add` error ⇒ `{:error, …}`, movie stays `:searching`.
- **`test/cinder/download/poller_test.exs`** (`use Cinder.DataCase, async: false`,
  `setup :set_mox_global`):
  - **full state machine — the literal "Done when" (council MAJOR, added):** `start_supervised!(Poller)`
    (no app-level poller runs in test, so `Poller.poll/1`'s default `GenServer.call(__MODULE__, …)`
    needs a started instance); insert a `:requested` movie (with `imdb_id`); `Download.start(movie)`
    with IndexerMock → a magnet release and ClientMock `add` → `{:ok, hash}`; then `Poller.poll/1`
    with ClientMock `status(hash)` → `:completed` **for that same hash**. Assert the movie walks
    `:requested → :searching →
    :downloading (download_id == hash) → :downloaded`. This is the one test that crosses the
    `start/1 → Poller` seam — the `download_id` handoff is the integration contract and must not
    fall in the gap between two half-tests.
  - poller-only: insert a `:downloading` movie (with a `download_id`); a synchronous `Poller.poll/1`
    (ClientMock → `:completed`) advances it to `:downloaded`; assert the broadcast
    (`Catalog.subscribe()` then `assert_receive {:movie_updated, %{status: :downloaded}}`). Also a
    non-`:completed` status leaves it `:downloading`.
  - **crash recovery (the OTP payoff):** `start_supervised!(Poller)`; insert a `:downloading`
    movie; `Process.exit(pid, :kill)`; poll `GenServer.whereis(Poller)` for a new pid `!= pid`;
    `Poller.poll/1` still advances the movie to `:downloaded` — proving state is re-derived from
    the DB, not held in the dead process (a stateful poller would fail this).
- **`test/cinder/download/client/qbittorrent_test.exs`** (Req.Test `stub/2`, single plug branching
  on `conn.request_path` to serve `login` then the action in order) — a **shape sanity-check**, not
  proof of live correctness (re-validated in Phase 5): login+`add` of a magnet returns the
  lowercased btih hash; a non-magnet `download_url` ⇒ `{:error, :unsupported_download_url}`;
  `status/1` normalizes a `:completed` and a `:downloading` qBit payload; error mapping (`"Fails."`/
  non-200 ⇒ `{:error, …}`, empty info ⇒ `:not_found`).
- **`test/cinder_web/live/watchlist_live_test.exs`** — a `{:movie_updated, movie}` broadcast (or a
  real `Catalog.transition`) updates the rendered badge for that movie live.

## Files

**Create:** `lib/cinder/download.ex`, `lib/cinder/download/poller.ex`,
`lib/cinder/download/client/qbittorrent.ex`, `priv/repo/migrations/*_add_download_fields.exs`,
the 4 test files above.

**Modify:** `lib/cinder/catalog/movie.ex`, `lib/cinder/catalog.ex`, `lib/cinder/application.ex`,
`lib/cinder_web/live/watchlist_live.ex`, `config/config.exs`, `config/test.exs`,
`config/runtime.exs`.

## Done-when (from ROADMAP, restated)

- `mix test` (the alias: compile `--warnings-as-errors`, `format --check-formatted`,
  `credo --strict`, suite) fully green.
- A test drives a movie through the full state machine (`:requested → :searching → :downloading →
  :downloaded`) with a mocked client.
- A test asserts the poller restarts cleanly after a simulated crash and still advances work.

## Deliberate tradeoffs (surfaced per council; decided, not hidden)

- **WatchlistLive subscription is kept, not deferred to Phase 5.** The contrarian flagged it as
  Phase-5 dashboard scope. Overruled: ROADMAP Phase 3's **Build** list literally says "Broadcast
  state changes over Phoenix.PubSub **so the LiveView updates live**" — wiring the *existing*
  watchlist view to update its badge is that deliverable. Phase 5's "status **dashboard** LiveView"
  is a separate, comprehensive view. Cutting the subscription would broadcast into the void and drop
  a named Build item. It's ~2 lines + one test.
- **The QBittorrent impl is kept, not deferred.** ROADMAP Phase 3 Build names "qBittorrent … impl".
  The Phase 2 precedent built the real Prowlarr impl + a Req.Test test, un-wired. We follow it — but
  honestly frame the test as a shape-check re-validated live in Phase 5 (it asserts the code matches
  our model of qBit, not qBit itself).
- **Pipeline state lives in `Catalog`.** `list_by_status/1`, `transition/2` (the broadcast
  choke-point), and `subscribe/0` go in `Catalog` because it owns the `Movie` schema and is the
  system of record. This makes `Download` depend *up* into `Catalog`, and makes `Catalog` the home
  of the broadcast contract — a deliberate coupling, not a god-context by accident. A separate
  "movie lifecycle" context would be over-engineering for the slice.
- **`Download` transitively depends on TMDB** (via `Catalog.get_movie/1` for lazy `imdb_id`). Named
  because it's non-obvious for a context called "Download." Justified: Phase 1's add persists from
  TMDB *search* results, which carry `imdb_id: nil`, so the lazy path is likely the *common* path,
  not an edge — and Decision 3 keeps Phase 1's add flow untouched.
- **`:searching` is now an ambiguous state** — "actively handing off" vs "wedged after an
  indexer/add error" (since errors leave the movie there with no retry). Inert in Phase 3 (nothing
  auto-runs `start/1`); flagged because **Phase 5's auto-trigger must disambiguate** in-flight vs
  wedged `:searching` movies.
- **Single global `"movies"` PubSub topic** (not per-movie), and **`add_to_watchlist` does not
  broadcast** (the adder updates its own assign; a second tab won't see a brand-new movie until
  reload). Both are correct YAGNI calls at single-household scale — recorded, not discovered.

## Out of scope (Phase 5 or later)

Auto-trigger from `:requested`; the Library/import step (`:downloaded → :available`); the status
dashboard; real Prowlarr/qBittorrent/Jellyfin configs and the live smoke test; download-failure
states, retries/backoff, and re-search of `:no_match`; session-cookie caching for qBit;
`.torrent`-URL (non-magnet) hash resolution.
