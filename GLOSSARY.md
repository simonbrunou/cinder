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
