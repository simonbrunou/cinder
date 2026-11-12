defmodule Cinder.Library.Filesystem.DiskMvExchangeCheckTest do
  # #1201: .github/scripts/mv_exchange_check.exs is the expression ci.yml's `container` job runs
  # through `bin/cinder rpc` in the booted release. These tests evaluate the same file in the
  # test node, with a fake `mv` first on PATH: the `test` job's coreutils 9.4 has no
  # `--exchange`, so only the `container` job runs the real one. The fake records each call's
  # arguments. PATH and the library roots are global, so the module is not async.
  use Cinder.DataCase, async: false

  import ExUnit.CaptureIO

  alias Cinder.ConfigCase

  @check ".github/scripts/mv_exchange_check.exs"

  @moduletag :tmp_dir

  @swap_py """
  import os, sys
  a, b = sys.argv[1:]
  os.rename(a, a + ".swap")
  os.rename(b, a)
  os.rename(a + ".swap", b)
  """

  @swap_mv ~S{exec python3 "$(dirname "$0")/swap.py" "$4" "$5"}

  test "prints the ok line last when Disk.exchange/2 swaps the two files", %{tmp_dir: tmp} do
    fake_mv!(tmp, @swap_mv)

    lines = run_check()
    [left, right] = exchanged_paths!(tmp)

    assert List.last(lines) == "MV_EXCHANGE_CHECK:ok"
    assert length(lines) == 2
    assert hd(lines) =~ "mv --exchange swapped #{left} and #{right}"
    refute File.exists?(Path.dirname(left))
  end

  test "prints the failed line with the error when mv exits non-zero", %{tmp_dir: tmp} do
    fake_mv!(tmp, ~S"""
    echo "mv: unrecognized option '--exchange'" >&2
    exit 1
    """)

    lines = run_check()
    [left, _right] = exchanged_paths!(tmp)

    assert lines == [
             "MV_EXCHANGE_CHECK:failed " <>
               inspect(
                 {{:error, {:exchange_failed, 1, "mv: unrecognized option '--exchange'\n"}},
                  {:ok, "left"}, {:ok, "right"}}
               )
           ]

    refute File.exists?(Path.dirname(left))
  end

  test "prints the failed line when mv exits 0 without swapping", %{tmp_dir: tmp} do
    fake_mv!(tmp, "exit 0")

    lines = run_check()
    [left, _right] = exchanged_paths!(tmp)

    assert lines == [
             "MV_EXCHANGE_CHECK:failed " <>
               inspect({:ok, {:ok, "left"}, {:ok, "right"}})
           ]

    refute File.exists?(Path.dirname(left))
  end

  test "refuses without calling Disk.exchange/2 when its paths lie under a library root",
       %{tmp_dir: tmp} do
    fake_mv!(tmp, @swap_mv)
    ConfigCase.put_env(:movies_library_path, System.tmp_dir!())

    assert [line] = run_check()
    assert line =~ ~r/^MV_EXCHANGE_CHECK:failed \{:inside_library_roots, \[/
    assert line =~ inspect(Path.expand(System.tmp_dir!()))
    refute File.exists?(calls_file(tmp))

    [dir] = Regex.run(~r{"(/[^"]*/cinder-mv-exchange-check-\d+)/left"}, line, capture: [1])

    assert line =~
             "{:inside_library_roots, #{inspect([Path.join(dir, "left"), Path.join(dir, "right")])}, "

    refute File.exists?(dir)
  end

  defp run_check do
    fn -> Code.eval_file(@check) end
    |> capture_io()
    |> String.split("\n", trim: true)
  end

  # Puts an `mv` that records its arguments, then runs `body`, first on PATH for this test.
  defp fake_mv!(tmp, body) do
    bin = Path.join(tmp, "bin")
    File.mkdir_p!(bin)
    File.write!(Path.join(bin, "swap.py"), @swap_py)
    mv = Path.join(bin, "mv")

    File.write!(mv, """
    #!/bin/sh
    printf '%s\\n' "$@" >>'#{calls_file(tmp)}'
    #{body}
    """)

    File.chmod!(mv, 0o755)
    path = System.get_env("PATH")
    on_exit(fn -> System.put_env("PATH", path) end)
    System.put_env("PATH", bin <> ":" <> path)
  end

  defp calls_file(tmp), do: Path.join(tmp, "mv-calls")

  # The two paths of the one `mv` call, which must pass the exchange flags first.
  defp exchanged_paths!(tmp) do
    assert ["--exchange", "--no-copy", "--no-target-directory", left, right] =
             tmp |> calls_file() |> File.read!() |> String.split("\n", trim: true)

    assert Path.dirname(left) == Path.dirname(right)
    assert Path.dirname(left) =~ ~r{/cinder-mv-exchange-check-\d+$}
    [left, right]
  end
end
