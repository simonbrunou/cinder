# Cinder

Cinder takes a household's request for a movie, TV series, e-book or audiobook, finds a release,
downloads it and imports it into the library a media server reads.

## Language

### Acquisition

**Release judge**:
The decision that accepts or rejects each release one search returned for one request target,
always with a named reason, and ranks the accepted ones. The manual-search panel lists it. For a
movie, a TV season or an anime title automatic selection takes its pick from the same judge, so
the two can't disagree, and it also names the stage that dropped a release before scoring: no
download client for its protocol, a name that isn't the target's, the audio pick, or for anime
episodes a release that isn't a story episode or doesn't map to the wanted episodes. Books have
no automatic selection.
_Avoid_: filter, matcher, release decision

**Set-cover**:
How automatic selection chooses the releases for a TV season's or an anime series' wanted
episodes: greedily, one release at a time, until the wanted episodes are covered or nothing left
fits. Each step takes a release whose audio tag satisfies the title's audio pick before an
untagged one (a TV season only; an anime policy judges audio its own way), then the one covering
the most still-wanted episodes, then the better-ranked release. Size is judged per episode,
against the still-wanted episodes a release covers. For a TV season, only when nothing fits that
way is a whole-season pack judged against the whole season, the **season band**.
_Avoid_: cover set, the picker, rung

**Household policy**:
The household's rules for acquiring one movie or series: which protocols have a download client,
the title's audio pick, the releases blocked for it, and the size band and quality preferences set
for its kind. The anime policy is resolved separately, on top of it.
_Avoid_: search opts, scorer opts

**Group wait**:
Holding back an anime release from a group outside the preferred ones until a set delay after it
was published, so a preferred group's release can arrive first. A release with no publication time
can't start the wait, so automatic selection never takes it.
_Avoid_: fallback delay (the setting, not the rule), group timing

**Blocked release**:
A release Cinder will not grab again for one movie or series, recorded with its reason: a failed or
stalled download, a release that broke its policy, a cancelled verification hold. One reason,
`no_upgrade`, blocks it for the upgrade sweep only: the pack placed nothing better than what the
library holds.
_Avoid_: blacklist, banned release

### Books

**Book family**:
E-books and audiobooks taken together. A work is requested, judged and imported the same way in
either form, with only the book kind's own rules differing.
_Avoid_: books (when it means e-books only)

**Book kind**:
The form a work is acquired in: e-book or audiobook. Each kind has its own accepted formats, size
band and release-name vocabulary.
_Avoid_: profile, media profile (a library root and its quality settings), format (a container
such as EPUB or M4B)

**Query plan**:
A book kind's rule for which identifiers of its editions to probe the indexers with, and in what
order: ISBN for an e-book, ASIN then ISBN for an audiobook. Every search for a work runs the most
specific evidence first: a few of those identifiers, then author and title, then free text.
_Avoid_: search strategy, query list

**Companion**:
A file beside a book download's one archive that can never be the book, from a fixed list: scene
files such as the `.nfo` and `.sfv`, a cover image, and any file whose extension the download
content check blocks, such as a filler `.exe`. The archive still extracts with companions beside
it, and a companion is never imported. Any other file beside the archive holds the book as an
unsupported archive.
_Avoid_: sidecar (a subtitle file beside a video), extras

### Catalog

**Title**:
A movie or a series: what a household asks the catalog for, and what a media profile, a language
pick and a deletion apply to. A book is not a title; it is a work with one target per media kind.
_Avoid_: media (on its own), item

### Downloads

**In-flight download**:
A download Cinder has handed to a download client and not yet passed to import, whatever the
client currently reports about it.
_Avoid_: active download

**Download watch**:
The look Cinder takes at each in-flight download on every poll, which ends in one verdict.
_Avoid_: download check, status poll

**Verdict**:
The single outcome of one download watch for one in-flight download: what Cinder should do with it
next.
_Avoid_: result, status

**Download failure**:
A verdict saying the download client reports the download went wrong: it errored, it finished with
no usable path, or the client no longer knows the job, torrent or usenet alike. A poller acts on one
only after a few ticks, because a job moving between queue and history looks the same for a
moment. Past that bound Cinder gives up on the release and blocklists it: a movie re-queues or
parks (an upgrade reverts), a TV grab parks, a book target is held.
_Avoid_: torrent not found, missing download

