#!/usr/bin/env python3
"""Linux root-contained filesystem helper for Cinder subtitle effects."""

import ctypes
import errno
import json
import os
import platform
import posixpath
import sys


LIBC = ctypes.CDLL(None, use_errno=True)
O_PATH = getattr(os, "O_PATH", 0o10000000)
O_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0o00400000)
O_DIRECTORY = getattr(os, "O_DIRECTORY", 0o00200000)
O_CLOEXEC = getattr(os, "O_CLOEXEC", 0o02000000)
RESOLVE_NO_MAGICLINKS = 0x02
RESOLVE_NO_SYMLINKS = 0x04
RESOLVE_BENEATH = 0x08
RENAME_EXCHANGE = 0x02
SYS_OPENAT2 = 437
SYS_RENAMEAT2 = {"x86_64": 316, "amd64": 316, "aarch64": 276, "arm64": 276}.get(
    platform.machine().lower()
)


class OpenHow(ctypes.Structure):
    _fields_ = [("flags", ctypes.c_uint64), ("mode", ctypes.c_uint64), ("resolve", ctypes.c_uint64)]


def emit(value):
    sys.stdout.write(json.dumps(value, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def fail(operation, phase, exc):
    number = (exc.errno or errno.EIO) if isinstance(exc, OSError) else errno.EIO
    emit(
        {
            "error": {
                "operation": operation,
                "phase": phase,
                "errno": number,
                "reason": errno.errorcode.get(number, "UNKNOWN"),
            }
        }
    )


def checked_relative(value):
    if not value or value.startswith("/") or "\x00" in value:
        raise OSError(errno.EINVAL, "invalid relative path")
    normalized = posixpath.normpath(value)
    if normalized == ".." or normalized.startswith("../"):
        raise OSError(errno.EXDEV, "path escapes root")
    return normalized


def open_root(root):
    if not os.path.isabs(root):
        raise OSError(errno.EINVAL, "root must be absolute")
    root_relative = root.lstrip("/") or "."
    slash_fd = os.open("/", O_PATH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    try:
        return open_beneath(
            slash_fd,
            root_relative,
            O_PATH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC,
        )
    finally:
        os.close(slash_fd)


def open_beneath(root_fd, relative, flags, mode=0):
    relative = checked_relative(relative)
    how = OpenHow(
        flags=flags | O_CLOEXEC,
        mode=mode,
        resolve=RESOLVE_BENEATH | RESOLVE_NO_MAGICLINKS | RESOLVE_NO_SYMLINKS,
    )
    result = LIBC.syscall(
        SYS_OPENAT2,
        root_fd,
        ctypes.c_char_p(os.fsencode(relative)),
        ctypes.byref(how),
        ctypes.sizeof(how),
    )
    if result < 0:
        number = ctypes.get_errno()
        raise OSError(number, os.strerror(number))
    return result


def open_parent(root, relative):
    relative = checked_relative(relative)
    parent_name = posixpath.dirname(relative) or "."
    basename = posixpath.basename(relative)
    if basename in ("", ".", ".."):
        raise OSError(errno.EINVAL, "invalid basename")
    root_fd = open_root(root)
    try:
        parent_fd = open_beneath(root_fd, parent_name, os.O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    finally:
        os.close(root_fd)
    return parent_fd, basename


def hold_open(root, relative, mode):
    modes = {
        "read": os.O_RDONLY | O_NOFOLLOW,
        "path": O_PATH | O_NOFOLLOW,
        "create": os.O_RDWR | os.O_CREAT | os.O_EXCL | O_NOFOLLOW,
        "write": os.O_RDWR | os.O_CREAT | os.O_TRUNC | O_NOFOLLOW,
    }
    if mode not in modes:
        raise OSError(errno.EINVAL, "invalid open mode")
    root_fd = open_root(root)
    try:
        fd = open_beneath(root_fd, relative, modes[mode], 0o600 if mode in ("create", "write") else 0)
    finally:
        os.close(root_fd)
    emit({"ok": {"fd": fd}})
    sys.stdin.buffer.read()
    os.close(fd)


def rename_exchange(src_parent, src_name, dst_parent, dst_name):
    if SYS_RENAMEAT2 is None:
        raise OSError(errno.ENOSYS, "unsupported architecture")
    result = LIBC.syscall(
        SYS_RENAMEAT2,
        src_parent,
        ctypes.c_char_p(os.fsencode(src_name)),
        dst_parent,
        ctypes.c_char_p(os.fsencode(dst_name)),
        RENAME_EXCHANGE,
    )
    if result < 0:
        number = ctypes.get_errno()
        raise OSError(number, os.strerror(number))


def sync_parents(*parents):
    seen = set()
    for parent in parents:
        stat = os.fstat(parent)
        identity = (stat.st_dev, stat.st_ino)
        if identity not in seen:
            os.fsync(parent)
            seen.add(identity)


def exchange(args):
    src_parent, src_name = open_parent(args[0], args[1])
    dst_parent, dst_name = open_parent(args[2], args[3])
    try:
        rename_exchange(src_parent, src_name, dst_parent, dst_name)
        try:
            sync_parents(src_parent, dst_parent)
        except OSError as exc:
            fail("exchange", "post_effect", exc)
            return
        emit({"ok": "exchange"})
    finally:
        os.close(src_parent)
        os.close(dst_parent)


def rename(args):
    src_parent, src_name = open_parent(args[0], args[1])
    dst_parent, dst_name = open_parent(args[2], args[3])
    try:
        os.rename(src_name, dst_name, src_dir_fd=src_parent, dst_dir_fd=dst_parent)
        try:
            sync_parents(src_parent, dst_parent)
        except OSError as exc:
            fail("rename", "post_effect", exc)
            return
        emit({"ok": "rename"})
    finally:
        os.close(src_parent)
        os.close(dst_parent)


def unlink(args, directory=False):
    parent, name = open_parent(args[0], args[1])
    operation = "rmdir" if directory else "unlink"
    try:
        if directory:
            os.rmdir(name, dir_fd=parent)
        else:
            os.unlink(name, dir_fd=parent)
        try:
            os.fsync(parent)
        except OSError as exc:
            fail(operation, "post_effect", exc)
            return
        emit({"ok": operation})
    finally:
        os.close(parent)


def mkdir(args):
    parent, name = open_parent(args[0], args[1])
    try:
        old_umask = os.umask(0o077)
        try:
            os.mkdir(name, int(args[2], 8), dir_fd=parent)
        finally:
            os.umask(old_umask)
        try:
            os.fsync(parent)
        except OSError as exc:
            fail("mkdir", "post_effect", exc)
            return
        emit({"ok": "mkdir"})
    finally:
        os.close(parent)


def sync_parent(args):
    parent, _name = open_parent(args[0], args[1])
    try:
        os.fsync(parent)
        emit({"ok": "sync_parent"})
    finally:
        os.close(parent)


def main():
    if len(sys.argv) < 2:
        raise OSError(errno.EINVAL, "missing operation")
    operation = sys.argv[1]
    args = sys.argv[2:]
    if operation == "hold" and len(args) == 3:
        hold_open(*args)
    elif operation == "exchange" and len(args) == 4:
        exchange(args)
    elif operation == "rename" and len(args) == 4:
        rename(args)
    elif operation == "unlink" and len(args) == 2:
        unlink(args)
    elif operation == "rmdir" and len(args) == 2:
        unlink(args, directory=True)
    elif operation == "mkdir" and len(args) == 3:
        mkdir(args)
    elif operation == "sync_parent" and len(args) == 2:
        sync_parent(args)
    else:
        raise OSError(errno.EINVAL, "invalid arguments")


if __name__ == "__main__":
    operation = sys.argv[1] if len(sys.argv) > 1 else "unknown"
    try:
        main()
    except OSError as exc:
        fail(operation, "pre_effect", exc)
        sys.exit(1)
