#!/usr/bin/env python3
# pyright: reportMissingImports=false
import argparse
import sys

from ffsubsync import ffsubsync


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


def main():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--cinder-input-format", required=True)
    parser.add_argument("--cinder-reference-format", default="")
    options, remaining = parser.parse_known_args()

    install_input_format(options.cinder_input_format)
    install_reference_format(options.cinder_reference_format)
    sys.argv = [sys.argv[0], *remaining]
    return ffsubsync.run(ffsubsync.make_parser())["retval"]


if __name__ == "__main__":
    raise SystemExit(main())
