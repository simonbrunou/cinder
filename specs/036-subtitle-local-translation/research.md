# Local subtitle extraction and translation fallback — design

**Date:** 2026-07-10
**Status:** approved for specification review
**Scope:** movies and TV episodes; imported media only.

## Goal

Fill every configured subtitle language when OpenSubtitles has no usable result for that
language. Search OpenSubtitles first, preferring an exact OSDb moviehash match and accepting an
ID match as a lower-quality fallback. Only a successful search with no usable candidate permits
local extraction or translation.

The local fallback prioritizes subtitles embedded in the imported media because they are
time-aligned with that file. If an embedded text track is unavailable, Cinder may use an existing
`.srt` sidecar. LibreTranslate supplies translated output. Local and ID-only results remain
eligible for replacement by a later moviehash match.

## Decisions

- `subtitle_languages` remains the complete target list. The `SUBTITLE_LANGUAGES` environment
  variable is its bootstrap value; the in-app setting continues to override it.
- Selection is **per requested target language**, never global. An OpenSubtitles English result
  does not prevent a French local fallback.
- OpenSubtitles precedence is: moviehash match, then ID match. Either is usable; a hash result is
  preferred and an ID result is provisional.
- A provider error, authentication failure, timeout, or daily-quota response is not a subtitle
  miss. It must not trigger LibreTranslate or replace a current file.
- For an OpenSubtitles miss, select the local source in this order:
  1. An extractable embedded text track in the requested language: extract it directly.
  2. The default, non-forced embedded text track: extract it once and translate it into each
     remaining requested language.
  3. An existing `.srt` sidecar: use it directly for an exact requested language or translate it
     for remaining languages.
- Image subtitle formats (PGS, VobSub) and forced-only tracks are not translation sources. OCR is
  out of scope.
- Only Cinder-managed sidecars may be replaced automatically. A sidecar without Cinder
  provenance is user-owned and is never overwritten. A sidecar linked by Cinder from the current
  download is marked Cinder-managed and may be superseded.
- Generated output is always `.srt`. SRT cue numbers, timestamps, blank separators, and inline
  markup are preserved; only dialogue text is sent to LibreTranslate.
- There is no subtitles Ecto table. A hidden adjacent manifest records the minimum provenance
  needed for safe upgrades.

## Architecture

### `Cinder.Subtitles`

Remains the coordinator for import-time fetching and the periodic sweeper. It changes from
"existing sidecar means skip" to a per-language decision that consults subtitle provenance,
OpenSubtitles, then local sources.

For each sidecar Cinder manages, the hidden manifest records:

```json
{
  "video_moviehash": "0123456789abcdef",
  "tracks": {
    "en": {"origin": "opensubtitles_hash"},
    "fr": {"origin": "translated"}
  }
}
```

The exact file name is an implementation detail, but it is adjacent to the video and ignored by
media servers. The manifest is written atomically alongside replacement sidecars.

Origins are `opensubtitles_hash`, `opensubtitles_id`, `embedded`, `translated`, and
`release_sidecar`. A current-video hash match with `opensubtitles_hash` is stable. All other
origins are provisional and are searched again by the sweeper. A manifest whose video hash no
longer matches the imported file invalidates its stable classification, so a video quality upgrade
cannot keep a subtitle that was hash-synced to the old file.

### Embedded subtitle extraction

Extend the existing `Cinder.Library.MediaInfo` behaviour and its FFmpeg implementation instead of
creating a second process seam. It exposes ordered, extractable text tracks with stream index,
normalized ISO language, default/forced disposition, and extraction to SRT bytes.

The FFmpeg implementation excludes image codecs before selection. `eng`, `fre`, and `fra` are
normalized to the ISO-639-1 codes used by `subtitle_languages` (`en`, `fr`). If extraction
fails, Cinder logs the failure and continues to the sidecar fallback without affecting video
import.

### LibreTranslate

Add `Cinder.Subtitles.Translator` as the required behaviour seam for the external translation
service, with one implementation: `Cinder.Subtitles.Translator.LibreTranslate`. It accepts an ordered
list of dialogue strings and a requested target language; the LibreTranslate call uses source
autodetection. The caller reconstructs the original SRT from the translated dialogue, preserving
all timing and control structure.

