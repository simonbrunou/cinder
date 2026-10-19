# Cinder

Cinder takes a household's request for a movie, TV series, e-book or audiobook, finds a release,
downloads it and imports it into the library a media server reads.

## Language

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
