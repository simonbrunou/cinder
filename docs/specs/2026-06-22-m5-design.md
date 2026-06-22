# M5 — TV acquisition + multi-file import (design)

**Date:** 2026-06-22
**Milestone:** M5 (XL) — make monitored episodes actually download and import.
**Status:** design approved; split into M5a / M5b / M5c sub-sessions (one per session, `/clear` between).

Movies are **untouched** everywhere in M5. `Movie`, `Download.start/1`, `Acquisition.best_release/2`,
`Scorer.select/2`, `Library.import_movie/1`, and the movie `Poller` keep their exact behaviour and tests
(408 green). M5 adds TV-only siblings alongside them.

## Locked decisions (this session)

- **3 sub-sessions:** M5a data layer → M5b acquisition logic → M5c poller + multi-file import.
  M5c carries the milestone's "Done when". This doc covers all three; only M5a is built this session.
- **Grab-centric episode model** (not mirror-Movie). The `episode.ex` comment governs: eligibility is
  *"monitored AND missing-file AND aired, never a bare status sweep."* Episodes get **no status enum**;
  state is derived. The download lifecycle lives in a separate `grabs` row.
- **TV stays admin-direct.** The non-admin TV request→approval flow is **deferred** out of M5 (TV is
  admin-only add today, the poller auto-grabs monitored episodes, so the loop is complete for an admin).
  Folds into a later Seerr-polish milestone.
- **Separate `Cinder.Download.TvPoller`** (config-gated like the movie poller). The movie poller is not
  overloaded or made polymorphic.
- **Fan-out in one `Repo.transaction`** — the WAL + `busy_timeout` correctness guarantee (M0). Every TV
  writer goes through a Catalog choke-point, exactly like movies.

## The grab-centric data model

### `grabs` — one download serving 1..N episodes

| column | type | meaning |
|---|---|---|
| `download_id` | string, not null | qBit infohash / SAB nzo_id |
| `download_protocol` | `Ecto.Enum [:torrent, :usenet]`, not null | routes `Download.Client.status/1` |
| `content_path` | string, null | **nil ⇒ still downloading; set ⇒ downloaded, ready to import.** The grab's phase is derived from this — no status column. |
| `download_attempts` | integer, not null, default 0 | bounded-retry counter for the advance pass |

`has_many :episodes` (the FK lives on `episodes`).

### `episodes` — four additive columns

| column | type | meaning |
|---|---|---|
| `file_path` | string, null | set on import; **presence ⇒ "available"** |
| `grab_id` | `references(:grabs, on_delete: :nilify_all)`, null | the active grab (nil ⇒ not downloading) |
| `search_attempts` | integer, not null, default 0 | bounded-retry / backoff for the search phase |
| `import_attempts` | integer, not null, default 0 | bounded-retry for the import phase |

### Derived episode state (no enum)

| state | predicate |
|---|---|
| available | `file_path` set |
| downloading | `grab_id` set (grab `content_path` nil ⇒ in flight, set ⇒ awaiting import) |
| wanted | `monitored ∧ file_path nil ∧ grab_id nil ∧ air_date ≤ today` |
| search-parked | wanted predicate **and** `search_attempts ≥ @max_attempts` (10) — derived, shown as "couldn't find" |

### Deliberate simplifications (each a `ponytail:` note in code, with its ceiling)

- **No episode status enum** — derived from `file_path`/`grab_id`. Ceiling: add an enum if we ever need
  fine-grained per-episode parked reasons.
- **Grab phase derived from `content_path`**, not a status column.
- **`grab_id` FK, not a `grab_episodes` join table.** One grab → many episodes is one-to-many; a join
  table only buys many-to-many / grab history we don't need. This *is* the "grab/download join table" the
  roadmap named, in its correct normal form (flagged because it reinterprets a locked-decision word).
- **Grabs are transient** — deleted after a successful import (or on park; the FK nilifies `episodes.grab_id`).
  The table only holds in-flight downloads. Ceiling: keep them if M6 wants a "what release got this" audit.
- **Backoff reuses `updated_at`** (like the movie poller), no separate `last_search_at`. A monitor-toggle
  bumping `updated_at` can only *delay* a retry harmlessly, never strand an episode.
- **Wanted is gated on `episode.monitored` only** (the leaf flag) — `set_season_monitored` already cascades
  to episodes and `add_series_to_watchlist` applies per-episode, so the leaf is the single source of truth.

## M5a — the data layer (this session)

