defmodule Cinder.CodeHealth.DiskTaskAwaitTest do
  # Keeps `Cinder.Test.DiskTask`'s wait between the test-env Disk bound and ExUnit's per-test
  # timeout, and makes a test file that names `BarrierFilesystem`, which delegates every
  # operation to Disk, or `Filesystem.Disk` itself await each of its tasks through it. DiskTask's
  # moduledoc says why (#1012). The walk skips an await inside `catch_exit/1`, which those files
  # keep for a task the test already killed: the await returns as soon as its monitor reports
  # that exit.
  use ExUnit.Case, async: true

  alias Cinder.Test.DiskTask

  @reaches_disk ["BarrierFilesystem", "Filesystem.Disk"]
  @awaits [:await, :await_many]

  test "DiskTask waits past the test-env Disk bound and under ExUnit's per-test timeout" do
    bound = Application.fetch_env!(:cinder, :disk_subprocess_timeout_ms)

    assert DiskTask.timeout_ms() > bound
    assert DiskTask.timeout_ms() < Keyword.fetch!(ExUnit.configuration(), :timeout)
  end

  test "a test file that reaches Disk awaits its tasks through DiskTask" do
    # This file names both markers, so it would keep the scan from ever coming back empty.
    scanned =
      for path <- Path.wildcard("test/**/*_test.exs"),
          path != Path.relative_to_cwd(__ENV__.file),
          source = File.read!(path),
          String.contains?(source, @reaches_disk),
          do: {path, source}

    refute scanned == [], "No test file names #{Enum.join(@reaches_disk, " or ")}."

    bare = for {path, source} <- scanned, line <- await_lines(source), do: "#{path}:#{line}"

    assert bare == [],
           "These tests await a task that can reach a Disk subprocess with Task.await or " <>
             "Task.await_many, whose ceiling can fall below the test-env Disk bound:\n" <>
             Enum.join(bare, "\n") <>
             "\nAwait each task with Cinder.Test.DiskTask.await/1 (docs/agents/testing.md)."
  end

  test "the walk finds each await form and skips one in catch_exit or a string" do
    source = ~S'''
    defmodule M do
      def a(task), do: Task.await(task)
      def b(task), do: Task.await(task, 15_000)
      def c(task), do: task |> Task.await()
      def d(tasks), do: Enum.map(tasks, &Task.await/1)
      def e(tasks), do: Task.await_many(tasks)
      def f(task), do: Elixir.Task.await(task)
      def g(task), do: catch_exit(Task.await(task))
      def h(task), do: Cinder.Test.DiskTask.await(task)
      def i(task), do: Task.yield(task, 100)

      @doc """
      Task.await(task)
      """
      def j, do: :ok
    end
    '''

    assert await_lines(source) == Enum.to_list(2..7)
  end

  # The lines of the `Task.await` and `Task.await_many` calls in the parsed source. A string's
  # contents are not code, and the walk does not descend into a `catch_exit/1`.
  defp await_lines(source) do
    {:ok, ast} = Code.string_to_quoted(source)

    {_ast, lines} =
      Macro.prewalk(ast, [], fn
        {:catch_exit, _, [_]}, lines ->
          {:catch_exit_skipped, lines}

        {{:., _, [{:__aliases__, _, task}, name]}, meta, _args} = node, lines
        when task in [[:Task], [:"Elixir", :Task]] and name in @awaits ->
          {node, [Keyword.get(meta, :line) | lines]}

        node, lines ->
          {node, lines}
      end)

    Enum.sort(lines)
  end
end
