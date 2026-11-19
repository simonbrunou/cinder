defmodule Cinder.Test.ChildVMTest do
  # The harness the child VM tests share (#1538). Its callers set a variable, send stderr to a
  # file, read stdin from a FIFO and act on a line. These tests cover the rest: a variable the
  # parent has, an empty value, output that could pass for the status, a line longer than one
  # port message, and a child that hangs, which takes the `:timeout` option.
  use ExUnit.Case, async: true

  alias Cinder.Test.ChildVM

  @ebin Path.dirname(:code.which(ChildVM))

  @tag :tmp_dir
  test "unsets a variable the parent has, and exports an empty value", ctx do
    assert System.get_env("HOME") not in [nil, ""]

    code = ~s[IO.inspect({System.get_env("HOME"), System.fetch_env("CINDER_CHILD_VM")})]
    {output, status} = ChildVM.run(code, ctx.tmp_dir, @ebin, env: {"HOME", nil})
    assert {status, output} == {0, ~s[{nil, :error}]}

    {output, status} = ChildVM.run(code, ctx.tmp_dir, @ebin, env: {"CINDER_CHILD_VM", ""})
    assert {status, output} == {0, inspect({System.get_env("HOME"), {:ok, ""}})}
  end

  @tag :tmp_dir
  test "takes the status from the port, not from a line the child prints", ctx do
    {output, status} =
      ChildVM.run(
        ~s[IO.puts("exit 0"); IO.write("no newline"); System.stop(2); Process.sleep(:infinity)],
        ctx.tmp_dir,
        @ebin
      )

    assert {status, output} == {2, "exit 0\nno newline"}
  end

  @tag :tmp_dir
  test "keeps an empty last line the child printed", ctx do
    assert ChildVM.run(~s[IO.write("a\\n\\n")], ctx.tmp_dir, @ebin) == {"a\n", 0}
  end

  @tag :tmp_dir
  test "joins a line longer than one port message into one line", ctx do
    {output, status} =
      ChildVM.run(~s[IO.puts(String.duplicate("a", 10_000)); IO.puts("next")], ctx.tmp_dir, @ebin)

    assert status == 0, output
    assert output == String.duplicate("a", 10_000) <> "\nnext"
  end

  # Each child outlives the wait, then exits by itself, so it leaves no process behind for long.
  @tag :tmp_dir
  test "flunks when the child sends nothing for the timeout", ctx do
    error =
      assert_raise ExUnit.AssertionError, fn ->
        ChildVM.run("Process.sleep(3_000)", ctx.tmp_dir, @ebin, timeout: 500)
      end

    assert error.message == "the child sent nothing for 500 ms and did not exit:\n"
  end

  # The wait restarts with each message, so it must outlast the child's boot before its first
  # line: 20 s, where a boot on a loaded host takes seconds. The port sends the first 4096 bytes
  # of the unfinished line as a piece and holds the rest.
  @tag :tmp_dir
  test "flunks with the lines and the piece of a line the child sent before it hung", ctx do
    code = ~s[IO.puts("started"); IO.write(String.duplicate("a", 5_000)); Process.sleep(40_000)]

    error =
      assert_raise ExUnit.AssertionError, fn ->
        ChildVM.run(code, ctx.tmp_dir, @ebin, timeout: 20_000)
      end

    assert error.message ==
             "the child sent nothing for 20000 ms and did not exit:\nstarted\n" <>
               String.duplicate("a", 4096)
  end
end
