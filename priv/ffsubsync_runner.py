#!/usr/bin/env python3
# pyright: reportMissingImports=false
import argparse
import json
import logging
import os
import re
import sys

import numpy as np
from ffsubsync import ffsubsync, generic_subtitles, speech_transformers, split_aligner

# Message templates (not rendered messages) of the ffsubsync 0.5.1 log records that carry the
# metrics `run()` does not return. Matching the template, and only for ffsubsync's own loggers,
# is what makes these unforgeable: the same stream also carries subtitle bytes verbatim — the
# `srt` parser logs an unparseable block, and a traceback can embed one — so a downloaded
# sidecar must never be able to contribute a metric. If a future engine reworded these, the
# metrics go missing and the caller reports the analysis unparseable rather than trusting a
# guess.
SCORE_TEMPLATE = "score:"
OFFSET_TEMPLATE = "offset seconds:"
RATE_TEMPLATE = "framerate scale factor:"
SEGMENT_TEMPLATE = "cue(s) offset"
LOW_QUALITY_TEMPLATE = "low-quality alignment"


class MetricsCollector(logging.Handler):
    """Collects the metrics `run()` does not return, and those it withholds when it refuses.

    `run()` reports the offset and framerate scale it *applied*, and reports neither when the
    alignment was rejected as low quality — it returns before recording them. The candidate
    values are logged before that check, so collecting them here keeps a rejected alignment
    describable (a review row carrying the score, offset and rate the engine refused) instead of
    indistinguishable from an unreadable one.
    """

    def __init__(self):
        super().__init__(level=logging.INFO)
        self.score = None
        self.offset_seconds = None
        self.framerate_scale_factor = None
        self.segment_offsets_seconds = []
        self.low_quality_reasons = []

    def emit(self, record):
        if not record.name.startswith("ffsubsync."):
            return
        template = record.msg if isinstance(record.msg, str) else ""
        args = record.args if isinstance(record.args, tuple) else ()
        try:
            if template.startswith(SCORE_TEMPLATE):
                self.score = float(args[0])
            elif template.startswith(OFFSET_TEMPLATE):
                self.offset_seconds = float(args[0])
            elif template.startswith(RATE_TEMPLATE):
                self.framerate_scale_factor = float(args[0])
            elif SEGMENT_TEMPLATE in template:
                self.segment_offsets_seconds.append(float(args[1]))
            elif template.startswith(LOW_QUALITY_TEMPLATE):
                self.low_quality_reasons = [str(args[0])]
        except (IndexError, TypeError, ValueError):
            return


def install_input_format(format_name):
    def get_srt_pipe_maker(args, _srtin):
        parser = ffsubsync.make_subtitle_parser(
            fmt=format_name,
            caching=True,
            **args.__dict__,
        )
        return lambda scale_factor: ffsubsync.make_subtitle_speech_pipeline(
            **ffsubsync.override(
                args,
                scale_factor=scale_factor,
                parser=parser,
            )
        )

    ffsubsync.get_srt_pipe_maker = get_srt_pipe_maker


def install_reference_format(format_name):
    if format_name:
        ffsubsync._ref_format = lambda _path: format_name


def install_output_format(format_name):
    original_write_file = generic_subtitles.GenericSubtitlesFile.write_file

    def write_file(subtitles, path):
        if not path or os.path.splitext(path)[1]:
            return original_write_file(subtitles, path)

        original_splitext = os.path.splitext
        os.path.splitext = lambda value: (
            (value, "." + format_name)
            if value == path
            else original_splitext(value)
        )
        try:
            return original_write_file(subtitles, path)
        finally:
            os.path.splitext = original_splitext

    generic_subtitles.GenericSubtitlesFile.write_file = write_file


