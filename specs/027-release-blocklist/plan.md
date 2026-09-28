# Release Blocklist + Search-Exclusion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Kill the re-download loop the ROADMAP names as the top deferred item. A release that parks for a
*deterministic* or *exhausted-download* reason is re-searched on the next tick / on `/status` Retry and the **same**
release is re-grabbed, because nothing records which release failed. Fix it minimally: one `blocked_releases` table holding
a per-item set of failed release names, captured at the existing park sites and **excluded inside release selection** by
mirroring the Scorer's existing group `blocked?/2` mechanism. Covers movies and TV.

**Architecture (decisions locked):**

- **Identifier = the downcased `release_title` string.** The headline bug is re-grabbing the *exact* same release; the
  title is the stable per-indexer release name (the same string returned each tick). Per-group/per-resolution filtering
  already exists as the Scorer `:blocklist` config — don't duplicate it. Human-readable for debugging.
- **Capture is reactive, exclusion is proactive — the proactive filter is load-bearing.** Recording a failed release
  changes nothing on its own; the loop lives in *selection* re-picking it. So the title is read at search time and passed
  as a `release_blocklist` scorer opt (one extra `Enum.reject`), and recorded at the terminal park.
- **The Release only exists at `client.add` time**, so persist its name on the row through writes that already happen:
  `Movie.release_title` written inside the existing `:downloading` transition in `Download.add_to_client`; `Grab.release_title`
  written in `Catalog.create_grab`. Crash-safe, no poller state, no re-query.
- **Which park reasons block:** (movies) the already-classified `@permanent_import_errors`
  (`:no_file_path`, `:no_video_file`, `:wrong_audio_language`) **plus** the download-side failures that only reach `park`
  *after* exhausting all `@max_attempts` retries (`:download_error`, `:torrent_not_found`, `:no_content_path`). (TV) the
  deterministic `:no_files_matched` empty-import **plus** the symmetric exhausted download-side reasons. A reason that has
  burned 10 retries is, by definition, not transient — that is exactly the "repeatedly-failing torrents/usenet" the ROADMAP
  entry names. Pre-grab search errors (`:bad_torrent`, `:no_imdb_id`, `:no_match`) never stored a `release_title`, so the
  nil-guarded block is a no-op for them automatically.
- **Permanent, per-item scope (`movie_id` / `series_id`).** No TTL, no global/infohash scope, no UI. Self-bounding: a
  blocked title can't be re-grabbed, so it can't be re-blocked → no growth. Retry does **not** clear the row (clearing
  reintroduces the loop) but nils the movie's stale `release_title`.

**Tech Stack:** Elixir/Phoenix 1.8, Ecto + `ecto_sqlite3`, ExUnit, Mox. No new deps.

## Global Constraints

- `mix test` (the alias) is the source of truth: `compile --warnings-as-errors`, `format --check-formatted`,
  `credo --strict`, `ecto.migrate`, then the suite. "Green" = this passes. The new migration applies automatically.
- **Empty-blocklist behaviour must be byte-identical to today.** With no `blocked_releases` rows, every selection and park
  must behave exactly as it does now — prove it by keeping the existing movie + TV suites green.
- **Every persisted write goes through a `Catalog` function.** The `release_title` writes ride the existing choke-points
  (movie via `Catalog.transition` → `transition_changeset` cast; grab via `Catalog.create_grab` → `Grab.changeset`). The
  new `block_release`/`block_grab_release` are new `Catalog` writers for a non-pipeline side table (no broadcast),
  consistent with existing non-transition writers like `create_grab` / `set_episode_monitored`.
- **🔴 Park-path writes MUST be non-raising (known hazard).** `block_release`/`block_grab_release` run inside the poller's
  `isolate`d park path. Per the project memory note *poller-isolate-only-logs-hotloop*: a raise inside an isolated unit
  re-raises every tick — `isolate` never parks. So these functions use **non-bang `Repo.insert/1`, log-and-swallow any
  `{:error, _}`, and return `:ok` unconditionally** (mirror `Download.best_effort_remove`). For the **movie** path, call
  `block_release` only **after** `Catalog.transition` has committed the terminal park (a best-effort side effect, like
  `Notifier.notify`). For the **TV** path, resolve `series_id_for_grab/1` and call `block_grab_release` **before**
  `park_grab` deletes the grab — but the insert itself must not be able to abort the park.
- **Scorer `rules/1` widens 5-tuple → 6-tuple** — update **both** destructure sites (`select/2` and `select_for/4`) in the
  same edit; the compiler flags a mismatch under `--warnings-as-errors`.
