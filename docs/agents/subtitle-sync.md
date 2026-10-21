# Subtitle sync: measuring a change

Read this before changing `Cinder.Subtitles.Sync`, its engine (`Cinder.Subtitles.Sync.Ffsubsync`,
`priv/ffsubsync_runner.py`) or its timing rules (`Cinder.Subtitles.Sync.TimingRules`). `mix test`
proves the code does what it says; it cannot prove the subtitles got better. Show that with
numbers, before and after, on a real corpus.

## Local engine

- The dev shell's `python3` imports ffsubsync 0.5.1, the version the Dockerfile pins, so the
  runner needs no venv: `nix develop -c python3 priv/ffsubsync_runner.py ...`.
- Pass exactly the flags `Cinder.Subtitles.Sync.Ffsubsync` builds (`sync/5` and `arguments/2`):
  `--cinder-input-format srt --cinder-reference-format <ext> --cinder-output-format srt --cinder-metrics-token TOKEN <reference> -i <input> -o <output> --skip-sync-on-low-quality --min-score 10 --quality-max-offset-seconds 90 --max-offset-seconds 90 --split-penalty 5 --max-framerate-deviation 0.26 --output-encoding same`.
  The metrics come back on one stdout line that starts with the token.
- The dev shell's numpy is not the image's. Compare a few local outputs with the ones the
  running app wrote before you trust local numbers.
- A video reference uses ffsubsync's default `subs_then_webrtc`: it reads the video's embedded
  text track when there is one, so a sync recorded as method "audio" is real audio only for a
  video without one. `--vad webrtc` forces real audio; it needs the video file.

## Corpus and ground truth

- **Sidecars.** The downloaded originals sit next to the synced files as
  `.<sidecar name>.cinder-sync-original` (`Cinder.Subtitles.SidecarTransaction.Backup`). They
  are mode 0600 and owned by the app user: read them as that user. As root, `tar` exits with
  "Permission denied" and leaves a partial archive. Check the file counts before you measure.
- **Truth.** The video's own text track in the sidecar's language:
  `ffmpeg -v error -i <video> -map 0:s:m:language:eng -f srt <truth>.srt`, falling back to
  `-map 0:s:0`. Extracting a track reads the whole file.
- **Pick series that test different things:**
  - one whose only own track is English SDH while the downloaded sidecars were timed to another
    cut: these need splits;
  - one with two official English tracks (for example British and SDH) plus French: align to one
    English track and score against the other for an independent truth, and score French against
    English to test cross-language alignment;
  - one whose sidecars are copies of the embedded track: it only catches regressions.
- **Match cues by text, never by index:** ffsubsync re-sorts its output by start time. A cue gets
  a true in-time only when its first two words open a truth cue (difflib word alignment with
  `autojunk=False`, monotone). Skip cues whose first words fall mid-cue.
- **Score the same cue set** before and after: the cues both versions placed. Report the episode
  count and the cue count.

## Metrics

- **Stacking:** in output order, a cue that starts more than 200 ms before the previous cue ends,
  when the two did not overlap in the original.
- **In-time error against truth:** the share within 2 frames, 250 ms, 500 ms, 1 s and 3 s; the
  median; p90; and the count more than 10 s off.
- **Ceiling:** two official tracks of the same episodes disagreed by a median of 167 ms, and only
  27% of their in-times agreed within 2 frames. Nothing scored against subtitle truth can show a
  gain below that, so do not chase frame-level in-times with subtitle truth.
- **Netflix structure** (the rules `TimingRules` applies): the share of gaps of 3 to 11 frames,
  of gaps under 2 frames, and of lines under 20 frames. Netflix's own files score about 0.7%, 0%
  and 0%.
- **Cuts:** the share of in-times and out-times within half a second of a detected cut. Official
  tracks also score about 36% here, so this mostly measures the cut detector. Validate the
  detector before trusting it.
- **Removed lines:** for every line missing from the output, check whether it has a truth onset.
  If it does, the line is in the video and removing it was wrong. An earlier sync version dropped
  "Previously on..." lines because the `srt` library drops cues with a negative start.

## Replaying the split search

The runner's `install_order_preserving_split()` replaces the engine's
`ffsubsync.ffsubsync.compute_split_offsets` with `order_preserving_split_offsets`. To compare
variants of that search without re-running the engine, load the runner through `importlib` and
wrap the function it installs with a capture function, after `install_order_preserving_split()`
ran: a wrapper set before it gets overwritten. Pickle the reference (`np.packbits`) and each
candidate's cues and keyword arguments, then replay the variants offline. Equivalence check: with
the order constraint disabled, the replacement must return the offsets and score of upstream's
`split_aligner.compute_split_offsets` exactly.

## Pitfalls

- A filtered pipeline (`mix test | grep`) that prints nothing is not a pass. Look for the
  `Result:` line.
- Edit a scratch script by rewriting the whole file, or re-read the lines right before the edit.
  A stale line edit can break the matching and silently drop episodes from the results.
- Compare the episode count with the previous run's. A drop, for example from 55 to 39, means a
  script bug, not a result.
