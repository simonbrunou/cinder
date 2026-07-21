# Stalled-download reaper — design

Council review: 2 rounds (perspective-diverse: state-machine / teardown-ordering /
red-team). Round 1 surfaced 5 blockers + material items — all resolved by pivoting off
a `stalled_since` column to deriving the stall clock from `updated_at`, sourcing
seeders from `num_seeds`, using the private no-publish `guarded_movie_transition/3` with
fence-before-clear, and making the `:stalled` blocklist operator-recoverable. Round 2:
consensus "sound to build"; build-notes and the emergent-property guardrail folded in
above. No material disagreement remains.

**Issue:** #147. **Date:** 2026-07-21. **Size:** M.

Opt-in, off by default. Detect a download that makes no forward progress for a
configurable window (dead torrent swarm, `metaDL` with 0 seeders, frozen job),
remove it from the client (with data), blocklist that release **recoverably**, and
reset the item so the next tick re-searches and picks a *different* release
(torrent **or** usenet).

Scope decided (issue Q&A): **both pollers** (movie `Poller` + TV `TvPoller`);
stalled **`:upgrading`** movies are reaped via revert (keep the live file);
reaps are bounded (see §Bounding).

## Why not fix the classifier

`classify/2` (qbittorrent.ex:451) maps `metaDL`/`stalledDL` to `:downloading`.
That is correct — a stalled torrent *is* downloading. The bug is that nothing ever
gives up on it. So the fix is a stall *timeout*, not a state remap.

## Detection — derive the stall clock from `updated_at`, no new column

`update_movie_download_metrics` / `update_grab_download_metrics` are **change-gated**
(catalog.ex:786, 797): when `progress`/`speed`/`eta` are unchanged, `metric_changes`
returns `%{}` and **no write happens** — so `updated_at` is not bumped. For a stalled
torrent (progress frozen, speed a steady `0`, `eta` the normalized-`nil` infinity
sentinel) every tick is a no-op write, so **`updated_at` freezes at the moment metrics
last changed = the moment the download stalled**. Therefore `now - updated_at` is the
stall duration, already persisted, on both `movies` and `grabs`. **No migration, no
schema column, no cast/reset/whitelist changes.** (This was the original design's
`stalled_since` column; the council found that column silently dropped on the movie
write path — `Movie.transition_changeset` doesn't cast it — and needed a matching
reset on every downloading-exit or it false-reaps a reused row. Deriving from
`updated_at` removes all of that.)

The reap decision is a single predicate evaluated in the `:downloading` branch of
`advance_with/2` (and `advance_upgrade_with/2`), right where `client.status/1` already
arrives each tick — no new poll pass, no new list query. `StallReaper.reap?/3` (pure):

```
reap?(updated_at, status, now) =
  status.speed == 0                       # hard numeric zero → torrents only
  and (now - updated_at) >= threshold(status.seeders)
```

- **`speed == 0`** (a *hard numeric zero*, guarded `speed === 0`, not `speed > 0` —
  `nil > 0` is `true` in Elixir term-ordering) makes this **torrent-only for free**:
  SABnzbd reports `speed: nil`, so a usenet job is never reaped — exactly the issue's
  "treat SAB conservatively." No SAB-specific branch. `ponytail:` comment on the gate.
- **threshold:** `seeders == 0 → no_seeders_timeout` (30 min); otherwise, including
  `seeders == nil` (unknown) → `stall_timeout` (2 h).

**`updated_at`-freeze invariant + ceiling** (documented in a `ponytail:` comment at
the reap site): the clock is only correct while nothing else writes the row mid-
download. Two known, benign perturbations, both in the safe (delay-a-reap) direction:
an unrelated row write (a metadata refresh, a language edit) bumps `updated_at`; and a
flaky client returning intermittent `{:error, _}` re-nils the metrics (a change → a
write → an `updated_at` bump). Neither causes a *false* reap; both merely postpone a
true one. Acceptable at single-household scale against a local qBittorrent.

The reap check reads the tick-start struct's `updated_at` (the frozen value). On the
stall-*start* tick the metric write bumps `updated_at` to now, so the reap only begins
measuring from the *next* tick — a one-tick (~5 s) lag, negligible against the
thresholds, and it guarantees no spurious reap at the moment speed first hits 0.
`reap?` diffs with `DateTime.diff/2` — both timestamps are `:utc_datetime`
(movie.ex, grab.ex; `now/0` at catalog.ex:2299 returns a truncated `DateTime`).

