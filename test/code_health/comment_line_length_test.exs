defmodule Cinder.CodeHealth.CommentLineLengthTest do
  # Credo's `Readability.MaxLineLength` (120 characters) skips any line its URL pattern matches.
  # That pattern also matches a dot followed by a whole word of 2 to 6 lowercase letters, as in
  # `Task.start` or `config.exs`, so a long comment line naming such a function or file passes
  # `credo --strict`. Credo also never reads config/ or priv/, and `mix format` wraps code, never
  # comments. On #1029 an edit joined two comment lines into one of 153 characters, and only a
  # reviewer saw it. This fence measures each comment in lib/, test/, config/, priv/, scripts/,
  # mix.exs and .formatter.exs from the parser's own comment list, and skips a comment holding a
  # URL, as Credo means to.
  use ExUnit.Case, async: true

  @max 120

  test "no comment line runs past #{@max} characters" do
    paths =
      Path.wildcard("{lib,test,config,priv,scripts}/**/*.{ex,exs}") ++
        Path.wildcard("*.exs", match_dot: true)

    long =
      for path <- paths,
          {line, width} <- path |> File.read!() |> long_comments(),
          do: "#{path}:#{line}: #{width} characters"

    assert long == [],
           "These comment lines run past #{@max} characters. Wrap them at 98, the width " <>
             "mix format gives code:\n" <> Enum.join(long, "\n")
  end

  test "a comment counts from column 1, and a URL comment or a string's # does not" do
    over = "  # " <> String.duplicate("x", 117)
    at_max = "  # " <> String.duplicate("x", 116)
    url = "  # https://example.com/" <> String.duplicate("x", 120)

    source = """
    defmodule M do
    #{over}
      @doc \"\"\"
    #{over}
      \"\"\"
      def f, do: :ok
    #{url}
    #{at_max}
      def g, do: :ok # #{String.duplicate("x", 102)}
      def h, do: "#{over}"
    end
    """

    assert long_comments(source) == [{2, 121}, {9, 121}]
  end

  # The `{line, width}` of each comment wider than `@max`, counting the code before it on its
  # line. A `#` inside a string or heredoc is not a comment, so the parser does not list it.
  defp long_comments(source) do
    {:ok, _ast, comments} = Code.string_to_quoted_with_comments(source)

    for %{line: line, column: column, text: text} <- comments,
        not String.contains?(text, "://"),
        width = column - 1 + String.length(text),
        width > @max,
        do: {line, width}
  end
end