**Blocked content**:
A download whose file list carries an executable or shortcut and nothing that could be the media
itself, which marks the release as a fake.
_Avoid_: fake payload, malware

**Stalled download**:
An in-flight download that has made no forward progress for longer than Cinder is configured to
wait.
_Avoid_: dead download, stuck download

### Health

**Probe target**:
One thing Cinder can check on demand (an external service, a library root, a local tool), with a
stable id, the settings group whose Test button checks it, whether setup requires it, whether
the dashboard shows it and whether the dashboard names the adapter the operator picked for it.
_Avoid_: service, health check

### Library

**Staged import**:
Files placed at their final library paths but still reversible until the catalog write that
records them commits. After that write, Cinder commits what the write recorded and rolls back the
rest, so no library file is left that no catalog row claims.
_Avoid_: stage handle, rollback map, import stage (one journal row of it)

**Household import lock**:
The one lock a poller's import holds from placing its files to settling them, so crash recovery
cannot roll back an import that is still in progress.
_Avoid_: stage handoff, handoff lock

**Imported quality**:
What Cinder recorded about the file a movie or episode holds: the resolution, source and language
read from its name (filled from the release title where the name says nothing), its size, and the
audio, embedded-subtitle and sidecar languages found in and next to it. An upgrade is judged
against it, and it is stored in the row's `imported_*` columns.
_Avoid_: quality map, old quality, existing quality

**Unrecorded quality**:
The imported quality of a held file that Cinder never recorded: no resolution, size or language,
because the file was adopted or imported before those columns existed. An import adopts the
incoming file's quality over it, and the upgrade sweep never replaces such a file on its own.
_Avoid_: nil baseline, nil quality

### Movies

**Movie lifecycle**:
The statuses a movie moves through from request to library, and the named events that move it
between them.
_Avoid_: pipeline state machine, status flow

**Parked movie**:
A movie stopped on a failure until someone retries it: no match, search failed or import failed.
_Avoid_: failed movie, stuck movie

**Verification hold**:
An import failure that keeps its download because Cinder could not check the release against the
movie's policy, waiting for the operator to retry, cancel or abort it.
_Avoid_: policy hold, verification block

**Re-queue**:
Sending a movie whose download died back to requested, with that release blocklisted, so the next
search picks another one.
_Avoid_: reset, re-search

**Upgrade revert**:
Returning an upgrading movie to available with its existing library file, after the replacement
failed.
_Avoid_: upgrade rollback, upgrade cancel

**Failure budget**:
How many failures of one kind a movie may take in its current phase before Cinder parks,
re-queues or reverts it.
_Avoid_: retry limit, max attempts

### Operator attention

**Offered action**:
An operator action Cinder accepts for an item in its current state, such as retry, discard or
pause. A button renders only for an offered action, and the action refuses an item that does not
offer it.
_Avoid_: available action, allowed action

**Needs attention**:
An item stopped until the operator acts: `/activity` offers an action for it or links to its fix.
A parked movie, a verification hold, a TV grab on a mapping, verification or residual-files hold,
or an anime hold. The Activity nav badge and the beacon pill count exactly these.
_Avoid_: held, stuck, failed

**Anime hold**:
A movie or series the search sweep skips because the household's anime preferences can't be
satisfied for it, with the reason why: dual audio for a title whose original language is unknown,
or embedded subtitles required with no subtitle languages set. Each reason clears only after the
operator changes something, so an anime hold needs attention, and the next sweep lifts it.
Cancelling a series, or setting its monitoring to none, lifts its hold at once.
_Avoid_: preferences hold, anime block

**Fix**:
The change, made on another page, that clears an item needing attention: the Audio pick or
profile on the title's detail page, or the subtitle languages in Settings. `/activity` links to it.
_Avoid_: remedy, resolution, correction (a subtitle timing change)

**Waiting item**:
An item Cinder skips until something changes that the operator does not have to change. It needs
no attention. No item waits today: an anime hold reason that cleared on its own would.
_Avoid_: held item, paused item (a paused book target is idle)

### Requests

