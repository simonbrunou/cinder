# Cinder — Build Roadmap

A single-household, self-hosted replacement for the Sonarr/Radarr/Seerr loop, built on
Phoenix/LiveView. This roadmap covers the **movies-only vertical slice**: request a movie →
find the best release → download it → import it into Jellyfin. TV, quality upgrades, and
multi-user are deliberately out of scope until the slice is solid (see *Parked*, bottom).

## How to run this with Claude Code

- Do **one phase per session**. `/clear` between phases so context stays clean.
- Start each phase in **plan mode** to scope it, then execute.
- **Commit at every phase boundary.** A phase is not done until its "Done when" block is green.
- Each phase's "Done when" is written so it can be pasted into `/goal` if you want an
  autonomous run for that phase.
- The Elixir tooling installed in Phase 0 runs compile/format/credo/test hooks around edits —
  that's what makes any goal run self-correcting. Don't skip Phase 0.

## Conventions (enforced every phase)

- `mix compile --warnings-as-errors` clean.
- `mix format --check-formatted` passes.
- `mix credo --strict` reports no issues.
- `mix test` fully green; every new behaviour gets a test.
- All external services (TMDB, Prowlarr, qBittorrent, Jellyfin) sit behind a **behaviour**
  (`@callback` specs) so they can be mocked with **Mox**. Tests never hit the network or a
  real service.
- HTTP via `Req`. DB via Ecto + `ecto_sqlite3` (single-household scale; swap to Postgres
  later if multi-process write contention ever becomes real).
- License: GPL-3.0 (see `LICENSE`).

---

## Phase 0 — Scaffold, tooling & guardrails

Do these in order. Steps 2–4 set up the Elixir Claude Code tooling, and they change how every
later phase runs, so finish Phase 0 before touching Phase 1.

**1. Scaffold.**
- `mix phx.new cinder --database sqlite3` (or Postgres; adjust later phases).
- `cd cinder`, init git, first commit.
- Add dev deps: `credo`, `mox`. Add a `test` alias in `mix.exs` that runs
  `compile --warnings-as-errors`, `format --check-formatted`, `credo --strict`, `test`.
  This alias is the source of truth every "Done when" block checks against.
- `LICENSE` (GPL-3.0).

**2. Install the `claude` hex library (one-shot tooling base).**
```
mix igniter.install claude
```
This generates `.claude.exs`, writes `.claude/settings.json` hooks, generates subagents and
slash commands, syncs dependency usage rules into `CLAUDE.md`, and creates `.mcp.json`. (Note:
the library is confusingly just named `claude`.)

**3. Configure `.claude.exs`.** Replace the generated file with this — fast checks on every
edit, the heavier credo+test pass when Claude finishes a turn (non-blocking, so it surfaces
failures for self-correction without infinite-loop risk), and Tidewave registered as an MCP:
```elixir
%{
  hooks: %{
    # fast, every file edit
    post_tool_use: [:compile, :format],
    # turn end: heavier checks, informational so Claude self-corrects
    stop: [
      :compile,
      :format,
      {"credo --strict", blocking?: false},
      {"test", blocking?: false}
    ],
    subagent_stop: [:compile, :format],
    # only fires on git commit commands
    pre_tool_use: [:compile, :format, :unused_deps]
  },
  mcp_servers: [:tidewave],
  subagents: []
}
```
Then `mix claude.install` to apply. (Atoms expand to mix tasks: `:compile` →
`mix compile --warnings-as-errors`, `:format` → `mix format --check-formatted`; a string like
`"test"` runs `mix test`.)

**4. Wire Tidewave (runtime intelligence MCP).**
- Add the dep: `{:tidewave, "~> 0.6", only: :dev}`, then `mix deps.get`.
- In `lib/cinder_web/endpoint.ex`, immediately **above** the `if code_reloading? do` block:
  ```elixir
  if Mix.env() == :dev do
    plug Tidewave
  end
  ```
- With `:tidewave` already in `mcp_servers`, `mix claude.install` writes it into `.mcp.json`.
  (Manual equivalent if needed: `claude mcp add --transport http tidewave
  http://localhost:4000/tidewave/mcp`.)
- Start the app, then `/mcp` in Claude Code should show tidewave "connected." Now Claude can
  `project_eval`, `execute_sql_query`, `get_ecto_schemas`, `get_logs`, and `get_docs` against
  the running app — use this throughout later phases instead of guessing.

**5. App-specific setup.**
- `CLAUDE.md`: usage rules are auto-synced between markers; add your project conventions
  *outside* the markers so syncs don't clobber them.
- Define the four client behaviours (`Cinder.Catalog.TMDB`, `Cinder.Acquisition.Indexer`,
  `Cinder.Download.Client`, `Cinder.Library.MediaServer`) as empty `@callback` contracts; wire
  Mox in `test/test_helper.exs`. Config selects the real impl in prod, the mock in test.
- Confirm Phoenix 1.8's bundled Tailwind + daisyUI renders.

**Optional:** add a plugin layer — `georgeguimaraes/claude-code-elixir` (modular: Expert LSP +
mix-format/compile/credo hooks) or the heavier `oliver-kriska/claude-elixir-phoenix` (agents +
`/phx:*` commands). Don't stack the heavy one on top of these hooks blindly; they overlap.

