#!/usr/bin/env python3
# pyright: reportMissingImports=false
import argparse
import json
import logging
import os
import sys

from ffsubsync import ffsubsync, generic_subtitles

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
