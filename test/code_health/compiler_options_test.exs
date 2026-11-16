defmodule Cinder.CodeHealth.CompilerOptionsTest do
  # #830: `Code.compiler_options/1` and `Code.put_compiler_option/2` set options for the whole VM,
  # not for the caller. `RemoteTypesTest` and `SeriesIdentitySyncCallsTest`, both async, each
  # turned `debug_info` on to compile a fixture and restored the run's `false` afterwards. A
  # restore that landed while the other module compiled left that fixture without debug info,
  # and the fence run went red on a file the change never touched. Any value the call sets,
  # the defaults or a saved one, can land in another module's compile that way.
  #
  # So this fence fails each call that sets a compiler option from a file under test/ that is not
  # an `async: false` test module: a file whose every `use ...Case` gives `async:` as the literal
  # `false`, or gives no `async:` (ExUnit's default is false). A file with no `use ...Case`, such
  # as a `test/support/` module that any async test can call, counts as async. A call that only
  # reads the options, `Code.compiler_options()` with no argument, passes. A fixture that needs a
  # `.beam` without a chunk drops it with `:beam_lib.strip/1` instead.
  #
  # The walk sees a call, a call split across lines, a capture with an arity
  # (`&Code.compiler_options/1`) and `apply(Code, ...)` with a literal function name. Forms the
  # walk does not see include: `Code` reached under an alias of another name or held in a
  # variable, `Kernel.apply/3` or `apply/3` with a function name not written as an atom, and a
  # call to the private `:elixir_config` that the `Code` functions use. A fixture shows each.
  use ExUnit.Case, async: true

  @setters [:compiler_options, :put_compiler_option]

  test "no async test module or support file sets a compiler option" do
    paths = Path.wildcard("test/**/*.{ex,exs}")

    # An empty or wrong glob would pass the check below on nothing.
    assert "test/code_health/remote_types_test.exs" in paths

    offenders =
      for path <- paths,
          offender <- path |> File.read!() |> offenders(),
          do: "#{path}: #{offender}"

    assert offenders == [],
           "these calls set a VM-wide compiler option outside an async: false test module; " <>
             "make the module async: false, or strip the chunk with :beam_lib.strip/1:\n  " <>
             Enum.join(offenders, "\n  ")
  end

  test "the walk reads the callers on main" do
    source = File.read!("test/code_health/remote_types_test.exs")

    assert offenders(source) == []
    assert source |> String.replace("async: false", "async: true") |> offenders() != []
  end

  describe "the walk" do
    test "fails each setter form in an async module" do
      source = ~S'''
      defmodule M do
        use ExUnit.Case, async: true

        def a, do: Code.compiler_options(debug_info: true, docs: true)
        def b, do: Code.put_compiler_option(:docs, false)
        def c(previous), do: Code.compiler_options(previous)
        def d do
          Code.compiler_options(
            ignore_module_conflict: true
          )
        end
        def e, do: &Code.compiler_options/1
        def f, do: apply(Code, :put_compiler_option, [:docs, true])
        def g, do: &Code.put_compiler_option/2
        def h, do: apply(Code, :compiler_options, [[docs: true]])
      end
      '''

      assert offenders(source) == [
               "compiler_options (line 4)",
               "put_compiler_option (line 5)",
               "compiler_options (line 6)",
               "compiler_options (line 8)",
               "compiler_options (line 12)",
               "put_compiler_option (line 13)",
               "put_compiler_option (line 14)",
               "compiler_options (line 15)"
             ]
    end

    test "counts a module with a non-literal async, or with no Case, as async" do
      variable = ~S'''
      defmodule M do
        use ExUnit.Case, async: @async
        def a, do: Code.compiler_options(docs: true)
      end
      '''

      options = ~S'''
      defmodule M do
        use ExUnit.Case, @options
        def a, do: Code.compiler_options(docs: true)
      end
      '''

      support = ~S'''
      defmodule Cinder.Test.Helper do
        use GenServer
        def a, do: Code.put_compiler_option(:docs, true)
      end
      '''

      mixed = ~S'''
      defmodule M do
        use ExUnit.Case, async: false
        use Cinder.DataCase, async: true
        def a, do: Code.compiler_options(docs: true)
      end
      '''

      assert offenders(variable) == ["compiler_options (line 3)"]
      assert offenders(options) == ["compiler_options (line 3)"]
      assert offenders(support) == ["put_compiler_option (line 3)"]
      assert offenders(mixed) == ["compiler_options (line 4)"]
    end

    test "passes a read, an async: false module, a module with no async, comments and strings" do
      read = ~S'''
      defmodule M do
        use ExUnit.Case, async: true
        # Code.compiler_options(debug_info: false)
        def a, do: Code.compiler_options()
        def b, do: "Code.compiler_options(docs: false)"
        def c, do: &Code.compiler_options/0
      end
      '''

      sync = ~S'''
      defmodule M do
        use ExUnit.Case, async: false
        def a, do: Code.compiler_options(debug_info: false)
      end
      '''

      default = ~S'''
      defmodule M do
        use Cinder.DataCase
        def a, do: Code.put_compiler_option(:docs, true)
      end
      '''

      no_async = ~S'''
      defmodule M do
        use ExUnit.Case, register: false
        def a, do: Code.put_compiler_option(:docs, true)
      end
      '''

      assert offenders(read) == []
      assert offenders(sync) == []
      assert offenders(default) == []
      assert offenders(no_async) == []
    end

    test "does not see the forms its header names" do
      source = ~S'''
      defmodule M do
        use ExUnit.Case, async: true
        alias Code, as: C
        def a, do: C.compiler_options(docs: true)
        def b(mod), do: mod.compiler_options(docs: true)
        def c, do: Kernel.apply(Code, :compiler_options, [[docs: true]])
        def d(fun), do: apply(Code, fun, [[docs: true]])
        def e, do: :elixir_config.put(:docs, true)
      end
      '''

      assert offenders(source) == []
    end
  end

  # Each call in `source` that sets a compiler option, or [] when the file is an `async: false`
  # test module.
  defp offenders(source) do
    {:ok, ast} = Code.string_to_quoted(source)

    if async?(ast) do
      {_ast, found} = Macro.prewalk(ast, [], &collect/2)
      Enum.reverse(found)
    else
      []
    end
  end

  # False only when the file holds a `use ...Case` and each one gives a literal false or no
  # `async:`.
  defp async?(ast) do
    {_ast, flags} =
      Macro.prewalk(ast, [], fn
        {:use, _, [{:__aliases__, _, parts} | rest]} = node, acc ->
          if parts |> List.last() |> Atom.to_string() |> String.ends_with?("Case") do
            {node, [async_option(rest) | acc]}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    flags == [] or Enum.any?(flags, &(&1 != false))
  end

  defp async_option([opts]) when is_list(opts), do: Keyword.get(opts, :async, false)
  defp async_option([]), do: false
  defp async_option(_other), do: :unknown

  # A capture with an arity above 0. Its inner `Code.compiler_options` node has no arguments, so
  # the call clause below skips it once the walk goes inside.
  defp collect(
         {:&, meta, [{:/, _, [{{:., _, [{:__aliases__, _, [:Code]}, name]}, _, []}, arity]}]} =
           node,
         acc
       )
       when name in @setters and arity > 0,
       do: {node, ["#{name} (line #{meta[:line]})" | acc]}

  defp collect({{:., _, [{:__aliases__, _, [:Code]}, name]}, meta, [_ | _]} = node, acc)
       when name in @setters,
       do: {node, ["#{name} (line #{meta[:line]})" | acc]}

  defp collect({:apply, meta, [{:__aliases__, _, [:Code]}, name, _args]} = node, acc)
       when name in @setters,
       do: {node, ["#{name} (line #{meta[:line]})" | acc]}

  defp collect(node, acc), do: {node, acc}
end