def order_preserving_split_offsets(
    reference,
    cues,
    *,
    sample_rate,
    start_seconds,
    split_penalty,
    max_offset_samples,
    length_penalty=0.0,
    offset_step_samples=1.0,
    return_score=False,
    log_segments=True,
):
    """`split_aligner.compute_split_offsets`, constrained so cues never overlap or reorder.

    The engine's piecewise search lets any cue take any offset for the price of a split, so a
    run of cues can jump onto speech that other cues already cover: a cold open moved 20s late
    over its own scene, a "previously on" recap stacked on the theme song, a credit line dropped
    onto dialogue. Each leaves two lines on screen at once and then nothing where the moved lines
    belonged. Here a split may move a cue earlier relative to the cues before it by at most the
    silence in front of it; moving later (inserted content) stays free. A cut that removed
    dialogue, not just a pause, therefore shows the next lines late until a later pause absorbs
    the shift, instead of stacking them on the lines before it. The constraint reads cues in
    start order: a file may list some out of order (signs or songs appended after the dialogue in
    an SRT converted from ASS), so the search runs on start-sorted cues and reports offsets in
    file order. The rating and the backtrack are the engine's own, unchanged.
    """
    n = len(cues)
    if n == 0:
        return ([], 0.0) if return_score else []

    starts, ends, is_speech = split_aligner._cue_sample_bounds(cues, sample_rate, start_seconds)
    order = np.argsort(starts, kind="stable")
    starts, ends, is_speech = starts[order], ends[order], is_speech[order]
    guards = np.minimum(ends - starts, float(split_aligner._MAX_GUARD_SAMPLES))

    step = float(offset_step_samples)
    if step <= 0:
        step = 1.0
    n_off = int(round(2 * max_offset_samples / step)) + 1
    offsets = -float(max_offset_samples) + step * np.arange(n_off)
    indices = np.arange(n_off)

    ref = (np.asarray(reference, dtype=np.float64) > 0).astype(np.float64)
    cumsum = np.concatenate([np.zeros(1), np.cumsum(ref)])
    pad = max_offset_samples + split_aligner._MAX_GUARD_SAMPLES + 2
    padded = np.concatenate([np.zeros(pad), cumsum, np.full(pad, cumsum[-1])])
    max_pos = len(padded) - 1

    def interp(pos):
        pos = np.clip(pos, 0.0, float(max_pos))
        lo = np.floor(pos).astype(np.int64)
        np.clip(lo, 0, max_pos - 1, out=lo)
        frac = pos - lo
        return padded[lo] * (1.0 - frac) + padded[lo + 1] * frac

    def rating_row(i):
        if not is_speech[i]:
            return np.zeros(n_off)
        start_pos = starts[i] + offsets + pad
        end_pos = ends[i] + offsets + pad
        cs = interp(start_pos)
        ce = interp(end_pos)
        overlap = ce - cs
        if length_penalty and guards[i] > 0:
            gl = cs - interp(start_pos - guards[i])
            gr = interp(end_pos + guards[i]) - ce
            return overlap - length_penalty * (gl + gr)
        return overlap

    # dp[o] = best total rating for cues[0..i] with cue i at offsets[o]. Cue i may follow a
    # predecessor at offsets[p] by jumping only when p <= o + slack: the predecessor's best
    # placement among those is a running maximum over the ascending offset grid. Ties resolve to
    # the lowest offset, as the engine's `np.argmax` does.
    dp = rating_row(0)
    back = np.full((n, n_off), -1, dtype=np.int32)
    covered_until = ends[0]
    for i in range(1, n):
        slack = int(np.floor(max(starts[i] - covered_until, 0.0) / step))
        covered_until = max(covered_until, ends[i])
        best = np.maximum.accumulate(dp)
        rises = dp > np.concatenate(([-np.inf], best[:-1]))
        best_idx = np.maximum.accumulate(np.where(rises, indices, 0))
        reachable = np.minimum(indices + slack, n_off - 1)
        jump_value = best[reachable] - split_penalty
        jumped = jump_value > dp
        back[i] = np.where(jumped, best_idx[reachable], -1)
        dp = rating_row(i) + np.where(jumped, jump_value, dp)

    best_total = float(dp.max())

    offset_idx = np.empty(n, dtype=np.int64)
    cur = int(np.argmax(dp))
    for i in range(n - 1, -1, -1):
        offset_idx[i] = cur
        if i > 0:
            b = int(back[i, cur])
            cur = b if b >= 0 else cur

    file_order = np.empty(n, dtype=np.float64)
    file_order[order] = offsets[offset_idx]
    result = file_order.tolist()
    if log_segments:
        split_aligner.log_split_segments(result, sample_rate)
    if return_score:
        return result, best_total
    return result


def install_order_preserving_split():
    ffsubsync.compute_split_offsets = order_preserving_split_offsets


# ASS override blocks (`{\an8}`, `{\i1}`): positioning and styling, never speech. SDH tracks put
# them in front of cues, which hides a bracketed sound cue (`{\an8}[music]`) from the engine.
_ASS_OVERRIDE = re.compile(r"\{\\[^}]*\}")
_LINE_BREAK = re.compile(r"\\[Nn]|\r?\n")
_engine_is_metadata = speech_transformers._is_metadata


def _non_dialogue_line(line):
    line = speech_transformers._MARKUP_TAG.sub("", line).strip()
    if not any(ch.isalnum() for ch in line):
        return True
    if any(ch in speech_transformers._NON_DIALOGUE_SYMBOLS for ch in line):
        return True
    closer = speech_transformers._PAIRED_NESTER.get(line[0])
    return closer is not None and line[-1] == closer


def is_metadata(content, is_beginning_or_end):
    """The engine's non-speech test, plus song lyrics and placeholder lines.

    The engine counts a cue as speech unless all of it is bracketed or made of music symbols, so
    a sung line ("♪ I got bills to pay ♪") and a placeholder ("_") count as dialogue. An SDH
    reference that subtitles a song wall to wall then reads as continuous speech, and dialogue
    overlaps it about equally well wherever it is placed: Lucifer S01E01's cold open landed
    16-20 s late on its own theme song. A cue is non-speech here when every line of it is
    non-dialogue: no letter or digit, a music symbol anywhere, or wholly bracketed.
    """
    content = _ASS_OVERRIDE.sub("", content)
    if _engine_is_metadata(content, is_beginning_or_end):
        return True
    return all(_non_dialogue_line(line) for line in _LINE_BREAK.split(content))


