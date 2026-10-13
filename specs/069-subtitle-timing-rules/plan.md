# Implementation Plan: Subtitle timing to the Netflix timing rules

**Spec**: `spec.md`. **Operator decision (2026-10-13)**: options A, B and C, shipped as three
stacked PRs in that order.

## PR A: timing-rule pass and two defects

- **Frame rate.** `Cinder.Library.MediaInfo.frame_rate/1` (new callback): `Ffprobe` reads
  `avg_frame_rate` (falling back to `r_frame_rate`) of the first video stream that is not cover
  art, bounded like `probe/1`. If it is unknown, the pass uses 24000/1001.
- **`Cinder.Subtitles.Sync.TimingRules.apply/3`.** A pure function over `.srt`/`.vtt` bytes.
  - Lines are taken in in-time order. When the gap to the next line is under half a second, the
    out-time moves to 2 frames before the next in-time. This closes small gaps and opens overlaps.
  - A line shorter than 20 frames is extended into the gap that follows, as far as 2 frames
    before the next line.
  - In-times never move. A change that would leave a line shorter than 20 frames is skipped.
  - Other formats (`.ass`, `.ssa`, `.sub`) come back unchanged: styled tracks overlap events on
    purpose.
  - Built on two new `Timing` primitives, `cue_times/2` and `put_cue_times/3`, which read and
    rewrite the cue rows `Timing.retime/4` already recognises.
- **Hook.** `Sync.apply_engine_output/6` runs the pass after `Timing.validate`.
  - The base is the engine's output, or the untouched source when the engine's correction is
    insignificant (±100 ms, rate within 0.0005).
  - `apply_verified_engine_output` then compares the final bytes with the source: unchanged
    bytes are `aligned`, changed bytes are `corrected`. Before this change an insignificant
    correction short-circuited to `aligned`, which would have silently discarded the pass.
- **Runner.**
  - A line shifted before 0:00 starts at 0:00 instead of being dropped by `srt`'s writer.
  - Segment metrics are logged in time order.
- **Re-sync.** `@sync_version` 6, so every automatic correction is redone.

## PR B: shot changes

- **Detection.** `MediaInfo.shot_changes/1` (new callback) runs ffmpeg `scdet` (threshold 10,
  scaled to 320 px, fast decode) and returns cut times in ms. It is bounded at 90 minutes.
- **Cache.** The `subtitle_shot_changes` table stores `moviehash` (unique) and the `times`. It is
  owned and written by `Cinder.Subtitles.ShotChanges` (subsystem table, like `import_stages`).
- **Rules** (in `TimingRules`), with `half` = half a second in frames:
  - **In-time, cut just before.** If the in-time is within `half` after a cut, it moves to the cut.
  - **In-time, cut just after.** If a cut falls within `half` after the in-time:
    - at least ¾·`half` before the cut, the in-time moves to `half` before the cut;
    - otherwise it moves to the cut.
  - **Out-time, cut just after.** If the out-time ends within `half` before a cut and no line
    starts before that cut, the out-time extends to 2 frames before the cut.
  - **Out-time, crossing a cut.** If the out-time crosses a cut by less than `half`, it moves to
    2 frames before the cut, provided the line keeps 20 frames and stays at or under 17
    characters per second. Otherwise it moves to `half` after the cut.
  - The gap and minimum-duration rules run after the cut rules.
- **When detection runs.** Detection costs about 7 CPU-minutes per 45-minute episode on prod.
  - It runs for units from a fresh download and from explicit `/subtitle-sync` requests.
  - Routine library scans use the cache only, so there is no silent multi-week backfill.
  - A video synced without cuts is redone when an explicit request finds the cache filled.
  - `sync.shot_changes` records whether cuts were applied.

## PR C: the video's own track

- **Track details.** `subtitle_tracks/1` also reports `hearing_impaired?`: the disposition flag,
  or a title naming SDH/CC/HI.
- **Fetch order.** Before searching OpenSubtitles, `Cinder.Subtitles` looks for an own track
  (`Cinder.Subtitles.OwnTrack`):
  - exact language, not forced, a text codec, at least 200 cues;
  - a track not for the hearing impaired is preferred, then the one with the most cues.
  - The track is extracted and committed with the new origin `own_track`.
  - It replaces a managed sidecar unless that one was retimed by hand. Unmanaged files are never
    touched. A hash-matched OpenSubtitles sidecar is already stable and is not revisited.
  - The older `embedded` origin stays the last-resort fallback when OpenSubtitles has nothing.
- **Cost bounds.** Listing tracks and extracting one each read the whole file (45–135 s on prod).
  - Tracks are listed only when the import probe saw a stream in that language
    (`imported_embedded_subtitles`, passed in the search criteria).
  - The list is kept per moviehash (`subtitle_track_probes` table, `Cinder.Subtitles.TrackProbe`).
  - `own_track` is stable for its moviehash, so it is never extracted again.
  - A library sweep spends at most 6 hours per run on new own-track work, then carries on with
    OpenSubtitles alone.
- **Timing rules for own tracks.** `own_track` sidecars join sync with the method `native`:
  - There is no engine run and no reference extraction, only the timing-rule pass (with cuts
    when cached).
  - They get the same backup, journal and reset guarantees as other automatic corrections.
  - One found at import is queued like a fresh download, which detects cuts. One found by a
    sweep is queued in the background with cached cuts only, so the library rollout does not
    trigger weeks of shot detection.

## Verification

- **Benchmark.** Lucifer S1–S3, Castle S1 and Stranger Things S1 (local copies plus prod
  rpc/container runs): compliance before and after, in-times unchanged by PR A.
- **Prod.** After each deploy, a prod smoke on one episode.
- **Tests.** `mix test` green for every PR.