**Emergent-property guardrail.** Firing correctness rests on an implicit property:
at a true stall all three change-gated fields are byte-stable — `progress` frozen,
`speed` a hard `0`, and `eta` the `8_640_000` infinity sentinel that `normalize/1`
maps to `nil` (qbittorrent.ex:448). If a future change adds a field to
`@download_metric_fields` (catalog.ex:36) that wobbles at zero speed, or alters the
eta normalization, `updated_at` stops freezing and the reaper silently never fires —
the worst failure for an opt-in safety feature. Two cheap guards (in the plan): (1) a
comment at the reap site coupling its correctness to `@download_metric_fields` + the
eta-sentinel normalization; (2) an integration test driving two consecutive stalled
metric ticks (`speed: 0`, eta sentinel) and asserting `updated_at` did not move.

## Seeders — add `:seeders` to the status map, sourced from `num_seeds`

Add `:seeders` to the `status/1` map. **qBittorrent `num_seeds`** (connected seeds),
**not** `num_complete`: `num_complete` is the tracker-scrape swarm total and is `-1`
(unknown) until a scrape lands — which for a `metaDL` torrent typically hasn't
happened, so it would map to `nil → 2 h` and the 30-min fast path would never fire for
the exact acceptance case. `num_seeds == 0` is the reliable "no peers" signal for a
dead/metaDL swarm. Map absent/`< 0 → nil`. SABnzbd → `nil`. The `status/1` behaviour
doc is updated; the field is optional so the Mox mock and existing callers are
unaffected.

## Reap action (movie, `:downloading`) — guarded, fence-before-clear, block-after-commit

A new `Catalog.reap_stalled_movie/1`, structured like `do_cancel_txn` (catalog.ex:1139)
but landing on `:requested` and fixing the two ordering traps the council found:

