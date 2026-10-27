defmodule Cinder.Test.MergerfsControl do
  @moduledoc """
  Python that makes a rooted-helper shim answer like mergerfs's control file (#972).

  mergerfs refuses a read open of `<mount>/.mergerfs` with `ENOENT`, but serves its config
  keys to a lookup of the file: a path `getxattr`, including one through an `O_PATH`
  descriptor's `/proc/self/fd/<n>` link. `fgetxattr` on an `O_PATH` descriptor fails with
  `EBADF` in the kernel before mergerfs sees it, so an int descriptor is left to the real call.

  `control` is the regular file that stands for the control file: `<mount>/.mergerfs`, or the
  target of a symlink planted there, which proves the helper never reads through the link.
  `python/3` returns lines to splice into a shim after it has exec'd the helper into
  `namespace`. They wrap the helper's `open_beneath` and `os.getxattr`, so `os.getxattr` must
  already hold whatever the shim answers for other keys.
  """

  @doc """
  `branches` answers `user.mergerfs.branches` (as `path=RW`) and `user.mergerfs.srcmounts`.
  `:inodecalc` answers `user.mergerfs.inodecalc`, `"hybrid-hash"` by default as on prod.
  """
  def python(control, branches, opts \\ []) do
    branch_modes = Enum.map_join(branches, ":", &"#{&1}=RW")
    srcmounts = Enum.join(branches, ":")
    inodecalc = Keyword.get(opts, :inodecalc, "hybrid-hash")

    """
    import errno
    import os

    CONTROL = #{inspect(control)}
    CONTROL_XATTRS = {
        "user.mergerfs.branches": os.fsencode(#{inspect(branch_modes)}),
        "user.mergerfs.srcmounts": os.fsencode(#{inspect(srcmounts)}),
        "user.mergerfs.inodecalc": os.fsencode(#{inspect(inodecalc)}),
    }

    def is_control(info):
        try:
            return os.path.samestat(info, os.stat(CONTROL))
        except FileNotFoundError:
            return False

    real_open_beneath = namespace["open_beneath"]

    def control_open_beneath(root_fd, relative, flags, mode=0, resolve=0):
        fd = real_open_beneath(root_fd, relative, flags, mode, resolve)
        if not flags & namespace["O_PATH"] and is_control(os.fstat(fd)):
            os.close(fd)
            raise OSError(errno.ENOENT, os.strerror(errno.ENOENT))
        return fd

    namespace["open_beneath"] = control_open_beneath

    shim_getxattr = os.getxattr

    def control_getxattr(path, name, **kwargs):
        if name not in CONTROL_XATTRS or isinstance(path, int):
            return shim_getxattr(path, name, **kwargs)
        try:
            found = is_control(os.stat(path))
        except OSError:
            found = False
        if not found:
            raise OSError(errno.ENODATA, os.strerror(errno.ENODATA))
        return CONTROL_XATTRS[name]

    os.getxattr = control_getxattr
    """
  end
end
