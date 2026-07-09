# Full pre-release audit — 2026-07-09

Seven parallel passes over the whole tree at `cbe6d73`: security, the four Cinder
invariants, LiveView UI/accessibility, the parser/import subsystem, silent failures,
DRY/over-engineering, and packaging/docs. Baseline: the strict `mix test` alias is green
(1028 tests), `mix hex.audit` reports 6 CVEs.

## Verdict

The security spine, import path safety, and accessibility are in unusually good shape —
all four invariants verified clean, auth internals solid, no injection sinks, secrets
never echoed or logged. What blocks a public announcement is: **known-CVE dependencies,
two verified wrong-media bugs in the acquisition path, two high-impact silent failures,
a stale README, and an unsafe compose port default.** Everything below is ranked; each
finding carries file:line and the minimal fix.

---

## P0 — fix before announcing

> **[all 8 fixed 2026-07-09]** — same session as the audit. Deps updated (`mix hex.audit`
> clean), the four code bugs fixed with regression tests (parser fixture, two title-guard
> tests, a Disk error-propagation test, and the extended TvPoller search-park test now
> asserting the announce-once notification + the derived `:search_parked` state), compose
> rebound to `127.0.0.1`, README status rewritten, ignore files patched. `mix test` green
> (1032). The episode-state derivation was centralized as `Catalog.episode_state/2` (the
> P2 "three drifting copies" item) since every copy needed the new state anyway.

### 1. Six known CVEs in shipped dependencies (4 HIGH)
`mix hex.audit`: `plug 1.19.2` (quadratic query-param decoding DoS, CVE-2026-54892),
`phoenix 1.8.8` (unbounded channel joins → process exhaustion, CVE-2026-56811),
`mint 1.9.0` (unbounded chunk buffering, CVE-2026-56810), `hpax 1.0.3` (HPACK integer
DoS, CVE-2026-58226); plus phoenix presence-JS (MED) and swoosh Graph adapter (LOW).
All have fixed releases (`phoenix 1.8.9` is out; `phoenix_live_view`, `req`, `swoosh`
also have minor bumps).
**Fix:** `mix deps.update phoenix phoenix_live_view plug mint hpax swoosh req`, re-run
`mix hex.audit` + `mix test`.

### 2. `S01-E02` parses as a whole-season pack → mis-grab + blocklist poisoning
`lib/cinder/acquisition/parser.ex:206` — the season→episode separator class `[._ ]?`
omits `-`. `Show.S01-E02.1080p…` falls through to `@bare_season` and becomes
`season: 1, episodes: nil` (a pack). Verified: in `Scorer.select_for` that fake pack
covers every wanted episode and beats a genuine 20 GB season pack on resolution; the
grab then imports nothing, parks, **blocklists the release**, and burns
`search_attempts` on all wanted episodes.
**Fix:** widen to `[._ -]?` (safe: `S01-S02` is pre-rejected by `multi_season?`,
`S01-1080p` still requires `e\d`); add `"Show.Name.S01-E02…" ⇒ {1, [2]}` to the parser
fixture matrix (currently uncovered).

### 3. Numeric series titles false-accept other shows → wrong media imported
`lib/cinder/acquisition.ex:174` — `title_matches?/2` is a normalized substring match, so
series "24" or "1923" matches any other show's release carrying a year in its name
(`Other.Show.2024.S01E05…` ⊃ `"24"`); the scorer then matches on season number alone and
a wholly different show is grabbed and imported under the series.
**Fix:** on the free-text fallback path require the normalized release title to *start
with* the normalized series title (scene names lead with the title), or at minimum
prefix-anchor short/all-numeric titles.

### 4. FS read errors become "empty directory" → good releases permanently parked + blocklisted
`lib/cinder/library/filesystem/disk.ex:20-33` — `find_files/1` swallows `File.ls`
errors (`EACCES` — the documented compose permission gotcha — `EIO`, an unmounted
downloads volume) into `{:ok, []}`. Downstream that's classified as a *deterministic
release defect*: movies park `:import_failed` + `Catalog.block_release`
(`poller.ex:155,255`); TV parks `:no_files_matched` + `block_grab_release`
(`tv_poller.ex:93-97,242`). A 30-second mount blip during an import tick permanently
blocks the best release, and the log ("no video file") is actively misleading.
**Fix:** return `{:error, reason}` from the top-level `File.ls` failure (the behaviour
contract already allows it and every caller already treats `{:error, _}` as transient —
bounded retry, no blocklist); keep nested `File.stat` failures best-effort but add a
`Logger.warning` in `classify`'s fallback.

