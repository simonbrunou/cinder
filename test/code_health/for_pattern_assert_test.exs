defmodule Cinder.CodeHealth.ForPatternAssertTest do
  # A `for` generator skips each element its pattern does not match, so in
  # `for {:error, changeset} <- results, do: assert ...` an `{:ok, _}` result is skipped and its
  # assertion never runs. On #1697 (PR #1823) a test of the refused secrets save looped that way
  # over its results, and the Standards review found that a save that wrongly succeeded would
  # pass. Bind each element to a variable and match it in the body, where a wrong element fails:
  # `for result <- results do {:error, changeset} = result ... end`. When the skip is meant,
  # filter with `match?/2` in a filter argument and assert the count kept, as
  # `test/cinder/books/corpus_b2b_test.exs` does.
  #
  # The fence fails a `for` in a test file when a generator's pattern is a tuple tagged `:ok` or
  # `:error`, also under `=` or a `when` guard, and the body calls an assertion: `assert`, `refute`,
  # `flunk`, or any call whose name starts with `assert` or `refute` (ExUnit's `assert_receive`,
  # a helper such as `assert_dropped`), local or remote, piped or captured. Other patterns that
  # can refuse an element are left alone: across `test/` on 2026-11-26 they matched 21 loops,
  # each over a list whose elements all match (a map pattern over rows of one shape) or a skip
  # its test meant (a pinned join, a `{group, :resolvable}` filter).
  #
  # Forms the walk does not follow include: a tag other than `:ok` or `:error`, or one nested
  # inside another pattern (`{id, {:ok, value}}`); a map, struct, list, literal or pinned
  # pattern; a filter argument, which states its skip; an assertion in a function the body calls
  # whose name does not start with `assert` or `refute`; an assertion on the loop's value outside
  # its body (`assert Enum.all?(for {:ok, x} <- results, do: x > 0)`); a bitstring generator.
  use ExUnit.Case, async: true

  test "no for loop in a test skips an assertion on an element its :ok or :error tag refuses" do
    offenders =
      for path <- Path.wildcard("test/**/*.{ex,exs}"),
          line <- path |> File.read!() |> skipping_lines(path),
          do: "#{path}:#{line}"

    assert offenders == [],
           "These for loops assert only on the elements their generator's :ok or :error " <>
             "pattern matches and skip the rest, so a wrong result passes. Bind each element " <>
             "to a variable and match it in the body: `for result <- results do " <>
             "{:error, changeset} = result ... end`. When the skip is meant, filter with " <>
             "match?/2 and assert the count kept:\n  " <> Enum.join(offenders, "\n  ")
  end

  test "the scan finds each tagged pattern before an assertion" do
    source = ~S'''
    for {:error, changeset} <- results, do: assert changeset.errors != []
    for {:ok, _} = ok <- results do
      assert ok
    end
    for ok = {:ok, _} <- results, do: refute is_nil(ok)
    for {:ok, a, b} <- rows, do: assert a == b
    for {:error, e} when is_atom(e) <- results, do: assert_dropped(e, :x)
    for {:ok, row} <- rows, do: ExUnit.Assertions.assert(row)
    for {:error, e} <- results, do: assert_receive {:done, ^e}
    for {:error, key} <- pairs, do: flunk(key)
    for x <- xs,
        {:error,
         reason} <- f(x) do
      refute_received {:ok, ^reason}
    end
    for {:error, e} <- results, reduce: 0 do
      acc -> assert e && acc
    end
    for {:error, e} <- results, into: %{} do
      if e, do: Assertions.assert(e)
      {e, e}
    end
    for {:error, e} <- results, do: Enum.each(e, &assert(&1))
    for {:error, e} <- results, into: [], do: assert e
    for {:error, e} <- results, do: e |> assert()
    for {:error, e} <- results, do: Enum.each(e, &assert/1)
    for {:ok, a, b, c} <- rows, do: assert a == b + c
    '''

    assert skipping_lines(source) == [1, 2, 5, 6, 7, 8, 9, 10, 13, 16, 19, 23, 24, 25, 26, 27]
  end

  test "the scan skips other patterns, loops without an assertion, comments and strings" do
    source = ~S'''
    for result <- results do
      assert {:error, _} = result
    end
    for _ <- 1..3, do: assert true
    for {key, value} <- map, do: assert key == value
    for %{name: name} <- rows, do: assert name
    for {:done, x} <- xs, do: assert x
    for {id, {:ok, x}} <- xs, do: assert id == x
    for %Row{ok: x} <- rows, do: assert x
    for [:ok, x] <- rows, do: assert x
    for :ok <- results, do: assert true
    for ^expected <- results, do: assert expected
    assert Enum.all?(for {:ok, x} <- results, do: x > 0)
    for {:ok, x} <- xs, do: send(self(), x)
    for {:ok, assert_total} <- xs, do: assert_total / 2
    for {:error, problem} <- read, do: problem
    for r <- results, match?({:ok, _}, r), do: assert r
    for <<c <- "abc">>, do: assert c
    # for {:error, e} <- results, do: assert e
    IO.puts("for {:error, e} <- results, do: assert e")
    """
    for {:error, e} <- results, do: assert e
    """
    '''

    assert skipping_lines(source) == []
  end

  # The line of each generator with an `:ok` or `:error` tagged pattern, in a `for` whose body
  # calls an assertion.
  defp skipping_lines(source, file \\ "nofile") do
    {_, lines} =
      source
      |> Code.string_to_quoted!(file: file)
      |> Macro.prewalk([], &{&1, skipping_line(&1) ++ &2})

    lines |> Enum.uniq() |> Enum.sort()
  end

  defp skipping_line({:for, _, args}) when is_list(args) do
    bodies = for options <- args, Keyword.keyword?(options), {:do, body} <- options, do: body

    if asserts?(bodies) do
      for {:<-, meta, [pattern, _enumerable]} <- args, tagged?(pattern), do: meta[:line]
    else
      []
    end
  end

  defp skipping_line(_), do: []

  defp tagged?({:=, _, [left, right]}), do: tagged?(left) or tagged?(right)
  defp tagged?({:when, _, [pattern, _guard]}), do: tagged?(pattern)
  defp tagged?({tag, _value}) when tag in [:ok, :error], do: true
  defp tagged?({:{}, _, [tag | _values]}) when tag in [:ok, :error], do: true
  defp tagged?(_), do: false

  defp asserts?(ast) do
    {_, found?} = Macro.prewalk(ast, false, &{&1, &2 or assertion?(&1)})
    found?
  end

  defp assertion?({{:., _, [_module, name]}, _, args}) when is_atom(name) and is_list(args),
    do: assertion_name?(name)

  # A local capture, `&assert/1`: its name is a variable-shaped node under `&` and `/`.
  defp assertion?({:&, _, [{:/, _, [{name, _, context}, arity]}]})
       when is_atom(name) and is_atom(context) and is_integer(arity),
       do: assertion_name?(name)

  defp assertion?({name, _, args}) when is_atom(name) and is_list(args),
    do: assertion_name?(name)

  defp assertion?(_), do: false

  defp assertion_name?(name) do
    name = Atom.to_string(name)
    name == "flunk" or String.starts_with?(name, ["assert", "refute"])
  end
end
