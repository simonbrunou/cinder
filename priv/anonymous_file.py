#!/usr/bin/env python3
import errno
import fcntl
import json
import os
import sys


def emit(payload):
    sys.stdout.write(json.dumps(payload, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def hold():
    fd = os.memfd_create(
        "cinder-subtitle-engine",
        flags=os.MFD_CLOEXEC | os.MFD_ALLOW_SEALING,
    )
    try:
        emit({"ok": {"fd": fd}})
        sys.stdin.buffer.read()
    finally:
        os.close(fd)


def seal(path):
    fd = os.open(path, os.O_RDWR | os.O_CLOEXEC)
    try:
        fcntl.fcntl(
            fd,
            fcntl.F_ADD_SEALS,
            fcntl.F_SEAL_WRITE
            | fcntl.F_SEAL_GROW
            | fcntl.F_SEAL_SHRINK
            | fcntl.F_SEAL_SEAL,
        )
        os.fsync(fd)
        emit({"ok": "sealed"})
    finally:
        os.close(fd)


def main():
    if sys.argv[1:] == ["hold"]:
        hold()
    elif len(sys.argv) == 3 and sys.argv[1] == "seal":
        seal(sys.argv[2])
    else:
        raise OSError(errno.EINVAL, "invalid anonymous-file operation")


try:
    main()
except OSError as exc:
    error_number = exc.errno if exc.errno is not None else errno.EIO
    emit({"error": {"reason": errno.errorcode.get(error_number, "EIO")}})
    raise SystemExit(1)