1. **Migration** `add_tv_pipeline_fields`: the `grabs` table + the 4 `episodes` columns +
   `index(:episodes, [:grab_id])`. Additive only. *(The indexed wanted-query is M6's job — not speculated here.)*
2. **`Cinder.Catalog.Grab`** schema (`lib/cinder/catalog/grab.ex`) + **`Episode.transition_changeset/2`**
   casting `[:file_path, :grab_id, :search_attempts, :import_attempts]` (no required status).
3. **Catalog API additions** (all broadcast `{:series_updated, series_id}` on the existing `"series"` topic,
   reusing the M4b broadcast pattern; `monitored` keeps its own writers):
   - `transition_episode/2` — single choke-point for episode pipeline writes.
   - `create_grab/3 (download_id, protocol, episode_ids)` — one `Repo.transaction`: insert grab + set
     `grab_id` on the listed episodes.
   - `mark_grab_downloaded/2 (grab, content_path)`.
   - `delete_grab/1` — deletes the grab; the FK nilifies `episodes.grab_id`.
   - `list_grabs_downloading/0` (`content_path` nil) / `list_grabs_downloaded/0` (`content_path` set).
   - `wanted_episodes/0` — the SQL-expressible wanted set (`monitored ∧ file_path nil ∧ grab_id nil ∧
     air_date ≤ today`), preloaded `season: :series`. Backoff/bound filtering stays in the poller (M5c),
     matching the movie poller's split.

**M5a Done when:** `mix test` (the alias) green; new tests cover the episode transition + grab lifecycle
(create → mark downloaded → delete unlinks episodes) + `wanted_episodes` inclusion/exclusion (monitored &
aired & missing in; un-aired, un-monitored, has-file, has-grab out); the **movie suite stays green** and the
movie pipeline is provably untouched.

## M5b — acquisition logic (next session, sketch)

- **Parser additions** (`lib/cinder/acquisition/parser.ex`): new fields `season :: pos_integer | nil` and
  `episodes :: [pos_integer] | nil` (a single ep ⇒ `[2]`; a range `S01E01-E03` ⇒ `[1,2,3]`; a whole-season
  pack ⇒ `season` set, `episodes` nil). New regex tables for `S01E02` / `1x02` / `S01E01-E03` and
  `S01` / `Season 1` / `Complete`. Existing resolution/codec/group/language untouched; movie names parse to
  nil TV fields. Grown fixture matrix.
- **Indexer behaviour** gains a TV callback (`search_tv/…` keyed on `tvdb_id` with title/season/episode
  fallback, TV categories) — behaviour + Prowlarr impl changed atomically; Mox auto-covers; movie `search/1`
  kept distinct.
- **Scorer** gains a TV `select_for/2` that scores releases against a wanted-episode *set* and may return
  multiple releases (a pack covering many, or per-episode singles when they beat the pack), with a per-TV
  size band. Movie `best_release/2` / `select/2` byte-for-byte unchanged.

## M5c — TV poller + multi-file import (carries the M5 Done-when)

- **`Cinder.Download.TvPoller`** — a separate GenServer registered in `application.ex`, gated by a config
  flag mirroring `:start_poller`. Stateless; three passes per tick mirroring the movie skeleton (`isolate/2`,
  `retry_or_fail/4` @ `@max_attempts = 10`, `park/3`, `search_due?/2` backoff):
  - **advance:** `list_grabs_downloading` → `client.status(download_id)` → on complete `mark_grab_downloaded`;
    bounded retry on transient error via `download_attempts`; park (delete grab + bump each episode's
    `search_attempts`) on terminal failure.
  - **import:** `list_grabs_downloaded` → walk `content_path`, parse `SxxEyy` per file, match to the grab's
    episodes, hardlink, set `episode.file_path`; on all matched files imported, delete the grab; unmatched
    files park gracefully (logged, not an error).
  - **search:** `wanted_episodes` → filter by backoff/bound → group by season → TV search + score →
    `create_grab` + `client.add`.
- **`Library.import_episode/2` + `import_pack/2`** — naming `Show (Year)/Season NN/Show (Year) - SxxEyy.ext`,
  reusing the `Filesystem` + `MediaServer` behaviours and the determinism primitives; graceful park for files
  with no `SxxEyy` or no matching Episode row. `import_movie/1` untouched.
- **Fan-out** (a completed pack → N episode imports) wrapped in one `Repo.transaction`.
- **No UI in M5.** The `{:series_updated, series_id}` broadcasts already refresh the open series-detail view;
  per-episode pipeline badges are a later polish.

**M5 Done when** (the roadmap's, carried by M5c): conventions pass + tests import (a) a single episode and
(b) a season pack into the correct hardlink layout against mocked FS + media server, mapping each pack file
to its Episode row, and an unmatchable file parks gracefully; plus a TvPoller crash-recovery test.

## Risks carried from the roadmap

- **Season-pack import is the highest bug-density area** — file→episode mapping on messy real names. M5b's
  parser fixtures + M5c's graceful park are the mitigation. Specials (`S00`) park gracefully but are not
  specially handled (that's M6).
- **Behaviour-signature churn** (Indexer TV callback) changes the behaviour + Prowlarr + Mox at once — land
  atomically in M5b, keep movie/TV callbacks distinct.
- **SQLite single-writer correctness** — every TV writer goes through a Catalog choke-point; the pack
  fan-out is one transaction. Never call a per-episode write N times outside a transaction.
