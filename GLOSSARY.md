# Cinder

Cinder takes a household's request for a movie, TV series, e-book or audiobook, finds a release,
downloads it and imports it into the library a media server reads.

## Language

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

**Release judge**:
The decision that accepts or rejects one release for one work, always with a named reason, and
ranks the accepted ones.
_Avoid_: filter, matcher

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

**Blocked content**:
A download whose file list carries an executable or shortcut and nothing that could be the media
itself, which marks the release as a fake.
_Avoid_: fake payload, malware

**Stalled download**:
An in-flight download that has made no forward progress for longer than Cinder is configured to
wait.
_Avoid_: dead download, stuck download

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
it. It holds one of its requester's quota slots under `auto_approve_all`. A season whose row no
longer exists is not outstanding.
_Avoid_: unfulfilled target, open request

### Settings

**Setting definition**:
Everything Cinder knows about one settings key: its shape, the `/settings` group it sits in, its
label, how a rejected value is explained, the env key it overlays and what it falls back to.
_Avoid_: config field, registry entry

**Bootstrap**:
The env value a setting falls back to when no row is stored, captured once before the first
overlay so a cleared setting reverts to it.
_Avoid_: default, base config

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