### 5. TV search exhaustion is completely invisible
`lib/cinder/download/tv_poller.ex:131,157-158` — episodes with
`search_attempts >= @max_attempts` are silently dropped from the sweep forever, with no
log on any attempt including the 10th, no Notifier event, and no UI state
(`core_components.ex:688-696` has no "gave up" badge; `series_detail_live.ex:344-348`
and `calendar_live.ex:37-41` ignore `search_attempts`). The movie analogue parks visibly
at `:search_failed` with a red badge + Retry + `{:movie_failed, …}`. A TV episode shows
**"Wanted" forever** while nothing will ever search it again.
**Fix:** `Logger.warning` + `Notifier.notify({:episode_search_exhausted, episode})` when
crossing the bound in `bump_not_grabbed`; derive a `:search_parked` badge
(`search_attempts >= 10` on a still-wanted episode) — the data is already loaded in both
views. No schema change.

### 6. Compose default exposes the admin-bootstrap window to the whole network (MEDIUM)
`docker-compose.yml` `ports: "4000:4000"` binds 0.0.0.0. First registrant becomes
permanent admin (`accounts.ex:78-92`), registration is open by design, and the
quickstart only ever browses `localhost`. On a LAN/VPS, anyone reaching :4000 before the
operator owns the instance (settings, service creds, disk writes).
**Fix:** ship `"127.0.0.1:4000:4000"` as the default; make LAN/proxy exposure the
documented, deliberate edit.

### 7. README front page is stale: "pre-1.0 (v0.7.0)" — but v1.0.0 is tagged and released
`README.md:12-14` vs `mix.exs:4` (`1.0.0`), `CHANGELOG.md:15` (`[1.0.0] - 2026-07-03`),
and the existing `v1.0.0` git tag.
**Fix:** rewrite the Status blurb for the launched state.

### 8. `.env` is in neither `.gitignore` nor `.dockerignore`
The quickstart tells every user to create `.env` containing `SECRET_KEY_BASE` (which
also derives the Cloak at-rest key) inside the clone; one casual `git add .` publishes
it. Nothing leaks into the image today (verified), but the build context contains it.
**Fix:** add `.env` to both; add `*.db*` to `.dockerignore` while there
(`cinder_dev.db`'s settings table can hold real creds). Also add
`.claude/settings.local.json` to `.gitignore` (currently untracked *and* unignored).

---

## P1 — should fix soon after (or before, they're small)

> **[fixed 2026-07-09]** — code items in PR #75 (plus its own review round: async approvals keyed
> per request, the update_password/rate-limiter interaction, availability semantics for `:future`
> seasons), docs items in PR #76. Exception: README **screenshots** still need a running instance
> to capture — the one item left for the maintainer.

### UI/UX
- **Single season-approve freezes the page** — `requests_live.ex:34`,
  `dashboard_live.ex:51`, `series_discovery_live.ex:69`: the seconds-long
  `find_or_create_series_at_requested` (1+N TMDB calls) runs synchronously in
  `handle_event`; the bulk path already uses `start_async` (`requests_live.ex:127-129`)
  for exactly this reason. Route single approves through the same pattern.
- **Season badges never reach "Available"** — `series_discovery_live.ex:220`,
  `my_requests_live.ex:67-72`: badges derive purely from request rows, so a fully
  imported season still reads "Denied"/"Approved" forever. Consult local series state
  (all episodes have `file_path` for the season) and rank `:available` above request
  status, mirroring the movie `title_state/3`.
- **Any season-request changeset error flashes "already requested"** —
  `series_discovery_live.ex:103`: the clause matches every `%Ecto.Changeset{}`; the
  comment describes a unique-violation check the code doesn't perform.
  `DiscoverLive.duplicate_request?/1` (discover_live.ex:123-134) does it right — move it
  to `LiveHelpers` and reuse.
- **"Cancel upgrade" failures are silent** — `activity_live.ex:136`:
  `Catalog.abort_upgrade/2`'s `{:error, :not_upgrading}` race result is discarded; the
  sibling `retry` handler (lines 78-87) flashes for the same race. Match and flash.
- **Silent no-op actions on `/series/:id`** — `series_detail_live.ex:228` (language
  dropdown snaps back with no flash) and `:232-250` (unconditional "Searching…" flash
  even when `transition_episode` returned `{:error, _}`). Case on results, flash errors.

### Silent failures
- **ffprobe failures silently disable wrong-language protection** — `library.ex:290`
  (`check_audio` `{:error, _} -> :ok`) and `library.ex:174-176`: a missing/broken
  `ffprobe` (media_info is on by default) means wrong-language files import "verified"
  and metadata reads as "no tags". One `Logger.warning` in the shared probe error path.
