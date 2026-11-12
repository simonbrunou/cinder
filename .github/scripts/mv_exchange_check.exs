# #1201: ci.yml's `container` job runs this file's text through `bin/cinder rpc` in the booted
# release, as the image's user. It swaps two files outside every library root with
# `Cinder.Library.Filesystem.Disk.exchange/2`, which takes its `mv --exchange` fallback for such
# paths. The `test` job's runner has coreutils 9.4, whose `mv` lacks `--exchange`, so no other
# CI run reaches the real `mv`. The last line it prints is `MV_EXCHANGE_CHECK:ok` only when the
# call returned `:ok` and the two files hold each other's contents. Any other result prints
# `MV_EXCHANGE_CHECK:failed` with that result, and a raise makes the rpc exit 1. The job's step
# fails unless the rpc exits 0 and prints the `ok` line.
# test/cinder/library/filesystem/disk_mv_exchange_check_test.exs runs this file against fake
# `mv` commands.
alias Cinder.Library.Filesystem.Disk
alias Cinder.Library.PathPolicy

dir =
  Path.join(
    System.tmp_dir!(),
    "cinder-mv-exchange-check-#{System.unique_integer([:positive])}"
  )

left = Path.join(dir, "left")
right = Path.join(dir, "right")

try do
  File.mkdir_p!(dir)
  File.write!(left, "left")
  File.write!(right, "right")
  roots = Cinder.Settings.library_roots()

  # Disk.exchange/2 takes its rooted helper, not `mv`, when both paths lie under a library
  # root; PathPolicy.deepest_root/2 is the test it makes.
  result =
    case Enum.filter([left, right], &PathPolicy.deepest_root(&1, roots)) do
      [] -> {Disk.exchange(left, right), File.read(left), File.read(right)}
      rooted -> {:inside_library_roots, rooted, roots}
    end

  case result do
    {:ok, {:ok, "right"}, {:ok, "left"}} ->
      IO.puts(
        "mv --exchange swapped #{left} and #{right}, outside library roots #{inspect(roots)}"
      )

      IO.puts("MV_EXCHANGE_CHECK:ok")

    other ->
      IO.puts(
        "MV_EXCHANGE_CHECK:failed #{inspect(other, limit: :infinity, printable_limit: :infinity)}"
      )
  end
after
  File.rm_rf(dir)
end
