#!/usr/bin/env python3
"""Linux root-contained filesystem helper for Cinder subtitle effects."""

import ctypes
import errno
import json
import os
import platform
import posixpath
import secrets
import stat
import sys
import time

LIBC = ctypes.CDLL(None, use_errno=True)
O_PATH = getattr(os, "O_PATH", 0o10000000)
O_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0o00400000)
O_DIRECTORY = getattr(os, "O_DIRECTORY", 0o00200000)
O_CLOEXEC = getattr(os, "O_CLOEXEC", 0o02000000)
RESOLVE_NO_XDEV = 0x01
RESOLVE_NO_MAGICLINKS = 0x02
RESOLVE_NO_SYMLINKS = 0x04
RESOLVE_BENEATH = 0x08
RENAME_EXCHANGE = 0x02
RENAME_NOREPLACE = 0x01
SYS_OPENAT2 = 437
SYS_RENAMEAT2 = {"x86_64": 316, "amd64": 316, "aarch64": 276, "arm64": 276}.get(
    platform.machine().lower()
)
MERGERFS_FULLPATH = "user.mergerfs.fullpath"
MERGERFS_BASEPATH = "user.mergerfs.basepath"
MERGERFS_ALLPATHS = "user.mergerfs.allpaths"
MERGERFS_SRCMOUNTS = "user.mergerfs.srcmounts"
MERGERFS_BRANCHES = "user.mergerfs.branches"
MERGERFS_INODECALC = "user.mergerfs.inodecalc"


class OpenHow(ctypes.Structure):
    _fields_ = [("flags", ctypes.c_uint64), ("mode", ctypes.c_uint64), ("resolve", ctypes.c_uint64)]


class EffectCommittedError(OSError):
    pass


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