1. **One transaction** (use the **private** `guarded_movie_transition/3`, catalog.ex:725
   — it performs **no** publication — composed inside an outer `Repo.transaction`, with
   `Repo.rollback(:stale_status)` on a miss and all broadcasts/notifies deferred to
   post-commit. **Not** the public `transition/3`: it opens its *own* nested transaction
   and broadcasts `{:movie_updated}` mid-txn, which would double/early-announce and
   break crash-atomicity. `account_active_movie_retry` (catalog.ex:698) is the exact
   in-repo pattern to follow.):
   - **Guarded** transition (`expect: :downloading`) to `:requested`, clearing the
     stale download fields (`download_id`, `download_protocol`, `release_title`,
     `release_policy_snapshot`, `content_path`) and bumping `search_attempts` (backoff
     spacing — see §Bounding). A concurrent user cancel/delete during the multi-second
     `status/1` window makes this miss → `Repo.rollback(:stale_status)`, no side effects
     (MEMORY: guarded-transition-expect). `do_cancel_txn`'s **unguarded** `Repo.update`
     is the wrong template for a poller writer — the reap must not clobber a just-
     cancelled row.
   - `Download.fence_movie_cleanup(movie)` on the **pre-clear original** struct
     (the argument, never the `updated` result — rebinding `movie = updated` is the one
     way to break this; Elixir immutability keeps the original's `download_id` intact
     even though the same txn's `update_all` clears the row). At `:downloading` the
     reserved intent has already been deleted (attach → complete → delete), so
     `fence_movie_cleanup` takes the `download_id`-carrying Path B (download.ex:357) and
     writes a `:cleanup_pending` intent. **The transition clears `download_id`; the fence
     needs it** — and the fence only queries the *intents* table, so the same-txn movie
     clear is not observable (no read-after-write hazard). Passing a cleared struct would
     make the fence return `[]`, orphaning the torrent forever (the #110 landmine). The
     fence **must stay inside this txn** (as `do_cancel_txn` does) for crash-atomicity —
     splitting "commit the clear, then fence" opens a window where the row is `:requested`
     with the old torrent un-fenced.
2. **Post-commit** (all best-effort, matching `park/3`'s ordering so a stale miss
   leaves no side effect):
   - `Download.cleanup_intents(intent_ids)` — reconciles the fence → `strict_remove` →
     `client.remove(id, delete_files: true)` (download.ex:483). If it raises inside the
     poller's `isolate/2`, the DB is committed and the `:cleanup_pending` row persists,
     so `reconcile_pending_intents` (top of every tick) retries the removal. Self-heals.
   - `Catalog.block_release(movie, :stalled)` on the **original** struct (the committed
     one has `release_title: nil`), **after** the guarded commit so a stale miss never
     writes a spurious permanent row.
   - `Notifier.notify({:movie_failed, updated, :stalled})` + broadcast.

## Reap action (movie, `:upgrading`) — reuse `revert_upgrade`

A stalled upgrade keeps its live library file. Reap = `revert_upgrade(movie, :stalled)`.
`revert_upgrade` already runs its guarded transition (`expect: movie.status`) and
already blocklists **before** clearing `release_title`, reading the pre-clear struct —
so the ordering is correct as-is. But it currently hardcodes
`block_release(movie, :upgrade_failed)` (poller.ex:550); a stall must record reason
**`:stalled`** (so the test asserts it and — though `revert_upgrade` lands on
`:available`, which `retry_movie` does not un-block, the stored reason stays
semantically correct; the live file is intact so this is acceptable). So this is a
**reason-branch**, ~3 lines, not a 1-line guard-set addition:
`if reason == :stalled, do: block_release(movie, :stalled)`, else the existing
`@permanent_import_errors`/`@download_failure_errors`-gated `:upgrade_failed`. No reset
to `:requested`; the live `file_path`/`imported_*` are untouched. Nothing to clear (no
`stalled_since` column).

## Reap action (TV grab) — new one-transaction `Catalog.reap_stalled_grab/1`

Combines `cancel_grab`'s intent-safe teardown with `finish_grab`'s `search_attempts`
bump — a combination no existing function offers (`park_grab` bumps+deletes but does no
client teardown; `cancel_grab` fences+deletes but does no bump). Buildable in one
transaction **only in this order** (the delete's `grab_id` FK `:nilify_all` runs last):

1. `episode_ids = episode_ids_for_grab(grab.id)` — needs links present.
2. `block_grab_release(grab, :stalled)` — resolves the series from the still-linked
   episodes (non-raising; must precede the delete, matching TV `park/1`).
3. Bump `search_attempts` on the grab's episodes via `missing_episodes_query(grab.id,
   [])` `inc:` — needs links present.
4. `fence_episode_cleanup(episode_ids, [grab_cleanup_spec(grab, episode_ids)])` — reads
   `download_id`/`protocol`/`title` off the in-memory grab struct (survives regardless).
5. `Repo.delete(grab)` **last**.

Post-commit: `cleanup_intents(intent_ids)` (self-heals as above), `broadcast_series`,
`Notifier.notify({:grab_failed, grab, :stalled})`. Episodes re-enter `wanted_episodes`
and re-search next tick; the blocklist skips the dead release.

## Recoverability — the `:stalled` blocklist must not be a one-way door

`blocked_releases` is insert-only and permanent, and `retry_movie` deliberately
**keeps** it (catalog.ex:854). Every existing blocklist writer earns that permanence
with 10 exhausted retries on a *deterministic* failure. The reaper blocklists on a
timeout — a weaker bar — so a slow-but-alive release wrongly reaped would be forbidden
forever, stranding the title at `:no_match` with no path back but raw SQL. That is
worse than today's "sits forever, operator can see it."

**Fix:** the `:stalled` reason is treated as *recoverable*, cleared only on **manual**
re-search entry points (never the automatic sweep, which keeps respecting the blocklist
so it converges rather than thrashes):

- **Movie:** `retry_movie` deletes the movie's `blocked_releases` rows whose
  `reason == "stalled"` (only that reason — the deterministic
  `:no_file`/`:wrong_audio_language`/`:bad_torrent` rows still persist, so the re-grab
  loop the existing comment guards against is not reintroduced). `retry_movie`'s callers
  are both manual (user Retry; language-edit re-queue). One operator Retry gives the
  reaped release a fresh chance; still dead → re-reaped, re-blocked.
- **TV:** the same `reason == "stalled"` clear goes in `Catalog.search_episode_now/1`
  (catalog.ex:3115) and `search_season_now/1` (catalog.ex:3135) — the manual
  "search now" actions from `series_detail_live` that already zero `search_attempts`
  (the true TV analogue of `retry_movie`). **Not** the monitoring toggles
  (`set_episode_monitored`/`set_season_monitored`), which flip `monitored` only and
  would leave a search-parked episode parked. Note `blocked_releases` is keyed by
  `series_id`, so a per-episode clear deletes the whole series' `:stalled` rows —
  deliberate and benign (every stalled release in the series gets a fresh chance):
  `DELETE WHERE series_id == <ep's series> AND reason == "stalled"`.

## Bounding — describe it correctly

- **Movie:** the terminal bound is **blocklist exhaustion**, *not* the `search_attempts`
  cap. `Download.start` returns `{:ok, %Movie{status: :no_match}}` (not an error) when
  the scorer finds nothing, and `search_one` treats `{:ok, _}` as success without
  consulting the cap — so `search_attempts` never parks a movie. Each reap blocklists
  one release; when the indexer's finite candidate set is exhausted the scorer returns
  `:no_match` and the movie parks there. The reap's `search_attempts` bump feeds only
  `search_due?` backoff (~60 s spacing between reaps). A pathological title with many
  slow releases reaps each once before parking — wasteful but finite and operator-
  recoverable (Retry, above). Documented as the known ceiling.
- **TV:** the cap *is* enforced up front — `search_wanted` filters
  `search_attempts >= max_search_attempts` (tv_poller.ex:270) — so the bump does bound
  the episode loop, as well as feeding backoff.

## Configuration (opt-in)

```elixir
config :cinder, Cinder.Download.StallReaper,
  enabled: false,
  stall_timeout: :timer.hours(2),
  no_seeders_timeout: :timer.minutes(30)
```

Read via `Application.get_env(:cinder, __MODULE__, [])` with the above as in-module
defaults (module config, like the pollers' `interval:`; not a `/settings` field — no
string→int coercion seam). No `StallReaper` GenServer — a pure helper module the two
pollers call.

## Module layout

`Cinder.Download.StallReaper` — pure, unit-testable, no DB/HTTP:

- `enabled?/0`, `stall_timeout/0`, `no_seeders_timeout/0`
- `reap?(updated_at, status, now)` → boolean (the predicate above)

The reap *actions* stay in the pollers (they differ per item) and call new
`Catalog.reap_stalled_movie/1`, the extended `revert_upgrade/2`, and new
`Catalog.reap_stalled_grab/1`.

## Visibility

`/activity` + detail LiveViews already bind `download_progress`/`speed`/`eta`; a reap
surfaces as the item returning to `:requested`/re-searching plus the existing
`{:movie_failed, _, :stalled}` / `{:grab_failed, _, :stalled}` notifier events. Each
reap is logged (`Logger.warning`). No new UI for v1.

## Testing

- **`StallReaper.reap?` (pure):** `speed == 0` past `no_seeders_timeout` with
  `seeders: 0` → true; `speed: nil` (SAB) → false regardless of age; `speed: 0`,
  `seeders: 5` → uses the 2 h threshold; `seeders: nil` → 2 h; below threshold → false.
- **`updated_at`-freeze invariant (integration, the guardrail):** drive two consecutive
  stalled-torrent metric ticks (`progress` frozen, `speed: 0`, `eta` sentinel→nil)
  through `advance` and assert the movie/grab `updated_at` did **not** move — locking the
  emergent property the whole derivation depends on.
- **Client `status` seeders:** qBit `num_seeds` → `:seeders`; `-1`/absent → nil; SAB → nil.
- **Movie reap (integration, mocked client):** a `:downloading` movie whose `updated_at`
  is older than `no_seeders_timeout` with a `seeders: 0` status → removed from client
  (`delete_files: true`), `release_title` blocklisted `:stalled`, reset to `:requested`,
  reserved intent cleared; a concurrent status change makes the guarded transition miss
  with no side effect; the disabled default reaps nothing.
- **Retry recovery:** `retry_movie` on a reaped movie clears its `:stalled` blocklist
  rows but leaves a `:wrong_audio_language` row intact.
- **Upgrade reap:** a stalled `:upgrading` movie → reverts to `:available`, live
  `file_path` untouched, release blocklisted `:stalled`.
- **TV grab reap:** a stalled grab → deleted, client job + intent torn down, episodes
  re-search with bumped `search_attempts`, release blocklisted `:stalled`.
- **Acceptance shape:** the two `[Teke]` Kizu subjects (movies, `metaDL`,
  `num_seeds: 0`) reaped → blocklisted → re-searched, with a well-seeded replacement
  then selected by the scorer (fixture-level, no network).

## Deliberately skipped

The `stalled_since` column (derived from `updated_at` instead); classifier remap; a
dedicated `StallReaper` GenServer/pass; a `stall_reaps` counter + `max_reaps` knob; a
`/settings` UI; SAB-specific reap thresholds (the `speed == 0` gate already excludes
SAB); hardening the flaky-client / unrelated-write `updated_at` perturbations (both
delay, never falsely trigger, a reap). Add any only if the reuse proves insufficient.
