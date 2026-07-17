# Operating Cinder

Operator guide for a self-hosted Cinder instance. For the architecture/build plan see
[`ROADMAP.md`](../ROADMAP.md); for local development see [`CONTRIBUTING.md`](../CONTRIBUTING.md).

## Deploy

The [`docker-compose.yml`](../docker-compose.yml) at the repo root is the supported deployment.
Copy `.env.example` to `.env`, set `SECRET_KEY_BASE` (`openssl rand -base64 48`), then
`docker compose up -d`. The container migrates the database on boot and serves on port 4000.

> **Upgrading from an early image:** the container owns its `/data` volume so a *fresh* `docker
> compose up` can write the database. Docker only sets a named volume's ownership when it's first
> created, so a `cinder_data` volume left root-owned by a pre-fix image keeps crash-looping after an
> upgrade. If the container can't write the DB after pulling a newer image, recreate the empty
> volume (`docker compose down && docker volume rm <project>_cinder_data`) or
> `chown -R 65534 /var/lib/docker/volumes/<project>_cinder_data/_data`.

## First run & security

The first account created becomes the **admin**; the first-run wizard (`/setup`) then collects your
service config and validates it. Registration stays **open** afterward — that's how other household
members sign up to request media.

Because the first registrant is the admin and Cinder serves plain HTTP on `0.0.0.0:4000` (TLS is
expected to terminate at a reverse proxy):

- **Create your admin immediately** after first boot. The first account to register *wins admin* —
  an exposed, not-yet-claimed instance lets a stranger take it.