- **`Catalog.create_grab/3 → /4`** touches its sole caller (`TvPoller.grab_assignment`) and existing `/3` test call sites —
  land atomically. `release_title` is optional (no `validate_required` change).
- Work on branch `release-blocklist`. Commit per task locally. **Do not push or open a PR until the user asks.** End every
  commit message with the repo's standard trailers (`Co-Authored-By:` + `Claude-Session:`).
- After code changes, run `graphify update .` to keep the graph current.

---

### Task 1: Migration + `BlockedRelease` schema + `release_title` columns

**Files:**
- Create: `priv/repo/migrations/20260628120000_add_release_blocklist.exs`
- Create: `lib/cinder/catalog/blocked_release.ex`
- Modify: `lib/cinder/catalog/movie.ex`, `lib/cinder/catalog/grab.ex`
- Test: `test/cinder/catalog/blocked_release_test.exs` (new) or extend `catalog_test.exs`

**Interfaces:**
- `release_title :: String.t() | nil` on `movies` and `grabs` (NOT `episodes` — the grab owns TV release identity).
- `Cinder.Catalog.BlockedRelease` schema on `blocked_releases` with `release_title`, `reason`, `belongs_to :movie`,
  `belongs_to :series`, timestamps; `changeset/2` casting `[:release_title, :reason, :movie_id, :series_id]` +
  `validate_required([:release_title])`.