- **`TvPoller.import_grab` swallows `finish_grab` errors** — `tv_poller.ex:103-109`:
  no `else` clause, no retry bump — a deterministic finalize failure re-imports every
  5 s forever with nothing in the logs. Add
  `{:error, reason} -> retry_or_park(grab, {:finish_grab, reason})`.
- **Subtitle provider errors logged at `:info` as "no subtitle"** —
  `subtitles.ex:122-124`: a revoked OpenSubtitles key silently stops subtitles; split
  the clause, `Logger.warning` for `{:error, _}`.
- **`Settings.save/2` returns `:ok` unconditionally** — `settings.ex:396-404`: safe
  today only because the txn uses bang functions; propagate the transaction result so a
  future refactor can't turn "Settings saved." into a lie.

### Security hardening
- **No rate limiting on login/registration** — stock phx.gen.auth; unbounded online
  brute-force against a known admin email on a public host. A small per-IP+email ETS
  counter on the login action suffices at this scale.
- **Indexer-supplied `.torrent` URL fetch is blind SSRF** —
  `qbittorrent.ex:53-111`: URLs come from tracker responses, not admin config. Scheme
  is allowlisted, GET-only, body never reflected — matches the Radarr/Sonarr trust
  posture. Either document as accepted or reject loopback/link-local targets on
  redirect hops (the first hop legitimately goes to Prowlarr).

### Docs/packaging
- **README in-app config table incomplete** — missing the entire Subtitles group
  (`opensubtitles_*`, `subtitle_languages`), Discord notifications
  (`discord_webhook_url`), `move_on_import`, `auto_approve_all`, `media_server_type`
  (`README.md:69-76` vs `lib/cinder/settings.ex` registry).
- **CHANGELOG `[Unreleased]` missing shipped features** — Discord notifications
  (PR #65), movie/series detail pages, audio-language/subtitle metadata, the
  `{tmdb-N}` find-files fix.
- **LAN-access trap undocumented** — `config/prod.exs:13-19` `force_ssl` redirects
  `http://192.168.x.x:4000` to `https://<PHX_HOST>` (default `localhost`) and dies.
  One paragraph in operating.md: browse from the host, tunnel, or set `PHX_HOST` behind
  a proxy first.
- **Screenshots still TODO** — `README.md:105-108`; capture before announcing.
- **Discord notifications entirely undocumented** — one settings-table line + an
  operating.md note.
- **Manual-search panel shows every season pack as "out of band"** —
  `scorer.ex:94` via `manual_search_component.ex:70-75`: `verdict/2` applies the TV
  per-episode band flat, contradicting `select_for`'s k× scaling (display-only — the
  auto-pick is correct). Scale by covered-episode count or label packs explicitly.

---

## P2 — debt worth scheduling (ponytail pass)

> **[done 2026-07-09]** — all items landed (magic-link subtree deleted, PeriodicWorker merged
> into PollerSkeleton as the `stateful: false` flavour, episode-code/request-title/derivation
> dedups, dead scorer opt + config line + test-only Accounts fns removed, graphify-out
> untracked) EXCEPT the Req-boilerplate lift, intentionally left: the shared shape exists
> verbatim in fewer than three impls and each carries real service quirks. Net ≈ −2,000 lines.

Ranked biggest cut first; net ≈ **−480 lib lines** (−750 with tests):

- `delete:` the **magic-link login subtree is production-dead** — nothing calls
  `Accounts.deliver_login_instructions/2`, so the whole chain
  (`UserLive.Confirmation` + route, `login_user_by_magic_link/1`,
  `get_user_by_magic_link_token/1`, `User.confirm_changeset/1`,
  `UserToken.verify_magic_link_token_query/1`, `UserNotifier` bodies, two
  `UserSessionController.create` clauses) is unreachable outside tests. SMTP isn't
  wired in prod, so it never worked. ~260 lib + ~270 test lines.
- `dry:` `Cinder.PeriodicWorker` is an ~85 % copy of
  `Cinder.Download.PollerSkeleton` — merge into one `__using__` with
  `call_timeout:`/`search_backoff:` opts. ~−60 lines.
- `dry:` Req boilerplate hand-copied across 7 service impls — lift only the identical
  `base`/`error` halves into `Cinder.HTTP.new/2` + `classify/2` (each impl keeps its
  real quirks: qBit cookie login, SAB query auth). ~−60 lines.
- `delete:` `Accounts.get_user_by_email/1` and `get_user!/1` have zero lib callers
  (test-only). ~−30 lines.
- `dry:` the `S01E02` code + `pad/1` helper copy-pasted 4× — two copies carry "extract
  when a third consumer appears" comments; the third and fourth exist
  (`library.ex:512-523`, `calendar_live.ex:46-47`, `notifier/log.ex:25-36`,
  `notifier/discord.ex:107-118`). One `episode_code/2` on `Catalog.Episode`.
