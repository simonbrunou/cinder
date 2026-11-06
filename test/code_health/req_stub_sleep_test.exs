defmodule Cinder.CodeHealth.ReqStubSleepTest do
  # A `Req.Test` stub meant to answer after a deadline holds its answer until the test signals,
  # never until a sleep ends: a caller that wakes late reads an answer that came after the
  # deadline (docs/agents/testing.md). #1215's first LibreTranslate test slept 1 s in its stub
  # against a 200 ms deadline, and its Standards review caught it. The fence fails every
  # `Process.sleep/1` or `:timer.sleep/1` inside the `fn` given to `Req.Test.stub/2` or
  # `Req.Test.expect/2,3`, directly or through a local wrapper that passes one of its parameters
  # on as that `fn` (`defp stub(fun), do: Req.Test.stub(Cinder.SabnzbdStub, fun)`). A wrapper
  # matches each local call of its name and arity anywhere in the file. A sleep that ends in an
  # answer races the caller's deadline whichever side of it the sleep means to land.
  # `Process.sleep(:infinity)` and `:timer.sleep(:infinity)` pass, written so and not piped: that
  # stub never answers. Forms the walk does not follow include: a helper that the `fn` calls; a
  # stub given as a capture, a plug module or a variable other than a wrapper's parameter;
  # `Req.Test` under an alias; an answer timed by `receive ... after`; a call piped into a wrapper
  # or one that leaves out a wrapper's default argument; a wrapper that is a macro, has a block
  # besides `do` such as `rescue`, or calls another wrapper.
  use ExUnit.Case, async: true

  @req_test [[:Req, :Test], [:"Elixir", :Req, :Test]]
  @stub_calls [:stub, :expect]
  @process [[:Process], [:"Elixir", :Process]]

  test "no Req.Test stub sleeps before it answers" do
    scans =
      for path <- Path.wildcard("test/**/*.{ex,exs}"),
          do: {path, path |> File.read!() |> scan()}

    # A walk that matched no stub would pass the check below on nothing.
    assert Enum.sum_by(scans, fn {_path, scan} -> scan.stubs end) > 100

    sleeps = for {path, scan} <- scans, line <- scan.sleeps, do: "#{path}:#{line}"

    assert sleeps == [],
           "These Req.Test stubs sleep before they answer, so a caller that wakes late can " <>
             "read an answer that came after its deadline:\n" <>
             Enum.join(sleeps, "\n") <>
             "\nHold the answer until the test sends a signal, as answer_unless_killed/0 in " <>
             "Cinder.Subtitles.Translator.LibreTranslateTest does (docs/agents/testing.md)."
  end

  test "the walk finds each sleep form in a stub and skips one outside it, in a comment or a string" do
    source = ~S'''
    defmodule M do
      def a, do: Req.Test.stub(S, fn conn -> Process.sleep(10) && conn end)
      def b, do: Req.Test.expect(S, fn conn -> :timer.sleep(10) && conn end)
      def c, do: Req.Test.expect(S, 2, fn conn -> Elixir.Process.sleep(10) && conn end)
      def d, do: Elixir.Req.Test.stub(S, fn conn -> Process.sleep(10) && conn end)
      def e, do: S |> Req.Test.stub(fn conn -> 10 |> Process.sleep() && conn end)

      def f do
        Req.Test.stub(S, fn conn ->
          receive do
            :go -> conn
          after
            0 ->
              if conn,
                do:
                  Process.sleep(
                    10
                  )
          end
        end)
      end

      def g do
        Req.Test.stub(S, fn conn ->
          # Process.sleep(10)
          conn
        end)

        Process.sleep(10)
      end

      def h, do: Req.Test.stub(S, &handler/1)
      def i, do: Req.Test.stub(S, SomePlug)

      @doc """
      Req.Test.stub(S, fn conn -> Process.sleep(10) && conn end)
      """
      def j, do: :ok

      def k, do: Req.Test.stub(S, fn conn -> Other.sleep(10) && :other.sleep(10) && conn end)
      def l, do: Req.Test.stub(S, fn conn -> Process.sleep(:infinity) && conn end)
    end
    '''

    assert scan(source) == %{stubs: 11, sleeps: [2, 3, 4, 5, 6, 16]}
  end

  test "the walk follows a local wrapper that passes its parameter on as the stub's fn" do
    source = ~S'''
    defmodule M do
      defp stub(fun), do: Req.Test.stub(S, fun)
      defp expect_n(n, fun) when is_integer(n), do: Req.Test.expect(S, n, fun)
      defp named(fun), do: fun

      def a, do: stub(fn conn -> Process.sleep(10) && conn end)
      def b, do: expect_n(2, fn conn -> Process.sleep(10) && conn end)
      def c, do: named(fn conn -> Process.sleep(10) && conn end)
      def d, do: stub(fn conn -> conn end)
      def e, do: stub(S, fn conn -> Process.sleep(10) && conn end)
      defp setup(%{} = _ctx), do: Req.Test.stub(S, fn conn -> conn end)
      def f, do: setup(fn -> Process.sleep(10) end)
    end
    '''

    assert scan(source) == %{stubs: 6, sleeps: [6, 7]}
  end

  # The number of stub calls in the parsed source, direct or through a local wrapper, and the
  # lines of the sleeps inside their `fn` arguments. A string's contents and a comment are not code.
  defp scan(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    wrappers = wrappers(ast)

    {_ast, acc} =
      Macro.prewalk(ast, %{stubs: 0, sleeps: []}, fn
        # A wrapper's own head, `stub(fun)`, is not a call to it: walk the body alone.
        {kind, meta, [_head, body]}, acc when kind in [:def, :defp] ->
          {{kind, meta, [body]}, acc}

        node, acc ->
          case stub_fn(node, wrappers) do
            {:ok, fun} -> {node, %{stubs: acc.stubs + 1, sleeps: sleep_lines(fun) ++ acc.sleeps}}
            :error -> {node, acc}
          end
      end)

    %{acc | sleeps: Enum.sort(acc.sleeps)}
  end

  # The `fn` a stub call receives: the last argument of `Req.Test.stub/expect`, or the argument a
  # local wrapper passes on.
  defp stub_fn({{:., _, [{:__aliases__, _, req_test}, name]}, _meta, [_ | _] = args}, _wrappers)
       when req_test in @req_test and name in @stub_calls,
       do: {:ok, List.last(args)}

  defp stub_fn({name, _meta, args}, wrappers) when is_atom(name) and is_list(args) do
    case Map.fetch(wrappers, {name, length(args)}) do
      {:ok, index} -> {:ok, Enum.at(args, index)}
      :error -> :error
    end
  end

  defp stub_fn(_node, _wrappers), do: :error

  # `{name, arity} => index` for each `def`/`defp` whose body passes its parameter at `index` as
  # the last argument of a `Req.Test.stub/expect` call.
  defp wrappers(ast) do
    {_ast, wrappers} =
      Macro.prewalk(ast, %{}, fn
        {kind, _, [head, [do: body]]} = node, wrappers when kind in [:def, :defp] ->
          {node, Map.merge(wrappers, wrapper(head, body))}

        node, wrappers ->
          {node, wrappers}
      end)

    wrappers
  end

  defp wrapper({:when, _, [head, _guard]}, body), do: wrapper(head, body)

  defp wrapper({name, _, params}, body) when is_atom(name) and is_list(params) do
    names = Enum.map(params, &var_name/1)

    {_ast, indexes} =
      Macro.prewalk(body, [], fn node, indexes ->
        with {:ok, last} <- stub_fn(node, %{}),
             var when is_atom(var) and not is_nil(var) <- var_name(last),
             index when is_integer(index) <- Enum.find_index(names, &(&1 == var)) do
          {node, [index | indexes]}
        else
          _not_passed_on -> {node, indexes}
        end
      end)

    case indexes do
      [index | _] -> %{{name, length(params)} => index}
      [] -> %{}
    end
  end

  defp wrapper(_head, _body), do: %{}

  defp var_name({name, _, context}) when is_atom(name) and is_atom(context), do: name
  defp var_name(_ast), do: nil

  defp sleep_lines({:fn, _, _} = fun) do
    {_ast, lines} =
      Macro.prewalk(fun, [], fn
        {{:., _, [module, :sleep]}, meta, args} = node, lines ->
          if sleeper?(module) and args != [:infinity],
            do: {node, [Keyword.get(meta, :line) | lines]},
            else: {node, lines}

        node, lines ->
          {node, lines}
      end)

    lines
  end

  defp sleep_lines(_stub), do: []

  defp sleeper?({:__aliases__, _, process}), do: process in @process
  defp sleeper?(:timer), do: true
  defp sleeper?(_module), do: false
end
