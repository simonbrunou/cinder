defmodule Cinder.Library.Filesystem.RenameIdentityTest do
  @moduledoc """
  The probe writes, renames and unlinks a file of its own to answer, inside a library folder the
  operator sees. Its verdict is covered end to end where it is acted on
  (`Cinder.Library.SidecarsTest`, `Cinder.Library.StageEngineTest`); what needs proving here is
  the invariant those tests can only observe on one branch — that no outcome leaves the probe
  file behind.
  """
  use Cinder.DataCase, async: false

  alias Cinder.Library.Filesystem.RenameIdentity

  @tag :tmp_dir
  test "a write that fails after creating the probe file still leaves nothing behind", %{
    tmp_dir: tmp
  } do
    library = Path.join(tmp, "movies")
    dir = Path.join(library, "Movie (2020)")
    File.mkdir_p!(dir)

    saved = Map.new([:filesystem, :path_policy], &{&1, Application.get_env(:cinder, &1)})
    Application.put_env(:cinder, :filesystem, Cinder.Test.BarrierFilesystem)
    Application.put_env(:cinder, :path_policy, Cinder.Library.PathPolicy)

    # `Disk.write_exclusive/2` creates the file with `O_EXCL` before it can fail on the write,
    # the fsync or the parent sync, and each of those closes the handle without unlinking. Nothing
    # sweeps this prefix, so a probe that gave up here would strand a dotfile in a media folder
    # for good.
    Application.put_env(:cinder, :filesystem_failure, %{
      operation: :write_exclusive,
      source_contains: ".cinder-inode-probe-",
      reason: :enospc,
      phase: :post_effect
    })

    on_exit(fn ->
      Application.delete_env(:cinder, :filesystem_failure)

      Enum.each(saved, fn
        {key, nil} -> Application.delete_env(:cinder, key)
        {key, value} -> Application.put_env(:cinder, key, value)
      end)
    end)

    assert RenameIdentity.probe(dir, library) == :unknown
    assert Path.wildcard(Path.join(dir, ".cinder-inode-probe-*"), match_dot: true) == []
  end
end