def _use_metadata_check(check):
    speech_transformers._is_metadata = check
    split_aligner._is_metadata = check


def install_lyric_filter():
    """Treat song lyrics as non-speech whenever the reference is a subtitle track.

    Subtitle tracks disagree about songs: an SDH track subtitles every lyric, a regular one
    subtitles none, so a lyric line on either side is timing with no counterpart on the other.
    Audio is different: the voice detector hears singing, so a sidecar's lyric lines are real
    anchors there and stay speech. The reference is fitted first (a video reference reads its
    embedded subtitle track when it has one, and only then falls back to the audio); the filter
    stays on for the sidecar and the piecewise search only if that fit never used the audio.

    When either side is nothing but lyrics (a sung-through musical, a songs-only track), the
    filter would leave it no speech at all: the engine then scores silence against silence,
    accepts the result and moves every line to the edge of the search window. That run uses the
    engine's own check on both sides instead, refitting the reference if it was already read.
    """
    state = {"heard_audio": False, "reference_fit": None}
    fit_using_audio = speech_transformers.VideoSpeechTransformer._fit_using_audio

    def fit_using_audio_marked(self, fname):
        state["heard_audio"] = True
        return fit_using_audio(self, fname)

    def use_engine_check():
        _use_metadata_check(_engine_is_metadata)
        fit, fit_args, fit_kwargs = state["reference_fit"]
        fit(*fit_args, **fit_kwargs)

    speech_transformers.VideoSpeechTransformer._fit_using_audio = fit_using_audio_marked
    make_reference_pipe = ffsubsync.make_reference_pipe

    def make_reference_pipe_without_lyrics(*args, **kwargs):
        pipe = make_reference_pipe(*args, **kwargs)
        fit = pipe.fit

        def fit_without_lyrics(*fit_args, **fit_kwargs):
            _use_metadata_check(is_metadata)
            try:
                fit(*fit_args, **fit_kwargs)
            finally:
                if state["heard_audio"]:
                    _use_metadata_check(_engine_is_metadata)
            if not state["heard_audio"]:
                state["reference_fit"] = (fit, fit_args, fit_kwargs)
                if not np.any(pipe.transform(*fit_args) > 0):
                    use_engine_check()
            return pipe

        pipe.fit = fit_without_lyrics
        return pipe

    ffsubsync.make_reference_pipe = make_reference_pipe_without_lyrics
    get_srt_pipe_maker = ffsubsync.get_srt_pipe_maker

    # The sidecar is parsed once here; the parser caches it for every pipeline built after.
    def get_srt_pipe_maker_checked(args, srtin):
        maker = get_srt_pipe_maker(args, srtin)
        if speech_transformers._is_metadata is is_metadata:
            subs = maker(1.0).named_steps["parse"].fit(srtin).subs_
            last = len(subs) - 1
            if all(is_metadata(sub.content, i in (0, last)) for i, sub in enumerate(subs)):
                use_engine_check()
        return maker

    ffsubsync.get_srt_pipe_maker = get_srt_pipe_maker_checked


def report(token, result, collector):
    """Emit one metrics line, prefixed with the caller's per-run token.

    The token is random per invocation, so nothing the engine echoes from a subtitle file can
    forge this line. The offset and framerate scale come from `run()`'s own return value, which
    reports what was *applied* (in piecewise mode, the median segment offset and the scale the
    split search settled on), and fall back to the logged candidate values for a run that was
    rejected before recording them.
    """
    sys.stdout.write(
        "%s %s\n"
        % (
            token,
            json.dumps(
                {
                    "sync_was_successful": bool(result.get("sync_was_successful")),
                    "score": collector.score,
                    "offset_seconds": _applied(
                        result.get("offset_seconds"), collector.offset_seconds
                    ),
                    "framerate_scale_factor": _applied(
                        result.get("framerate_scale_factor"),
                        collector.framerate_scale_factor,
                    ),
                    "segment_offsets_seconds": collector.segment_offsets_seconds,
                    "low_quality_reasons": collector.low_quality_reasons,
                }
            ),
        )
    )
    sys.stdout.flush()


def _applied(applied, candidate):
    return candidate if applied is None else applied


def main():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--cinder-input-format", required=True)
    parser.add_argument("--cinder-reference-format", default="")
    parser.add_argument("--cinder-output-format", required=True)
    parser.add_argument("--cinder-metrics-token", required=True)
    options, remaining = parser.parse_known_args()

    install_input_format(options.cinder_input_format)
    install_reference_format(options.cinder_reference_format)
    install_output_format(options.cinder_output_format)
    install_order_preserving_split()
    install_lyric_filter()
    sys.argv = [sys.argv[0], *remaining]

    collector = MetricsCollector()
    logging.getLogger().addHandler(collector)
    try:
        result = ffsubsync.run(ffsubsync.make_parser())
    finally:
        logging.getLogger().removeHandler(collector)

    report(options.cinder_metrics_token, result, collector)
    return result["retval"]


if __name__ == "__main__":
    raise SystemExit(main())
