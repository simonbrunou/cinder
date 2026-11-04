defmodule Cinder.CodeHealth.AssertMatchMessageTest do
  # ExUnit's `assert/2` and `refute/2` are functions, so in `assert {:ok, _} = call(), "message"`
  # the match runs before assert gets the message. A value that does not match raises a
  # MatchError, and the message never prints. On #1135 three messages in a new test never
  # printed; the #895 thread had met the same form (nix#79). Write ExUnit's documented form,
  # `assert match?({:ok, _}, call()), "message"`, or drop the message: `assert {:ok, _} = call()`
  # prints the pattern and the value. A bare variable always matches, so `assert value = call(),
  # "message"` still prints its message when the value is falsy, and the fence allows it.
  use ExUnit.Case, async: true

  test "no assert or refute takes a message after a pattern match" do
    offenders =
      for path <- Path.wildcard("test/**/*.{ex,exs}"),
          line <- path |> File.read!() |> dead_message_lines(path),
          do: "#{path}:#{line}"

    assert offenders == [],
           "These asserts match a pattern before their message, so a value that does not " <>
             "match raises a MatchError and the message never prints. Write " <>
             "`assert match?(pattern, expr), message`, with the value in the message when the " <>
             "message names only the input. When the pattern binds a variable used later, " <>
             "bind the value first, assert match? on it, then match it: " <>
             "`result = expr`, `assert match?({:ok, _}, result), message`, " <>
             "`{:ok, value} = result`. Or drop the message:\n  " <>
             Enum.join(offenders, "\n  ")
  end

  test "the scan finds each form of the dead message" do
    source = ~S'''
    assert {:ok, _} = call(), "message"
    assert(%{a: 1} = call(), "message")
    refute {:error, _} = call(), "message"
    assert {:ok, ^pinned} =
             call(),
           "message"
    assert [_ | _] = list, label
    assert value = {:ok, _} = call(), "message"
    assert ready? and ({:ok, _} = call()), "message"
    refute ({:ok, _} = call()) && true, "message"
    assert Enum.all?(xs, fn x -> {:ok, _} = f(x) end), "message"
    ExUnit.Assertions.assert({:ok, _} = call(), "message")
    ({:ok, _} = call()) |> assert("message")
    assert {:ok, _} = call(), message: "message"
    assert (cond do
              {:ok, _} = call() -> true
              true -> false
            end),
           "message"
    ({:ok, _} = call()) |> ExUnit.Assertions.assert("message")
    Assertions.assert({:ok, _} = call(), "message")
    assert quote(do: unquote({:ok, _} = call())), "message"
    assert quote(bind_quoted: [x: {:ok, _} = call()], do: x), "message"
    '''

    assert dead_message_lines(source) ==
             [1, 2, 3, 4, 7, 8, 9, 10, 11, 12, 13, 14, 15, 20, 21, 22, 23]
  end

  test "the scan skips other asserts, comments and strings" do
    source = ~S'''
    assert {:ok, _} = call()
    assert match?({:ok, _}, call()), "message"
    assert value = call(), "a falsy value prints this"
    assert (value = call()) == :ok, "message"
    assert match?({:ok, _} = whole, call()), "message"
    assert Enum.all?(xs, fn %{} = x -> x.ok end), "message"
    assert for(%{} = m <- xs, do: m), "message"
    assert (with {:ok, _} = w <- call(), do: w), "message"
    assert quote(do: {:ok, _} = call()), "message"
    assert Kernel.match?({:ok, _} = whole, call()), "message"
    assert call() == :ok, "message"
    # assert {:ok, _} = call(), "message"
    IO.puts("assert {:ok, _} = call(), \"message\"")
    """
    assert {:ok, _} = call(), "message"
    """
    '''

    assert dead_message_lines(source) == []
  end

  # The line of each assert or refute that takes a message (or options) after its first argument
  # and whose first argument holds a match that can raise: one whose left side is not a bare
  # variable. Local, remote (`ExUnit.Assertions.assert`, or `Assertions.assert` after an alias)
  # and piped calls count alike.
  defp dead_message_lines(source, file \\ "nofile") do
    {_, lines} =
      source
      |> Code.string_to_quoted!(file: file)
      |> Macro.prewalk([], &{&1, dead_message_line(&1) ++ &2})

    lines |> Enum.uniq() |> Enum.sort()
  end

  defp dead_message_line(node) do
    case assertion(node) do
      {line, argument} -> if raises?(argument), do: [line], else: []
      nil -> []
    end
  end

  # The pipe comes first: `a |> assert(m)` is also a call with two arguments.
  defp assertion({:|>, meta, [argument, {callee, _, [_message]}]}),
    do: if(assert_callee?(callee), do: {meta[:line], argument})

  defp assertion({callee, meta, [argument, _message]}),
    do: if(assert_callee?(callee), do: {meta[:line], argument})

  defp assertion(_), do: nil

  defp assert_callee?(name) when name in [:assert, :refute], do: true

  defp assert_callee?({:., _, [{:__aliases__, _, alias}, name]}) when name in [:assert, :refute],
    do: alias in [[:ExUnit, :Assertions], [:Assertions]]

  defp assert_callee?(_), do: false

  # A match raises unless its left side is a bare variable. A `match?` pattern, a `<-` pattern
  # and a `fn`, `case` or `receive` clause head never raise a MatchError, so the walk skips them.
  # Quoted code does not run either, but its `unquote` arguments and `bind_quoted:` values do. A
  # `cond` clause head is an expression that runs, so the walk reads it.
  defp raises?({:=, _, [left, right]}), do: not bare_variable?(left) or raises?(right)
  defp raises?({:match?, _, [_pattern, expression]}), do: raises?(expression)

  defp raises?({{:., _, [{:__aliases__, _, [:Kernel]}, :match?]}, _, [_pattern, expression]}),
    do: raises?(expression)

  defp raises?({:<-, _, [_pattern, expression]}), do: raises?(expression)
  defp raises?({:quote, _, args}), do: unquoted_raises?(args)

  defp raises?({:cond, _, [[do: clauses]]}),
    do: Enum.any?(clauses, fn {:->, _, [[head], body]} -> raises?(head) or raises?(body) end)

  defp raises?({:->, _, [_heads, body]}), do: raises?(body)
  defp raises?({call, _, args}) when is_list(args), do: raises?(call) or raises?(args)
  defp raises?({left, right}), do: raises?(left) or raises?(right)
  defp raises?(list) when is_list(list), do: Enum.any?(list, &raises?/1)
  defp raises?(_), do: false

  defp unquoted_raises?({name, _, [argument]}) when name in [:unquote, :unquote_splicing],
    do: raises?(argument)

  defp unquoted_raises?({:bind_quoted, bindings}), do: raises?(bindings)

  defp unquoted_raises?({call, _, args}) when is_list(args),
    do: unquoted_raises?(call) or unquoted_raises?(args)

  defp unquoted_raises?({left, right}), do: unquoted_raises?(left) or unquoted_raises?(right)
  defp unquoted_raises?(list) when is_list(list), do: Enum.any?(list, &unquoted_raises?/1)
  defp unquoted_raises?(_), do: false

  defp bare_variable?({name, _, context}) when is_atom(name) and is_atom(context), do: true
  defp bare_variable?(_), do: false
end