- **Do not expose port 4000 to an untrusted network.** Run Cinder behind a reverse proxy (with TLS)
  or a VPN — this is the real access control. Registration stays **open** after the admin exists
  (that's how household members sign up), and **self-registered accounts are auto-confirmed**: they
  can log in and submit requests immediately (no email confirmation step).
- **Login rate limiting:** password login is capped at 10 failures per `{ip, email}` per 15
  minutes (blocked attempts get the same generic error as bad credentials). Behind a reverse
  proxy every client shares the proxy's IP, so the cap is effectively per-email there — meaning
  anyone who can reach the login page can lock a known email's password login for a window
  (a targeted-lockout nuisance, accepted at household scale; an authenticated password change
  always clears the block). Registration has no limiter.
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

## Configuration: environment vs in-app

Boot-only keys (`SECRET_KEY_BASE`, `DATABASE_PATH`, `PHX_*`, `PORT`, `POOL_SIZE`, `RELEASE_NAME`,
`DNS_CLUSTER_QUERY`) stay in the environment. Everything else — TMDB, indexer, download clients,
media server, the per-kind library roots (`movies_library_path`, `tv_library_path`), the per-kind
size bands, subtitles, and notifications — is edited at `/settings` and
stored in the database. **DB values override the env bootstrap; clearing a setting reverts to the
env value/default.** Secret fields are encrypted at rest with a key derived from `SECRET_KEY_BASE`.

### Discord notifications

Set a **Discord webhook URL** under Notifications in `/settings` and Cinder posts an embed on
request approvals, newly-available movies/episodes, and pipeline failures (including a TV season
whose search budget is exhausted). Unset, events go to the server log only. Posts are best-effort
with a 3-second timeout — a Discord outage never touches the pipeline.

### Trust posture: indexer-supplied download URLs

Cinder fetches `.torrent` files from whatever URL the indexer returns (scheme-limited to
http/https, response used only to hash and hand to the download client — never rendered). That
means your indexer/trackers can, in principle, make Cinder issue GET requests to arbitrary
addresses — the same posture as Radarr/Sonarr. You chose the indexer; point Cinder only at one
you trust.

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

- **Extra disk.** A copy keeps **both** the download and the library file. Unless `move_on_import` is
  enabled (it deletes the source after a successful import), a cross-filesystem import permanently
  consumes **2×** the file's size.
- **Time.** A copy takes time proportional to the file size and runs inside the poller tick, so a
  large file (or a serially-copied season pack) briefly serializes other pipeline work. Fine at
  single-household scale.
- Cinder's container runs as `nobody` (uid/gid **65534**). Give your download client a matching
  `PUID`/`PGID` (the linuxserver.io images take these env vars), or a shared group with group write
  — otherwise the link **or copy** fails with a permission error and the item parks as
  `:import_failed`.

> **Note:** this covers *local* filesystems the Cinder container can read. A remote or
> container-mapped download path that Cinder can't `stat` (different host, unmounted volume) is a
> separate, unaddressed gap — mount the download directory into Cinder's container.

## Backups

Back up the SQLite database — the `/data` volume (`cinder.db` plus its `-wal`/`-shm` sidecars).
That's the entire app state.

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

## Health & retry

`/dashboard` (admin) shows the **Service health** panel that pings each configured service (with a
**Recheck** button), the approval queue, and recent activity. `/activity` (admin) shows every
item's live pipeline state — a parked item (`:search_failed` / `:no_match` / `:import_failed`)
shows a **Retry** button there that resets it to `:requested` with attempt counters zeroed; the
poller re-queues it on the next tick. (The old `/status` and `/grabs` URLs redirect to
`/activity`.)

The media-server library scan after an import is **best-effort**: if the scan call fails (e.g. an
endpoint/header mismatch on your Jellyfin/Plex version) the item still reaches `:available`, and
your server picks the file up on its next periodic scan.

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
| `:search_failed` | A release was found but couldn't be handed off, or transient errors exhausted ~10 min of retries. | Check the server log. Often a malformed/HTML "torrent", a BitTorrent **v2-only** torrent (see limits), or a Prowlarr/qBittorrent outage. **Retry** once fixed. |
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
`Show (Year) - S01E02.fr.srt` — the convention both Jellyfin and Plex auto-detect next to the video
file, with no library scan configuration required.

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

A periodic TMDB refresh reconciles season/episode data, so a newly-announced or late-dated episode
becomes search-eligible on its own once its air date passes — no manual re-add. The **`/calendar`**
view (admin) lists upcoming monitored episodes.

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

## Anime

Anime is a **per-title opt-in profile** — `Auto`, `Standard`, or `Anime` — on any movie or series.
`Auto` (the default) behaves exactly like `Standard` until a title is explicitly confirmed as
Anime: set it directly from the movie/series detail page, or propose it when requesting a title and
let an admin confirm it on approval. Nothing about where a file lands or how Jellyfin/Plex see it
changes — only how Cinder searches for and verifies it.

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
`/status`/`/dashboard` service health and via **Test connection** in `/settings`. Without it, Cinder
skips both checks and imports permissively — a missing probe never blocks an import.

## Library roots: movies vs TV

Each library kind has its **own** import root — movies under `movies_library_path`, TV under
`tv_library_path` — and (for Plex) its own scan section. Point your media server's Movies and Shows
libraries at the two roots. **Each root is required and has no fallback:** with one unset, that
kind's grabs *hold* (downloaded, logged, shown red on `/dashboard`) rather than importing into the
wrong library, and the first-run wizard won't finish until both roots validate writable.

> **Upgrading across the key regularization:** the movie config keys gained the `MOVIES_` prefix the
> TV keys already had — `LIBRARY_PATH` → `MOVIES_LIBRARY_PATH`, `PLEX_SECTION` → `MOVIES_PLEX_SECTION`
> (and a new `TV_PLEX_SECTION` for the Shows library). Stored `/settings` rows migrate automatically,
> **but environment variables do not** — if you bootstrap movie config via `docker-compose.yml` /
> `.env`, rename those vars before redeploying, or the movie root/section reverts to unset (movie
> imports hold, red on `/dashboard`, until set). Keep both roots on the same filesystem as the download
> client's completed dir for instant hardlinks; a root on a different filesystem still works via the
> automatic copy fallback (see "Hardlink, with an automatic cross-filesystem copy fallback").

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

- **BitTorrent v1 only.** Releases with a v2-only (SHA-256) infohash aren't handled; most public
  trackers are still v1.
- **SABnzbd "Pause on Duplicates" must be OFF.** That mode re-keys the download id after an add, so
  Cinder loses track of the job and it parks.
- **Specials (season 0) aren't grabbed** by the TV sweep for a `Standard`-profile series. An
  `Anime`-profile series is the exception: a Season 0 episode grabs once it's explicitly classified
  story-special/recap *and* monitored (see "Anime" above).
- **Air-date eligibility is by UTC calendar day.** An episode becomes search-eligible when its TMDB
  air date is "today or earlier" in **UTC**, so far from UTC it can flip to wanted up to ~a day
  early or late. Harmless for a household (it just grabs a few hours off) — there's no per-timezone
  scheduling.