def open_beneath(root_fd, relative, flags, mode=0, resolve=0):
    relative = checked_relative(relative)
    how = OpenHow(
        flags=flags | O_CLOEXEC,
        mode=mode,
        resolve=RESOLVE_BENEATH | RESOLVE_NO_MAGICLINKS | RESOLVE_NO_SYMLINKS | resolve,
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
        fd, union_identity = hold_open_mergerfs(root, relative, modes[mode], mode)
        result = {"fd": fd}
        if union_identity is not None:
            result["union_identity"] = union_identity
        emit({"ok": result})
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
    if mode == "create":
        return create_mergerfs_file(root, relative, flags)

    try:
        union_fd = open_mergerfs_path(root, relative)
    except OSError as exc:
        if mode == "write" and exc.errno == errno.ENOENT:
            return create_mergerfs_file(root, relative, flags)
        raise

    try:
        basepath, backing_relative = mergerfs_backing_location_fd(union_fd)
        logical_identity = file_identity(union_fd)
        union_identity = legacy_union_identity(mergerfs_mountpoint(root), union_fd)
        backing_flags = flags & ~(os.O_CREAT | os.O_EXCL | os.O_TRUNC)
        backing_fd = open_at_root(
            basepath,
            backing_relative,
            backing_flags,
            resolve=RESOLVE_NO_XDEV,
        )
        try:
            verify_mergerfs_mapping(
                root,
                relative,
                basepath,
                backing_relative,
                logical_identity,
                backing_fd,
            )
            if mode == "write":
                os.ftruncate(backing_fd, 0)
            return backing_fd, union_identity
        except BaseException:
            os.close(backing_fd)
            raise
    finally:
        os.close(union_fd)


def open_mergerfs_path(root, relative):
    root_fd = open_root(root)
    try:
        return open_beneath(
            root_fd,
            relative,
            os.O_RDONLY | O_NOFOLLOW,
            resolve=RESOLVE_NO_XDEV,
        )
    finally:
        os.close(root_fd)


def open_at_root(root, relative, flags, mode=0, resolve=0):
    root_fd = open_root(root)
    try:
        return open_beneath(root_fd, relative, flags, mode, resolve)
    finally:
        os.close(root_fd)


def file_identity(fd):
    stat = os.fstat(fd)
    return [stat.st_dev, stat.st_rdev, stat.st_ino]


def legacy_union_identity(mountpoint, fd):
    if mountpoint is None or not stat.S_ISREG(os.fstat(fd).st_mode):
        return None
    try:
        inodecalc = os.fsdecode(mergerfs_control_xattr(mountpoint, MERGERFS_INODECALC))
    except OSError:
        return None
    if inodecalc in {
        "devino-hash",
        "devino-hash32",
        "hybrid-hash",
        "hybrid-hash32",
    }:
        return file_identity(fd)
    return None


def verify_mergerfs_mapping(
    root, relative, basepath, backing_relative, logical_identity, backing_fd
):
    current_union = open_mergerfs_path(root, relative)
    try:
        current_basepath, current_relative = mergerfs_backing_location_fd(current_union)
        if (
            file_identity(current_union) != logical_identity
            or current_basepath != basepath
            or current_relative != backing_relative
        ):
            raise OSError(errno.ESTALE, "mergerfs logical mapping changed")
    finally:
        os.close(current_union)

    current_backing = open_at_root(
        basepath,
        backing_relative,
        O_PATH | O_NOFOLLOW,
        resolve=RESOLVE_NO_XDEV,
    )
    try:
        if file_identity(current_backing) != file_identity(backing_fd):
            raise OSError(errno.ESTALE, "mergerfs backing file changed")
    finally:
        os.close(current_backing)


def create_mergerfs_file(root, relative, flags):
    check_logical_absence(root, relative)
    parent_relative = posixpath.dirname(checked_relative(relative)) or "."
    basename = posixpath.basename(relative)
    parent_fd = open_mergerfs_path(root, parent_relative)
    try:
        basepath, backing_parent = mergerfs_backing_location_fd(parent_fd)
    finally:
        os.close(parent_fd)
    backing_relative = posixpath.join(backing_parent, basename)
    fd = open_at_root(
        basepath,
        backing_relative,
        flags | os.O_CREAT | os.O_EXCL,
        0o600,
        RESOLVE_NO_XDEV,
    )
    identity = file_identity(fd)
    try:
        wait_for_unique_path(
            root, relative, basepath, backing_relative, identity
        )
    except OSError as exc:
        os.close(fd)
        raise EffectCommittedError(exc.errno or errno.EIO, str(exc)) from exc
    except BaseException:
        os.close(fd)
        raise
    return fd, None


def rename_with_flags(src_parent, src_name, dst_parent, dst_name, flags):
    if SYS_RENAMEAT2 is None:
        raise OSError(errno.ENOSYS, "unsupported architecture")
    result = LIBC.syscall(
        SYS_RENAMEAT2,
        src_parent,
        ctypes.c_char_p(os.fsencode(src_name)),
        dst_parent,
        ctypes.c_char_p(os.fsencode(dst_name)),
        flags,
    )
    if result < 0:
        number = ctypes.get_errno()
        raise OSError(number, os.strerror(number))


def rename_exchange(src_parent, src_name, dst_parent, dst_name):
    rename_with_flags(src_parent, src_name, dst_parent, dst_name, RENAME_EXCHANGE)


def rename_noreplace(parent, source, destination):
    rename_with_flags(parent, source, parent, destination, RENAME_NOREPLACE)


def mountinfo_unescape(value):
    return (
        value.replace("\\040", " ")
        .replace("\\011", "\t")
        .replace("\\012", "\n")
        .replace("\\134", "\\")
    )


def mount_id(fd):
    with open(f"/proc/self/fdinfo/{fd}", encoding="utf-8") as fdinfo:
        for line in fdinfo:
            field, separator, value = line.partition(":")
            if field == "mnt_id" and separator:
                return value.strip()
    raise OSError(errno.EIO, "open descriptor has no mount identity")


def mergerfs_mountpoint(path):
    """Mountpoint of path's opened mount, but only when it is mergerfs."""
    fd = open_root(path)
    try:
        expected_id = mount_id(fd)
    finally:
        os.close(fd)

    with open("/proc/self/mountinfo", encoding="utf-8") as mountinfo:
        for line in mountinfo:
            fields = line.split()
            if fields[0] != expected_id:
                continue
            separator = fields.index("-")
            if fields[separator + 1] == "fuse.mergerfs":
                return posixpath.normpath(mountinfo_unescape(fields[4]))
            return None
    return None


def mergerfs_mount(path):
    return mergerfs_mountpoint(path) is not None


def mergerfs_control_xattr(mountpoint, name):
    fd = open_mergerfs_path(mountpoint, ".mergerfs")
    try:
        return os.getxattr(fd, name)
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


def exchange_mergerfs(src_root, src_relative, dst_root, dst_relative):
    src_fd = open_mergerfs_path(src_root, src_relative)
    try:
        src_base, src_relative = mergerfs_backing_location_fd(src_fd)
    finally:
        os.close(src_fd)

    dst_fd = open_mergerfs_path(dst_root, dst_relative)
    try:
        dst_base, dst_relative = mergerfs_backing_location_fd(dst_fd)
    finally:
        os.close(dst_fd)

    src_dir = posixpath.dirname(src_relative) or "."
    dst_dir = posixpath.dirname(dst_relative) or "."
    if src_base != dst_base:
        raise OSError(errno.EXDEV, "mergerfs exchange crosses backing filesystems")

    root_fd = open_root(src_base)
    try:
        src_backing_parent = open_beneath(
            root_fd,
            src_dir,
            os.O_RDONLY | O_DIRECTORY | O_NOFOLLOW,
            resolve=RESOLVE_NO_XDEV,
        )
        dst_backing_parent = open_beneath(
            root_fd,
            dst_dir,
            os.O_RDONLY | O_DIRECTORY | O_NOFOLLOW,
            resolve=RESOLVE_NO_XDEV,
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
    anchor_fd = open_mergerfs_path(root, anchor_relative)
    try:
        basepath, backing_anchor = mergerfs_backing_location_fd(anchor_fd)
    finally:
        os.close(anchor_fd)

    logical_parts = checked_relative(anchor_relative).split("/")
    backing_parts = checked_relative(backing_anchor).split("/")
    if backing_parts[-len(logical_parts) :] != logical_parts:
        raise OSError(errno.EXDEV, "mergerfs backing path does not match library root")

    prefix = backing_parts[: -len(logical_parts)]
    return basepath, posixpath.join(*prefix, checked_relative(relative))


def check_logical_absence(root, relative):
    try:
        fd = open_mergerfs_path(root, relative)
    except OSError as exc:
        if exc.errno == errno.ENOENT:
            return
        raise
    try:
        if len(mergerfs_allpaths(fd)) > 1:
            raise EffectCommittedError(
                errno.EEXIST, "logical mergerfs path spans backing branches"
            )
    finally:
        os.close(fd)
    raise OSError(errno.EEXIST, "logical mergerfs path already exists")


def mergerfs_allpaths(fd):
    paths = os.getxattr(fd, MERGERFS_ALLPATHS).split(b"\0")
    return [posixpath.normpath(os.fsdecode(path)) for path in paths if path]


def tombstone_identity(branch, backing_relative):
    """Identity of a backing container, refusing anything but a lone zero-byte file."""
    fd = open_at_root(
        branch,
        backing_relative,
        O_PATH | O_NOFOLLOW,
        resolve=RESOLVE_NO_XDEV,
    )
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise OSError(errno.EEXIST, "duplicate backup container is not a regular file")
        if info.st_size != 0:
            raise OSError(errno.ENOTEMPTY, "duplicate backup container is not a tombstone")
        # A hardlinked container is reachable under a pathname we did not prove,
        # so removing this link would not be removing the whole file.
        if info.st_nlink != 1:
            raise OSError(errno.EMLINK, "duplicate backup container is hardlinked")
        return [info.st_dev, info.st_rdev, info.st_ino]
    finally:
        os.close(fd)


def verify_quarantined_tombstone(fd, expected):
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_size != 0:
        raise OSError(errno.ENOTEMPTY, "quarantined container is no longer an empty tombstone")
    if info.st_nlink != 1:
        raise OSError(errno.EMLINK, "quarantined container is hardlinked")
    if [info.st_dev, info.st_rdev, info.st_ino] != expected:
        raise OSError(errno.ESTALE, "quarantined container is no longer the surveyed file")


def quarantine_duplicate(branch, backing_relative, expected):
    """Rename a proven duplicate aside, re-prove it, then unlink it.

    The rename is RENAME_NOREPLACE so a concurrently created pathname is never
    clobbered. The descriptor opened after the rename is held across both the
    proof and the unlink, and the size is re-proved through that same
    descriptor immediately before removal, so a writer that appends between the
    proof and the unlink is caught rather than silently losing its bytes. A
    container that was replaced, filled, or hardlinked is restored to its
    original name instead of destroyed.
    """
    parent_relative = posixpath.dirname(backing_relative) or "."
    name = posixpath.basename(backing_relative)
    parent = open_at_root(
        branch,
        parent_relative,
        os.O_RDONLY | O_DIRECTORY | O_NOFOLLOW,
        resolve=RESOLVE_NO_XDEV,
    )
    try:
        private = f".{name}.cinder-duplicate-{secrets.token_hex(16)}"
        rename_noreplace(parent, name, private)
        try:
            fd = os.open(private, O_PATH | O_NOFOLLOW | O_CLOEXEC, dir_fd=parent)
            try:
                remove_proven_tombstone(parent, private, fd, expected)
            finally:
                os.close(fd)
        except OSError as exc:
            if isinstance(exc, EffectCommittedError):
                raise
            restore_quarantined_duplicate(parent, private, name, exc)
    finally:
        os.close(parent)


def remove_proven_tombstone(parent, private, fd, expected):
    """Unlink a quarantined tombstone, proving it through the held descriptor.

    The proof reads the inode the descriptor already pins, so a writer that
    appended through its own descriptor is caught here. The unlink itself
    resolves the NAME (Linux has no funlinkat), so what makes it safe is the
    128-bit unguessable private name plus RENAME_NOREPLACE, not the descriptor.
    """
    verify_quarantined_tombstone(fd, expected)
    # ponytail: external writers appending after this proof require cooperative locking.
    # A failed unlink committed nothing, so let it propagate as a plain OSError:
    # the caller restores the original name rather than stranding a hidden
    # .cinder-duplicate-* orphan that mergerfs would surface in the union.
    os.unlink(private, dir_fd=parent)
    try:
        os.fsync(parent)
    except OSError as exc:
        raise EffectCommittedError(
            exc.errno or errno.EIO, "duplicate removal could not be synced"
        ) from exc


def restore_quarantined_duplicate(parent, private, name, cause):
    """Put an unproven quarantined container back under its original name."""
    try:
        rename_noreplace(parent, private, name)
        os.fsync(parent)
    except OSError as restore:
        raise EffectCommittedError(
            restore.errno or errno.EIO, "duplicate quarantine could not be restored"
        ) from restore
    raise cause


def reconcile_duplicates(args):
    """Remove proven, owned, zero-byte duplicate containers of one logical path.

    Every backing container must be a lone zero-byte regular file. The kept
    container must either carry the caller's physical identity or be the current
    mergerfs selection for a verified legacy union identity. Anything nonzero,
    hardlinked, ambiguous, or unowned raises before a byte is touched.
    """
    root, relative = args[0], args[1]
    expected = [int(args[2]), int(args[3]), int(args[4])]

    # user.mergerfs.allpaths is only authoritative on a real mergerfs mount.
    # Anywhere else it is ordinary, caller-writable metadata, and trusting it
    # would let a forged xattr name arbitrary files -- including files outside
    # the configured roots -- as deletable "duplicates".
    mountpoint = mergerfs_mountpoint(root)
    if mountpoint is None:
        raise OSError(errno.EINVAL, "logical path is not on a mergerfs mount")

    fd = open_mergerfs_path(root, relative)
    try:
        paths = mergerfs_allpaths(fd)
        legacy_location = None
        if legacy_union_identity(mountpoint, fd) == expected:
            legacy_location = mergerfs_backing_location_fd(fd)
    finally:
        os.close(fd)

    branches = mergerfs_branches(mountpoint)
    # Branches mirror the MOUNT, and the library root may be a subdirectory of
    # it, so a container sits at <branch>/<root-relative-to-mount>/<relative>.
    below_mount = posixpath.relpath(posixpath.normpath(root), mountpoint)
    backing_relative = checked_relative(relative)
    if below_mount != ".":
        backing_relative = posixpath.join(checked_relative(below_mount), backing_relative)

    if len(paths) < 2:
        raise OSError(errno.EINVAL, "logical path does not span backing branches")
    if len(paths) != len(set(paths)):
        raise OSError(errno.EINVAL, "logical path repeats a backing container")

    legacy_kept = None
    if legacy_location is not None:
        legacy_base, legacy_relative = legacy_location
        if legacy_relative != backing_relative:
            raise OSError(errno.EXDEV, "selected backing path does not match logical path")
        legacy_kept = posixpath.join(legacy_base, legacy_relative)
        verify_backing_container(legacy_kept, backing_relative, branches)
        if paths.count(legacy_kept) != 1:
            raise OSError(errno.ESTALE, "selected backing container is not unique")

    containers = []
    for path in paths:
        branch = verify_backing_container(path, backing_relative, branches)
        containers.append((path, branch, tombstone_identity(branch, backing_relative)))

    identities = {tuple(identity) for _path, _branch, identity in containers}
    if len(containers) != len(identities):
        raise OSError(errno.ESTALE, "backing containers alias the same file")

    physical_kept = [path for path, _branch, identity in containers if identity == expected]
    if len(physical_kept) == 1:
        kept = physical_kept[0]
    elif not physical_kept and legacy_kept is not None:
        kept = legacy_kept
    else:
        raise OSError(errno.ESTALE, "owned backup container is not unique")

    kept_branch = next(branch for path, branch, _identity in containers if path == kept)
    duplicates = [
        (path, branch, identity)
        for path, branch, identity in containers
        if path != kept
    ]

    for index, (_path, branch, identity) in enumerate(duplicates):
        try:
            if kept == legacy_kept:
                verify_legacy_selection(root, relative, mountpoint, expected, kept)
            elif tombstone_identity(kept_branch, backing_relative) != expected:
                raise OSError(errno.ESTALE, "owned backup container changed")
            quarantine_duplicate(branch, backing_relative, identity)
        except OSError as exc:
            if index and not isinstance(exc, EffectCommittedError):
                raise EffectCommittedError(
                    exc.errno or errno.EIO, "duplicate reconciliation partially applied"
                ) from exc
            raise

    emit({"ok": "reconcile_duplicates"})


def mergerfs_branches(mountpoint):
    """Configured backing branches, read from the mount's own control file.

    branches/srcmounts are runtime CONFIG keys: mergerfs serves them only from
    <mountpoint>/.mergerfs. The control file is opened without crossing mounts;
    reading the keys from a target file or nested mount would trust
    caller-writable metadata. legacy_union_identity reads inodecalc the same way.
    """
    try:
        raw = os.fsdecode(mergerfs_control_xattr(mountpoint, MERGERFS_BRANCHES))
    except OSError:
        raw = os.fsdecode(mergerfs_control_xattr(mountpoint, MERGERFS_SRCMOUNTS))

    branches = []
    for entry in raw.split(":"):
        # user.mergerfs.branches yields "path=MODE"; srcmounts yields bare paths.
        entry = entry.split("=", 1)[0]
        if entry:
            branches.append(posixpath.normpath(entry))
    return branches


def verify_backing_container(path, backing_relative, branches):
    """Prove a listed container really is this logical path inside a branch.

    mergerfs maps a logical path onto <branch>/<relative>, so a container that
    does not sit at that exact position under a configured branch is not a
    backing copy of this file and must never be removed.
    """
    if not posixpath.isabs(path):
        raise OSError(errno.EINVAL, "backing container path is not absolute")

    for branch in branches:
        if path == posixpath.join(branch, backing_relative):
            return branch

    raise OSError(errno.EXDEV, "backing container is not inside a configured branch")


def verify_legacy_selection(root, relative, mountpoint, expected, kept):
    fd = open_mergerfs_path(root, relative)
    try:
        if legacy_union_identity(mountpoint, fd) != expected:
            raise OSError(errno.ESTALE, "legacy mergerfs identity changed")
        basepath, backing_relative = mergerfs_backing_location_fd(fd)
        if posixpath.join(basepath, backing_relative) != kept:
            raise OSError(errno.ESTALE, "mergerfs selected backing container changed")
    finally:
        os.close(fd)


def wait_for_unique_path(root, relative, basepath, backing_relative, expected_identity):
    expected_path = posixpath.join(basepath, backing_relative)
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        try:
            fd = open_mergerfs_path(root, relative)
        except OSError as exc:
            if exc.errno != errno.ENOENT:
                raise
        else:
            try:
                if mergerfs_allpaths(fd) == [posixpath.normpath(expected_path)]:
                    current = open_at_root(
                        basepath,
                        backing_relative,
                        O_PATH | O_NOFOLLOW,
                        resolve=RESOLVE_NO_XDEV,
                    )
                    try:
                        if file_identity(current) == expected_identity:
                            return
                        raise OSError(errno.ESTALE, "mergerfs backing path changed")
                    finally:
                        os.close(current)
                raise OSError(errno.EEXIST, "logical mergerfs path spans backing branches")
            finally:
                os.close(fd)
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
            if not exchange_mergerfs(args[0], args[1], args[2], args[3]):
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

    check_logical_absence(args[0], args[1])
    basepath, backing_relative = mergerfs_near_relative(args[0], args[2], args[1])
    parent_name = posixpath.dirname(backing_relative) or "."
    basename = posixpath.basename(backing_relative)
    root_fd = open_root(basepath)
    try:
        parent = open_beneath(
            root_fd,
            parent_name,
            os.O_RDONLY | O_DIRECTORY | O_NOFOLLOW,
            resolve=RESOLVE_NO_XDEV,
        )
    finally:
        os.close(root_fd)

    try:
        old_umask = os.umask(0o077)
        private = f".{basename}.cinder-create-{secrets.token_hex(16)}"
        try:
            os.mkdir(private, int(args[3], 8), dir_fd=parent)
        finally:
            os.umask(old_umask)
        try:
            created = os.open(
                private,
                os.O_RDONLY | O_DIRECTORY | O_NOFOLLOW,
                dir_fd=parent,
            )
        except OSError as exc:
            fail("mkdir_near", "post_effect", exc)
            return
        try:
            identity = file_identity(created)
            try:
                rename_noreplace(parent, private, basename)
            except OSError as exc:
                fail("mkdir_near", "post_effect", exc)
                return
            sync_parents(parent)
            wait_for_unique_path(
                args[0], args[1], basepath, backing_relative, identity
            )
        except OSError as exc:
            fail("mkdir_near", "post_effect", exc)
            return
        finally:
            os.close(created)
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
    elif operation == "reconcile_duplicates" and len(args) == 5:
        reconcile_duplicates(args)
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
        phase = "post_effect" if isinstance(exc, EffectCommittedError) else "pre_effect"
        fail(operation, phase, exc)
        sys.exit(1)
