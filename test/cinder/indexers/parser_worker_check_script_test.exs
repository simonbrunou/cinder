defmodule Cinder.Indexers.ParserWorkerCheckScriptTest do
  # #1665: .github/scripts/parser_worker_check.exs is the expression ci.yml's `container` job
  # runs through `bin/cinder rpc` in the booted release. These tests evaluate the same file in the
  # test node: once against the real worker, then with `:parser_worker_erl` pointed at stubs. The
  # key is global, so the module is not async.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Cinder.ConfigCase

  @check ".github/scripts/parser_worker_check.exs"

  test "prints the ok line last when the real worker answers td b and crashes on the :has()" do
    assert run_check() == [
             "td b answered its row and td:has(b[border=1]) ended its worker as :crash",
             "PARSER_WORKER_CHECK:ok"
           ]
  end

  describe "with a stub worker" do
    @describetag :tmp_dir

    test "prints the failed line with both results when every worker crashes", %{tmp_dir: tmp} do
      stub!(tmp, "exit 1")

      assert run_check() == [
               "PARSER_WORKER_CHECK:failed " <> inspect({{:error, :crash}, {:error, :crash}})
             ]
    end

    test "prints the failed line when the has worker answers instead of crashing", %{
      tmp_dir: tmp
    } do
      first = answer!(tmp, "first", <<?R, 1::32, 1::32, 1, 1::32, "x">>)
      second = answer!(tmp, "second", <<?R, 1::32, 0::32>>)
      seen = Path.join(tmp, "seen")

      stub!(
        tmp,
        "if [ -e #{seen} ]; then cat #{second} >&3; else touch #{seen}; cat #{first} >&3; fi"
      )

      assert run_check() == [
               "PARSER_WORKER_CHECK:failed " <> inspect({{:ok, [[{"t", "x"}]]}, {:ok, [[]]}})
             ]
    end

    test "prints the failed line when td b answers no row", %{tmp_dir: tmp} do
      empty = answer!(tmp, "empty", <<?R, 0::32, 1::32>>)
      seen = Path.join(tmp, "seen")
      stub!(tmp, "if [ -e #{seen} ]; then exit 1; else touch #{seen}; cat #{empty} >&3; fi")

      assert run_check() == [
               "PARSER_WORKER_CHECK:failed " <> inspect({{:ok, []}, {:error, :crash}})
             ]
    end
  end

  # A file holding `answer` framed as the worker frames its answer.
  defp answer!(tmp, name, answer) do
    file = Path.join(tmp, name)
    File.write!(file, <<byte_size(answer)::32, answer::binary>>)
    file
  end

  # The stubs put tmp_dir paths into sh unquoted, and tmp_dir holds the test name.
  defp stub!(tmp, body) do
    if tmp =~ ~r/[^A-Za-z0-9_\/.,-]/,
      do: raise(ArgumentError, "rename the test: sh misreads its tmp_dir #{inspect(tmp)}")

    path = Path.join(tmp, "erl")
    File.write!(path, "#!/bin/sh\n" <> body <> "\n")
    File.chmod!(path, 0o755)
    ConfigCase.put_env(:parser_worker_erl, path)
  end

  defp run_check do
    fn -> Code.eval_file(@check) end
    |> capture_io()
    |> String.split("\n", trim: true)
  end
end
