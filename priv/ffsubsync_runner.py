#!/usr/bin/env python3
# pyright: reportMissingImports=false
import argparse
import os
import sys

from ffsubsync import ffsubsync, generic_subtitles


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


def main():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--cinder-input-format", required=True)
    parser.add_argument("--cinder-reference-format", default="")
    parser.add_argument("--cinder-output-format", required=True)
    options, remaining = parser.parse_known_args()

    install_input_format(options.cinder_input_format)
    install_reference_format(options.cinder_reference_format)
    install_output_format(options.cinder_output_format)
    sys.argv = [sys.argv[0], *remaining]
    return ffsubsync.run(ffsubsync.make_parser())["retval"]


if __name__ == "__main__":
    raise SystemExit(main())
