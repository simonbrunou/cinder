#!/usr/bin/env python3
"""Linux root-contained filesystem helper for Cinder subtitle effects."""

import ctypes
import errno
import json
import os
import platform
import posixpath
import sys
import time

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
MERGERFS_FULLPATH = "user.mergerfs.fullpath"
MERGERFS_BASEPATH = "user.mergerfs.basepath"


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
    if mergerfs_mount(root):
        fd = hold_open_mergerfs(root, relative, modes[mode], mode)
        emit({"ok": {"fd": fd}})
        sys.stdin.buffer.read()
        os.close(fd)
        return

    root_fd = open_root(root)
    try:
        fd = open_beneath(root_fd, relative, modes[mode], 0o600 if mode in ("create", "write") else 0)
    finally:
        os.close(root_fd)
    emit({"ok": {"fd": fd}})
    sys.stdin.buffer.read()
    os.close(fd)


def hold_open_mergerfs(root, relative, flags, mode):
    if mode == "write":
        parent, name = open_parent(root, relative)
        try:
            try:
                basepath, backing_relative = mergerfs_backing_location(parent, name)
            except OSError as exc:
                if exc.errno != errno.ENOENT:
                    raise
                basepath, backing_parent = mergerfs_backing_location_fd(parent)
                backing_relative = posixpath.join(backing_parent, name)
        finally:
            os.close(parent)
    elif mode == "create":
        parent_relative = posixpath.dirname(checked_relative(relative)) or "."
        basename = posixpath.basename(relative)
        root_fd = open_root(root)
        try:
            parent_fd = open_beneath(
                root_fd, parent_relative, os.O_RDONLY | O_DIRECTORY | O_NOFOLLOW
            )
        finally:
            os.close(root_fd)
        try:
            basepath, backing_parent = mergerfs_backing_location_fd(parent_fd)
        finally:
            os.close(parent_fd)
        backing_relative = posixpath.join(backing_parent, basename)
    else:
        parent, name = open_parent(root, relative)
        try:
            basepath, backing_relative = mergerfs_backing_location(parent, name)
        finally:
            os.close(parent)

    root_fd = open_root(basepath)
    try:
        return open_beneath(
            root_fd,
            backing_relative,
            flags,
            0o600 if mode in ("create", "write") else 0,
        )
    finally:
        os.close(root_fd)


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


def mountinfo_unescape(value):
    return (
        value.replace("\\040", " ")
        .replace("\\011", "\t")
        .replace("\\012", "\n")
        .replace("\\134", "\\")
    )


def mergerfs_mount(path):
    path = posixpath.normpath(path)
    match = None
    with open("/proc/self/mountinfo", encoding="utf-8") as mountinfo:
        for line in mountinfo:
            fields = line.split()
            separator = fields.index("-")
            mountpoint = mountinfo_unescape(fields[4])
            if path == mountpoint or path.startswith(mountpoint.rstrip("/") + "/"):
                candidate = (len(mountpoint), fields[separator + 1] == "fuse.mergerfs")
                if match is None or candidate[0] > match[0]:
                    match = candidate
    return match is not None and match[1]


def mergerfs_backing_location(parent, name):
    fd = os.open(name, os.O_RDONLY | O_NOFOLLOW | O_CLOEXEC, dir_fd=parent)
    try:
        return mergerfs_backing_location_fd(fd)
    finally:
        os.close(fd)


def mergerfs_backing_location_fd(fd):
    fullpath = os.fsdecode(os.getxattr(fd, MERGERFS_FULLPATH))
    basepath = os.fsdecode(os.getxattr(fd, MERGERFS_BASEPATH))
    if not posixpath.isabs(fullpath) or not posixpath.isabs(basepath):
        raise OSError(errno.EINVAL, "invalid mergerfs backing path")

    fullpath = posixpath.normpath(fullpath)
    basepath = posixpath.normpath(basepath)
    if posixpath.commonpath((basepath, fullpath)) != basepath:
        raise OSError(errno.EXDEV, "mergerfs backing path escapes branch")

    return basepath, checked_relative(posixpath.relpath(fullpath, basepath))


