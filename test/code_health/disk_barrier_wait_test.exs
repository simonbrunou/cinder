defmodule Cinder.CodeHealth.DiskBarrierWaitTest do
  # Makes a test file that names `BarrierFilesystem` or `Filesystem.Disk` pass
  # `Cinder.Test.DiskTask.timeout_ms/0` to each `assert_receive` of a `{:filesystem_barrier, ...}`
  # message, as `disk_task_await_test.exs` makes it await each task through DiskTask. DiskTask's
  # moduledoc says why (#1034). The rule covers every barrier wait in such a file, including one
  # whose task reaches no subprocess before its pause, so the fence needs no per-site judgment.
  use ExUnit.Case, async: true

  @reaches_disk ["BarrierFilesystem", "Filesystem.Disk"]
  @disk_task [[:DiskTask], [:Cinder, :Test, :DiskTask]]

  test "a test file that reaches Disk waits for each barrier message past the Disk bound" do
    # This file names both markers, so it would keep the scan from ever coming back empty.
    scanned =
      for path <- Path.wildcard("test/**/*_test.exs"),
          path != Path.relative_to_cwd(__ENV__.file),
          source = File.read!(path),
          String.contains?(source, @reaches_disk),
          do: {path, source}

    refute scanned == [], "No test file names #{Enum.join(@reaches_disk, " or ")}."

    short =
      for {path, source} <- scanned,
          line <- short_barrier_wait_lines(source),
          do: "#{path}:#{line}"

    assert short == [],
           "These tests wait for a {:filesystem_barrier, ...} message with no timeout or a " <>
             "timeout other than DiskTask.timeout_ms(), which can fall below the test-env " <>
             "Disk bound:\n" <>
             Enum.join(short, "\n") <>
             "\nPass Cinder.Test.DiskTask.timeout_ms() as each assert_receive's timeout " <>
             "(docs/agents/testing.md)."
  end

  test "the walk finds each short barrier wait and skips refute_receive, other waits, strings" do
    source = ~S'''
    defmodule M do
      test "waits" do
        assert_receive {:filesystem_barrier, pid, ref, :rename, ^path}
        assert_receive {:filesystem_barrier, pid, ref, :rename, ^path}, 15_000
        assert_receive {:filesystem_barrier, pid, ref, :rename, ^path}, @timeout
        assert_receive {:filesystem_barrier, pid, ref, :rename, ^path}, DiskTask.timeout_ms() + 1
        assert_receive {:filesystem_barrier, pid, ref, :rename, ^path}, DiskTask.timeout_ms()
        assert_receive {:filesystem_barrier, pid, ref, :rename, ^path}, Cinder.Test.DiskTask.timeout_ms()
        assert_receive {:filesystem_barrier, pid, ref, :rename, ^path}, DiskTask.timeout_ms(), "msg"
        refute_receive {:filesystem_barrier, _pid, _ref, :rename, _path}, 100
        assert_receive {:written, result}, 15_000
        assert_receive :movie_scan
      end

      @doc """
      assert_receive {:filesystem_barrier, pid, ref, :rename, path}
      """
      def j, do: :ok
    end
    '''

    assert short_barrier_wait_lines(source) == Enum.to_list(3..6)
  end

  # The lines of the `assert_receive` calls whose pattern is a `{:filesystem_barrier, ...}` tuple
  # and whose timeout is not a `DiskTask.timeout_ms()` call. A string's contents are not code.
  defp short_barrier_wait_lines(source) do
    {:ok, ast} = Code.string_to_quoted(source)

    {_ast, lines} =
      Macro.prewalk(ast, [], fn
        {:assert_receive, meta, [{:{}, _, [:filesystem_barrier | _]} | rest]} = node, lines ->
          if disk_task_timeout?(rest),
            do: {node, lines},
            else: {node, [Keyword.get(meta, :line) | lines]}

        node, lines ->
          {node, lines}
      end)

    Enum.sort(lines)
  end

  # The arguments after the pattern: the timeout, then an optional failure message.
  defp disk_task_timeout?([{{:., _, [{:__aliases__, _, module}, :timeout_ms]}, _, []} | _]),
    do: module in @disk_task

  defp disk_task_timeout?(_rest), do: false
end