**Request target**:
The thing a request asks for: a movie, one season of a series, or a book in one media kind. A
request names it by an id that means something different per kind: a movie's TMDB id, the series'
TMDB id plus a season number, or a local book work id plus a media kind.
_Avoid_: request item, requested title

**Target key**:
The typed key for a request target (`{:movie, tmdb_id}`, `{:season, tmdb_id, number}`,
`{:book, work_id, kind}`), so ids from different kinds never meet in one map.
_Avoid_: target id

**Watchable**:
A request target the household can watch on the media server now: a movie at `:available` or
`:upgrading`, or a season whose aired episodes have all landed. A book is never watchable; it lands
in Booklore or Audiobookshelf instead.
_Avoid_: available (on its own, it also names the book and movie badge states)

**Outstanding target**:
A request target an approved request still waits on: it has not landed and no operator has stopped
it. It holds one of its requester's quota slots under `auto_approve_all`. A target with no row stays
outstanding and keeps its slot, whether its movie, season or book row is gone or never existed.
_Avoid_: unfulfilled target, open request

**Approval**:
The step that commits Cinder to acquiring a request target. In one transaction the request becomes
`:approved` and its target is created or armed: a movie or series row at `:requested`, or a
monitored book target. Nothing is announced until it commits. An approval is either an admin
approval of a pending request or an auto-approval.
_Avoid_: acceptance, grant

**Auto-approval**:
An approval at request time, with no pending stage: the request is an admin's own, or
`auto_approve_all` is on. It re-counts the requester's quota after the target exists and is refused
over quota. An admin approval never checks the quota: it does not grow the count, and the admin
decides.
_Avoid_: auto-accept, instant request

### Settings

**Setting definition**:
Everything Cinder knows about one settings key: its shape, the `/settings` group it sits in, its
label, how a rejected value is explained, the env key it overlays and what it falls back to.
_Avoid_: config field, registry entry

**Bootstrap**:
The env value a setting falls back to when no row is stored, captured once before the first
overlay so a cleared setting reverts to it.
_Avoid_: default, base config

### Status writes

**Guarded write**:
A change to a movie's, episode's, book target's or request's state that lands only if the row
still holds what the caller read. One that misses is stale and changes nothing; one that commits
is announced once, after its transaction commits; one refused inside a transaction rolls that
whole transaction back.
_Avoid_: CAS, transition (on its own)

**Stale write**:
A guarded write whose row moved on since the caller read it, so it writes nothing. A poller
re-reads the row on its next tick; an operator action reports that the item already changed.
_Avoid_: conflict, race loss

### Subtitles

**Sidecar**:
A subtitle file stored next to its video, named after it (`Movie.en.srt`).
_Avoid_: subtitle file, external subtitle

**Managed sidecar**:
A sidecar Cinder wrote or adopted and records in the video's hidden subtitle manifest, so Cinder may
rewrite it.
_Avoid_: owned sidecar, tracked subtitle

**Moviehash**:
The OpenSubtitles hash of a video's bytes, used as the video's identity: a different moviehash at
the same path means a different file.
_Avoid_: video hash, fingerprint

**Correction**:
New timing for a managed sidecar, either automatic (from alignment) or manual (an offset and rate
the operator chose).
_Avoid_: fix, adjustment, resync

**Immutable original**:
The sidecar's bytes from before its first correction, kept beside it so every later correction and
every reset starts from them.
_Avoid_: backup copy, source file

**Backup tombstone**:
An immutable original that is no longer needed, emptied to zero bytes but kept with its recorded
identity so Cinder can later prove it owns that file.
_Avoid_: empty backup, deleted backup

**Sidecar replacement transaction**:
The crash-safe protocol through which every change to a managed sidecar's bytes goes: corrections,
resets and newly fetched subtitles.
_Avoid_: sync write, atomic write

**Pending record**:
The manifest entry that names a correction's expected and new bytes before any byte changes, so an
interrupted correction can be finished or undone.
_Avoid_: applying state, intent

**Final record**:
The manifest entry that describes a managed sidecar's current timing: how it was aligned, from which
original, against which moviehash.
_Avoid_: sync metadata, sync state

**Cleanup journal**:
The manifest entry that keeps the previous final record while an immutable original is being
retired, so an interrupted reset or replacement can be finished.
_Avoid_: cleanup state, provenance
