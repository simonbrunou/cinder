defmodule Cinder.CodeHealth.FenceFilesTest do
  # Threads add repo-wide fences in parallel. #1003 and #1005 each added one to
  # `test/code_health_test.exs` at the same spot and named it in that module's doc, so the second
  # to merge conflicted and needed a `main` merge, a full `mix test` and a second CI run. A new
  # fence goes in its own file under `test/code_health/`, which no other PR edits.
  use ExUnit.Case, async: true

  @path "test/code_health_test.exs"
  @tests 19

  test "test/code_health_test.exs gains no new test" do
    count = @path |> File.read!() |> test_count()

    assert count <= @tests,
           "#{@path} holds #{count} tests, more than #{@tests}. Add a new fence as its own " <>
             "file under test/code_health/ instead (docs/agents/testing.md)."
  end

  test "the count includes a test inside describe" do
    source = ~S'''
    defmodule M do
      test "top" do
      end

      describe "group" do
        test "nested", ctx do
        end
      end
    end
    '''

    assert test_count(source) == 2
  end

  test "the count skips a test spelled out inside a string" do
    source = ~S'''
    defmodule M do
      test "top" do
      end

      @source """
      test "in a heredoc" do
      end
      """
    end
    '''

    assert test_count(source) == 1
  end

  # Counts the `test` calls in the parsed source, wherever they sit. A string's contents are not
  # code, so a fixture that spells out a test inside a heredoc is not counted.
  defp test_count(source) do
    {:ok, ast} = Code.string_to_quoted(source)

    {_ast, count} =
      Macro.prewalk(ast, 0, fn
        {:test, _, [_name | _]} = node, count -> {node, count + 1}
        node, count -> {node, count}
      end)

    count
  end
end