def exchange_mergerfs(src_parent, src_name, dst_parent, dst_name):
    src_base, src_relative = mergerfs_backing_location(src_parent, src_name)
    dst_base, dst_relative = mergerfs_backing_location(dst_parent, dst_name)
    src_dir = posixpath.dirname(src_relative) or "."
    dst_dir = posixpath.dirname(dst_relative) or "."
    if src_base != dst_base:
        raise OSError(errno.EXDEV, "mergerfs exchange crosses backing filesystems")

    root_fd = open_root(src_base)
    try:
        src_backing_parent = open_beneath(
            root_fd, src_dir, os.O_RDONLY | O_DIRECTORY | O_NOFOLLOW
        )
        dst_backing_parent = open_beneath(
            root_fd, dst_dir, os.O_RDONLY | O_DIRECTORY | O_NOFOLLOW
        )
    finally:
        os.close(root_fd)

    try:
        rename_exchange(
            src_backing_parent,
            posixpath.basename(src_relative),
            dst_backing_parent,
            posixpath.basename(dst_relative),
        )
        try:
            sync_parents(src_backing_parent, dst_backing_parent)
        except OSError as exc:
            fail("exchange", "post_effect", exc)
            return False
    finally:
        os.close(src_backing_parent)
        os.close(dst_backing_parent)

    return True


def mergerfs_near_relative(root, anchor_relative, relative):
    anchor_parent, anchor_name = open_parent(root, anchor_relative)
    try:
        basepath, backing_anchor = mergerfs_backing_location(anchor_parent, anchor_name)
    finally:
        os.close(anchor_parent)

    logical_parts = checked_relative(anchor_relative).split("/")
    backing_parts = checked_relative(backing_anchor).split("/")
    if backing_parts[-len(logical_parts) :] != logical_parts:
        raise OSError(errno.EXDEV, "mergerfs backing path does not match library root")

    prefix = backing_parts[: -len(logical_parts)]
    return basepath, posixpath.join(*prefix, checked_relative(relative))


def wait_for_path(root, relative):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        root_fd = open_root(root)
        try:
            fd = open_beneath(root_fd, relative, O_PATH | O_NOFOLLOW)
        except OSError as exc:
            if exc.errno != errno.ENOENT:
                raise
        else:
            os.close(fd)
            return
        finally:
            os.close(root_fd)
        time.sleep(0.05)
    raise OSError(errno.EIO, "mergerfs path remained stale")


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
        try:
            rename_exchange(src_parent, src_name, dst_parent, dst_name)
        except OSError as exc:
            if (
                exc.errno != errno.EINVAL
                or not mergerfs_mount(args[0])
                or not mergerfs_mount(args[2])
            ):
                raise
            if not exchange_mergerfs(src_parent, src_name, dst_parent, dst_name):
                return
            emit({"ok": "exchange"})
            return
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


def mkdir_near(args):
    if not mergerfs_mount(args[0]):
        mkdir([args[0], args[1], args[3]])
        return

    basepath, backing_relative = mergerfs_near_relative(args[0], args[2], args[1])
    parent_name = posixpath.dirname(backing_relative) or "."
    basename = posixpath.basename(backing_relative)
    root_fd = open_root(basepath)
    try:
        parent = open_beneath(
            root_fd, parent_name, os.O_RDONLY | O_DIRECTORY | O_NOFOLLOW
        )
    finally:
        os.close(root_fd)

    try:
        old_umask = os.umask(0o077)
        try:
            os.mkdir(basename, int(args[3], 8), dir_fd=parent)
        finally:
            os.umask(old_umask)
        try:
            sync_parents(parent)
            wait_for_path(args[0], args[1])
        except OSError as exc:
            fail("mkdir_near", "post_effect", exc)
            return
        emit({"ok": "mkdir_near"})
    finally:
        os.close(parent)


def chmod(args):
    root_fd = open_root(args[0])
    try:
        fd = open_beneath(root_fd, args[1], os.O_RDONLY | O_NOFOLLOW)
    finally:
        os.close(root_fd)
    try:
        os.fchmod(fd, int(args[2], 8))
        emit({"ok": "chmod"})
    finally:
        os.close(fd)


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
    elif operation == "mkdir_near" and len(args) == 4:
        mkdir_near(args)
    elif operation == "chmod" and len(args) == 3:
        chmod(args)
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
