# Cinder — Pre-v1.0 Release Audit

**Date:** 2026-06-25 · **Tree:** `main` @ `81a2642` · **Version:** `0.7.0` → targeting `v1.0.0`

## Verdict

**Conditional GO.** The codebase is in genuinely strong shape for a v1.0 — the security spine
(the request/approval gate), the state-machine choke-point discipline, the SQLite-correctness
design, and the import/secrets paths all held up under adversarial review. There is **one
release-gating defect**, and it is a one-line Dockerfile fix in the *packaging* layer, not the app:
a fresh `docker compose up` cannot write its database. Everything else is should-fix polish or
documented/accepted ceilings.

The real remaining gate is the same one the ROADMAP already names: the **pending live homelab
sign-offs** (qBittorrent torrent grab, live TV season-pack, the dashboard badge check, and a clean
`docker compose up` against the published image). The version is intentionally still `0.7.0` until
those pass — and the blocker below is exactly what the "fresh-image boots to the wizard" sign-off
would have caught.

## Baseline (verified at audit start)

| Check | Result |
|---|---|
| `mix test` (full alias) | **673 passing** |
| `mix credo --strict` | clean (0 issues, 143 files) |
| `mix compile --warnings-as-errors` | clean |
| `mix format --check-formatted` | clean |

## Method

A multi-agent audit: **13 dimension-finders → adversarial verification of every finding →
completeness critic → targeted gap-fill.** 81 agents, ~5.1M tokens. Every finding below was
independently re-checked by a skeptic instructed to *refute* it against the real code; 4 were
refuted, 7 partially confirmed, 44 confirmed. The highest-impact items were then re-verified by
hand (Dockerfile, scorer band, poller import path, the auth/approval spine).

Severity counts (post-verification): **1 release-blocker · 1 high · 1 medium · 25 low · 24 info ·
4 refuted.** The blocker and the high are the *same* finding.

---

## 1. Release blocker — fix before tagging v1.0

### B1 · Fresh `docker compose up` crash-loops: `nobody` can't write the SQLite DB
`Dockerfile:85–94`, `docker-compose.yml:22,30–31` · *packaging* · **verified by hand**

The container runs `USER nobody` (uid 65534). The DB lives at `/data/cinder.db` on the named
volume `cinder_data:/data`. The Dockerfile creates and chowns only `/app` — `/data` does not exist
in the image, so Docker creates the fresh volume's mountpoint **root-owned**. `ecto_sqlite3` then
fails to open the DB for write, the boot migration hits `EACCES`, and the container crash-loops.
**The exact path the README promises (`docker compose up --build` → first-run wizard) is the one
that breaks** on a clean install.

**Fix (one line, before `USER nobody`):**
```dockerfile
RUN mkdir -p /data && chown nobody:root /data
```
A fresh named volume inherits ownership from the image directory at the mount path, so this
propagates. Then verify with a genuinely empty volume — this *is* one of the pending M8 live
sign-offs, and it currently fails.

---

## 2. Should-fix before tag (cheap, real, stranger-facing)

### S1 · Media bind-mount is root-owned → onboarding wizard can't finish
`docker-compose.yml:28–32`, `config/runtime.exs:86–90` · *packaging* · **medium**

Sibling of B1. `${MEDIA_ROOT:-./media}:/media` is a bind mount that keeps host ownership; `./media`
auto-created by compose is root-owned and the `movies/`/`tv/` subdirs don't exist. The wizard
requires both library roots writable (`Health.check_service(:movies_library|:tv_library)` →
`mkdir_p`), so it cannot reach "Finish", and the later import hardlink would `EACCES` too. It *is*
discoverable in-product (red "Library" rows on the wizard), so it's friction, not a silent failure.
**Fix:** document `mkdir -p media/{movies,tv,downloads} && sudo chown -R 65534:65534 media` in the
quickstart, and consider surfacing the hint in the wizard error text.

