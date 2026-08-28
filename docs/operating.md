# Operating Cinder

Operator guide for a self-hosted Cinder instance. For the architecture/build plan see
[`ROADMAP.md`](../ROADMAP.md); for local development see [`CONTRIBUTING.md`](../CONTRIBUTING.md).

## Deploy

The [`docker-compose.yml`](../docker-compose.yml) at the repo root is the supported deployment.
Copy `.env.example` to `.env`, set `SECRET_KEY_BASE` (`openssl rand -base64 48`), then
`docker compose up -d`. The container migrates the database on boot and serves on port 4000.

**Before upgrading** (`docker compose pull && docker compose up -d`), snapshot `/data` — see
[Backups](#backups) below for the safe (non-`cp`) way to copy a live SQLite database.

> **Upgrading from an early image:** the container owns its `/data` volume so a *fresh* `docker
> compose up` can write the database. Docker only sets a named volume's ownership when it's first
> created, so a `cinder_data` volume left root-owned by a pre-fix image keeps crash-looping after an
> upgrade. If the container can't write the DB after pulling a newer image, recreate the empty
> volume (`docker compose down && docker volume rm <project>_cinder_data`) or
> `chown -R 65534 /var/lib/docker/volumes/<project>_cinder_data/_data`.

## First run & security

Claiming the first account requires the one-time **`CINDER_BOOTSTRAP_TOKEN`** (set in
`docker-compose.yml`/`.env`, `openssl rand -hex 32`): while no admin exists yet, registration only
succeeds if the submitted bootstrap-token field matches it, and that registrant becomes the
**admin**. A fresh instance with no token configured fails closed — it cannot create the first
account at all, so an exposed, not-yet-claimed instance can't be taken over by a stranger who just
finds it first. The first-run wizard (`/setup`) then collects your service config and validates it;
remove the token from your deployment once the admin is claimed (it isn't needed again unless every
admin account is later deleted).

Registration stays **open** after the admin exists — that's how other household members sign up —
but a later self-registration is no longer trusted automatically: the account is created
**inactive** and, after logging in, lands on a "pending approval" page rather than the app. An
admin must **activate** it from `/users` before the new account can search, request, or do anything
else (a configured notifier pings the admin when one is waiting). Self-registered accounts are still
**auto-confirmed** (no email-confirmation step) even while inactive — confirmation and activation
are separate gates.

Because the admin-claim step happens over plain HTTP on `0.0.0.0:4000` (TLS is expected to
terminate at a reverse proxy):

- **Keep the bootstrap token private and set it before first boot.** It's the only thing standing
  between an exposed, unclaimed instance and a stranger claiming admin.
- **Do not expose port 4000 to an untrusted network.** Run Cinder behind a reverse proxy (with TLS)
  or a VPN — this is the real access control, since an unclaimed instance still accepts (bootstrap
  gated) registration attempts and a claimed one still accepts (now inactive-pending) self-signups
  from anyone who can reach it.
- **Registration is rate-limited per source IP:** at most 10 registration attempts per minute per
  IP (blocked attempts get a generic "too many attempts" flash). Behind a reverse proxy or tunnel
  that doesn't forward the real client IP, every visitor shares one bucket — see the login-limiter
  caveat below for the same effect.
- **Login rate limiting:** password login is capped at 10 failures per `{ip, email}` per 15
  minutes (blocked attempts get the same generic error as bad credentials). Behind a reverse
  proxy every client shares the proxy's IP, so the cap is effectively per-email there — meaning
  anyone who can reach the login page can lock a known email's password login for a window
  (a targeted-lockout nuisance, accepted at household scale; an authenticated password change
  always clears the block).
- **Browsing over plain HTTP from another machine won't work.** In production Cinder redirects
  any non-`localhost` HTTP request to `https://$PHX_HOST`. The compose default binds
  `127.0.0.1:4000`, so the quickstart (browsing from the Docker host) just works — but the
  common homelab case, compose on a NAS and a browser at `http://192.168.x.x:4000`, gets
  redirected to a dead HTTPS URL. Either browse from the host (or an SSH tunnel), or put the
  TLS-terminating reverse proxy up first and set `PHX_HOST` to its domain.
- **Optional outer Basic-auth gate:** set `CINDER_BASIC_AUTH_USER` **and**
  `CINDER_BASIC_AUTH_PASSWORD` (environment, both required) to put HTTP Basic auth in front of the
  whole app — a stopgap while the instance has no admin yet (the boot log warns exactly then), or a
  second layer when you can't front Cinder with a proxy/VPN. Unset ⇒ no gate.
- **Sign in with Plex:** once a Plex media server is configured (`PLEX_URL`/`PLEX_TOKEN` or the
  `/settings` equivalents), the log-in page shows a "Sign in with Plex" button. Only Plex accounts
  with access to that server (owner or a shared user) may sign in — anyone else is rejected. The
  first successful Plex login always creates a new regular-user account — Plex's reported email is
  never used to look up or log into an existing account, since email isn't proof of inbox
  ownership and that would let anyone with mere watch access log in as whoever happens to share it.
  A Plex Home managed account with no email can't sign in this way. To attach Plex to an existing
  account (e.g. an admin who registered by password), log in normally and link it from Account
  settings (`/users/settings`).
- **Plex watchlist sync (opt-in, per user):** a Plex-linked user can switch on "Request titles I
  add to my Plex watchlist" in Account settings (`/users/settings`); it is off by default and only
  that account's owner can turn it on — there is no household-wide switch. A background sweep
  checks each opted-in user's Plex watchlist about every 15 minutes. A new movie becomes one
  request; a show is looked up in TMDB and becomes one request for each currently known numbered
  season (`1` and up). Season 0 specials stay manual because adding a show to a Plex watchlist does
  not express an intent to fetch its extras. Every request is made **by that user**, so the approval
  gate and their request quota apply independently, exactly as if they had clicked Add. A season
  that could not be submitted (for example, because quota is exhausted) remains unmarked and is
  retried; a newly published season is picked up on a later sweep while the show remains
  watchlisted. Removing a title does nothing: nothing is un-requested or deleted. Sync needs the
  Plex auth token from sign-in, stored encrypted at rest alongside the settings secrets; if Plex
  later rejects it, sync switches itself off for that user alone and they can re-link to resume.
- **Sign in with OpenID Connect:** configure **OIDC issuer URL**, **OIDC client id**, and **OIDC
  client secret** in the Accounts section of `/settings`, then register the exact callback
  `https://<PHX_HOST>/auth/oidc/callback` with the provider. This first version supports one
  confidential, HTTPS, discovery-capable OIDC provider using `client_secret_basic` with
  RS256-signed ID tokens, and requests the `openid email profile` scopes. Standard claims may come
  from the ID token or UserInfo endpoint.
  Production callback URLs require the TLS reverse proxy and correct `PHX_HOST` described above.
  The client secret is encrypted at rest and never echoed back by the settings form; provider
  access/refresh tokens are not stored. On first sign-in, a standard boolean
  `email_verified: true` claim is required: its email may attach the stable issuer/subject identity
  to an existing account, or creates an inactive regular user for admin approval. OIDC never
  creates the first admin. Once linked, later sign-ins use issuer + subject and do not depend on an
  unchanged email claim. Providers that omit `email_verified` cannot create or attach accounts.
- **Sign in with Jellyfin:** once a Jellyfin server is configured (`JELLYFIN_URL` or the
  `/settings` equivalent), the log-in page shows a "Sign in with Jellyfin" username/password form,
  checked against that server's own `Users/AuthenticateByName` — so only accounts the server
  already knows can sign in, and no API key is needed for it. The same rules as Plex apply: the
  first successful Jellyfin login always creates a new regular-user account (role `:user`, awaiting
  admin approval), never an email-based login into an existing one, and attaching Jellyfin to an
  existing account is an explicit action from Account settings. Jellyfin exposes no email address,
  so a created account gets a placeholder `…@jellyfin.invalid` one with email notifications off
  until its owner sets a real address. Attempts are rate-limited exactly like password login. Emby
  serves the same endpoint and should work if you point `JELLYFIN_URL` at one — untested.
  One wrinkle for early installs: an account imported from Jellyfin before Cinder started recording
  the Jellyfin id at import time carries no id, so its owner's first "Sign in with Jellyfin" creates
  a *second*, pending account instead of logging them in, and re-running the import will not repair
  it. The address Jellyfin reports is derived from a display name, which is not proof of inbox
  ownership, so Cinder will not link the two for you. Repair it by hand from `/users`: **Reset
  password** on the original account, let its owner sign in with that password and link Jellyfin
  from Account settings, then deny the duplicate.

## Privacy & GDPR

The instance operator is the data controller. Cinder stores user emails, hashed passwords,
locales, email-notification preferences (`notify_email`), and Plex identifiers/usernames
(`plex_id`, `plex_username`), Jellyfin identifiers/usernames, and OIDC issuer/subject/display name;
session and email-change tokens (including a `sent_to` copy of the email); requests attributed by
`user_id`; and an append-only `admin_audit` trail containing actor ids only.

When configured, the SMTP relay receives user email addresses and request titles, Discord receives
request notifications without email addresses, plex.tv handles its authentication/watchlist calls
using the linked user's encrypted token, and the OIDC provider handles the authorization round-trip
without Cinder storing its access or refresh tokens. TMDB and Prowlarr receive no user identity.

Users can delete their own account, and admins can delete accounts from `/users`; deletion cascades
tokens and requests, while audit rows retain only numeric ids and any email values are scrubbed.
Users can also download their per-user JSON export from the settings page. A daily janitor prunes
expired tokens and `admin_audit` rows older than 365 days.

SQLite backups contain all of this data and must be protected and retired consistently with account
erasure. The `smtp_username` setting is stored unencrypted in the settings table.

## Configuration: environment vs in-app

Boot-only keys (`SECRET_KEY_BASE`, `DATABASE_PATH`, `PHX_*`, `PORT`, `POOL_SIZE`, `RELEASE_NAME`,
`DNS_CLUSTER_QUERY`) stay in the environment. Everything else — TMDB, indexer, download clients,
media server, the standard per-kind library roots (`movies_library_path`, `tv_library_path`), the
per-kind size bands, subtitles, and notifications — is edited at `/settings` and stored in the
database. **DB values override the env bootstrap; clearing a setting reverts to the env
value/default.** Secret fields are encrypted at rest with a key derived from `SECRET_KEY_BASE`.

### Download clients and completed-torrent cleanup

Choose at most one client for each protocol in `/settings`: **qBittorrent or Transmission** for
torrents, and **SABnzbd or NZBGet** for Usenet. A disabled protocol is never searched or polled.
Transmission support requires its label-capable RPC API (RPC version 16+, provided by
Transmission 3 and 4). Each client health check verifies authentication and any configured local
path prefix; the normal poller, retry adoption, content checks, and importer continue to use the
shared download-client contract.

Completed torrents seed indefinitely by default. To reclaim them automatically, set a positive
**ratio**, a positive **seed time in hours**, or both under Download. Cinder reads the clients'
native qBittorrent/Transmission metrics and removes a completed torrent after either configured
limit is reached, but only after the import/request lifecycle no longer owns that download.
Missing metrics never trigger deletion. Clearing both fields returns to indefinite seeding; the
limits do not apply to Usenet jobs.

### Discord notifications

Set a **Discord webhook URL** under Notifications in `/settings` and Cinder posts an embed on
request approvals, newly-available movies/episodes, and pipeline failures (including a TV season
whose search budget is exhausted). Unset, events go to the server log only. Posts are best-effort
with a 3-second timeout — a Discord outage never touches the pipeline.

### Trust posture: indexer-supplied download URLs

Cinder fetches `.torrent` and `.nzb` files from whatever URL the indexer returns (scheme-limited to
http/https, response used only to identify or hand bytes to the download client — never rendered). That
means your indexer/trackers can, in principle, make Cinder issue GET requests to arbitrary
addresses — the same posture as Radarr/Sonarr. You chose the indexer; point Cinder only at one
you trust.

Cinder rejects URLs and magnet/tracker hosts that resolve to loopback, RFC1918, link-local, or
cloud-metadata addresses before fetching them. Because that pre-check resolves the host and the HTTP
client then resolves again independently at connect time, a narrow DNS-rebinding window remains
(documented in `lib/cinder/http_policy.ex`). The robust mitigation is a **network egress ACL** that
denies the Cinder container outbound access to internal ranges — `127.0.0.0/8`, `10.0.0.0/8`,
`172.16.0.0/12`, `192.168.0.0/16`, and `169.254.0.0/16` (which includes the `169.254.169.254`
cloud-metadata endpoint). Enforce it at the host firewall, a filtering proxy, or your orchestrator's
network policy; Docker Compose has no native egress filter.

## Hardlink, with an automatic safe-copy fallback

On a completed download Cinder **hardlinks** the file into the library — instant, no copy, no extra
disk. When a hardlink isn't possible Cinder **automatically falls back to a crash-safe copy**. A
hidden journaled candidate is built first. If the library filesystem also rejects the final
candidate hardlink, Cinder exclusively creates the destination (never overwriting another creator),
records its identity, and streams bounded chunks. Cinder does not commit or request a media-server
scan until that stream completes; a crash leaves an identifiable partial that recovery safely
removes or rolls back. A media server independently watching the directory may briefly notice that
in-progress file before Cinder commits it. This covers both the download and library living on
**different** filesystems *and* a single mount whose filesystem has no hardlink support at all
(FAT/exFAT on a USB drive, SMB/CIFS without Unix extensions, some FUSE mounts). No configuration —
Cinder detects the case and switches per import; a log line records each fallback.

Keep both on the **same filesystem** when you can — it's faster and uses no extra disk. The compose
file keeps both under one `/media` mount (`/media/movies`, `/media/tv`, `/media/downloads`). The copy
fallback only matters when you can't:

- **Extra disk.** A copy keeps **both** the download and the library file, so a cross-filesystem
  import permanently consumes **2×** the file's size. `move_on_import` reclaims that, but only for
  **Usenet** imports — it deletes the source after a successful import and never touches a torrent.
- **Time.** A copy takes time proportional to the file size and runs inside the poller tick, so a
  large file (or a serially-copied season pack) briefly serializes other pipeline work. Fine at
  single-household scale.
- Cinder's container runs as `nobody` (uid/gid **65534**). Give your download client a matching
  `PUID`/`PGID` (the linuxserver.io images take these env vars), or a shared group with group write
  — otherwise the link **or copy** fails with a permission error and the item parks as
  `:import_failed`.

If a download client reports paths from a different host or container namespace, configure
that client's remote and local path prefixes in `/settings`. For example, if the client reports
`/downloads/Movie.mkv` but Cinder mounts the same directory at `/media/downloads`, map remote
`/downloads` to local `/media/downloads`. The client health check verifies that the configured
local prefix is an existing readable directory.

## Backups

Back up the SQLite database — the `/data` volume (`cinder.db` plus its `-wal`/`-shm` sidecars).
That's the entire app state.

When background polling is enabled, Cinder creates a verified online snapshot shortly after
startup and about every 24 hours thereafter. By default these private mode-`0600` files live in
`/data/backups` and only the newest **seven** Cinder-owned snapshots are retained. Every snapshot
must pass SQLite's full `PRAGMA integrity_check` before it counts as successful; a failed attempt
is removed and does not prune an older good copy. The Settings download button uses this same
snapshot implementation for an on-demand copy.

Retention bounds local recovery copies, but it is not an off-host backup. Regularly copy a
verified snapshot and the matching `SECRET_KEY_BASE` to separate protected storage. Media files
are not in the SQLite snapshot and need their own backup policy.

**Don't `cp` a live WAL database.** Cinder runs SQLite in WAL mode, so at any moment recent writes
live in the `-wal` sidecar, not yet in `cinder.db`. A plain `cp` of the files while the container is
running can capture a torn, inconsistent snapshot. Either:

- **stop the container first** (`docker compose stop cinder`), then copy `/data`; or
- take a consistent online copy with SQLite's own tooling, e.g.
  `sqlite3 /data/cinder.db ".backup /data/backup.db"` or `VACUUM INTO`.

**Keep `SECRET_KEY_BASE` with the backup.** It's the master key: the at-rest encryption key for
stored secrets is *derived from it*, so **a leaked `SECRET_KEY_BASE` compromises every stored
service credential**, and losing it (or rotating it) means re-entering every credential in
`/settings` after a restore.

To verify a restore candidate independently, run
`sqlite3 /path/to/cinder-backup.sqlite3 "PRAGMA integrity_check;"` and require the single result
`ok`. To restore, stop Cinder, preserve the current database and WAL sidecars for diagnosis,
replace `cinder.db` with the verified snapshot using the expected owner and mode `0600`, then
restart with the original `SECRET_KEY_BASE`. Never overwrite a running WAL database.

### Database growth and reclaiming space

`blocked_releases` rows age out after **180 days** via the daily janitor sweep (they accrue one row
per distinct rejected release name — mostly audio/subtitle verification rejections — and are never
re-blocked); `:stalled`-reason rows also clear earlier on a manual retry. `admin_audit` rows are
pruned after 365 days. Over months or years of normal operation `cinder.db`
grows accordingly, and SQLite doesn't shrink the file on its own as old rows are deleted — freed
pages are just reused, not released back to the OS.

If the on-disk size becomes worth reclaiming, run an occasional `VACUUM` (rebuilds the file and
frees unused pages) via the same `sqlite3 /data/cinder.db` access pattern used above, e.g.
`sqlite3 /data/cinder.db "VACUUM;"`, or enable `PRAGMA auto_vacuum = INCREMENTAL` so it happens
continuously (set it before any tables exist, or run one full `VACUUM` right after enabling it on
an existing database, for the setting to take effect). Note that `VACUUM INTO` — the online-backup
command a few lines up — copies the *entire* database, so its cost scales with total DB size, not
with how much has changed since the last backup: expect that backup step to get slower as
`cinder.db` grows.

## Health & retry

`/dashboard` (admin) shows the **Service health** panel that pings each configured service (with a
**Recheck** button), the approval queue, and recent activity. `/activity` (admin) shows every
item's live pipeline state — a parked item (`:search_failed` / `:no_match` / `:import_failed`)
shows a **Retry** button there that resets it to `:requested` with attempt counters zeroed; the
poller re-queues it on the next tick. (The old `/status` and `/grabs` URLs redirect to
`/activity`.)

### Liveness probe (`/healthz`)

`GET /healthz` is an unauthenticated, dependency-free liveness endpoint (no DB call — it reads each
poller's last-tick timestamp from memory, so it stays fast and truthful even under load). It returns
**200 `ok`** when polling is disabled or every enabled background poller has ticked recently, and
**503** with a short plain-text body naming the stale poller when one's last *successful* tick is
older than **3× its interval** — i.e. a wedged or crash-looping pipeline the rest of the app can
still look healthy around. A just-booted poller that hasn't ticked yet is not counted stale (200).

The compose file wires this as the container `healthcheck`. **Caveat:** `docker compose` only *marks*
the container `unhealthy` on repeated failures — it does **not** restart it (`restart:` reacts to the
process exiting, not to a failing health probe). To actually restart on unhealthy, pair it with an
autoheal sidecar (e.g. `willfarrell/autoheal`) or run under an orchestrator (Kubernetes, Swarm,
Nomad) that acts on the reported health status.

The media-server library scan after an import is **best-effort**: if the scan call fails (e.g. an
endpoint/header mismatch on your Jellyfin/Plex version) the item still reaches `:available`, and
your server picks the file up on its next periodic scan.

Every 15 minutes, a separate bounded inventory reads movies and series from the configured media
server and reconciles them to Cinder by exact TMDB id. Successful complete reads set new item ids
and clear vanished ones, which turns the existing **Open in Plex/Jellyfin** button into a title
deep link. Failed or partial reads leave the previous ids untouched; Cinder never guesses by title
or year. This worker is disabled with the other pollers when `start_poller` is false.

### Quarantined import recovery

Cinder journals every staged import so a crash cannot confuse an uncommitted file with one the
catalog owns. Transient cleanup failures retry with capped exponential backoff (30 seconds through
30 minutes) and quarantine after eight failed attempts; a permanent file-identity conflict
quarantines immediately. Quarantine is fail-closed: Cinder retains the journal and every file it
cannot prove it owns instead of repeatedly deleting or overwriting an unknown path.

Inspect quarantined journals from the release container:

```sh
docker compose exec cinder bin/cinder rpc \
  'IO.inspect(Cinder.Library.quarantined_import_stages(), pretty: true, limit: :infinity)'
```

After fixing the reported permission, mount, or destination conflict, explicitly release one by
its journal `id`. Replace `123` below with the integer `id` shown by the inspection command:

```sh
docker compose exec cinder bin/cinder rpc \
  'IO.inspect(Cinder.Library.retry_import_stage(123))'
```

`rpc` connects to the running Cinder release, so the container must already be running.

Retry only resets the cleanup attempt budget and makes the preserved rollback or committed-cleanup
action due. It does **not** discard the journal, delete files, change the recovery direction, or
override identity checks; the next poll performs the same fail-closed reconciliation.

## Troubleshooting parked states

| State | Meaning | What to do |
|---|---|---|
| `:no_match` | No acceptable release found (the scorer rejected all results, or the title has no IMDb id on TMDB). | Passive; nothing to fix. Relax scoring if it's too strict. |
| `:search_failed` | A release was found but couldn't be handed off, or transient errors exhausted ~10 min of retries. | Check the server log. Often a malformed/HTML download response or an indexer/download-client outage. **Retry** once fixed. |
| `:import_failed` | The completed download had no usable video file, or import failed repeatedly — commonly a **permission mismatch** or, on a cross-filesystem copy, **a full library disk** (`:enospc`) — or (with `ffprobe` installed) the file's audio language didn't match the request. (A cross-filesystem path itself is **not** a failure — Cinder copies automatically.) | Check the log for the permission/disk error; see the hardlink section above. For a language mismatch, **Retry** re-searches (the wrong release is now filtered out). |

## Audio-language verification

If you set a per-title language preference (other than *Any*), Cinder filters releases by the
language tag in their name — *French + original* filters like *French* here; the stricter
both-tracks requirement only applies on the Anime path (see below). As a backstop for releases
whose name lies or omits the language, it also
checks the **actual audio tracks** of a completed download before importing, using **`ffprobe`**
(part of FFmpeg, shipped in the Docker image). This covers both **movies and TV**: a wrong-language
movie parks at `:import_failed`; a wrong-language episode file in a season pack is skipped so that
episode re-searches, while the correctly-languaged episodes still import.

It is conservative by design — a language outside the recognized set, an audio code it doesn't
recognize, a missing/unreadable probe, or a missing `ffprobe` binary all **import** rather than
reject, so a correctly-languaged file is never stranded; only a provably-different language is
refused. Always on in the shipped image (there is no runtime toggle); setting a title's language
preference to *Any* skips the check for that title, and an image without `ffprobe` skips it
entirely (probes then import-permissive).

## Subtitles

Cinder can fetch `.srt` subtitle sidecars for imported movies and episodes from
[OpenSubtitles.com](https://www.opensubtitles.com/), in the languages your household wants. It's
**opt-in and off by default**: nothing is fetched until you set both `Subtitle languages`
(comma-separated, e.g. `en,fr`) and your OpenSubtitles API key, username, and password in the
**Subtitles** group in `/settings`. A blank language list keeps the feature fully inert — no
searches, no downloads, no OpenSubtitles account required.

Two triggers fetch subtitles, both **best-effort** — a subtitle miss never fails or parks a video
import:

- **At import time**, right after a movie or episode's file lands.
- **A 12h background sweep** that re-checks every already-imported movie and episode for a missing
  sidecar in a wanted language — this catches subtitles uploaded to OpenSubtitles *after* the
  release landed, without needing a re-import.

Sidecars are named `<video basename>.<lang>.srt` — e.g. `Movie (2020) {tmdb-1}.en.srt`,
`Show (Year) {tmdb-2} - S01E02.fr.srt` — the convention both Jellyfin and Plex auto-detect next to
the video file, with no library scan configuration required.

Cinder also aligns its managed sidecars without exposing half-written files. If `/media` is a
mergerfs mount, bind every backing branch into the Cinder container read-write at the same absolute
path mergerfs reports (for example, `/mnt/media1:/mnt/media1`); the single `/media` bind is still
required. Without those backing mounts, alignment fails closed and leaves the subtitle unchanged.

Separately from OpenSubtitles, any loose subtitle files (`.srt`, `.ass`, …) the release itself
shipped are imported alongside the video only for folder/pack downloads — a bare single-file
download has no sibling files to carry over — while embedded subtitle tracks are still detected
for single-file imports either way.

**Matching is moviehash-first**: a hash match is specific to the imported file and becomes stable.
When no hash match is available, Cinder falls back to the movie/episode IDs (IMDb for movies; TMDB
plus season/episode for TV). ID matches are provisional and are rechecked on later sweeps, so a
later hash-matched subtitle can replace one that may not match an atypical release's framerate.

After an empty successful OpenSubtitles response, Cinder can fall back to an embedded subtitle track
or an SRT that shipped with the release. It only creates the configured target languages. If that
local source needs translation, Cinder calls a separately self-hosted LibreTranslate instance; set
its URL and optional API key in **Subtitles**. LibreTranslate is never contacted when OpenSubtitles
returns a result or an error.

Candidate subtitles are filtered to exclude **hearing-impaired** and **machine-translated**
results; among what's left, the one with the most downloads wins.

**Quota:** a free OpenSubtitles account allows **20 subtitle downloads/day**. Searching doesn't
count against it, so the 12h sweep re-checking for still-missing subtitles costs nothing extra.
Once the daily quota is spent, downloads simply stop for the rest of that tick (logged, not
retried) and resume automatically the next day.

**Don't want to hand Cinder OpenSubtitles credentials?** Both Jellyfin and Plex have their own
subtitle plugins that fetch subtitles independently, with zero Cinder-side configuration — the
existing zero-config alternative for a household that would rather not. This is also why Cinder
doesn't shell out to Bazarr instead of building its own fetch: Bazarr has no standalone folder-scan
mode, it reads its media list from Sonarr/Radarr's API — so running it against Cinder's library
would mean also running Sonarr/Radarr, defeating the point of Cinder replacing them.

## TV: monitoring, season packs, and the calendar

**TV requests work like movie requests.** Any authenticated user can search for a TV show on
`/series` and request a season from the show's discovery page. A non-admin's request is
`:pending` until an admin approves or denies it from the approval queue; an admin's own request
auto-approves. Per-user quotas, the **My requests** view, and per-season state badges
(Pending / Approved / Denied) all apply, in parity with movies. A denied season can be
re-requested. On approval, the series is created (if not already present) and **only that season**
is monitored — the admin can adjust episode-level monitoring from the series detail page (`/series/:id`,
admin-only).

The TV poller then takes over: it searches each still-wanted monitored episode (monitored, aired,
no file yet), preferring a season pack when one covers them and falling back to per-episode grabs;
on import it maps each file in a pack to its episode by parsing `SxxEyy`. A file it can't match
to a wanted episode is **logged and skipped** (the grab parks and its episodes re-search) rather
than mis-filed.

**Standard Season 0 episodes are opt-in.** Once an admin explicitly monitors an aired special on
the series detail page, the normal TV sweep searches it and imports a matching `S00Exx` file under
`Season 00`. Unmonitored specials remain untouched. Anime keeps its stricter classification rule
described below.

A periodic TMDB refresh reconciles season/episode data, so a newly-announced or late-dated episode
becomes search-eligible on its own once its air date passes — no manual re-add. The **`/calendar`**
view (admin) lists upcoming monitored episodes. Set the household's IANA timezone (for example,
`Europe/Paris` or `America/New_York`) in `/settings`; it defines "today" consistently for both
eligibility and the calendar. Invalid timezone names are rejected, and existing installs default
to `Etc/UTC` until one is saved.

**Tuning grabs.** The `Release size bands` group in `/settings` sets a min/max size (decimal GB)
and a preferred-resolution list **per library kind** (Movies and TV). For TV the band is **per
episode**: a season pack of N episodes is allowed up to N× the max, so don't set the max to a
whole-pack figure (the movie band is per movie). The bands ship with defaults — movies 0.3–15 GB,
TV 0.05–4 GB per episode — so a fresh install can't match a multi-hundred-GB batch archive for a
single wanted episode. A blank field means the default; an explicit `0` means no limit. A too-low
max (or any min above what your indexer carries) silently rejects every release, so the episode
stays wanted and nothing grabs; loosen the band if legitimate releases are being excluded.

**Preferred sources** (per kind): a comma-separated allow-list of `remux, bluray, webrip, webdl,
hdtv, dvd, cam`. Leave blank to accept any source. An untagged (parser-undetected) release is
always kept; only a release whose detected source is recognized and *not* in your list is rejected.
Within a resolution, earlier-listed sources rank higher.

**Title terms and upgrade cutoff** (per kind): preferred terms are case-insensitive phrases used
after resolution and source to rank otherwise-equivalent releases; earlier-listed terms rank
higher. A blocked term rejects any release title containing that phrase from automatic selection.
Both policies remain overridable in **Find a better match**. The optional resolution cutoff stops
automatic movie searches once the current file reaches that point (or a higher-ranked preferred
resolution). TV searches are season-scoped and stop once every held episode in the season reaches
the cutoff; until then, keeping the whole held season claimable lets safe season packs upgrade the
remaining episodes. The cutoff must appear in that kind's preferred-resolution list. It never
hides or disables manual search.

## Anime

Anime is a **per-title opt-in profile** — `Auto`, `Standard`, or `Anime` — on any movie or series.
`Auto` (the default) searches as `Standard`, and retries through the Anime engine only when a
Standard search finds no match on a Japanese-animation title. Confirm a title as Anime outright to
skip that Standard pass: set it directly from the movie/series detail page, or propose it when
requesting a title and let an admin confirm it on approval. Nothing about where a file lands or
how Jellyfin/Plex see it changes — only how Cinder searches for and verifies it.

Once a title is Anime, release search understands native/romaji/licensed title aliases and
absolute/scene episode numbering, so a release like `One Piece 1122v2` resolves to the right episode
without any TMDB season/episode math. **Specials (Season 0) grab only when explicitly classified:**
a story-special or recap episode that's also monitored is searched and grabbed like any other
episode; an unclassified special or a pure extra never is.

### "Needs mapping" (TV only)

Cinder will not import a downloaded anime batch until every file in it is certainly mapped to one
wanted episode. If a file is ambiguous, unidentifiable, a duplicate claim, or doesn't belong to what
was actually grabbed, the *whole* download holds on `/activity` as **Needs mapping**, with the
reason shown inline. One narrow exception (issue #123): exactly one non-ignored video that parses
no episode markers, for a grab that reserved exactly one episode, is inferred to be that episode
instead of holding.

- Fix the files on disk (rename an ambiguous file to the episode it actually is, remove a stray
  extra, etc.), then click **Retry import** — Cinder re-runs the same exact-mapping check against
  the current state of the files and imports if it now resolves cleanly.
- Or click **Discard** to cancel the download; its episodes return to the wanted queue and search
  again normally.

The hold survives an app restart — nothing is auto-resolved or lost while you're away.

### "Needs verification" (movies and TV)

Separately from the name-based language filter (see "Audio-language verification" above), an Anime
title's Audio pick (per-title) and its global embedded-subtitle preference (below) can require a
specific audio or embedded-subtitle mode. Cinder freezes that requirement into the grab when the
release is chosen, then checks it against the actual file with `ffprobe` before staging:

- A **confirmed violation** (the probed audio/subtitles provably don't match) is handled
  automatically — the release is rejected and blocklisted and the movie/episode re-searches. No
  action needed.
- When Cinder **can't reach a verdict** (`ffprobe` isn't installed, the probe fails, or the file
  isn't readable yet), it retries for a while and then holds the item as **Needs verification**
  (the movie's detail page for a movie; `/activity` for a TV grab) rather than guessing either way.
  Fix whatever blocked the probe — install/configure `ffprobe`, fix a file permission, wait for a
  mount to come back — then click **Retry verification**.

### Audio mode (per-title)

Every movie/series has one Audio pick (its `preferred_language`) — Original / French / French +
original / Any, set from the movie/series detail page. For an Anime title this same pick doubles
as the Anime audio mode: Original requires the title's own original-language audio, French
requires a French dub, French + original requires both the dub and the original track, and Any
requires nothing. There is no global default and no separate axis — it's the same picker used to
filter releases on the standard (non-anime) path.

### Global Anime settings

`/settings` → **Anime releases** sets, for every Anime title:

- **Embedded subtitles** — allow / prefer embedded / require embedded.
- **Preferred groups** / **Blocked groups** — comma-separated release-group names.
- **Preferred-group fallback delay** — hours to wait for a preferred group before falling back to
  the next-best release (`0` disables waiting).

There is no per-title override for these — every Anime title shares them.

### `ffprobe`

Both the audio/subtitle checks above and the pre-existing language check (see "Audio-language
verification") need **`ffprobe`** (part of FFmpeg, shipped in the Docker image). Its binary
name/path is the `ffprobe_bin` setting in `/settings` (default: `ffprobe` on `PATH`; no environment
bootstrap — set it in `/settings`). Availability shows up as a **Media info (ffprobe)** row in
`/dashboard` service health and via **Test connection** in `/settings`. Without it, Cinder
skips both checks and imports permissively — a missing probe never blocks an import.

## Named media profiles and library roots

Each library kind has a required standard import root — movies under `movies_library_path`, TV
under `tv_library_path` — and (for Plex) its own scan section. Admins manage movie and TV profiles
at `/settings/profiles`. A profile has an operator-chosen name, selects the existing Standard or
Anime handling engine, and may set a normalized absolute library root. A blank profile root uses
the matching existing Standard/Anime root. Release rules and media-server scan sections remain
per media kind; profiles do not duplicate them.

The v2 migration creates Standard and Anime profiles for movies and TV, links every explicit
legacy selection and request to its matching profile, and leaves Auto titles or requests without a
proposed handling unlinked. A profile referenced by a title/request may only be renamed; its kind,
handling, and root stay fixed, and the final profile of either kind cannot be deleted. Reassigning
a title with existing files is rejected unless every file remains inside the new effective root.
The first-run wizard still requires both standard roots, and a grab whose selected destination is
unavailable holds rather than importing into the wrong place. Point Jellyfin or Plex at every
distinct root you configure.

> **Upgrading across the key regularization:** the movie config keys gained the `MOVIES_` prefix the
> TV keys already had — `LIBRARY_PATH` → `MOVIES_LIBRARY_PATH`, `PLEX_SECTION` → `MOVIES_PLEX_SECTION`
> (and a new `TV_PLEX_SECTION` for the Shows library). Stored `/settings` rows migrate automatically,
> **but environment variables do not** — if you bootstrap movie config via `docker-compose.yml` /
> `.env`, rename those vars before redeploying, or the movie root/section reverts to unset (movie
> imports hold, red on `/dashboard`, until set). Keep both roots on the same filesystem as the download
> client's completed dir for instant hardlinks; a root on a different filesystem still works via the
> automatic copy fallback (see "Hardlink, with an automatic cross-filesystem copy fallback").

## Adopting an existing library

If you already have a Radarr/Sonarr/Plex-shaped library, **`/library` → "Adopt existing library"**
(`/library/adopt`, admin-only) pulls those files into Cinder's catalog without re-downloading. It
**scans every configured legacy and explicit named movie/TV root**, matches each unmanaged video
against TMDB, and files your confirmed matches — reading only the filesystem, TMDB, and catalog
until you confirm. Adoption from an explicit named root records that exact profile; a shared
fallback root stays Auto because its profile cannot be inferred safely.

- **Nothing is auto-guessed.** Candidates land in three buckets: **auto-matched** (an unambiguous
  hit — review, then adopt), **ambiguous** (pick the right TMDB title before adopting), and
  **unmatched** (no confident match — left alone). A Sonarr/Radarr provider tag in the folder name
  (`Show Name {tvdb-1234}`, `Movie (2019) {tmdb-56789}`, or `{imdb-tt0000000}`) is resolved directly;
  otherwise adoption searches by title + year.
- **Adoption records existing files in place** — it does not move, rename, or re-hardlink them, so
  they must already sit under the movie/TV roots in the usual `Title (Year)/…` layout. Confirmed
  paths are written through the same `Catalog` transition choke-points as the live pipeline.
- **TVDB-split part files** (a season/episode file that TVDB numbers but TMDB folds into one episode —
  e.g. a supersized episode or a two-part finale) surface as an **additional part** on the combined
  TMDB episode rather than a new row, and are adopted only when you confirm them (see the 2026-07-27
  addendum in `docs/specs/2026-07-22-159-tvdb-tmdb-cardinality-decision.md`).

## Deleting media

The delete dialogs for movies and TV shows (`/library`) and for individual seasons and episodes
(`/series/:id`) include an opt-in **"Delete file from disk"** checkbox (unchecked by default).
Ticking it removes the library file when you confirm the deletion; empty parent folders left behind
are pruned automatically.

- **Season/episode file deletion leaves the item monitored** — the TV poller will re-grab it on
  the next sweep. Tick "stop monitoring" as well if you want to drop it permanently.
- **Disk space is reclaimed only once the download client also drops its copy.** Library files are
  hardlinks; the space frees when the last link (either the library copy or the download client's
  completed-downloads copy) is deleted.

## Known limitations

- **There is no tracker-specific or RSS automation.** Cinder searches the normalized results that
  Prowlarr exposes for a requested title; it does not infer private-tracker rules, consume tracker
  RSS feeds, or apply tracker-specific folklore without a concrete, generic policy to enforce.

- **SABnzbd "Pause on Duplicates" must be OFF.** That mode re-keys the download id after an add, so
  Cinder loses track of the job and it parks.
- **SABnzbd job names are title-bearing, so its Smart Episode/Series duplicate detection can
  misfire on a legitimate cinder re-grab.** A "Find a better match" upgrade, or a re-search after
  a release was blocklisted, can look like a duplicate of an earlier job for the same title and
  get paused or discarded by SABnzbd. Turn off series duplicate detection (or scope it away from
  Cinder's SABnzbd category) to avoid it. When a SABnzbd job does park a title, Cinder now
  preserves the client's own reason (paused / its `fail_message`) as the parked-item detail on
  `/activity`, so the cause is visible instead of a bare "couldn't be imported."
- **SABnzbd health warns on risky config.** The `/dashboard` and `/settings` "Test connection" health
  check reads SABnzbd's config and shows an amber warning (and logs it) when it finds settings that wedge
  Cinder's grabs: a `folder_max_length` below **200** (which truncates the mandatory
  `.cinder-<key>` job-name suffix so SABnzbd can never find the job — keep it at the default 246 or
  higher), or duplicate handling (**Pause on Duplicates** / **series duplicate detection**) left on
  for Cinder's category. These are warnings only — the service still tests as reachable.
- **Archive and disc movie releases are not imported.** RAR volumes and `BDMV`/`VIDEO_TS`/ISO
  releases park with an explicit unsupported-format reason. Supporting them safely requires an
  explicit, health-checked extraction or remux runtime and a deterministic main-feature policy;
  Cinder will not guess a title or silently choose the largest playlist. Multi-file movies are
  accepted only when every video forms one unambiguous, contiguous stack named with
  `CD`/`disc`/`disk`/`part` plus `1..N`.