**Done when:** the project boots (`mix phx.server`), `mix test` (the alias) passes on an empty
suite, `/mcp` shows tidewave connected, and the four behaviours + their Mox mocks compile.

---

## Phase 1 — Catalog (discovery + watchlist)

**Context:** `Cinder.Catalog`

**Build:**
- `Cinder.Catalog.TMDB` behaviour + real impl (search, fetch details) + Mox mock.
- Ecto schema for a watchlisted movie (tmdb_id, title, year, poster, status enum:
  `:requested`).
- A LiveView: search box → results from TMDB → "Add" button → persists to watchlist →
  watchlist renders below. daisyUI components, real-time updates via LiveView assigns.

**Done when:** conventions pass + a test proves "search a title (mocked TMDB) and add it
persists a `:requested` movie," and the LiveView renders the watchlist.

---

## Phase 2 — Acquisition (find the best release)

**Context:** `Cinder.Acquisition`

**Build:**
- `Cinder.Acquisition.Indexer` behaviour (Torznab query against Prowlarr) + real impl + mock.
- A release parser module: extract resolution, codec, release group, size, language from a
  release name. (No mature Elixir lib exists — write a focused parser with a test fixture set.)
- A scorer with **explicit, configurable rules**: prefer 1080p, reject releases outside a
  size band, honour a blocklist. Returns the chosen release or `:no_match`.

**Done when:** conventions pass + tests select the expected release from fixture lists for:
the happy case, the all-too-large case (→ `:no_match`), and a blocklisted-group case. No
network in tests.

---

## Phase 3 — Download (hand off + track)

**Context:** `Cinder.Download`

**Build:**
- `Cinder.Download.Client` behaviour (qBittorrent: add release, report status) + impl + mock.
- A `GenServer` poller under the app supervisor that polls active downloads and advances
  state: `:requested → :searching → :downloading → :downloaded`.
- Broadcast state changes over Phoenix.PubSub so the LiveView updates live.

**Done when:** conventions pass + a test drives a movie through the full state machine with a
mocked client, **and** a test asserts the poller restarts cleanly after a simulated crash
(this is the OTP payoff — prove it).

---

## Phase 4 — Library (import into Jellyfin)

**Context:** `Cinder.Library`

**Build:**
- `Cinder.Library.MediaServer` behaviour (trigger scan) + Jellyfin impl + mock.
- On `:downloaded`: hardlink the file into the library, rename to Jellyfin's
  `Title (Year)/Title (Year).ext` scheme, trigger a scan, set status `:available`.
- Filesystem ops behind a thin behaviour too, so the import is testable without touching disk.

**Done when:** conventions pass + a test proves a completed download produces the correct
hardlink + rename + scan call against mocked FS and Jellyfin, and the movie ends `:available`.

---

## Phase 5 — Wire the loop + live smoke test

**Build:**
- End-to-end wiring: a `:requested` movie flows automatically through acquisition → download
  → import with no manual steps.
- A status dashboard LiveView: every movie with its live state, real-time via PubSub.
- Replace mock configs with real Prowlarr / qBittorrent / Jellyfin in dev config.

**Done when:** conventions pass **and** a manual live smoke test succeeds: request one real
movie and watch it land in Jellyfin. (Mocked tests prove wiring and logic; only a live run
proves your actual indexer returns what you expect.)

### Phase 5 — remaining to sign off

The core loop is validated live (2026-06-20): a real movie went `:requested → :available`,
imported as a true hardlink, scanned into Plex. See the live-validation report for the running
config and ops gotchas. Still open:

- **[done] Media-server scan is best-effort** — a failed scan no longer strands a correctly
  hardlinked movie at `:import_failed`; the import reaches `:available` and the server picks the
  file up on its next periodic scan. (`Cinder.Library.import_movie/1`.)
- **`/status` retry action** — a per-movie "retry" that clears a parked
  `:search_failed`/`:no_match`/`:import_failed` back to `:requested` with attempt counters reset
  (replaces the documented IEx reset). LiveView event + UI.
- **`/status` config-health** — a reachability ping per external service (indexer / download
  client / media server) so an unwired/unreachable dependency is visible on the dashboard instead
  of only in the logs.
- **Torrent path — live sign-off (needs homelab):** the live run went via Usenet/SABnzbd. Exercise
  a qBittorrent grab end-to-end — base32 magnet, `.torrent` URL fetch, `Cinder.Download.Torrent.infohash/1`
  status polling — and confirm a malformed/HTML "torrent" parks gracefully rather than looping.
- **`/status` visual check (needs homelab):** open the dashboard against the running instance and
  confirm badges advance live.
- **Deploy: no auto-migration (ops):** the release start command doesn't migrate and there's no
  Coolify pre-deploy hook — run `bin/cinder eval "Cinder.Release.migrate()"` after migration-bearing
  deploys, or wire a hook.

---

## Parked (explicitly out of scope for the slice)

TV / seasons / episode monitoring · RSS calendar for new episodes · quality upgrades and
cutoffs · multi-user auth and request approval · per-tracker quirks · notifications.

Revisit only after the movie loop has run reliably for a couple of weeks.