### S2 · Scorer: a release with missing/zero indexer size bypasses the max-size band
`lib/cinder/acquisition/scorer.ex:116–119` · *acquisition* · **low (core-logic correctness)** · **verified by hand**

`within_band?/3` does `size = release.size || 0` then `size <= max_size`. `0 <= any_max` is always
true, so a release whose indexer omits size (common on some trackers) sails past the upper bound and
becomes selectable — for movies (`select/2`) and TV packs (per-episode `k·max`). Partially masked
when a `min_size` is configured (0 fails the lower bound), so the live case is **max set, min unset**.
**Fix:** one guard — treat unknown size as *failing* the upper band when a `max_size` is configured
(or score it last). Fixes both the movie and TV paths at once.

### S3 · `default_transaction_mode: :immediate` — make `busy_timeout` actually govern the multi-writer transactions
`config/runtime.exs:147` / `config/dev.exs:11` (no `default_transaction_mode`) · *concurrency* · **low (linchpin of the locked SQLite decision)**

`refresh_series` (and `register_user`'s first-admin count, and `create_pending`) run a **deferred**
read-then-write transaction: a `SELECT` takes a WAL read snapshot, then the writes try to upgrade
the lock. Exqlite defaults to `BEGIN` (deferred), so a concurrent writer can produce
`SQLITE_BUSY_SNAPSHOT`, which `busy_timeout` does **not** retry. M0's concurrency test proves the
*immediate-mode connection-layer* behaviour, but the app's real transactions are deferred — so the
WAL + `busy_timeout` contract that the whole "SQLite stays" decision rests on doesn't fully cover
them. **Fix:** set `default_transaction_mode: :immediate` on `Cinder.Repo` (runtime + dev). One
line; every `Repo.transaction` then takes the write lock upfront and `busy_timeout` governs.
This also closes S8 (double-admin race).

### S4 · `sanitize()` leaves `..`/`.` intact → path-traversal in the import dest
`lib/cinder/library.ex:247–251` (also covers `build_episode_dest`) · *library* · **low (security-adjacent)**

`@illegal` strips slashes/colons but not dots. A movie titled `".."` (no year) → `library_name`
returns `".."` → `Path.join([root, "..", "...mkv"])` escapes one dir above the library root. Low
reachability (titles come from TMDB), but it's a filesystem-write path in a public product. **Fix:**
route names matching `^\.+$` into the tmdb-id fallback inside `sanitize` — one guard covers movies
and episodes.

### S5 · `/activity` retry crashes the LiveView on a forged `phx-value`
`lib/cinder_web/live/activity_live.ex:49–53` (root cause `lib/cinder/catalog.ex:125`) · *web* · **low (robustness)**

The `retry` handler passes the client-controlled `phx-value-id` straight into
`Catalog.get_movie_by_id/1` → `Repo.get(Movie, id)` with no cast guard; `phx-value-id="x"` raises
`Ecto.Query.CastError` and crashes the LiveView. Admin-only route, so not a security hole — but a
crash on bad input. **Fix:** look the movie up from `socket.assigns.movies` (the convention the
other handlers already use), not `get_movie_by_id`.

### S6 · SABnzbd add is a side-effecting GET that Req auto-retries → duplicate downloads
`lib/cinder/download/client/sabnzbd.ex:28–38`, `config/runtime.exs:42–46` · *clients* · **low**

`add/1` issues `GET /api?mode=addurl`. Req's default `:safe_transient` policy retries GETs up to 3×
on transient failures, and `addurl` is side-effecting — each retry re-queues the same NZB. **Fix:**
`retry: false` on the add call (or in the Sabnzbd client's `req_options`).

---

## 3. Optional code hardening (real, low, safe to defer)

| # | Finding | Location | Fix |
|---|---|---|---|
| H1 | Two movies sharing Title+Year collide on dest; `:eexist` masks it as success → second movie mis-linked | `library.ex:231–242` | Disambiguate folder with `tmdb_id` (`Title (Year) [tmdbid-N]`, Jellyfin-supported), or stat same-inode before treating `:eexist` as success |
| H2 | Duplicate-source pack (two files parse same `SxxEyy`) records one episode from two files | `library.ex:118–126,155–166` | Dedupe matched pairs per episode before `link_all`; route extras to unmatched (logged) |
| H3 | Admin quota change (`update_user_quota`) writes no `admin_audit` row — every other destructive admin action does | `accounts.ex:230–232` | Wrap in a txn + `Audit.log_or_rollback`; needs an `actor` arg threaded from `users_live` |
| H4 | Concurrent `refresh_series` renumber can mislabel an in-flight grab's imported files | `tv_poller.ex:119–132` + `library.ex` + `catalog.ex:990–1024` | In `reconcile`, skip renumbering rows that currently own a `grab_id` |
| H5 | WAL + `busy_timeout` set in dev/test and the *prod branch* of runtime — a non-prod release omits both | `runtime.exs:136–148` | Centralize in `config.exs` `config :cinder, Cinder.Repo`, or assert at boot |
| H6 | `foreign_keys` pinned in dev/test but not runtime (relies on exqlite default `:on`) | `runtime.exs:144–148` | Add `foreign_keys: :on` — one line, zero behaviour change today |
| H7 | First-admin count runs in a deferred txn → two concurrent first-run registrations could both become admin | `accounts.ex:78–91` | Mitigated by S3 (`:immediate`); first-run window is seconds and operator-controlled |
| — | *Not actioned:* movie import that hardlinks then fails the `:available` transition re-imports each tick | `poller.ex:172–179` | **Deliberate, commented** ignore-and-retry; a *permanent* transition failure isn't reachable. Left as-is by design. |

---

## 4. Docs (do at tag time — cheap)

- **Roll `CHANGELOG [Unreleased]` → `## [1.0.0] - <date>`** and bump `mix.exs` to `1.0.0`; keep the
  **BREAKING** per-kind library rename (`LIBRARY_PATH` → `MOVIES_LIBRARY_PATH` + `TV_LIBRARY_PATH`)
  loud with its migration step. (This is the tag-time mechanical step; today's `[Unreleased]` is
  honest, just unversioned.)
- Docs reference `MOVIES_LIBRARY_PATH`, but the only published image (`:latest` = 0.7.0) predates
  the rename — **resolves itself when v1.0.0 is tagged from HEAD** (the point of this audit).
- `operating.md` boot-only key list omits `RELEASE_NAME` (README/CLAUDE.md list it) — add it.
- **Backups:** the docs name the `-wal`/`-shm` sidecars but don't warn that a hot `cp` of a live WAL
  DB can be torn. Add: stop the container, or use `sqlite3 .backup` / `VACUUM INTO`.
- One-line **air-date caveat:** eligibility is evaluated by UTC calendar day; an episode can flip
  `:wanted` up to ~a day early/late vs an operator far from UTC. (Don't build a timezone subsystem.)
- Make the **registration/exposure warning louder** and add that self-registered accounts are
  **auto-confirmed** (can log in + submit requests immediately) — pair with the "don't expose :4000"
  note. There is no rate-limiting on register/login (accepted household ceiling, but say so).
- Confirm `operating.md` states: **`SECRET_KEY_BASE` compromise = every stored credential
  compromised**, and rotation forces re-entering all secrets (the vault key is derived from it).

---

## 5. Confirmed sound — no action (highlights)

The adversarial pass spent as much effort confirming strengths as finding faults. Notably:

- ✅ **The approval gate is closed (movies *and* TV).** `Requests.create_request/2` is the only
  user-facing creation path; a non-admin without `auto_approve_all` routes to `create_pending`,
  which inside one transaction does **only** a `Request` insert — it never calls
  `find_or_create_at_requested` / `find_or_create_series_at_requested`. So a non-admin can never
  put a movie at `:requested` or spawn a monitored (auto-grabbing) series tree before an admin
  approves. *This is the #1 release risk and it holds.* (Independently re-read by hand.)
- ✅ **Session/token/sudo/IDOR** controls are correct (fixation prevented, 32-byte DB-backed tokens,
  14-day expiry, signed `Lax` remember-me, per-user request scoping).
- ✅ **Choke-point discipline holds** — no raw `Repo.update` on `status`/`file_path`/`grab_id`
  sidesteps `transition`/`transition_episode`/the grab lifecycle anywhere, web layer included.
- ✅ **Best-effort scan** correctly handles errors, raises *and* exits — a failed media-server scan
  never strands a correctly-imported file.
- ✅ **Secrets at rest:** AES-GCM, secret rows only, key from `SECRET_KEY_BASE`; a wrong-key secret
  is skipped (never poured into env), never echoed to the form; boot ordering is right.
- ✅ **No refresh/grab data-corruption race**; the `file_path`-XOR-`grab_id` invariant is preserved.
- ✅ Renamed-key upgrade **fails safe** (hold, not data loss) and is documented.
- ✅ Malformed/HTML "torrents" park as `{:error, :bad_torrent}`; clients return error tuples, never
  raise into the pipeline; NUL-in-title fails gracefully.

Accepted/documented ceilings restated (no action for v1.0): open-registration bootstrap window;
deny-then-delete re-opens a re-request (UI-surfaced); SSRF surface on the trusted-indexer `.torrent`
fetch; qBittorrent magnet "success" isn't confirmed against a follow-up poll (homelab sign-off);
title-match guard false-negatives on qualifier titles like *The Office (US)* (self-heals after one
Refresher pass backfills `tvdb_id`); no `/health` endpoint; vault key reproducible from
`SECRET_KEY_BASE`; three pollers share a 5s interval (WAL + `busy_timeout` makes overlap correct);
PubSub handlers re-read the full watchlist (single-household scale); inert magic-link generator code.

## 6. Refuted (checked and dismissed)

- "Lone-episode fallback blocked by a numbered sibling" — **intentional and explicitly tested**
  (`library_test.exs:268`): never mislabel a clearly-numbered other episode as the wanted one.
- "Partial settings-overlay degrades silently" — unreachable (the only DB read happens once, before
  any `put_env`; a failure means nothing overlays).
- "Season request doesn't validate `season_number`" — unreachable (the sole caller only builds attrs
  from an existing parsed season; the approval path nil-guards anyway).
- "Phase-aligned pollers maximize contention" — WAL + `busy_timeout` is precisely the design that
  makes a two-writer overlap correct, not flaky.

## 7. The real remaining gate — pending live homelab sign-offs (from ROADMAP M8)

These need real hardware and are the actual reason the version is still `0.7.0`:

1. **Fresh `docker compose up` → first-run wizard on the freshly built image** — *currently fails*
   on **B1**; re-test after the one-line fix.
2. **qBittorrent torrent grab end-to-end** — base32 magnet, `.torrent` URL fetch, and a
   malformed/HTML "torrent" parking gracefully (code path verified; live run pending).
3. **Live TV season-pack** grabs + imports into Jellyfin/Plex.
4. **`/activity` (ex-`/status`) badge-advance** visual check.

---

## Recommendation

Fix **B1** (mandatory), then **S1–S6** (all cheap, all real, none risky), then run the four live
sign-offs. **S3** (`:immediate`) is the one I'd push hardest among the "low" items — it's a one-line
change that makes the locked SQLite-correctness decision actually hold for the app's real
transactions. After that, the tree is in a tag-able state: roll the changelog, bump to `1.0.0`, and
cut the tag. No architectural rework is warranted — the foundations are sound.
