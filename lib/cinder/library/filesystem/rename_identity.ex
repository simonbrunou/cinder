defmodule Cinder.Library.Filesystem.RenameIdentity do
  @moduledoc """
  Whether a mount reports a file identity that survives a rename.

  Every ownership decision the import makes — "is the file at this path still the one I put
  there?" — compares the `{major_device, inode}` pair `lstat` reports. On a normal filesystem
  that pair is a property of the file, so it can be captured at one path and checked at another
  after a rename. Some FUSE and union mounts compute the inode they report from the *path*
  instead — mergerfs with `inodecalc=path-hash` is the concrete case, and `priv/rooted_fs.py`
  already reads that setting for its own union-identity handling — so one physical file reports
  two different inodes either side of a rename nothing else touched. A caller that reads the
  difference as "someone replaced my file" then takes the wrong branch (issue #558).

  Rather than infer the answer from the mount type, ask the mount: create an empty file under
  an unguessable name, rename it, and see whether the reported identity moved with it.

  Only `:unpreserved` is a positive finding — the mount demonstrably did not carry the identity
  across a rename of its own probe file, so an identity mismatch there is not evidence of
  anything. `:unknown` (the probe could not run) says nothing and callers must keep whatever
  they do without it. Call this only where a mismatch is about to decide what happens to a file
  on disk, never on a path that succeeded: it writes, renames and unlinks a file to answer.
  """

  alias Cinder.Library.PathPolicy

  @probe_prefix ".cinder-inode-probe-"

  @doc """
  Probes whether `dir` (which must sit under library root `root`) reports a file identity that
  a rename preserves.
  """
  @spec probe(String.t(), String.t()) :: :preserved | :unpreserved | :unknown
  def probe(dir, root) do
    source = probe_path(dir)
    dest = probe_path(dir)

    with {:ok, ^source} <- safe_destination(source, root),
         {:ok, ^dest} <- safe_destination(dest, root),
         :ok <- fs().write_exclusive(source, "") do
      verdict = compare_across_rename(source, dest)
      # The probe file sits at `dest` when the rename landed and at `source` when it did not, and
      # an :unknown gives no way to tell which: discard both so no verdict can leave litter in a
      # library folder.
      discard(source, root)
      discard(dest, root)
      verdict
    else
      _ -> :unknown
    end
  end

  defp compare_across_rename(source, dest) do
    with {:ok, %{major_device: device, inode: inode}} <- fs().lstat(source),
         :ok <- fs().rename(source, dest),
         {:ok, renamed} <- fs().lstat(dest) do
      if {renamed.major_device, renamed.inode} == {device, inode},
        do: :preserved,
        else: :unpreserved
    else
      _ -> :unknown
    end
  end

  # 96 random bits, the same unguessable-name convention the sidecar quarantine and
  # `AtomicFile.temporary/3` use: a probe must never collide with a real file, and a name a
  # concurrent import could predict would make the probe itself racy.
  defp probe_path(dir) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    Path.join(dir, "#{@probe_prefix}#{token}")
  end

  defp discard(path, root) do
    case path_policy().deletable_file(path, [root], filesystem: fs()) do
      :ok -> fs().rm(path)
      {:error, _reason} -> :ok
    end
  end

  defp safe_destination(path, root),
    do: path_policy().destination(path, root, filesystem: fs())

  defp fs, do: Application.get_env(:cinder, :filesystem)
  defp path_policy, do: Application.get_env(:cinder, :path_policy, PathPolicy)
end
