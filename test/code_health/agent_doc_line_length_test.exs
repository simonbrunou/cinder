defmodule Cinder.CodeHealth.AgentDocLineLengthTest do
  # The agent docs under docs/agents/ wrap their prose at 100 columns, and no formatter rewraps
  # Markdown. On #1347 (for #1301) an edit that inserted two sentences into ci.md's "Wall-clock
  # tests" bullet left a 109-character line, which only the Spec reviewer saw, and the next edit
  # joined two lines into one of 143. The ADRs under docs/adr/ and the changelog.d/ fragments
  # wrap at 100 too: on #839 an edit joined two ADR lines into ones of 148 and 137, which only the
  # Spec reviewer saw, and on #1308 and #1368 (for #913) a fragment's width took hand rewraps.
  # This fence fails a prose line over 100 characters. It skips a line inside a ``` block, a
  # table row, a line holding a URL, and a line holding a code span that, at the line's indent
  # and with one character after it, does not fit in 100 columns, such as a whole `curl` command:
  # no rewrap brings that line under 100. It reads the Markdown line by line, since each prose
  # line is one unit of the wrap. It pairs each run of backticks with the next run of the same
  # length on the line. It fails on the forms it does not read: a ~~~ fence and a backtick run
  # with no partner on its line, such as a code span split across two lines. It reads an
  # indented code block as prose, so a long line there fails too; the docs use none today.
  use ExUnit.Case, async: true

  @max 100

  test "no prose line in docs/agents, docs/adr or changelog.d runs past #{@max} characters" do
    dirs = ["docs/agents", "docs/adr", "changelog.d"]
    paths = Enum.flat_map(dirs, &Path.wildcard("#{&1}/*.md"))

    # A wrong glob would pass the check below on nothing.
    for dir <- dirs do
      assert Enum.any?(paths, &String.starts_with?(&1, dir <> "/")), "no Markdown file in #{dir}"
    end

    found =
      for path <- paths,
          {line, what} <- path |> File.read!() |> long_lines(),
          do: "#{path}:#{line}: #{describe(what)}"

    assert found == [],
           "Wrap these prose lines at #{@max}, and keep each code span on one line inside a " <>
             "``` block or a pair of backtick runs:\n" <> Enum.join(found, "\n")
  end

  test "a prose line counts, and the lines a rewrap cannot shorten do not" do
    over = String.duplicate("x", @max + 1)
    at_max = String.duplicate("x", @max)
    span = "`" <> String.duplicate("y", @max - 2) <> "`"
    short_span = "`" <> String.duplicate("y", @max - 3) <> "`"
    indented_span = "`" <> String.duplicate("y", @max - 4) <> "`"

    source = """
    #{over}
    #{at_max}
    ```sh
    #{over}
    ```
    | #{over} |
    see https://example.com/#{over}
    #{span},
    #{short_span} x
      - #{over}
      #{indented_span}, x
    #{String.duplicate("z", 60)} `test/cinder/library/imported_quality_test.exs`
    """

    assert long_lines(source) == [
             {1, @max + 1},
             {9, @max + 1},
             {10, @max + 5},
             {12, 108}
           ]
  end

  test "a 109-character line fails, as the one the Spec reviewer caught on #1347 did" do
    assert long_lines("intro\n  " <> String.duplicate("x", 107) <> "\n") == [{2, 109}]
  end

  test "pairs backtick runs by length, fails on the forms it does not read, reads an indented block" do
    double = "`` ` `` and `a` " <> String.duplicate("x", @max)
    indented = "    " <> String.duplicate("i", @max)

    source = """
    #{double}
    a span opens `here and
    closes` on the next line
    ~~~
    ```elixir
    ~~~ inside a code block
    ```

    #{indented}
    """

    assert long_lines(source) == [
             {1, String.length(double)},
             {2, :unpaired_backtick},
             {3, :unpaired_backtick},
             {4, :tilde_fence},
             {9, @max + 4}
           ]
  end

  defp describe(width) when is_integer(width), do: "#{width} characters"
  defp describe(:tilde_fence), do: "a ~~~ fence, which this fence does not read: use ```"
  defp describe(:unpaired_backtick), do: "a backtick run with no partner on its line"

  # The `{line, width}` of each prose line wider than `@max`, and `{line, form}` for each line
  # in a form the fence does not read. A line that opens or closes a ``` block flips the state,
  # and the lines between are code.
  defp long_lines(source) do
    {found, _in_code} =
      source
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.reduce({[], false}, fn {text, line}, {found, in_code} ->
        trimmed = String.trim_leading(text)

        cond do
          String.starts_with?(trimmed, "```") -> {found, not in_code}
          in_code -> {found, in_code}
          String.starts_with?(trimmed, "~~~") -> {[{line, :tilde_fence} | found], in_code}
          true -> {check(text, line, found), in_code}
        end
      end)

    Enum.reverse(found)
  end

  defp check(text, line, found) do
    case spans(text) do
      :unpaired ->
        [{line, :unpaired_backtick} | found]

      {:ok, spans} ->
        if long?(text, spans), do: [{line, String.length(text)} | found], else: found
    end
  end

  defp long?(text, spans) do
    trimmed = String.trim_leading(text)
    indent = String.length(text) - String.length(trimmed)

    String.length(text) > @max and not String.starts_with?(trimmed, "|") and
      not String.contains?(text, "://") and
      not Enum.any?(spans, &(indent + String.length(&1) >= @max))
  end

  # The code spans of a line: each run of backticks with the next run of the same length.
  defp spans(text) do
    text |> String.split(~r/`+/, include_captures: true) |> pair([])
  end

  defp pair([], spans), do: {:ok, spans}

  defp pair(["`" <> _ = run | rest], spans) do
    case Enum.split_while(rest, &(&1 != run)) do
      {_inner, []} -> :unpaired
      {inner, [^run | tail]} -> pair(tail, [run <> Enum.join(inner) <> run | spans])
    end
  end

  defp pair([_text | rest], spans), do: pair(rest, spans)
end