`libretranslate_url` and an optional secret `libretranslate_api_key` are settings-store entries
in the existing Subtitles group, with environment bootstrap equivalents. If no URL is configured,
translation is unavailable and the worker logs a best-effort miss; it does not change imported
media or provider behaviour.

### Filesystem and media-server refresh

The existing filesystem behaviour gains only the read primitive required to use a source `.srt`.
Replacement writes use the existing write and rename primitives: write a sibling temporary file,
then rename it into place. This avoids a partial SRT if Cinder is interrupted.

After a new or replaced Cinder-managed sidecar is committed, request the same movie or TV
media-server scan used by import. Subtitle work stays off the import and poller path and remains
best-effort.

## Per-language data flow

1. Read the manifest and compute the current video moviehash when needed.
2. If the target has a current `opensubtitles_hash` entry, leave it untouched.
3. Search OpenSubtitles for that target language using the existing ID and moviehash criteria.
   - Hash candidate: download, atomically replace the Cinder-managed target, write
     `opensubtitles_hash` provenance.
   - ID candidate: download only for a missing or provisional Cinder target, then write
     `opensubtitles_id` provenance.
   - Empty successful result: continue to local fallback.
   - Provider error or quota: leave the target unchanged; do not translate.
4. On a successful provider miss, use an exact-language embedded text track if one exists.
5. For still-missing targets, extract the default non-forced embedded text track once and translate
   its dialogue into each target.
6. If there is no usable embedded track, use an existing `.srt` sidecar as the exact-language or
   translation source.
7. Commit the output and manifest atomically, then refresh the appropriate media-server library.

An unmarked existing target sidecar is never replaced. It may be read as a translation source only
after no usable embedded source exists.

## Import and sweep integration

Import continues to dispatch subtitle work through `Cinder.Subtitles.TaskSupervisor`, after the
video and release sidecars are in the library. It passes the media kind so a successful sidecar
write can refresh the right library.

The 12-hour sweep derives work from imported files as today. It skips only stable hash-provenance
targets; missing and provisional targets are rechecked. A small per-video lock
serializes import and sweep work, preventing duplicate downloads or competing writes. The app is a
single-instance household deployment, so no distributed locking system is introduced.

## Error handling

- FFmpeg probe/extraction errors, invalid SRT, LibreTranslate errors, filesystem failures, and
  media-server scan failures are logged and do not affect video import state.
- OpenSubtitles quota stops the remaining provider work for that sweep tick, as it does today.
- Translation failure leaves the current subtitle intact and the target missing or provisional for
  a later retry.
- A temporary or partial subtitle is never promoted over the current target path.

## Testing

All tests are mocked through the existing behaviour seams; no test contacts FFmpeg,
LibreTranslate, or OpenSubtitles.

- Provider selection: a hash match beats a higher-download ID match; an ID result is accepted and
  marked provisional; provider errors and quota never invoke local fallback.
- Per-language behaviour: an OpenSubtitles `en` result plus no `fr` result fills only `fr`
  locally.
- Extraction: an exact embedded target track is copied to SRT; otherwise the default non-forced
  text track is extracted once and supplies translations; image, forced-only, and failed tracks
  fall through.
- Sidecars: existing `.srt` is used only when no usable embedded source exists; unmarked targets
  are never overwritten.
- SRT translation: cue count, sequence, timestamps, separators, and markup survive translation.
- Manifest: ID/local tracks recheck and upgrade to a hash match; a changed video invalidates a
  prior hash-stable entry; a stable current hash match is skipped.
- Concurrency/atomicity: import and sweep cannot both commit a target, and a failed temporary write
  leaves the old sidecar and manifest intact.
- Import and sweep remain best-effort, and successful sidecar changes request the correct
  media-server scan.

`mix test` remains the completion check.

## Deliberately excluded

- OCR or conversion of image subtitles.
- Translating `.ass`, `.ssa`, `.sub`, or `.vtt` content.
- A subtitle database, retry counters, or per-item UI overrides.
- Additional translation providers or automatic model hosting.
- Deleting an old sidecar when no replacement can be produced.