- `dry:` request-title snippet verbatim in 3 views → `request_title/1` in
  `LiveHelpers` (`dashboard_live.ex:197-203`, `requests_live.ex:272-278`,
  `my_requests_live.ex:58-64`).
- `dry:` derived episode state re-implemented in 3 places, kept honest only by
  "keep in lock-step" comments → `Catalog.episode_state/2` next to
  `wanted_episodes_query` (`calendar_live.ex:37-44`, `series_detail_live.ex:344-348`,
  `catalog.ex:1532-1540`). Kills the drift risk finding P0-5 touches.
- `delete:` Scorer's group `:blocklist` opt — no production caller, no `/settings`
  field (`scorer.ex:127,206-207`). Release-title blocklist keeps `:blocklisted`.
- `dry:` `Settings.plan_flat/3` byte-identical to the non-secret `plan_config/3`
  clause (`settings.ex:714-738`) — delegate.
- `delete:` `config :cinder, Cinder.Download.Poller, interval: 5_000` restates
  `@default_interval` (`config.exs:66`).
- Nice-to-haves from packaging: no container healthcheck (add only if an orchestrator
  needs it), `.env.example` missing the OpenSubtitles bootstrap vars
  (`runtime.exs:58-64`), stale `0.7.0` pin example in `docker-compose.yml:18`, no
  Dockerfile base-image bump mechanism (consider Renovate), untrack
  `graphify-out/GRAPH_REPORT.md` (1,167 lines of stale-prone tool output; the
  plans/specs scanned clean of secrets/hostnames and are fine to ship).

---

## Verified clean

- **All four Cinder invariants** (full-repo sweep): the approval gate isn't bypassable
  (server-built attrs, status/user_id not smuggleable; `add_to_watchlist` has zero
  non-admin callers; poller pickup unchanged); every sensitive route behind
  `require_admin` with actor always from `current_scope`; zero `Repo` writes outside
  the `Catalog.transition`/`transition_episode` choke-points in download/library/
  acquisition; secrets never echoed or logged (grown secret set fully registered,
  `type="password" value=""`, key-only decrypt logging, header-borne API keys).
- **Auth internals** (stock phx.gen.auth, correctly kept): hashed single-use tokens,
  session rotation, all-token revocation on password change, fail-closed sudo mode,
  timing decoy, role/`confirmed_at` never castable; first-user-admin race actually
  closed by `default_transaction_mode: :immediate`.
- **Injection/sinks**: no raw SQL with user input, no `raw/1`, no
  `String.to_atom`/`binary_to_term` on external input, `ffprobe` via arg-list
  `System.cmd`. **Path safety**: dest names sanitized, `delete_file/1` fail-closed
  inside expanded library roots, no release-derived string reaches a dest path.
- **IDOR**: every id-carrying admin event re-resolves the target server-side;
  forged payloads fall to catch-all no-ops; last-admin/self-delete guards re-checked
  in-transaction with audit rows.
- **Accessibility & LiveView correctness** (all 22 view/component files): labels
  associated, icon-only controls labeled, badges icon+label (never color-alone), skip
  link, theme radiogroup with roving tabindex; subscribe-under-`connected?`,
  catch-all `handle_info`/`handle_event` everywhere, broadcast shapes verified,
  defensive param parsing throughout.
- **Parser/scorer/import** beyond the two P0s: precedence order and all nil-park
  valves verified empirically; blocklist round-trip exact; k× band scaling in `cover`;
  unmatched/wrong-audio files logged, never silently dropped; grab lifecycle ordering
  correct in both pollers.
- **Packaging**: multi-stage Dockerfile, runs as `nobody`, no secrets/source in the
  image, boot migrations confirmed, compose↔`runtime.exs` env contract fully matched,
  quickstart traced end-to-end, CI runs the real strict alias, release workflow +
  GHCR + OCI labels correct, GPL-3.0-or-later consistent everywhere, operating.md
  caveats all still accurate against code.

## Suggested order

1. `mix deps.update` for the CVEs (P0-1) — mechanical, do it first, re-run the suite.
2. The two acquisition bugs (P0-2, P0-3) + fixture rows — small regex/guard diffs.
3. The two silent-failure HIGHs (P0-4, P0-5) — both are "media silently never
   arrives" class.
4. Compose binding, README status, ignore files (P0-6..8) — minutes each.
5. P1 as one cleanup PR (UI flashes + logging + docs).
6. P2 at leisure; the magic-link deletion is the one worth doing before strangers
   start reading the code.