- [ ] **Step 1: Branch.** `git checkout -b release-blocklist`
- [ ] **Step 2: Migration.** One migration:
  - `for tbl <- [:movies, :grabs], do: alter table(tbl) do add :release_title, :string end` (mirrors the `[:movies, :episodes]`
    loop in `20260627120000_add_imported_source.exs` — note: **movies + grabs** here).
  - `create table(:blocked_releases)`: `add :release_title, :string, null: false`; `add :reason, :string`;
    `add :movie_id, references(:movies, on_delete: :delete_all)`; `add :series_id, references(:series, on_delete: :delete_all)`;
    `timestamps(type: :utc_datetime)`.
  - `create index(:blocked_releases, [:movie_id])` and `create index(:blocked_releases, [:series_id])`.
  - **No unique index** — SQLite NULL-distinct semantics make a composite-with-null unique awkward, and dedup is
    unnecessary (a blocked title can't be re-grabbed). Harmless duplicate titles collapse in the `in` membership check.
- [ ] **Step 3: `BlockedRelease` schema** per Interfaces.
- [ ] **Step 4: Schema fields.** `Movie`: add `field :release_title, :string`, add `:release_title` to
  `transition_changeset/2`'s cast list (pipeline-adjacent download state). `Grab`: add `field :release_title, :string`, add
  `:release_title` to `changeset/2`'s cast list (stays optional).
- [ ] **Step 5:** `mix test` green; round-trip the `BlockedRelease` changeset in a quick schema test.

---

### Task 2: Persist the chosen release name at the two grab choke-points

**Files:** `lib/cinder/download.ex`, `lib/cinder/catalog.ex`, `lib/cinder/download/tv_poller.ex`
- Test: `test/cinder/download_test.exs`, `test/cinder/catalog/catalog_tv_pipeline_test.exs`

**Interfaces:** `Catalog.create_grab/4` (adds trailing `release_title`); `Download.add_to_client` writes
`release_title: release.title` into its existing `:downloading` transition map.

- [ ] **Step 1:** Movie — in `Download.add_to_client/2`, add `release_title: release.title` to the existing
  `Catalog.transition(movie, %{status: :downloading, download_id: ..., download_protocol: ...})` map (same transaction —
  never a torn write).
- [ ] **Step 2:** TV — change `Catalog.create_grab(download_id, protocol, episode_ids)` →
  `create_grab(download_id, protocol, episode_ids, release_title)`; thread it into `insert_and_link_grab` →
  `Grab.changeset(%{download_id:, download_protocol:, release_title:})`. Update the sole caller
  `TvPoller.grab_assignment/2` to pass `release.title`. Update existing `/3` test call sites atomically.
- [ ] **Step 3:** Tests: `Download.start/1` (IndexerMock returns one scoreable release, ClientMock.add returns an id) → the
  movie row has `release_title == that title`, status `:downloading`. `create_grab/4` persists `release_title` on the grab.

---

### Task 3: Catalog blocklist read/write functions (non-raising) + retry clears stale title

**Files:** `lib/cinder/catalog.ex` — place near the grab-lifecycle functions (`create_grab`..`park_grab`), reusing the
private `series_id_for_grab/1` and that section's transaction style.
- Test: `test/cinder/catalog_test.exs`

**Interfaces:**
- `block_release(%Movie{}, reason) :: :ok` — nil-`release_title` → no-op; else inserts a `BlockedRelease`
  `%{release_title: movie.release_title, reason: to_string(reason), movie_id: movie.id}`. **Non-raising** (non-bang insert,
  log+swallow). No broadcast.
- `block_grab_release(%Grab{}, reason) :: :ok` — nil-`release_title` → no-op; else inserts with
  `series_id: series_id_for_grab(grab.id)`. **Non-raising.**
- `blocked_release_titles(%Movie{}) :: [String.t()]` and `blocked_release_titles_for_series(series_id) :: [String.t()]` —
  indexed `select: b.release_title` queries.

- [ ] **Step 1:** Implement the four functions per Interfaces. Both writers wrap `Repo.insert/1`, log on `{:error, _}` via
  `Logger.warning`, return `:ok` always.
- [ ] **Step 2:** In `retry_movie/1`, add `release_title: nil` to the transition attrs (clear stale grab state on re-queue;
  the blocklist row persists, keyed by `movie_id`). Add a one-line comment that the parked row's `release_title` is stale
  download state, not live.
- [ ] **Step 3:** Tests: round-trip block + read; nil no-op (inserts nothing, count unchanged); `retry_movie/1` **preserves**
  the blocklist row while nil-ing `release_title`; `block_grab_release` scopes by series.

---

### Task 4: Scorer title-exclusion filter (mirror group `blocked?/2`)

**Files:** `lib/cinder/acquisition/scorer.ex`
- Test: `test/cinder/acquisition/scorer_test.exs`

**Interfaces:** new scorer opt `release_blocklist :: [String.t()]` (downcased internally), consumed in `select/2` and
`select_for/4`.

- [ ] **Step 1:** Extend `rules/1` to a 6-tuple, adding
  `rules |> Keyword.get(:release_blocklist, []) |> Enum.map(&String.downcase/1)`. Update both destructure sites.
- [ ] **Step 2:** New predicate alongside `blocked?/2`:
  `defp title_blocked?(%Release{title: nil}, _), do: false` /
  `defp title_blocked?(%Release{title: t}, list), do: String.downcase(t) in list`.
- [ ] **Step 3:** In both `select/2` and `select_for/4`, in the existing reject pipeline change the group line to
  `|> Enum.reject(&(blocked?(&1, blocklist) or title_blocked?(&1, release_blocklist)))`. `select_for`'s `cover`/`band`
  machinery is unaffected (the reject is top-level).
- [ ] **Step 4:** Tests (reuse the `defp release(attrs)` fixture): `select/2` rejects a blocked title, still returns the
  non-blocked candidate; both blocked → `:no_match`; case-insensitive. `select_for/4` rejects a blocked season-pack but
  still covers the wanted set from remaining episode releases.

---

### Task 5: Feed the blocklist into search opts (both pollers)

**Files:** `lib/cinder/download.ex`, `lib/cinder/download/tv_poller.ex`

- [ ] **Step 1:** Movie — in `Download.start/1`, add `release_blocklist: Catalog.blocked_release_titles(movie)` to the `opts`
  built before `Acquisition.best_release(imdb_id, opts)` (opts already flow to `Scorer.select`).
- [ ] **Step 2:** TV — in `TvPoller.search_group/1`, add `release_blocklist: Catalog.blocked_release_titles_for_series(series.id)`
  to the `opts` built before `Acquisition.best_releases(...)` (flows to `Scorer.select_for`). No change in `Acquisition` —
  it already forwards `opts`.

---

### Task 6: Capture at the existing park sites (deterministic + exhausted-download)

**Files:** `lib/cinder/download/poller.ex`, `lib/cinder/download/tv_poller.ex`

**Interfaces:** define a module attr listing the download-side reasons that only reach `park` after exhausting
`@max_attempts` (movie: `@download_failure_errors [:download_error, :torrent_not_found, :no_content_path]`; confirm the
exact atoms in `poller.ex`/`tv_poller.ex` and mirror for TV).

- [ ] **Step 1:** Movie `park/3`: **after** the terminal `Catalog.transition(...)` commits, add
  `if reason in @permanent_import_errors or reason in @download_failure_errors, do: Catalog.block_release(movie, reason)`.
  Because `park` only sees a download-side reason *after* retry exhaustion, a single network blip can't block a good
  release; the nil-guard makes pre-grab parks no-ops.
- [ ] **Step 2:** TV `park/2`: resolve `series_id` / call `block_grab_release(grab, reason)` **before**
  `Catalog.park_grab(grab)` deletes the grab, guarded by `reason == :no_files_matched or reason in @tv_download_failure_errors`.
  The block insert is non-raising so it cannot abort the park.
- [ ] **Step 3:** Confirm: transient/non-exhausted parks and pre-grab search parks add nothing (no matching reason and/or
  nil `release_title`).

---

### Task 7: Integration tests (movie + TV headline regressions)

**Files:** `test/cinder/download/poller_test.exs`, `test/cinder/download/tv_poller_test.exs`, `test/cinder/download_test.exs`

- [ ] **Movie headline:** pre-seed a `blocked_releases` row for a `:requested` movie (title = release **A**, the natural
  winner — make A `1080p` and B `720p` so A would win absent the blocklist). IndexerMock.search returns `[A, B]` (both
  scoreable). `Download.start/1` → ClientMock.add receives **B**, never A; movie advances to `:downloading` on B. (If only A
  is returned → movie ends `:no_match`, not re-grabbed.)
- [ ] **TV headline (symmetry — the load-bearing TV filter):** pre-seed a `blocked_releases` row scoped to the series for a
  wanted episode/season (title = blocked pack). IndexerMock.search_tv returns `[blocked-pack, good-release]`. Drive
  `TvPoller.search_group` → ClientMock.add gets the good release and `create_grab` links it; never the blocked pack.
- [ ] **Download-failure capture:** drive a movie to terminal exhaustion on a download-side reason (e.g. ClientMock reports
  `:error` status until `@max_attempts`) → after park, `blocked_release_titles(movie)` contains the grabbed title; a
  subsequent `Download.start/1` does not re-grab it.
- [ ] **Capture fires for each permanent import reason** (`:wrong_audio_language`, `:no_video_file`, `:no_file_path`) so a
  future narrowing of `@permanent_import_errors` is caught.
- [ ] No network or disk: IndexerMock/ClientMock only; FilesystemMock/MediaServerMock where import is involved.

---

## Done when

`mix test` (the alias) is green — `compile --warnings-as-errors`, `format --check-formatted`, `credo --strict`, suite —
**and**:

1. A Scorer test proves `select/2` and `select_for/4` reject a release whose title is in `release_blocklist` while still
   selecting a non-blocked candidate (case-insensitive).
2. A Catalog test proves `block_release/2` + `blocked_release_titles/1` round-trip, no-op on a nil `release_title`, and that
   `retry_movie/1` **preserves** the blocklist row while clearing the movie's `release_title`. The block writers are
   non-raising (a forced insert error logs and returns `:ok`, the park transition still commits).
3. A Download test proves `add_to_client` persists `release_title`; the TV path proves `create_grab/4` stores it and
   `block_grab_release/2` scopes by series.
4. **Movie headline:** a movie with a pre-seeded blocked release is NOT re-grabbed on re-search (ClientMock.add receives a
   different release, or the movie ends `:no_match`).
5. **TV headline:** the symmetric test proves `TvPoller.search_group` reads the series blocklist and the blocked pack is
   never re-grabbed.
6. **Download-failure exhaustion:** a release that exhausts all `@max_attempts` download retries is recorded and not
   re-grabbed on the next search.
7. The movie and TV happy-path pipelines remain green with an empty blocklist — **no behaviour change when the table is
   empty.**

## Accepted limitations (documented, not built)

- **Cross-indexer title variance** defeats the exact-downcased match (a second indexer returning a slightly different name
  for the same release could be re-grabbed). Accepted at per-item household scope; the global/infohash variant is the
  parked future enhancement.
- **A title whose only release is blocklisted** parks at `:no_match` and `/status` Retry re-parks at `:no_match` (the row
  persists). The only recovery is delete + re-add. A `/status` "clear blocklist" button is a small, sanctioned fast-follow.
- **`:wrong_audio_language` is preference-relative** — broadening `preferred_language` later does not unblock the prior
  wrong-language release (it's still wrong-language for the old preference; the re-search just looks for a different one).
- **Mixed-language TV packs** (some episodes correct, some wrong) finish as `{:ok, imported, _}`, not `:no_files_matched`,
  so the grab isn't blocked; the still-wanted wrong-audio episodes re-search and can re-select the same pack, bounded by
  `episode.search_attempts` (10). A full fix needs per-episode (not per-grab) release identity — out of scope.
