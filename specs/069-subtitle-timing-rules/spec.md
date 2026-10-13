# Feature Specification: Subtitle timing to the Netflix timing rules

**Feature Branch**: `069-subtitle-timing-rules`

**Status**: Agreed 2026-10-13: the operator chose A, B and C. See `plan.md`.

**Scope choice for B**: the backfill was left open. New downloads and explicit `/subtitle-sync`
requests detect shot changes. Routine library scans use cached cuts only, which avoids an unasked
3-week CPU backfill. Any title can be backfilled by syncing it from `/subtitle-sync`.

## Problem

After #711 and #712, Cinder's automatic alignment puts a downloaded sidecar's lines in order and
close to the video, but the result is not what a professional subtitle file looks like. The operator
asked for "perfect" subtitles, measured against the Netflix
[Timed Text Style Guide: Subtitle Timing Guidelines](https://partnerhelp.netflixstudios.com/hc/en-us/articles/360051554394-Timed-Text-Style-Guide-Subtitle-Timing-Guidelines).
Those rules are:

1. **In-time on the first frame of audio** (1–2 frames of tolerance).
2. **Shot changes**: within half a second of a shot change, an in-time or out-time moves to it
   (out-times stop 2 frames before it).
3. **Minimum duration**: 20 frames.
4. **Gaps**: at least 2 frames between lines, and a gap under half a second is closed to 2 frames
   ("chaining").
5. **Out-time** about half a second after the audio ends when no line follows.

The operator also pointed at one visible defect left after #711. In S01E01 of Lucifer the WEB cut
drops some dialogue that the downloaded file still has, so about 20 lines after that point show
late until the next long pause.

## Measurements (2026-10-13)

The ground truth is the video's own subtitle track in the sidecar's language. A sidecar line is
scored only when its first two words open a line of that track, so its true in-time is exact.

- **Lucifer S1–S3.** English sidecars against the WEB track, 55 episodes.
- **Castle S1.** Two independent official English tracks (British, US SDH) and a French track.
  This gives an independent truth: align the English sidecar to the SDH track and score it against
  the British one, or align the French sidecar to the English track and score it against the French
  one.
- **Stranger Things S1.** Netflix official tracks. Its OpenSubtitles files are copies of them, so
  it only checks for regressions.

### In-time accuracy

| Comparison | median | p90 | within 2 frames | within 500 ms | within 1 s |
|---|---|---|---|---|---|
| Castle: British track vs SDH track, both official | 167 ms | 375 ms | 27% | 97% | 99.6% |
| Lucifer en, shipped v5 | 173 ms | 630 ms | 28% | 85% | 97% |
| Castle en, shipped v5 (independent truth) | 191 ms | 530 ms | 24% | 89% | 98% |
| Castle fr against the en track, shipped v5 | 91 ms | 403 ms | 46% | 93% | 97% |

Two official tracks of the same video disagree by a median of 167 ms, and only 27% of their lines
start within 2 frames of each other. Below that level an official track cannot measure "on the
first frame of audio": it would take hand-timed ground truth. Shipped v5 is already at about the
level of two official tracks, apart from its tail (p90 530–630 ms against 375 ms).

Per-line refinements tried on top of v5, scored the same way:

- **Snapping in-times to the reference track's line starts.**
  - Castle en: p90 530 → 458 ms, but the median went from 191 to 209 ms and lines within 2 frames
    from 24% to 19%.
  - Castle fr: lines within 250 ms 82% → 89%, p90 403 → 291 ms.
- **Snapping in-times to voice-detector onsets** (webrtc, the same detector the engine uses for
  audio): worse everywhere. Lucifer S1 median 133 → 233 ms, Castle en 190 → 333 ms, Castle fr
  90 → 177 ms.
- **Same-language text anchoring** (a line takes the in-time of the reference line it matches):
  - Castle en: lines within 500 ms 89% → 94% and p90 521 → 418 ms, but 0.8% of lines landed more
    than 3 s off.
  - Removing unmatched lines that had no room left removed 51 lines on Lucifer. 23 of them have a
    similar line in the video's track: the track stores some two-line cues with their lines swapped,
    which breaks the word alignment.
  - It did not remove the S01E01 cut lines it was meant to.
- **Letting the piecewise search hide lines** so a backward jump can use their time (a penalty per
  hidden line of 75 to 300): no change in any metric. The cut lines were never hidden, because a
  dense reference rates every placement about the same.

### Timing rules (structure)

Share of gaps or lines that break rules 3 and 4:

| Files | gaps of 3–11 frames | gaps under 2 frames | lines under 20 frames |
|---|---|---|---|
| Netflix official en (Stranger Things) | 0.7% | 0.0% | 0.0% |
| Lucifer official WEB en | 13.3% | 32.0% | 0.1% |
| Castle official British en | 11.4% | 0.1% | 0.0% |
| All aligned benchmark sidecars, v5 | 8.4% | 49.4% | 0.8% |
| Same, after the out-time pass below | 0.0% | 0.1% | 0.7% |

The out-time pass only moves out-times:

- A gap under half a second becomes exactly 2 frames.
- A gap under 2 frames, or an overlap, opens to 2 frames.
- A line shorter than 20 frames grows into the following gap where there is room.

### Cost of shot detection on prod (CT 121, 2 cores)

ffmpeg `scdet` on 300 s of a 1080p h264 episode took 51 s of wall time (fast decode, scaled to
320 px) and found 111 shot changes. That is about 7 minutes per 45-minute episode. For the roughly
4,300 videos in the library, a one-time backfill would take about 500 hours, roughly 3 weeks of
both cores [estimate: assumes an average length of 45 minutes].

### Defects found along the way

- **The first line is lost when its shift pushes it before 0:00.** The engine's SRT writer
  (`srt.sort_and_reindex`) silently drops any line with a negative start. 16 of 55 Lucifer
  episodes lose "Previously on Lucifer…", which the video does contain.
- **Segment metrics follow file order.** `log_split_segments` groups offsets in file order, so a
  sidecar that lists lines out of order reports more segments than it has. This affects only the
  `segments` count shown in `/subtitle-sync`.

## Options

**A. Timing-rule pass plus the two defects** (recommended)
- Apply the out-time pass to every automatic correction (rules 3 and 4). Rule 5 needs the time
  the audio ends, which Cinder does not measure, so it is not applied.
- Clamp a line shifted before 0:00 to start at 0 instead of dropping it.
- Report segments in time order.
- In-times do not change. The pass needs the video's frame rate, from ffprobe.
- One re-sync of the library (sync metadata version 6).

**B. A, plus shot changes (rule 2)**
- Detect shot changes once per video, cache them by moviehash, and move in-times and out-times to
  them within half a second.
- Costs about 7 CPU-minutes per new episode. The library backfill is either about 3 weeks of
  background CPU or new imports only.

**C. A, plus prefer the video's own track**
- When the video has a full text track in the wanted language, use that track instead of a
  downloaded one: official timing, and exactly the video's cut.
- It fixes the S01E01 kind of cut defect for every same-language case. In this library 64% of
  managed sidecars have such a track: 2,614 of 4,090 align with method `embedded`.
- It does not help French on Lucifer, which has no French track.
- It changes what players show: SDH tracks carry sound cues, and some tracks use British spelling.

**Not proposed.** Per-line in-time snapping, text anchoring, and hiding lines. None of them beat
v5 reliably against an independent official track, and the line-removal variants removed dialogue
that is in the video.

## Non-goals

- Re-segmenting or merging lines (rule 6, "borrowing time"), or editing text for reading speed.
- Forced narratives (rule 7).
- Frame-accurate in-times for audio-only videos. That needs speech recognition, which is not in
  the image.

## Done when

The operator picks a scope. For each chosen option:

- The measured compliance on the Lucifer, Castle and Stranger Things benchmark is reproduced on
  prod output.
- `mix test` is green.
