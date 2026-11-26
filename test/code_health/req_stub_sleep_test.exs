defmodule Cinder.CodeHealth.ReqStubSleepTest do
  # A `Req.Test` stub meant to answer after a deadline holds its answer until the test signals,
  # never until a sleep ends: a caller that wakes late reads an answer that came after the
  # deadline (docs/agents/testing.md). #1215's first LibreTranslate test slept 1 s in its stub
  # against a 200 ms deadline, and its Standards review caught it. A sleep that ends in an answer
  # races the caller's deadline whichever side of it the sleep means to land.
  #
  # The fence fails every `Process.sleep/1` or `:timer.sleep/1` inside a `fn` in the argument of
  # a stub call. `Process.sleep(:infinity)` and `:timer.sleep(:infinity)` pass, written so and not
  # piped: that stub never answers. A stub call is one of these, written out or piped:
  # - `Req.Test.stub/2` or `Req.Test.expect/2,3`, whose argument is its last one;
  # - `Cinder.NewznabFixtures.route/1`, qualified, or bare in a file that imports that module, whose
  #   stub calls each `fn` of the map it gets;
  # - a call of a local wrapper, a `def` or `defp` whose body passes one of its parameters to a
  #   stub call, or names it inside that argument (`defp stub(fun), do: Req.Test.stub(S, fun)`).
  #   It matches each local call of its name and arity anywhere in the file, and its argument is
  #   what the caller passes at those parameters.
  # In the argument, the walk reads each `fn` literal, also one inside another call
  # (`wrap(fn ... end)`). Where the argument, a value of its map literal or a wrapper's argument is
  # a variable the file binds to a literal `fn` or map, or a call or bare name of a local function
  # of arity 0 (`healthy_route()`), it reads what that holds the same way. A variable reads as
  # every binding of its name in the file, so a sleep in another test's `fn` of that name fails it
  # too.
  #
  # Forms the walk does not follow include: a helper that the `fn` calls, such as a loop that
  # spins until a clock time (#1755 and #1758's first draft held stubs so); a stub or a map value
  # given as a capture (`&answer/2`) or a plug module; a variable bound to anything else, one that
  # comes in through a test's context, or one inside another call or a map update
  # (`wrap(answer)`, `%{base | "a" => answer}`); a local function with arguments that returns a
  # `fn`; an answer timed by `receive ... after`; a function that passes on a parameter with a
  # default, and a call that leaves out a wrapper's default argument; a wrapper that is a
  # macro or calls another wrapper; a stub call on a quoted module atom
  # (`:"Elixir.Req.Test".stub/2`); an import of `Cinder.NewznabFixtures` inside a `quote`, such as
  # a case template's `using`, which leaves the files that use it unread.
  #
  # A file that aliases or imports `Req` or a module under it, requires one with `as:`, or names
  # `Cinder.NewznabFixtures` in such a form or in an import other than
  # `import Cinder.NewznabFixtures`, fails the test "no test file renames Req.Test or the Newznab
  # fixtures". A `test/support` function or macro other than `route/1` that installs a stub fails
  # "each test/support function that installs a Req.Test stub is one the walk follows".
  use ExUnit.Case, async: true

  @req_test [[:Req, :Test], [:"Elixir", :Req, :Test]]
  @stub_calls [:stub, :expect]
  @process [[:Process], [:"Elixir", :Process]]
  @fixtures [[:Cinder, :NewznabFixtures], [:"Elixir", :Cinder, :NewznabFixtures]]

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
             "\nHold the answer until the test sends a signal, as the stub in " <>
             "Cinder.HTTPPolicyTest \"gives each of two concurrent calls its own request " <>
             "task event\" does (docs/agents/testing.md)."
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

  test "the walk follows each fn in the map given to the imported Newznab fixtures' route/1" do
    source = ~S'''
    defmodule M do
      import Cinder.NewznabFixtures, only: [route: 1]

      def a, do: route(%{"a" => fn _conn, _query -> Process.sleep(10) && :default end})
      def b, do: route(%{"b" => fn _, _ -> :default end, "c" => fn _, _ -> :timer.sleep(10) end})
      def c, do: route(%{"d" => fn _c, _q -> Enum.each([1], fn _ -> Process.sleep(10) end) end})
      def d, do: route(%{"e" => fn _conn, _query -> Process.sleep(:infinity) end})
      def e, do: route(%{"f" => healthy_route()})
      def f(answer), do: route(%{"g" => answer})
    end
    '''

    assert scan(source) == %{stubs: 6, sleeps: [4, 5, 6]}
  end

  test "the walk follows a qualified route/1 and leaves a route/1 in a file without the import" do
    source = ~S'''
    defmodule M do
      import Other.Fixtures

      def a, do: route(%{"a" => fn _conn, _query -> Process.sleep(10) end})
      def b, do: Cinder.NewznabFixtures.route(%{"b" => fn _c, _q -> Process.sleep(10) end})
      def c, do: Elixir.Cinder.NewznabFixtures.route(%{"c" => fn _c, _q -> Process.sleep(10) end})
      alias Cinder.NewznabFixtures
      def d, do: NewznabFixtures.route(%{"d" => fn _conn, _query -> Process.sleep(10) end})
    end
    '''

    assert scan(source) == %{stubs: 2, sleeps: [5, 6]}
  end

  test "the walk follows a route/1 map value or a stub argument held by a variable or a function" do
    source = ~S"""
    defmodule M do
      import Cinder.NewznabFixtures

      defp held, do: fn _conn, _query -> Process.sleep(10) end
      defp answering(answer), do: route(%{"a" => fn _c, q -> answer.(q) end})
      def a, do: route(%{"b" => held()})
      def b, do: route(%{"c" => held})

      def c do
        answer = fn _conn, _query -> :timer.sleep(10) end
        route(%{"d" => answer})
      end

      def d, do: answering(fn _query -> Process.sleep(10) end)
      def e, do: answering(fn _query -> [] end)

      def f do
        routes = %{"e" => fn _conn, _query -> Process.sleep(10) end, "x" => held()}
        route(routes)
      end

      def g, do: %{"f" => fn _conn, _query -> Process.sleep(10) end} |> route()

      def h do
        handler = fn conn -> Process.sleep(10) && conn end
        Req.Test.stub(S, handler)
      end

      defp guarded(fun) do
        Req.Test.stub(S, fun)
      rescue
        _error -> :ok
      end

      def i, do: guarded(fn conn -> Process.sleep(10) && conn end)
      def j, do: route(%{"g" => wrap(fn _conn, _query -> Process.sleep(10) end)})
      def k, do: route(%{"h" => &answer/2})

      def l do
        answer = fn _query -> Process.sleep(10) end
        answer
      end

      defp piped(table), do: table |> route()
      def m, do: piped(%{"i" => fn _conn, _query -> Process.sleep(10) end})
      defp held_parens(), do: fn _conn, _query -> Process.sleep(10) end
      def n, do: route(%{"j" => held_parens()})
      defp k_routes, do: %{"k" => held()}
      def o, do: route(k_routes())
      defp self_ref, do: %{"z" => self_ref()}
      def p, do: route(self_ref())
      defp ping, do: pong()
      defp pong, do: ping()
      def q, do: route(%{"y" => ping()})

      def r do
        loop = %{}
        loop = %{"w" => loop}
        route(loop)
      end

      def s, do: :"Elixir.Req.Test".stub(S, fn conn -> Process.sleep(10) && conn end)
    end
    """

    assert scan(source) ==
             %{stubs: 20, sleeps: [4, 4, 4, 4, 10, 14, 18, 22, 25, 35, 36, 40, 45, 46]}
  end

  test "each test/support function that installs a Req.Test stub is one the walk follows" do
    helpers =
      for path <- Path.wildcard("test/support/**/*.{ex,exs}"),
          helper <- path |> File.read!() |> stub_helpers(),
          do: {path, helper}

    assert helpers == [{"test/support/newznab_fixtures.ex", {:route, 1}}],
           "The walk follows Cinder.NewznabFixtures.route/1 alone among test/support's " <>
             "functions that install a Req.Test stub. A caller's fn given to any other one " <>
             "can sleep unseen. Teach scan/1 the new one, as it reads route/1, or list it " <>
             "here once its stub calls no fn its caller gives:\n" <>
             Enum.map_join(helpers, "\n", fn {path, {name, arity}} ->
               "#{path}: #{name}/#{arity}"
             end)
  end

  test "stub_helpers/1 lists each function or macro whose body installs a stub" do
    source = ~S"""
    defmodule M do
      import Cinder.NewznabFixtures

      def a(routes), do: Req.Test.stub(S, fn conn -> routes && conn end)
      defp b(n, fun) when is_integer(n), do: Elixir.Req.Test.expect(S, n, fun)
      def c, do: Req.Test.json(:conn, %{})
      def d(x), do: x
      def e(host, fun), do: route(%{host => fun})
      defmacro f(fun), do: quote(do: Req.Test.stub(S, unquote(fun)))

      def g(fun) do
        Req.Test.stub(S, fun)
      rescue
        _error -> :ok
      end

      def h(routes), do: routes |> Cinder.NewznabFixtures.route()
    end
    """

    assert stub_helpers(source) == [{:a, 1}, {:b, 2}, {:e, 2}, {:f, 1}, {:g, 1}, {:h, 1}]

    own = ~S"""
    defmodule Cinder.NewznabFixtures do
      def route(routes), do: Req.Test.stub(S, fn conn -> routes && conn end)
      def route_all(host, fun), do: route(%{host => fun})
    end
    """

    assert stub_helpers(own) == [{:route, 1}, {:route_all, 2}]

    other = ~S"""
    defmodule Other do
      def route_all(host, fun), do: route(%{host => fun})
    end
    """

    assert stub_helpers(other) == []
  end

  test "no test file renames Req.Test or the Newznab fixtures" do
    renames =
      for path <- Path.wildcard("test/**/*.{ex,exs}"),
          line <- path |> File.read!() |> renames(),
          do: "#{path}:#{line}"

    assert renames == [],
           "The walk knows Req.Test and Cinder.NewznabFixtures by their full names and " <>
             "`import Cinder.NewznabFixtures` alone, so a stub call under another name can " <>
             "sleep unseen. Write the full name, with no alias or `as:`, instead of these:\n" <>
             Enum.join(renames, "\n")
  end

  test "renames/1 finds each alias, import or require-as of Req or the fixtures, but one import" do
    source = ~S"""
    defmodule M do
      import Cinder.NewznabFixtures
      alias Req.Test
      alias Req.Test, as: T
      import Req.Test
      alias Cinder.NewznabFixtures
      alias Cinder.{NewznabFixtures}
      import Elixir.Cinder.NewznabFixtures, only: [route: 1]
      alias Cinder.Request
      import Plug.Conn
      alias Req
      require Req.Test, as: R
      require Req.Test
      require Req.Test, warn: false
      alias :"Elixir.Req.Test", as: Q
      require :"Elixir.Cinder.NewznabFixtures", as: F
      alias :"Elixir.Plug.Conn", as: C
    end
    """

    assert renames(source) == [3, 4, 5, 6, 7, 11, 12, 15, 16]
  end

  # The number of stub calls in the parsed source, direct or through a local wrapper, and the
  # lines of the sleeps inside their `fn` arguments. A string's contents and a comment are not code.
  defp scan(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    imported = imported_wrappers(ast)
    wrappers = Map.merge(imported, wrappers(ast, imported))
    names = %{bound: bound_fns(ast), defs: zero_arity_bodies(ast)}

    {_ast, acc} =
      Macro.prewalk(ast, %{stubs: 0, sleeps: []}, fn
        # A wrapper's own head, `stub(fun)`, is not a call to it: walk the body alone.
        {kind, meta, [_head, body]}, acc when kind in [:def, :defp] ->
          {{kind, meta, [body]}, acc}

        # A piped call goes on unpiped, so its inner call is not counted again.
        node, acc ->
          call = unpipe(node)

          case stub_fn(call, wrappers) do
            {:ok, fun} ->
              sleeps = fun |> resolve(names) |> sleep_lines()
              {call, %{stubs: acc.stubs + 1, sleeps: sleeps ++ acc.sleeps}}

            :error ->
              {node, acc}
          end
      end)

    %{acc | sleeps: Enum.sort(acc.sleeps)}
  end

  # `x |> f(y)` as `f(x, y)`, so a piped stub call or wrapper call reads as written out.
  defp unpipe({:|>, _, [left, {call, meta, args}]}) when is_list(args),
    do: {call, meta, [left | args]}

  defp unpipe(node), do: node

  # The `fn` a stub call receives: the last argument of `Req.Test.stub/expect`, or the arguments a
  # local wrapper passes on. For `Cinder.NewznabFixtures.route/1` it is the map whose `fn`s that
  # helper's stub calls.
  defp stub_fn({{:., _, [{:__aliases__, _, req_test}, name]}, _meta, [_ | _] = args}, _wrappers)
       when req_test in @req_test and name in @stub_calls,
       do: {:ok, List.last(args)}

  defp stub_fn({{:., _, [{:__aliases__, _, fixtures}, :route]}, _meta, [routes]}, _wrappers)
       when fixtures in @fixtures,
       do: {:ok, routes}

  defp stub_fn({name, _meta, args}, wrappers) when is_atom(name) and is_list(args) do
    case Map.fetch(wrappers, {name, length(args)}) do
      {:ok, indexes} -> {:ok, {:__block__, [], Enum.map(indexes, &Enum.at(args, &1))}}
      :error -> :error
    end
  end

  defp stub_fn(_node, _wrappers), do: :error

  # `{name, arity} => indexes` for each `def`/`defp` whose body passes on, or names inside, its
  # parameters at `indexes` in the argument of a stub call: `Req.Test.stub/expect`'s last
  # argument, or `route/1`'s map.
  defp wrappers(ast, imported) do
    {_ast, wrappers} =
      Macro.prewalk(ast, %{}, fn
        {kind, _, [head, [{:do, _} | _] = blocks]} = node, wrappers when kind in [:def, :defp] ->
          {node, Map.merge(wrappers, wrapper(head, blocks, imported))}

        node, wrappers ->
          {node, wrappers}
      end)

    wrappers
  end

  defp wrapper({:when, _, [head, _guard]}, blocks, imported), do: wrapper(head, blocks, imported)

  defp wrapper({name, _, params}, blocks, imported) when is_atom(name) and is_list(params) do
    names = Enum.map(params, &var_name/1)

    {_ast, indexes} =
      Macro.prewalk(blocks, [], fn node, indexes ->
        case node |> unpipe() |> stub_fn(imported) do
          {:ok, fun} -> {node, named_params(fun, names) ++ indexes}
          :error -> {node, indexes}
        end
      end)

    case indexes |> Enum.uniq() |> Enum.sort() do
      [_ | _] = indexes -> %{{name, length(params)} => indexes}
      [] -> %{}
    end
  end

  defp wrapper(_head, _blocks, _imported), do: %{}

  # The indexes of `names` that `ast` names as a variable.
  defp named_params(ast, names) do
    {_ast, found} =
      Macro.prewalk(ast, [], fn node, found ->
        case var_name(node) do
          nil -> {node, found}
          var -> {node, [var | found]}
        end
      end)

    for {name, index} <- Enum.with_index(names), name != nil, name in found, do: index
  end

  # `route/1` as a wrapper of its one argument, in a file that imports `Cinder.NewznabFixtures`.
  defp imported_wrappers(ast) do
    {_ast, imported?} =
      Macro.prewalk(ast, false, fn
        {:import, _, [{:__aliases__, _, fixtures} | _]} = node, _imported?
        when fixtures in @fixtures ->
          {node, true}

        node, imported? ->
          {node, imported?}
      end)

    if imported?, do: %{{:route, 1} => [0]}, else: %{}
  end

  # `name => values` for each variable the file binds to a literal `fn` or map
  # (`answer = fn ... end`), every binding of that name in the file together.
  defp bound_fns(ast) do
    {_ast, bound} =
      Macro.prewalk(ast, %{}, fn
        {:=, _, [var, {kind, _, _} = fun]} = node, bound when kind in [:fn, :%{}] ->
          case var_name(var) do
            nil -> {node, bound}
            name -> {node, Map.update(bound, name, [fun], &[fun | &1])}
          end

        node, bound ->
          {node, bound}
      end)

    Map.new(bound, fn {name, fns} -> {name, {:__block__, [], fns}} end)
  end

  # `name => body` for each `def`/`defp` of arity 0 in the file.
  defp zero_arity_bodies(ast) do
    {_ast, bodies} =
      Macro.prewalk(ast, %{}, fn
        {kind, _, [{name, _, params}, [{:do, _} | _] = blocks]} = node, bodies
        when kind in [:def, :defp] and is_atom(name) and params in [nil, []] ->
          {node, Map.put(bodies, name, {:__block__, [], Keyword.values(blocks)})}

        node, bodies ->
          {node, bodies}
      end)

    bodies
  end

  # A stub argument with each variable the file binds to a literal `fn` or map, and each call or
  # bare name of a local arity-0 function, replaced by what it holds: the argument itself, a
  # wrapper's arguments, or a map's values, also in a map it was replaced by.
  defp resolve({:%{}, meta, pairs}, names) when is_list(pairs) do
    {:%{}, meta,
     Enum.map(pairs, fn
       {key, value} -> {key, resolve(value, names)}
       other -> other
     end)}
  end

  defp resolve({:__block__, meta, items}, names) when is_list(items),
    do: {:__block__, meta, Enum.map(items, &resolve(&1, names))}

  defp resolve({name, _, context} = var, names) when is_atom(name) and is_atom(context) do
    case Map.get(names.bound, name) || Map.get(names.defs, name) do
      nil ->
        var

      value ->
        resolve(value, %{bound: Map.delete(names.bound, name), defs: Map.delete(names.defs, name)})
    end
  end

  defp resolve({name, _, []} = call, names) when is_atom(name) do
    case Map.fetch(names.defs, name) do
      {:ok, body} -> resolve(body, %{names | defs: Map.delete(names.defs, name)})
      :error -> call
    end
  end

  defp resolve(ast, _names), do: ast

  # `{name, arity}` of each `def`, `defp`, `defmacro` or `defmacrop` whose body calls
  # `Req.Test.stub/expect` or `route/1`.
  defp stub_helpers(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    imported = Map.merge(imported_wrappers(ast), fixtures_module_wrappers(ast))

    {_ast, helpers} =
      Macro.prewalk(ast, [], fn
        {kind, _, [head, [{:do, _} | _] = blocks]} = node, helpers
        when kind in [:def, :defp, :defmacro, :defmacrop] ->
          {node, helper(head, blocks, imported) ++ helpers}

        node, helpers ->
          {node, helpers}
      end)

    Enum.reverse(helpers)
  end

  # `route/1` as a wrapper of its one argument, in a file that defines `Cinder.NewznabFixtures`,
  # where it is a local call.
  defp fixtures_module_wrappers(ast) do
    {_ast, own?} =
      Macro.prewalk(ast, false, fn
        {:defmodule, _, [{:__aliases__, _, fixtures} | _]} = node, _own?
        when fixtures in @fixtures ->
          {node, true}

        node, own? ->
          {node, own?}
      end)

    if own?, do: %{{:route, 1} => [0]}, else: %{}
  end

  defp helper({:when, _, [head, _guard]}, blocks, imported), do: helper(head, blocks, imported)

  defp helper({name, _, params}, blocks, imported) when is_atom(name) do
    {_ast, stubs?} =
      Macro.prewalk(blocks, false, fn node, stubs? ->
        {node, stubs? or match?({:ok, _fun}, node |> unpipe() |> stub_fn(imported))}
      end)

    if stubs?, do: [{name, length(params || [])}], else: []
  end

  defp helper(_head, _blocks, _imported), do: []

  # The line of each `alias`, `import` or `require ..., as:` whose module names `Req` or
  # `NewznabFixtures`, but `import Cinder.NewznabFixtures`: under such a name, a stub call reads
  # as a call the walk does not know.
  defp renames(source) do
    {:ok, ast} = Code.string_to_quoted(source)

    {_ast, lines} =
      Macro.prewalk(ast, [], fn
        {:import, _, [{:__aliases__, _, fixtures} | _]} = node, lines
        when fixtures in @fixtures ->
          {node, lines}

        {:require, meta, [module, opts]} = node, lines when is_list(opts) ->
          if Keyword.has_key?(opts, :as) and names_stub_module?(module),
            do: {node, [Keyword.get(meta, :line) | lines]},
            else: {node, lines}

        {kind, meta, [module | _]} = node, lines when kind in [:alias, :import] ->
          if names_stub_module?(module),
            do: {node, [Keyword.get(meta, :line) | lines]},
            else: {node, lines}

        node, lines ->
          {node, lines}
      end)

    Enum.sort(lines)
  end

  defp names_stub_module?(module) do
    {_ast, found?} =
      Macro.prewalk(module, false, fn
        # Each part of an alias, or a module written as its quoted atom (`:"Elixir.Req.Test"`).
        atom, found? when is_atom(atom) ->
          parts = atom |> Atom.to_string() |> String.split(".")
          {atom, found? or "Req" in parts or "NewznabFixtures" in parts}

        node, found? ->
          {node, found?}
      end)

    found?
  end

  defp var_name({name, _, context}) when is_atom(name) and is_atom(context), do: name
  defp var_name(_ast), do: nil

  # The lines of the sleeps inside each `fn` anywhere in `stub`. A sleep outside every `fn` runs
  # before the stub is installed.
  defp sleep_lines(stub) do
    {_ast, lines} =
      Macro.prewalk(stub, [], fn
        {:fn, _, _} = fun, lines -> {:fn_walked, fn_sleep_lines(fun) ++ lines}
        node, lines -> {node, lines}
      end)

    lines
  end

  defp fn_sleep_lines(fun) do
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

  defp sleeper?({:__aliases__, _, process}), do: process in @process
  defp sleeper?(:timer), do: true
  defp sleeper?(_module), do: false
end
