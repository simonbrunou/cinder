# Media info: audio languages + subtitles for acquired media

**Date:** 2026-07-07
**Status:** approved (design)
**Scope:** movies + TV. Post-import only. No release-picker change.

## Problem

The detail pages show an imported file's `resolution / size / source / language` (a single
parsed audio-language tag). They do **not** show which **audio languages** the file actually
carries, nor whether it has **subtitles** — embedded (in-container) or sidecar (loose `.srt`).
The parsed `language` tag is a name-derived guess; it says nothing about subtitles.

We want, for already-acquired media, the **true** audio languages and subtitle languages,
distinguishing embedded from sidecar, read from the real file at import and shown on the
movie/series detail pages.

## Non-goals (YAGNI)

- The manual-search **release picker** stays as-is (it already shows the name-parsed
  `language`; embedded-vs-sidecar can't be known before download).
- No subtitle **content** inspection, no per-language scoring, no change to the OpenSubtitles
  fetch subsystem.
- **Forced/SDH** flags are preserved in the imported sidecar's filename (for the media server)
  but are **not** modeled as separate fields or shown separately.

## What we capture (per imported video file)

- **Audio languages** — ISO codes from the file's audio streams (ffprobe).
- **Embedded subtitle languages** — ISO codes from the file's subtitle streams (ffprobe).
- **Sidecar subtitle languages** — from `.srt/.ass/.ssa/.sub/.vtt` files shipped alongside the
  video in the download folder. These are now **imported** (hardlinked) next to the video so the
  media server can use them, and their languages recorded.

Codes are lowercased ISO; `"und"` when a track/file declares no resolvable language.

## Storage

Three new nullable columns on **both** `movies` and `episodes`, mirroring the existing
`imported_*` convention (precedent: `genres` is already `{:array, :string}`; `ecto_sqlite3`
JSON-encodes array columns):

```
imported_audio_languages     {:array, :string}   # ["en", "fr"]
imported_embedded_subtitles  {:array, :string}   # ["en"]
imported_sidecar_subtitles   {:array, :string}   # ["fr"]
```

**Decision:** three arrays, not one JSON map — consistent with the sibling `imported_*` fields,
self-documenting, read directly by the detail templates. No new query needs them, so no index.

Added to each schema's `transition_changeset/2`. The import write already routes through
`Catalog.transition` (movie `:downloaded → :available`) and `Catalog.finish_grab` /
`transition_episode` (episode), each carrying an `imported_*` quality map — we extend that map
with the three new lists. **No new write path at import.**

## Probe: one ffprobe call, both stream types

Replace the `Cinder.Library.MediaInfo` behaviour callback:

```
# was: audio_languages(path) :: {:ok, [code]} | {:error, reason}
probe(path) :: {:ok, %{audio: [code], subtitles: [code]}} | {:error, reason}
```

One `ffprobe` invocation returns both audio and subtitle stream language tags
(`-show_entries stream=codec_type:stream_tags=language`, all streams, then bucket by
`codec_type`). Same untagged/`und` dropping as today.

`Cinder.Library`'s `check_audio` (the language-mismatch/park check) reads `probe(...).audio` —
**behavior unchanged**, just sourced from the combined probe, so its result is reused for both
the park check and storage (one probe per file). A missing or failing `ffprobe` still returns
`{:error, _}` and the importer treats it as "can't verify, import anyway" (audio langs / subs
recorded empty).

**Capture runs unconditionally.** Today `verify_audio(_source, nil)` short-circuits and skips
the probe when no preferred language is set. Capture must not depend on that gate: the import
probes every file for storage, and the park check additionally consults `.audio` **only** when a
target language is set. So a movie with `preferred_language` `"any"`/`nil` still records its
audio + subtitle languages; it just isn't parked on a mismatch.

**Decision:** replace `audio_languages/1` with `probe/1` (one process) rather than add a second
callback. Only `check_audio` consumes it. Behaviour + `Ffprobe` impl + Mox mock + tests change
atomically (house norm for behaviour-signature changes).

## Sidecar import (shared helper, through the `fs()` behaviour)

A shared helper used by the movie placement (`place`) and the TV placement
(`place_episode_file`), invoked right after the video is hardlinked:

1. In the **source** folder of the video, find sibling subtitle files with extensions
   `.srt .ass .ssa .sub .vtt`. Match by the video's basename stem; for a single-video download
   (movie or lone-episode grab) a lone subtitle file with no stem match is still accepted.
2. Hardlink each next to the **dest** video, renamed
   `<dest_stem>.<lang>[.forced][.sdh].<ext>` — preserving the language token and any
   `forced`/`sdh`/`cc` flag so the media server picks them up.
3. Return the list of sidecar language codes for storage.

All filesystem work goes through the existing `fs()` behaviour (find/hardlink), so it is tested
without touching disk.

**Sidecar language parse:** the token between the stem and extension (`Name.en.srt`,
`Name.eng.forced.srt`), resolved via a small alias map derived from `Parser.audio_codes`
(639-1/639-2 forms) plus full-word language names. A `forced`/`sdh`/`cc`/`hi` token is a flag,
not a language; skip it. Unknown or absent language → `"und"` (a sidecar still counts as present).

## Backfill existing library

`mix cinder.media_info.backfill` — a Mix task:

- Lists every `:available` movie and every episode with a `file_path`.
- For each: `probe/1` the imported file (audio + embedded subs), and scan the file's **library**
  folder for currently-present sidecar files.
- Writes the three fields via a new **descriptive** writer `Catalog.set_media_info/2` — a
  non-transition changeset in the style of `enrich_movie` / the language edit (it enriches
  descriptive fields on an already-`:available` row; it is **not** a status transition, so it
  does not go through `Catalog.transition`).
- Idempotent — safe to re-run.

**Stated limitation:** backfill cannot resurrect release-shipped sidecars that imports predating
this feature left in the download folder (only the video was hardlinked then). It reports
embedded tracks + whatever `.srt` currently sits next to the file. New imports capture sidecars
correctly.

## Display

- **Movie detail** (`movie_detail_live`) — two rows added to the existing "Downloaded file"
  `<dl>`: **Audio** (one language badge per code) and **Subtitles** (one badge per subtitle
  language, tagged *embedded* or *sidecar*). Each row gated on a non-empty list.
- **Series detail** (`series_detail_live`) — compact audio + subtitle language badges on each
  **imported** episode row (those with a `file_path`). Kept minimal to avoid crowding a full
  season.

New gettext strings for the labels/tags; run `gettext.extract --merge` last (line-ref drift).

## Testing

All mocked (`media_info` + `fs`), no disk, no network:

- **Probe parsing** — fixture ffprobe output → `%{audio:, subtitles:}` codes; untagged/`und`
  dropped; error/missing-binary → `{:error, _}`.
- **Sidecar discovery + link + language parse** — a source folder with a video + `Name.en.srt`
  + `Name.fr.forced.srt` → both hardlinked next to the dest, languages `["en","fr"]`, flags
  preserved in the dest filename; a lone `subs.srt` for a single video accepted as `"und"`.
- **Importer stores the fields** — `import_movie` and `import_episodes` persist
  `imported_audio_languages / _embedded_subtitles / _sidecar_subtitles`; the audio park check
  still behaves exactly as before.
- **Backfill** — fills the three fields on an existing `:available` movie + episode from a
  mocked probe/scan; re-run is idempotent.
- **Detail pages** — render audio + subtitle badges with the embedded/sidecar tag; render
  nothing when the lists are empty.

## Touch list

- Migration: 3 columns × `movies`, `episodes`.
- `Cinder.Catalog.{Movie,Episode}` — add fields to `transition_changeset`; new
  `Catalog.set_media_info/2` + a `media_info_changeset`.
- `Cinder.Library.MediaInfo` behaviour + `Ffprobe` impl + Mox mock — `probe/1`.
- `Cinder.Library` — `check_audio` reads `.audio`; the shared sidecar-import helper; thread the
  three lists into the movie + episode quality maps.
- `mix cinder.media_info.backfill`.
- `movie_detail_live`, `series_detail_live` — display.
- Tests as above; gettext extract last.
