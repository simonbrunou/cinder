# Changelog

All notable changes to Cinder are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Cinder aims to follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- **Bounded `ffprobe`/`ffmpeg` media-inspection calls (#447).** `MediaInfo.Ffprobe`'s four
  file-inspecting calls — `probe/1`, `probe_policy/1`, `subtitle_tracks/1`, `extract_subtitle/2`
  — used to shell out with no Elixir-side timeout. A single hung `probe/1`/`probe_policy/1` call
  on a pathological file could stall every subsequent import-poller tick for every movie and TV
  target indefinitely; a hung `subtitle_tracks/1`/`extract_subtitle/2` call likewise stalled the
  subtitle-fetch queue or backfill sweep. Each now runs as a supervised subprocess killed by OS
  pid at a bound: ~10s for `probe/1` and `probe_policy/1` (true metadata-only reads, and the two
  that run inside the import poller's own tick), and 30 minutes for `subtitle_tracks/1` and
  `extract_subtitle/2` — both have to demux through the whole file, not just its header, so they
  need headroom for a large remux over a household NAS, and both run only on the dedicated
  subtitle-fetch path, never the import poller. A hang now fails that one probe instead of
  freezing its caller.
- **Garbled indexer titles no longer abort a whole title's search pass (#451).**
  `Parser.parse/1`, `AnimeParser.parse/2`, and the anime free-text search guard
  (`Anime.apply_title_guard/2`) all ran `/u`-flagged regexes directly against a raw indexer
  title. A `/u` regex makes `:re.run` validate its subject as UTF-8 first, and Prowlarr
  aggregates trackers with inconsistent encodings, so a single garbled or mis-encoded release
  title raised `ArgumentError` with no rescue anywhere in the parsing chain. The poller's own
  per-unit isolation (`isolate/2`) already caught that and logged it loudly at `:error` with a
  full stack trace — this was never silent — but the whole `Enum.map(&Release.new/1)` pass for
  that title aborted with it, discarding every other, perfectly good candidate release alongside
  the one garbled title, and repeating on the next tick as long as the same indexer result kept
  appearing. Both parser entry points, and the anime guard, now scrub the title to valid UTF-8
  first (dropping one invalid byte at a time, keeping the rest of the string intact), so one
  garbled release degrades to an unrecognized candidate instead of taking its title's whole
  search pass down with it.
- **Dot-separated anime releases now match their known titles (#450).** The anime free-text search
  guard and the anime parser's own season/episode resolver only normalized titles with NFKC, trim,
  whitespace-collapse, and downcase before comparing a release title to a known series title — no
  separator canonicalization. A scene release named with dots or underscores instead of spaces
  (`Puella.Magi.Madoka.Magica.S01E01...`, the actual convention most anime groups use) never
  matched a known title stored as `Puella Magi Madoka Magica`, so a correctly-named, perfectly
  good release was invisible to both search and coordinate parsing. Both sites now canonicalize
  `.`/`_`/`-` to spaces character-by-character (length-preserving, so the offset used to slice out
  the remainder after the matched title still lines up). Because a looser match can also
  over-match, `legal_title_remainder?/1` gained a negative lookahead so a numbered sequel or season
  folded into a release title (e.g. `Title.4.2024...`) can no longer free-text-match the base
  title (`Title (2019)`) by misreading the sequel number as an absolute episode number — closing
  off a genuine wrong-release grab that the looser match would otherwise have opened up.
- **A subtitle provider's error page can no longer overwrite a working subtitle (#452).**
  `Subtitles.download_and_commit/8` treated any HTTP 200 body from OpenSubtitles as subtitle
  content and wrote it straight to the sidecar with no structure check — unlike every other write
  path in the subsystem (manual/automatic sync corrections validate through
  `Sync.Timing.validate/2`; translation only commits when `Srt.render/2` actually returns a
  binary). A Cloudflare interstitial or truncated response landing with a 200 status — not
  implausible against a third-party API — could silently replace a previously good, already-synced
  subtitle with garbage. Downloaded content now runs through `Sync.Timing.validate/2` before it's
  committed; a validation failure is logged and skipped instead of written.
- **A crash-looping background worker can no longer take down the whole app (#456).** All 16
  poller workers (search, refresh, cleanup, backups, the janitor) were flat siblings of
  `Cinder.Repo` and `CinderWeb.Endpoint` under one supervisor sharing its default restart budget (3
  restarts / 5 seconds). Each poller's tick body is wrapped defensively, but the code that runs on
  every restart — reading its configured interval and scheduling the next tick — was not, so a bad
  interval value could crash-loop fast enough to exhaust that shared budget and bring the whole
  supervisor down, taking the database connection pool and the web endpoint with it. The 16
  workers now live under their own `Cinder.PollerSupervisor`, sized to their count — but nesting
  alone wasn't enough: three of that inner supervisor's own near-instant restarts still fit inside
  the outer supervisor's budget and brought it down anyway, so the inner supervisor is now started
  with `restart: :temporary` — a persistent crash loop exhausts and permanently kills its own
  subtree once, instead of cascading. A new `Cinder.PollerSupervisor.Watchdog` logs loudly at
  `:error` if that ever happens, since nothing else would otherwise notice that every background
  worker had silently stopped.
- **Slow or unresponsive storage can no longer stall the whole household behind one subtitle
  adjustment or library adoption (#453, #455).** A manual subtitle-offset adjustment
  (`Sync.manual_in_scope/5`) held a SQLite write-lock transaction (`mode: :immediate`) across a
  `:global.trans` acquisition, a manifest read, a sidecar-directory scan, one-or-two
  `Moviehash.of_file/1` reads of the video file itself, and a manifest write — none of it a
  database write. Library adoption (`Catalog.Adoption.adopt_movie_at_available/5` and
  `adopt_series_files/5`) held the same kind of lock across an `lstat` walk of every path component
  down to the candidate file. SQLite holds one write lock database-wide, so on a slow or
  network-mounted library root, either operation could block every other writer in the app — both
  pollers included — for as long as the filesystem work took, up to the 5-second busy timeout. The
  subtitle-adjustment lock is dropped outright, not narrowed — it was never doing anything
  transactional; `manual/4`'s own hash checks and the existing `:global.trans` lock already cover
  what it appeared to guarantee — and the operation now re-checks the item still belongs to its
  catalog scope after the filesystem work, reporting `{:error, :stale_scope}` if it moved.
  Adoption now runs its filesystem validation before opening a transaction, then re-resolves the
  profile (and series) fresh inside a transaction scoped to just the database write.
- **A forged event no longer crashes the login or registration page (#457).** `UserLive.Login` and
  `UserLive.Registration` had `handle_event` clauses for their known events but no catch-all, so
  any `phx-click` with an unrecognized event name — trivial for a client to send — crashed the
  LiveView with `FunctionClauseError` and lost the in-progress form. Both views now fall through to
  a no-op catch-all instead of crashing.
- **The 5-second download and TV pollers no longer full-table-scan on every tick (#454).**
  `movies.status`, `grabs.content_path`, and `book_grabs.content_path` back the pollers' hot
  `WHERE` queries but carried no index, so SQLite scanned every row in all three tables every 5
  seconds, forever — cost that only grows as library history accumulates, unlike every TV-pipeline
  table, which already had one. A new migration adds a plain index on `movies.status` and partial
  indexes on `grabs.content_path` and `book_grabs.content_path` matching each poller's actual
  `WHERE` predicate, the same pattern `episodes_wanted_index` already uses.
- **An anime remaster or reissue release is no longer rejected for naming its own release year
  twice (#458).** `exact_movie_year?/2` required a release title to contain *exactly one*
  year-like token equal to the target year, so `Akira.1988.4K.Remaster.2020.BluRay...` was
  rejected outright even though 1988 — the correct year — was right there, because the `2020`
  remaster date made it a second match. It now accepts the target year being present among however
  many year-like tokens the title carries, matching the tolerance the non-anime year guard already
  had.
- **Changing an account's email now revokes its other session tokens (#464).**
  `Accounts.update_user_email/2` (self-service) and `admin_update_email/3` (admin editing a
  member) updated the email but never revoked existing session tokens — only the password-change
  path did that. A stolen or leaked session, or one left open on a shared device, survived a
  defensive email change untouched. Both paths now delete the account's session tokens in the
  same transaction as the email write, so a failed update can't log everyone out, and a
  successful one makes every other session's token invalid — rejected the next time it makes a
  request or a LiveView remounts. This is a deliberate divergence from the `phx.gen.auth`
  generator's default behavior, which leaves sessions untouched on an email change — not a fix to
  generated code.
- **CI and release workflows now pin third-party GitHub Actions to commit SHAs, not mutable
  version tags (#466).** A tag like `@v4` can be repointed by its maintainer or anyone who
  compromises their account or CI — this has happened to actions in this same class before — and
  the release workflow runs several with `packages: write` and a `GITHUB_TOKEN`. Every third-party
  `uses:` in `ci.yml` and `release.yml` is now pinned to a full commit SHA with the version kept
  as a trailing comment, and Dependabot's `github-actions` ecosystem is enabled so future SHA
  bumps arrive as a reviewable PR instead of silently.
- **Email delivery failures no longer log raw, unsanitized error text (#463).** Every other
  notifier routes its failure reason through `HTTPPolicy.sanitize_log/1` before logging; the email
  notifier logged `inspect(reason)`, `Exception.message/1`, and `inspect(value)` directly, so an
  SMTP auth or connection failure could echo unbounded or configuration-shaped text straight into
  the application log. It now sanitizes the same way its siblings do.
- **The Activity page's grab list is no longer unbounded and fully preloaded on every mount or
  broadcast (#459).** Every terminal grab transition already deletes its row synchronously
  (`commit_grab_imports`'s closed branch, `close_grab/1`, `finish_grab/3`, `cancel_grab/2`,
  `reap_stalled_grab/1`), so `Grabs.list_grabs/0` was never scanning permanent history — but it
  still had no limit and preloaded `grab_files` plus `episodes: [season: :series]` for every grab
  still retained (in-flight downloads and everything on hold), re-running that full, unfiltered
  query on every Activity mount and on every `series_updated`/`series_deleted` broadcast. It now
  always includes every grab currently on hold plus the 200 most recent overall, so the nav badge
  and the page can never disagree, and the query stays bounded regardless of how many concurrent
  downloads or holds accumulate.
- **The book detail page no longer issues one query per target and per author (#461).** Blocklist
  and author-policy lookups ran once per row instead of batched, unlike the equivalent lookups
  elsewhere in the app (`Catalog.series_library_sizes/0`, `Books.target_sizes/0`). Rows here are
  small and bounded (at most two targets, typically a handful of credited authors), so this was
  never a real slowdown, but `BookDetailLive` now uses batched lookups for consistency with the
  rest of the codebase.
- **Database backups no longer leave orphaned snapshot files behind after a crash (#460).** A
  daily backup writes to a randomly-named `.cinder-backup-pending-*.sqlite3` file before renaming
  it to its final name; if the process is killed mid-`VACUUM INTO` (an OOM, a power loss), the
  pending file stuck around forever, because the pruning sweep's glob pattern didn't match its
  dotfile name. Pruning now also removes stale pending files older than one backup interval.
- **Wrong-audio import rejections now log at the same severity as the sibling warning beside
  them (#462).** They were logged at `Logger.info` while the generic "import skipped N unmatched
  file(s)" message they're folded into logs at `Logger.warning` — Cinder's own stock production
  config (`config/prod.exs`) sets the logger level to `:info`, so the message wasn't dropped by
  default, but it sat one severity step below the more prominent line beside it, and would be the
  first casualty of any external log filter set stricter than info (a common aggregator default).
  An operator investigating a stuck TV import saw the generic warning but had to go hunting at a
  lower level for the specific "wanted language X, rejected" detail that would tell them the
  release needs replacing. Now logged at `Logger.warning`, matching `log_unmatched/1` and the
  movie path's own audio-check failure log.
- **A settings test no longer fails under `mix test --cover` (#465).** Coverage instrumentation's
  overhead delayed a lock release past the SQLite busy timeout, producing a spurious "Database
  busy" failure unrelated to the code under test. Test-only; no runtime behavior changed.

## [3.0.0] - 2026-09-02

### Added
- **E-book and audiobook requests.** Any household member can search a book by title/author and
  request it as an e-book or an audiobook, independently monitored per work, through the same
  request→approval gate, per-user quotas, and My-requests view movies and TV already use. Work
  identity resolves through Open Library (primary) with an optional Hardcover key (secondary),
  never falling back to a first-result guess when identity is ambiguous.
- **Bounded book/audiobook acquisition.** A dedicated release parser and scorer accepts EPUB/
  AZW3/MOBI (e-books) or M4B/MP3 (audiobooks), rejects unrecognized or contradictory formats, and
  extracts `.zip`/`.cbz`/`.rar`/`.cbr` archives through the same bounded, entry- and size-capped
  extractor discipline the rest of the pipeline already uses. A multi-track audiobook imports
  atomically as one target.
- **Booklore and Audiobookshelf publication.** Imports land under dedicated `books`/`audiobooks`
  library roots; Cinder requests an Audiobookshelf scan after every successful audiobook import
  and retries automatically on failure, without ever re-downloading the file.
- **Retry, blocklist, and "Find a better match" for books.** A held book target shows its exact
  reason with a Retry button; a confirmed-bad release is blocklisted; an available target can be
  replaced with a better release exactly like a movie/TV upgrade.
- **Bounded per-author monitoring policies.** An author can be opted into future-only, full
  back-catalogue, or specific-work monitoring in one preview-then-confirm batch, capped so a large
  bibliography cannot fan out into an unbounded burst of provider requests.
- **Readarr/Bookshelf migration.** An existing Readarr-protocol Bookshelf library (e-book or
  audiobook) adopts in place from `/library/adopt` — no re-download, no file rewrite — with a
  bounded preview, monitoring-flag evidence preserved without auto-scheduling acquisition, and an
  idempotent repeat adoption safe to re-run.
- **First-run validation now covers every library kind.** The setup wizard's readiness checklist
  requires a writable e-book and audiobook root, exactly as it already required movies and TV.

## [2.0.0] - 2026-08-15

### Added
- **Named media profiles.** Admins can create separate movie and TV profiles with their own names,
  Standard or Anime handling, and optional library roots. Requests, approvals, title changes,
  imports, and adoption preserve the selected profile through database-backed ids while legacy
  Standard/Anime API inputs remain compatible. Wrong-kind assignments, referenced profile edits,
  stale adoption files, and destinations outside the selected root fail closed.
- **Plex watchlist TV-season sync.** A watchlisted show now expands through TMDB into one request
  for every currently known numbered season, preserving Cinder's per-season model. Each request is
  still made as that Plex user, so their quota and the household approval gate apply independently;
  specials remain an explicit manual choice, and seasons that could not be requested are retried.
- **Generic OpenID Connect sign-in.** An admin can configure one confidential OIDC provider in
  `/settings`; Cinder uses discovery plus authorization code, state, nonce, PKCE, and signed-token
  validation. A provider-verified email may attach an existing account, while a new identity lands
  as an inactive regular user awaiting approval and can never bootstrap the first admin.
- **Automatic verified database backups.** Cinder now writes private online SQLite snapshots
  about daily, verifies each with SQLite's full integrity check, and retains only the newest seven;
  the admin download uses the same snapshot implementation.
- **Household-local TV air dates.** A validated IANA timezone in Settings now decides when a TMDB
  air date becomes wanted and keeps the calendar and automatic searches on the same local day.
- **Safe multi-part movie imports.** Strict contiguous `CD`/`disc`/`disk`/`part` stacks import as
  native Jellyfin/Plex stack files and stay tracked through upgrades, deletion, adoption, backfill,
  and subtitle sync. Ambiguous stacks, RAR releases, and disc structures fail explicitly.
- **Transmission and NZBGet download clients.** Settings can select exactly one torrent client
  (qBittorrent or Transmission) and one Usenet client (SABnzbd or NZBGet), with credentials,
  health checks, remote-path mapping, restart-safe operation markers, polling, and cleanup through
  the existing download-client boundary.
- **Opt-in completed-torrent cleanup.** Operators can set a ratio and/or seed-time limit. The
  cleaner uses qBittorrent/Transmission's native metrics and removes a completed torrent only
  after the threshold is reached and Cinder no longer has an owner for it; blank limits preserve
  indefinite seeding.

## [1.1.0] - 2026-08-14

### Added
- **Admin database backups.** Settings can download a consistent online SQLite snapshot behind
  the admin gate, with private temporary-file cleanup and explicit restore caveats for
  `SECRET_KEY_BASE` and media files.
- **BitTorrent v2 and hybrid releases.** qBittorrent downloads now use the canonical truncated-v2
  torrent id for v2/hybrid metainfo and accept decoded `btmh` magnet topics while retaining v1
  `btih` support.
- **Opt-in Standard-profile specials.** Explicitly monitored Season 0 episodes now search,
  download, and import through the normal Standard TV pipeline; unmonitored specials remain idle.
- **Browser-verified release container.** CI bootstraps and signs into the built image with a real
  browser, verifies compiled assets and LiveView navigation, and the README now shows Dashboard
  and Library screenshots captured from that flow.
- **Automatic Anime TV upgrades.** The upgrade hunter now uses Anime policy selection and frozen
  episode mappings, respects the TV cutoff, and re-verifies each downloaded file before replacing
  anything. Ambiguous or worse replacements leave the existing episode files intact.
- **Writable household request API.** The existing admin API key can create movie/season requests,
  approve or deny pending requests, and delete request rows. Every mutation stays behind the
  `Cinder.Requests` approval gate and uses a deterministic active admin actor; optional active member
  attribution preserves that member's quota and approval behavior. Keys issued by the former
  read-only API are revoked on upgrade; an admin must generate a new writable key.
- **Optional Anime library destinations.** Movies and TV explicitly using the Anime profile can
  import into separate roots configured in `/settings`; blank fields fall back to the existing
  standard roots. Import safety, deletion, subtitles, disk reporting, and library adoption all
  recognize every configured root.
- **Media-server title deep links.** A bounded 15-minute Plex/Jellyfin inventory reconciles movies
  and series by exact TMDB id, so available-title links open the matched server item. The server
  front door remains the fallback, and failed or partial inventories never clear known matches.
- **Per-library release rules and upgrade cutoffs.** Movies and TV can rank preferred title terms,
  reject blocked title terms, and stop automatic re-download searches at a chosen preferred
  resolution. Manual search remains the override surface for every rule and stays available after
  the cutoff is reached.
- **Opt-in Plex watchlist sync.** A Plex-linked user can switch on "Request titles I add to my
  Plex watchlist" in Account settings; a background sweep turns each new movie on their watchlist
  into a request *by that user* about every 15 minutes, so the approval gate and their quota
  apply exactly as if they had clicked Add. Off by default and per user, never a household-wide
  switch. Shows are skipped (Cinder requests TV per season), removing a title does nothing, a
  title is requested at most once even after it is deleted, and a rejected Plex token disables
  sync for that one user. The auth token is encrypted at rest; markers are GDPR-covered
  (cascade + export).
- **Requester "Report an issue."** An available title can be flagged (wrong content, audio,
  subtitles, playback, other) from My Requests or the movie page; admins get a live `/issues`
  queue with Resolve/Dismiss, a Discord heads-up, and the reporter is emailed in their locale
  when it's resolved. Rate-bounded, GDPR-covered (cascade + export).
- **Migration at real-instance scale.** Sonarr snapshots fetch with bounded concurrency, one
  broken series becomes a blocked diagnostic row instead of failing the whole preview, planning
  is single-pass, and confirming adopts with targeted revalidation instead of three full
  re-fetches. The preview itself gains select-all/deselect-all, bulk Fold/Part application with
  a pending counter, 50-row windowed buckets, and honest skipped-item reporting.
- **Migrated TVDB numbering now works end-to-end.** The tvdb "aired" coordinates persisted by
  migration drive standard TV search and import (operator-chosen scene groups outrank them),
  and MANUAL search carries the same alternate-numbering mapping — a manual grab of an
  alt-numbered release reserves the correct episodes or refuses with a clear error, never a
  wrong-episode guess.
- **"More like this"** recommendations on movie and series detail pages, and TV's
  "Find a better match" is now findable — a series-level entry point plus promoted per-season
  controls.
- **Operator holds are visible.** A second admin nav badge counts items needing action on
  Activity (agreeing exactly with what the page renders), and a `{:operator_hold, …}` notifier
  event fires once per new hold (Log + Discord).

### Fixed
- **SABnzbd configuration warnings are actionable.** Risky folder-name and duplicate-handling
  settings now render as amber warnings in Settings and Dashboard while reachable clients remain
  usable and genuine health errors keep precedence.
- **TV searches no longer grab a spinoff merely because its name contains the wanted series.**
  Prowlarr's TVDB and free-text union now keeps per-result provenance: ID-scoped AKA names remain
  trusted, while free-text names must finish the wanted title immediately before a release marker.
- **"Find a better match" now answers the language question it was silent on.** Every row carries
  a language badge — untagged included, which means English by scene convention and so is exactly
  the row an audio pick decides; previously untagged rows rendered no badge at all and read as "no
  opinion". A release the automatic search would actually reject on language is badged as such
  (icon and screen-reader text, not colour alone) and ranked below one that satisfies the pick,
  never hidden: the panel is the override surface. The panel had mirrored the
  sweep's size band, resolutions, sources and blocklist but *not* the audio pick, so a release the
  automatic search would rank last sorted as high as one it would pick.
- **A Hindi subtitle can now be named.** `hi` is ISO-639-1 Hindi as well as the hearing-impaired
  flag, and it was stripped as a flag before the language was read — so `Movie (2024).hi.srt`, the
  very convention Cinder writes, resolved to `und`, and Hindi had no other ISO-639-1 spelling to
  fall back on. `hi` is now read as the language when the name carries no other one, and stays a
  flag when it does (`Movie.fr.hi.srt` is still French, hearing-impaired). Sidecars are renamed
  from one decision, so a Hindi file no longer lands as `Movie.hi.hi.srt`.
- **A movie whose wanted language isn't the default audio track is now flagged.** The import check
  only asked whether the language was *present*, so a MULTi release with a dub flagged default
  passed while playing in the dub (41 of 87 multi-audio movies on the maintainer's instance). The
  ffprobe call now also reads the default disposition and stores the default track's language on
  the movie, and the movie page warns when the wanted language is in the file but isn't that track.
  Advisory only — nothing parks, and the file is otherwise correct.

  It stays silent unless the evidence is unambiguous: nothing flagged default, an untagged default
  track, or several flagged tracks (Matroska's FlagDefault means "eligible for automatic
  selection", so the player picks by viewer preference) all count as *not established*.

  **Operator action:** existing rows have no stored default track, so the warning can't fire for
  them. Run `mix cinder.media_info.backfill` to re-probe already-imported media.
- **Vanished TMDB episodes are retired.** Refresh now deletes vanished rows that carry no
  operator state, so phantom "wanted" episodes stop being searched forever and a freed slot
  lets renumbering land the genuine episode correctly; anything with files, grabs, or manual
  evidence is preserved exactly as before.
- `Cinder.Settings` and `Cinder.Catalog.SeriesCatalog` were split (`Settings.Registry`,
  `Catalog.SeriesDeletion` — pure code motion) well below the 1,500-line cap; the audit also
  verified every `async: false` test designation is genuinely required under the pinned
  single-connection pool.
- **Radarr/Sonarr migration.** `/library/adopt` gains a migration-source mode: point Cinder at
  a running Radarr/Sonarr (URL + API key in Settings, with test-connection probes and optional
  path-prefix mapping) and adopt the whole library through a preview bucketed
  ready / needs-decision / blocked / already-managed. Sonarr's per-episode TVDB identity is
  persisted as provider coordinates (N-to-1 folds supported), and TVDB-split files require an
  explicit Fold-or-Part choice — never a guessed adoption.
- **Lossless season-pack import.** A standard pack with files that match no episode no longer
  finalizes and deletes its source: matched episodes import immediately, residual files are
  persisted (restart-safe) and fence source cleanup until the operator resolves each one on
  `/activity` — Fold (bind the provider coordinate; extra source not retained), Keep as part
  (staged to a part destination and tracked on the episode), or Hold.
- **Richer detail pages.** Series pages show synopsis, genres, rating, first-air date, and an
  "Open in Plex/Jellyfin" button; movie and series pages get a top-cast strip linking to the
  person pages, and movies a "Part of collection" link.
- **My Requests visibility.** Season requests show live "X of Y episodes" progress with a
  Downloading state; Available rows open the media server; every row shows when it was
  requested.
- **Database-volume monitoring.** The disk card, telemetry, and `/healthz` now watch the volume
  holding the SQLite database (503 below a hard floor) — a full app volume no longer wedges
  silently; the WAL's on-disk size is capped via a pinned `journal_size_limit`.
- **Key-rotation visibility.** Stored secrets that can no longer be decrypted (changed
  `SECRET_KEY_BASE`, bad restore) surface as a loud `/settings` alert naming the affected
  fields and a failing service-health row, instead of a log line and a silently dead pipeline.

### Fixed
- **A dead download re-searches instead of parking.** When the download client reports a grab as
  terminally failed (an aborted NZB, a torrent it no longer knows about), Cinder now blocklists
  that release and goes straight back to searching for the next-best one, rather than re-polling
  the corpse ten times and parking for a human to press Retry. Bounded by the blocklist: once
  every candidate is used up the movie parks at "no match" as before.
- **Non-English titles no longer miss untagged releases.** A French (or any non-English) film set
  to its original audio now considers releases with no language tag — French scene groups
  routinely publish original-audio releases with a bare name — instead of parking at "no match"
  with a perfect candidate on the indexer. A properly tagged release still always wins, and the
  import-time audio check still rejects a confirmed wrong-language file.
- The 12h refresher no longer re-runs completed one-time localization backfills on every tick,
  and a transient database error in one pass can no longer crash the whole refresh sweep.
- OpenSubtitles quota exhaustion is remembered until the next UTC day — no more burned
  authenticated calls after the daily limit.
- `Cinder.Catalog` and `Cinder.Settings` were split below the 1,500-line cap
  (`Catalog.MediaProfiles`, `Settings.Crypto` — pure code motion).
- **TV "Find a better match" for imported episodes.** Manual search now works on fully or
  partially imported seasons; grabbing a release for episodes that already have files creates an
  upgrade grab and the import atomically swaps the old file(s) for the verified new one — a
  failed upgrade leaves the old file and availability untouched. Brings TV to parity with the
  movie upgrade path.
- **"Request all seasons."** One click fans out a request per remaining season through the
  normal quota/approval path, reporting how many were submitted if the quota runs out mid-way.
- **Denial notifications + "Request again."** Denying a request now notifies the requester
  (email in their locale, Discord embed, log), and a denied row on My Requests offers a
  one-click re-request. The admin nav shows a live pending-request count badge.
- **Metrics in production.** LiveDashboard is mounted behind the admin gate (was dev-only), so
  the poller/transition/HTTP telemetry finally has a viewer; "Metrics" appears in the admin nav.
- **Minimum-free-disk guard.** Pollers skip a grab (without burning a search attempt) when the
  release wouldn't fit with a safety margin, and imports hold below a floor — a full disk no
  longer churns failed downloads. The first-run wizard now signposts the optional
  notifications setup so alerts aren't silently off.

### Fixed
- **Adoption is atomic and monitoring-preserving.** An adopted movie commits directly at
  available (no window a poller could race into a duplicate download), per-episode write
  failures are surfaced instead of silently counted as skips, and adopting files for a series
  you already monitor no longer resets its monitoring.
- **Part-file deletion is failure-consistent** — successfully unlinked paths reach the database
  even when a later path fails, the deletion audit stays truthful on partial failure, and size
  displays include part files.
- **Stall detection can't be strung along.** The 24 h downloading cap now keys on a dedicated
  progress clock that only genuine byte progress advances — speed/ETA jitter or transient client
  errors no longer postpone the reap. Upgrade grabs get the same protection.
- **`/healthz` no longer reports healthy forever when a poller wedges before its first tick.**
- **Registration throttling works behind cloudflared** — the limiter now keys on the resolved
  client IP instead of the tunnel's transport peer, so one client can't exhaust the shared
  bucket.
- Boot-migration failures log the migration and error loudly before the crash propagates.
- **TV parity on the landing page.** Popular TV and Top Rated TV rails join the movie rails on
  `/`, and the genre browser gains a Movies/TV toggle backed by TMDB's distinct TV genre list —
  same cards, badges, season-picker flow, and crash-isolated fetches as the existing rails.
- **Account-activated notification.** Activating a pending account now emails the user (in their
  locale) instead of silently flipping a flag only an open "pending approval" tab would notice.
- **Adoption reads Sonarr/Radarr provider tags.** `{tvdb-N}` and `{imdb-tt…}` folder tags resolve
  to TMDB via the find-by-external-id endpoint and adopt without title search; a tag that doesn't
  resolve falls back to the existing operator-resolution flow, never a guess.
- **TVDB-split episodes can be adopted (#159, adoption-scoped).** A combined TMDB episode can
  absorb multiple on-disk part files, assigned explicitly by the operator from the adoption
  screen; deletion, backfill, and re-scans account for the extra parts.
- **Standard TV search understands alternate season numbering (#132).** When a series has
  alternate-season coordinates (the anime A6 machinery), the standard path now derives
  id-scoped alt-season queries and accepts releases matching them — TVDB-numbered indexers can
  satisfy TMDB-combined shows.
- **TMDB in the service-health panel**, and `/healthz` wired into the deploy path (compose
  `healthcheck:` + operating docs).
- **`blocked_releases` age-out.** The retention janitor now prunes blocklist rows older than
  180 days; database growth no longer needs manual pruning.

### Fixed
- **Season approval is crash-safe and atomic.** TMDB fetches complete before any transaction and
  the request flip + series creation commit together — a crash mid-approval can no longer strand
  an approved request with no series (or an orphan series with no request).
- **Usenet downloads can't wedge forever.** A protocol-agnostic 24 h cap on time spent
  `:downloading` parks + blocklists + re-searches a stalled job even when the client reports no
  speed (SABnzbd); SABnzbd failure reasons are preserved verbatim on `/activity`, and its health
  check warns on a truncating `folder_max_length` or a duplicate-handling policy that would
  silently pause Cinder's own regrabs.
- **Notification delivery is off the poller's critical path.** Transports run as bounded
  supervised tasks with a per-delivery timeout — a slow SMTP relay can no longer stall a poller
  tick (and `/healthz`) while keeping per-transport isolation.
- **Rail-only movies can be requested.** The Add button on the Popular / Top Rated / Now Playing /
  genre rails was a silent no-op for a movie appearing in no other section.
- **Media localization reworked** (follow-up to #172). French titles now pick the right regional
  variant (fr-FR over fr-CA — "Sing" shows "Tous en scène", not "Chantez!") and no longer
  flip-flop between views. The FR UI could silently corrupt canonical data: saving a movie/series
  edit form wrote the French display title into the canonical column, and manual TV/anime search
  queried the indexer with it — LiveView assigns now stay canonical and localization happens only
  at render. Coverage completed: approval queue, my requests, calendar (incl. episode titles),
  global toasts, and held-series ordering. Stored translations are trimmed to supported locales,
  requests snapshot a canonical title + translations at creation, and the 12h refresher backfills
  existing movies/series (first pass ~1 min after boot). Also restores the `mix.lock` heroicons
  `depth: 1` option #172 dropped, which broke `mix` on fresh checkouts.
- **BREAKING (behavior):** release size bands now ship with defaults — movies 0.3–15 GB, TV
  0.05–4 GB per wanted episode — instead of unbounded, so a fresh install can't legally match a
  multi-hundred-GB batch archive for a single wanted episode (#108). An instance that ran with a
  band left blank applies the defaults after upgrade: releases outside them stop matching. A blank
  `/settings` field now means "use the default"; enter an explicit `0` to restore the old
  unbounded behavior. Bands already set in `/settings` are unaffected.

### Added
- **More discovery rails + genre browsing.** The `/` landing page grows three more TMDB-backed
  rails below Trending (Popular, Top Rated, Now Playing) and a row of genre filter chips that
  loads a `/discover/movie`-filtered grid — same cards, badges, and Add flow as every other rail.
  Each rail fetches concurrently and independently; one failing doesn't affect the others or break
  the page. A movie appearing in more than one rail (TMDB's lists commonly overlap) renders once,
  kept in the earliest rail it appears in.
- **Sign in with Plex.** A "Sign in with Plex" button on the log-in page (shown once Plex is
  configured) authenticates via Plex's PIN flow; only accounts with access to the household's
  configured Plex server (owner or shared user) may sign in. First login always creates a new
  `:user`-role account — Plex's reported email is never used to look up or log into an existing
  account (email isn't proof of inbox ownership, so that would let anyone with mere watch access
  log in as whoever happens to share that email). To attach Plex to an existing account (e.g. an
  admin's), link it from Account settings while logged in.
- **Anime-aware handling.** A per-title opt-in profile (`Auto`/`Standard`/`Anime` on movies and
  series — `Auto` stays `Standard` unless a title is explicitly confirmed, either directly or as a
  requester's proposal an admin approves) makes release search alias- and absolute/scene-number-aware
  (native/romaji/licensed titles; releases like `One Piece 1122v2` resolve without TMDB season math),
  searches Season 0 specials only when they're explicitly classified story-special/recap and
  monitored, holds an ambiguous downloaded batch as **Needs mapping** on `/activity` instead of
  guessing (**Retry import** after fixing the files, or **Discard**), and enforces global Anime
  audio/subtitle/release-group preferences (`/settings`) with a post-download `ffprobe` verification
  that rejects and blocklists a release whose actual audio/subtitles provably violate them (`ffprobe`
  availability now also shows up as a `/status` health check and a `/settings` Test connection, like
  every other service).
- **Subtitles.** Optional OpenSubtitles.com integration fetches `.srt` sidecars for imported
  movies and episodes in configured languages, at import time and via a 12h backfill sweep.
  Opt-in: set `Subtitle languages` + OpenSubtitles credentials in Settings. Best-effort — never
  blocks an import.
- **Discord notifications.** Optional webhook (Settings → Notifications) posts embeds on
  approvals, availability, and failures; log-only when unset.
- **Movie/series detail pages** with TMDB metadata and per-file info (resolution, size,
  audio/subtitle languages captured at import via ffprobe).
- **Login rate limiting.** Password login capped at 10 failures per `{ip, email}` per 15 min;
  blocked attempts return the same generic error (no enumeration oracle).
- **TV search exhaustion is visible.** An episode whose 10 search attempts run out shows a
  "Search failed" badge (series page + calendar), logs a warning, and notifies — the per-episode
  Search button re-queues it.
- Season badges reach **Available** for requesters (series page + My requests) once every aired
  episode of the season has a file.

### Fixed
- Dependency updates clearing all known CVE advisories (phoenix, plug, mint, hpax, swoosh).
- `Show.S01-E02`-style names no longer parse as whole-season packs (and spaced-dash variants
  parse as episodes).
- Short/numeric series titles ("24", "1883") no longer match other shows' release names on the
  free-text indexer path; non-Latin titles fail closed instead of matching everything.
- A transient filesystem error (unreadable/unmounted downloads dir, at any depth) is retried
  instead of permanently parking + blocklisting a good release.
- Season approvals run off the LiveView — a single approve no longer freezes the page during
  TMDB fetches.
- The manual-search panel bands TV releases per episode, so season packs no longer all read
  "out of band".
- `find_files` walks directories instead of globbing, so `{tmdb-N}` library folders are
  searchable.

### Changed
- `docker-compose.yml` binds `127.0.0.1:4000` by default — claim your admin before exposing the
  port (see the compose comments for LAN/proxy exposure).
- **BREAKING (dogfood only — never released):** the anime per-title release-preference overrides
  (audio mode, subtitle languages, embedded-subtitle mode, preferred/blocked groups, fallback delay
  — added on movies/series earlier in this same development cycle) are dropped in favor of the
  global `/settings` → Anime releases values only; anyone testing off `main` who had set per-title
  values loses them. Nothing changes for a tagged release, since this tier never shipped in one.
- **BREAKING (dogfood only — never released):** the global `/settings` → Anime releases **Audio
  mode** setting and the single-axis per-title `anime_audio_mode` override (added earlier in this
  same cycle) are merged into the existing per-title **Audio** pick (`preferred_language`): the
  values are now Original / French / French + original / Any, chosen once per movie/series with
  no global fallback. On the standard (non-anime) path, French + original filters exactly like
  French. The migration **unconditionally materializes** every anime title's previously effective
  mode onto its Audio pick — per-title override first, else the global setting, else Original (the
  shipped default) — so every no-override anime title is rewritten, not left unchanged. Two
  carve-outs: for an anime title whose old Audio pick differed from the materialized value, that
  pick's former import-time audio-check meaning (`Cinder.Library`'s per-title language filter,
  which reads `preferred_language` regardless of profile) is superseded by the materialized value;
  and an `anime_audio_mode` value on a title no longer at the Anime profile is dropped, not
  materialized. Nothing changes for a tagged release.
- The interim anime grab-mapping-correction page is removed; a `Needs mapping` hold now resolves
  through the same `/activity` **Retry import** / **Discard** actions used everywhere else. The
  underlying safety guarantee — an ambiguous batch never stages a file — is unchanged.
- The one-shot `mix cinder.anime.probe` research tool used to make the A0 anime-provider decision
  is removed; the decision itself is recorded in `docs/audits/2026-07-12-anime-provider-contracts.md`.

## [1.0.0] - 2026-07-03

First public release — a single-container, self-hosted replacement for the Sonarr/Radarr/Seerr
loop (movies + TV + multi-user request/approval), validated ahead of launch by a full pre-v1.0
audit of functionality, security, and UI/UX.

### Added
- **Manual search ("Find a better match")** — an interactive release panel for any title: every
  release the indexer returns, with the scorer's verdict (in band / blocklisted / wrong
  resolution…) and the option to **grab any one manually**, overriding the auto-pick. Movies:
  on `/activity` and the library; TV: per season on the series page. Grabbing a replacement for an
  **already-available movie** downloads it in the background (`:upgrading`) and **atomically swaps**
  the library file on completion — any failure reverts to the existing file untouched, and the
  upgrade can be cancelled mid-download.
- **Release blocklist** — a release that terminally fails (confirmed wrong-language import,
  exhausted download retries) is remembered per title and excluded from future searches, so the
  same bad release is not re-grabbed every cycle. A manual **Retry** clears the slate for a fresh
  pick.
- **`move_on_import` setting** — optionally remove the source download after a successful import
  (Usenet only; torrents are never auto-removed so seeding survives).
- **French interface** — full interface localization with a language switcher (English/French);
  translation completeness is enforced by the test suite.
- **Navigation & pages restructure** — `/dashboard` (service health, approval queue, recent
  activity), `/activity` (live movie pipeline + TV downloads; absorbs the old `/status` and
  `/grabs`, which now redirect), and `/library` (browse + manage everything you've added).
- **Admin efficiency** — bulk approve/deny with row selection in the approval queue, and
  **Reopen** (undo) for a mistakenly denied request.
- **UI overhaul** — a unified design system (buttons, badges, forms, empty states), light/dark
  theme toggle, mobile responsiveness across every page, AA-contrast text, and
  accessibility labels on icon-only controls.
- **Cross-filesystem import** — when the download and library live on different filesystems, import
  no longer fails (`:exdev`). Cinder hardlinks when it can and **automatically falls back to an atomic
  copy** (copy into a temp on the library filesystem, then rename into place) when it can't — a common
  self-host layout that previously parked at `:import_failed`. Same-filesystem imports are unchanged
  (instant hardlink). Trade-off: a copy keeps both files (2× disk unless `move_on_import` is on) and
  takes time proportional to file size; see `docs/operating.md`.
- **Import-time audio-language verification** — Cinder probes a completed download's actual audio
  tracks (via `ffprobe`, shipped in the Docker image) before importing and refuses a file whose
  audio is a confirmed different language from the request — the safety net behind the name-based
  filter (à la Radarr's MediaInfo check), for releases whose name lies or omits the language. Covers
  **movies and TV**: a wrong-language movie parks at `:import_failed`; a wrong-language episode file
  in a pack is skipped so that episode re-searches, while correctly-languaged episodes still import.
  Conservative: a language outside the recognized set, an unrecognized audio code, or a missing
  probe all import rather than reject, so a correctly-languaged file is never stranded. Enabled by
  default; set `media_info: nil` (config) to disable.
- Delete media files from disk when removing a movie, TV show, season, or episode (opt-in
  checkbox on the delete dialogs; mirrors Sonarr/Radarr). Deleting a season/episode file leaves
  the item monitored so the poller re-grabs it, unless you also tick "stop monitoring". Empty
  library folders are pruned. Because library files are hardlinks, disk space is reclaimed only
  once the download client also drops its copy.
- **Multi-user TV requests (parity with movies)** — any authenticated user can search for a TV
  show on `/series` and request a season from the show's discovery page (`/series/tmdb/:tmdb_id`).
  A non-admin's request is `:pending` until an admin approves/denies it; an admin's own request
  auto-approves. Quota enforcement, the **My requests** view, and per-season state badges
  (Pending / Approved / Denied) all apply. On approval, the series is created and only the
  requested season is monitored; the admin can adjust episode-level monitoring from
  `/series/:id` (admin-only). The `/series` discovery page and show discovery are now
  **authenticated** (no longer admin-only); monitor management stays admin-only.
- **Per-kind library config (Movies, TV)** — every library kind has its own import root, Plex
  scan section, and editable release size band, all derived from one `Cinder.Library.kinds/0`
  list, so movies and TV behave identically and a new media type (books, audio) is a one-line
  addition. Movies now get an editable size band in `/settings`, like TV (per-episode for TV).
  Both library roots remain required and separate (the TV root does not fall back to the movie root).
- **Per-library Plex scan** — `MediaServer.scan(kind)` refreshes the right Plex section, so a TV
  import refreshes the Shows library. Previously a single movie-only section was refreshed and TV
  imports never refreshed Plex (Jellyfin's full refresh was unaffected). `/status` now shows a
  per-kind library health row, and a missing root holds the import (visible red) instead of failing.
- Per-kind **preferred sources** setting (Blu-ray / WEB-DL / HDTV / …) in `/settings` → Release
  size bands, mirroring preferred resolutions. Empty = accept any source; untagged releases are
  always kept; only a recognized-but-unlisted source is rejected.

### Changed
- The import-time upgrade decision now honors the per-kind **preferred sources** setting
  (`language → resolution → source → size`), consistent with release selection — so when a
  collision occurs at the library destination, a same-resolution better-source release replaces an
  imported lesser-source file instead of being discarded on a size tie. Persists a new
  `imported_source` per movie/episode (additive migration; existing rows rank a missing source
  last, and are never re-grabbed, so the change is inert for already-imported items).
- **BREAKING (config):** library config keys are regularized per kind — the movie env vars gain the
  `MOVIES_` prefix the TV ones already had:
  - `LIBRARY_PATH` → `MOVIES_LIBRARY_PATH`
  - `PLEX_SECTION` → `MOVIES_PLEX_SECTION` (plus a new `TV_PLEX_SECTION` for the Shows library)

  Stored `/settings` rows are renamed automatically by a migration on upgrade — **but environment
  variables are not.** If you bootstrap via `docker-compose.yml` / `.env`, rename these there
  before redeploying, or the movie library path/section reverts to unset (movie imports then hold,
  shown red on `/status`, until you set it).

### Fixed
- **Low-resolution grabs** — a movie/episode could be grabbed below the requested resolution (e.g.
  asking for a French film in 1080p and getting 480p). The preferred-resolution setting only
  *re-ordered* candidates, so when the only in-band release was a lower resolution it was grabbed
  anyway. It is now a **strict allow-list**: a release whose resolution isn't in
  `movies_preferred_resolutions` / `tv_preferred_resolutions` (default `1080p, 720p`) is rejected
  outright, and an **untagged** release (no resolution in its name) is rejected too. If nothing in
  the allow-list is available, the item parks and re-searches rather than grabbing a worse release —
  widen the list (e.g. add `2160p`) to accept more resolutions. Clearing the field reverts to the
  default `1080p, 720p` allow-list; it does not turn filtering off.
- **Wrong-language matches** — a movie could be grabbed and imported in the wrong language (e.g. a
  French film matched in Hungarian). The release parser recognized only five languages, so a foreign
  dub parsed as "no tag" and the language filter then assumed an untagged release was the title's
  *original* audio. The parser now recognizes ~40 audio-language tags (adapted from Radarr's GPL
  `LanguageParser`; subtitle markers like `ENG.SUBS` / `LATINO.SUBS` are stripped so they don't read
  as audio), and an untagged release is treated as **English** (scene convention) rather than the
  title's original.
- **qBittorrent v5.x compatibility** — qBittorrent ≥ 5.x answers `POST /api/v2/auth/login` with
  `204 No Content` (not `200`) and names the session cookie `QBT_SID_<port>` (not `SID`). The client
  accepted only `200` and resent a literal `SID=` cookie, so every qBittorrent call (add / status /
  health) failed login with `{:qbittorrent_status, 204}` on modern servers. It now accepts any `2xx`
  login and threads the real session cookie back verbatim.
- **Pre-v1.0 release-audit fixes:**
  - **Docker:** the image now creates and owns `/data`, so a fresh `docker compose up` can write its
    SQLite database instead of crash-looping (the `nobody` user couldn't write the root-owned
    fresh-volume mountpoint).
  - **Scorer:** a release whose indexer omits the size no longer slips past a configured max-size
    band (it's accepted only when no band is set) — affected both movies and TV packs.
  - **Library import:** a title that sanitizes to only dots (e.g. `..`) now falls back to a tmdb-id
    folder instead of escaping the library root; an existing destination is treated as an idempotent
    success only when it's already a hardlink of the source (a *different* file colliding on the same
    `Title (Year)` name now fails loudly rather than mis-linking); and a TV pack with two files
    naming the same episode keeps the largest and logs the rest instead of colliding.
  - **`/activity`:** the Retry button no longer crashes the LiveView on a forged (non-numeric) id.
  - **SABnzbd:** the side-effecting `addurl` is no longer auto-retried by `Req`, preventing duplicate
    downloads on a transient failure.
  - **Admin audit:** changing a user's request quota now writes an `admin_audit` row, like every
    other destructive admin action.
  - **TV refresh:** the periodic TMDB reconcile no longer renumbers an episode with an in-flight
    grab (which could mislabel that grab's imported files).
  - **qBittorrent:** an indexer download URL that redirects to a `magnet:` URI (standard Prowlarr
    behavior for magnet-only trackers) now routes through the magnet add path instead of crashing
    the search unit and re-searching every 5s forever; redirects are followed manually with a hop
    limit, and a redirect to a non-HTTP scheme parks cleanly. Wrong credentials now make **one**
    login attempt per poller per 10 minutes instead of one per item per tick — which tripped
    qBittorrent's consecutive-failure IP ban (default: 5 failures → 1 h) within a single tick.
  - **TV search:** the wrong-series title guard now applies only to free-text (no TVDB id)
    searches, and equates `&`/`and` — previously every season of an ampersand-titled
    ("Law & Order") or AKA-titled ("Money Heist" vs `La.Casa.de.Papel.…`) show was rejected and
    permanently stranded at *couldn't find*.
  - **Cancel races:** every poller write-back is now guarded on the status it read, so cancelling
    a movie mid-search/mid-download can no longer be silently overwritten by the in-flight poller
    unit; a season pack grab links only still-monitored episodes, so **Cancel series** can no
    longer be resurrected by a search that was already in flight; and a TV grab that fails to link
    removes the just-added client download instead of orphaning it.
  - **Approval queue:** approve/deny are now guarded on the row's live status, so two admin
    sessions racing (e.g. a slow bulk approve vs a concurrent deny) can no longer silently reverse
    each other's decision; deleting a request updates other admins' open queues live; a failed
    deny/approve shows an error instead of silently doing nothing; and the per-row deny form has a
    Cancel button.
  - **/activity delete:** deleting a download now also removes it from the download client
    (previously it kept downloading and collided with the automatic re-grab) and reports failure
    instead of always flashing "Download deleted."
  - **Parser:** word-form multi-season packs (`Season 1-5`) are rejected instead of read as
    season 1, and a group fragment like `-S1CK` on a season-less name no longer masquerades as a
    whole-season pack.
  - **Manual-search panel:** verdicts now use your configured size band, preferred
    resolutions/sources, and blocklist — they previously ignored them and contradicted the
    auto-pick.
  - **Settings:** typing a replacement secret while also ticking "Clear saved value" now keeps the
    typed value (previously both were discarded and the service silently lost auth); an unusable
    size-band value (`abc`, `0`) is rejected with an error naming the field instead of persisted
    and silently treated as *no limit*; deleting an episode/season file also resets its search
    counter so a previously parked episode really is re-grabbed.
  - **Health checks:** every probe is bounded (3 s connect + receive, no retries) so a blackholed
    host can't hang "Test connection" for minutes; TMDB/Prowlarr calls no longer triple-retry on
    top of the pollers' own retry budget; an unconfigured Plex shows "Not configured" instead of
    an opaque failure.
  - **UI polish:** warning-level flashes (e.g. a partial season-file delete) now actually render;
    the per-season "Search all missing" button searches only that season (was series-wide);
    dates are localized in French; the admin **Users** nav entry no longer lights up on the
    Account page; a specials-only series shows an explanatory empty state instead of a blank
    list; a TMDB outage on the series page says so instead of "Series not found."; a deleted
    movie's *Available* badge clears live on the discover page.

### Internal
- SQLite correctness settings (`journal_mode: :wal`, `busy_timeout`, `foreign_keys: :on`, and now
  `default_transaction_mode: :immediate`) are pinned once in `config/config.exs` so every
  environment — including a non-prod release — applies them. `:immediate` makes `busy_timeout`
  govern the app's read-then-write transactions (a deferred `BEGIN` could still raise
  `SQLITE_BUSY_SNAPSHOT`, which `busy_timeout` can't retry).

## [0.7.0] - 2026-06-23

First packaged, publicly installable release — the movies + TV + multi-user product behind a
Docker image and a first-run wizard. Pre-1.0: dogfooding ahead of the v1.0 public launch.

### Added
- **Movies pipeline** — request → Prowlarr search → qBittorrent/SABnzbd download → hardlink +
  import into Jellyfin/Plex, advanced by background pollers with live LiveView status and
  crash-recovery.
- **TV pipeline** — series/season/episode monitoring, season-pack and multi-episode parsing +
  scoring, multi-file import, a periodic TMDB refresh sweep, and an upcoming-episodes calendar.
- **Multi-user** — local accounts with `admin`/`user` roles; non-admins request, an admin
  approves/denies (the approval gate lives in the data model), per-user quotas, and a notifier
  seam.
- **In-app configuration** — a settings store overlaying env bootstrap (secrets encrypted at
  rest via Cloak), a first-run setup wizard that validates every service before completion, and
  per-service health checks on `/status`.
- **Packaging** — Docker image, `docker-compose.yml` + `.env.example`, a tag-triggered GitHub
  Actions workflow publishing `ghcr.io/simonbrunou/cinder`, and operator + contributor docs.

[Unreleased]: https://github.com/simonbrunou/cinder/compare/v3.0.0...HEAD
[3.0.0]: https://github.com/simonbrunou/cinder/compare/v2.0.0...v3.0.0
[2.0.0]: https://github.com/simonbrunou/cinder/compare/v1.1.0...v2.0.0
[1.1.0]: https://github.com/simonbrunou/cinder/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/simonbrunou/cinder/compare/v0.7.0...v1.0.0
[0.7.0]: https://github.com/simonbrunou/cinder/releases/tag/v0.7.0
