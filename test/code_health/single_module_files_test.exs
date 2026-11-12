defmodule Cinder.CodeHealth.SingleModuleFilesTest do
  # Each file Mix compiles defines one module: deps/phoenix/usage-rules/elixir.md, which AGENTS.md
  # "Usage Rules" points to, says "**Never** nest multiple modules in the same file as it can
  # cause cyclic dependencies and compilation errors" (docs/agents/testing.md). The fence walks
  # every `.ex` file under the project's `elixirc_paths` (`lib/`, plus `test/support/` in the test
  # env) and fails a file with more than one module form: `defmodule`, `defprotocol` or `defimpl`,
  # bare or called through `Kernel.` or `Elixir.Kernel.`, and a call or capture of
  # `Module.create` or `Elixir.Module.create`. It counts them at any depth, inside a `quote` too:
  # a macro that quotes a `defmodule` puts a second module in each file that uses it. `.exs` test
  # files are outside the rule, since `mix test` loads them in memory and they leave no `.beam`
  # and no entry in `mix xref graph`. #1279 moved the three nested structs the compiled files held
  # (`CinderWeb.SeriesDiscoveryLive.Reread`, `Cinder.Subtitles.SidecarTransaction.Workspace.Sweep`,
  # `Cinder.PushRepeatsPr.Context`) into their own files.
  #
  # The walk reads each file's source before macro expansion, so it does not see every module a
  # file generates. Forms the walk does not follow include: `Module.create/3` or a `Kernel` form
  # called through an alias (`alias Module, as: M`); `Module.create/3` called through `apply/3`
  # or the atom `:"Elixir.Module"`; a module that a `use`d or imported macro defines in the
  # caller; a module
  # built by `Code.eval_string/1` or `Code.compile_string/1`; and the implementations that
  # `@derive` and `Protocol.derive/3` define. A string, a sigil, a heredoc and a comment hold no
  # module form. "the walk skips each form it does not follow" shows each of these.
  use ExUnit.Case, async: true

  @kernel_forms [:defmodule, :defprotocol, :defimpl]
  @kernel [[:Kernel], [:"Elixir", :Kernel]]
  @module [[:Module], [:"Elixir", :Module]]

  @usage_rule "deps/phoenix/usage-rules/elixir.md says: \"**Never** nest multiple modules in " <>
                "the same file as it can cause cyclic dependencies and compilation errors\""

  test "each file Mix compiles defines one module" do
    paths = Mix.Project.config()[:elixirc_paths]

    # Without both, the walk would skip files `mix test` compiles and pass on them.
    assert "lib" in paths and "test/support" in paths

    files = compiled_files(paths)

    # A walk that found no files would pass the check below on nothing.
    assert length(files) > 300

    assert offenders(files) == [], message(offenders(files))
  end

  @tag :tmp_dir
  test "the walk finds every .ex file below each path and names each file with two modules",
       %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "a/b"))
    File.write!(Path.join(dir, "one.ex"), "defmodule One do\nend\n")

    File.write!(
      Path.join(dir, "a/b/two.ex"),
      "defmodule Two do\n  defmodule Inner do\n  end\nend\n"
    )

    File.write!(Path.join(dir, "a/script.exs"), "defmodule A do\nend\ndefmodule B do\nend\n")

    files = compiled_files([dir])
    two = Path.join(dir, "a/b/two.ex")

    assert files == Enum.sort([Path.join(dir, "one.ex"), two])
    assert offenders(files) == [{two, [1, 2]}]

    assert message(offenders(files)) ==
             "These files Mix compiles define more than one module:\n" <>
               "#{two}: lines 1, 2\n" <>
               "Move each extra module into its own file, named after the module. " <>
               @usage_rule <> " (docs/agents/testing.md)."
  end

  @tag :tmp_dir
  test "the walk fails on a compile path that is not a directory", %{tmp_dir: dir} do
    file = Path.join(dir, "lone.ex")
    File.write!(file, "defmodule Lone do\nend\n")

    assert_raise ExUnit.AssertionError, ~r/not a directory.*lone\.ex/s, fn ->
      compiled_files([dir, file])
    end
  end

  test "the walk counts each module form, at any depth" do
    source = ~S'''
    defmodule M do
      defmodule Nested do
      end

      defprotocol P do
        def f(x)
      end

      defimpl P, for: Integer do
        def f(x), do: x
      end

      def a, do: Kernel.defmodule(K, do: nil)
      def b, do: Elixir.Kernel.defprotocol(KP, do: nil)
      def c, do: Kernel.defimpl(P, [for: Atom], do: nil)
      def d, do: Module.create(C, quote(do: nil), __ENV__)
      def e, do: Elixir.Module.create(D, quote(do: nil), __ENV__)
      def f, do: C2 |> Module.create(quote(do: nil), __ENV__)
      def g, do: &Module.create/3

      defmacro h do
        quote do
          defmodule Quoted do
          end
        end
      end

      defmodule(
        Split,
        do: nil
      )
    end

    defmodule Second do
    end

    defimpl P, for: Second do
      def f(x), do: x
    end
    '''

    assert module_form_lines(source) ==
             [1, 2, 5, 9, 13, 14, 15, 16, 17, 18, 19, 23, 28, 34, 37]
  end

  test "the walk skips a module spelled out in a string, a sigil, a heredoc or a comment" do
    source = ~S'''
    defmodule M do
      @moduledoc """
      defmodule InDoc do
      end
      """

      @doc """
      defmodule InFunctionDoc do
      end
      """
      # defmodule InComment do end
      def a, do: "defmodule InString do end"
      def b, do: ~S(defmodule InSigil do end)
      def c, do: :defmodule
      def d(defmodule), do: defmodule
    end
    '''

    assert module_form_lines(source) == [1]
  end

  test "the walk skips each form it does not follow" do
    source = ~S'''
    defmodule M do
      use Some.Generator
      import Some.Macros
      alias Module, as: Mod
      alias Kernel, as: K

      @derive {Inspect, only: [:a]}
      defstruct [:a]

      def a, do: Mod.create(A, quote(do: nil), __ENV__)
      def b, do: K.defmodule(B, do: nil)
      def c, do: apply(Module, :create, [C, quote(do: nil), __ENV__])
      def d, do: :"Elixir.Module".create(D, quote(do: nil), __ENV__)
      def e, do: generated_module(E)
      def f, do: Code.eval_string("defmodule F do end")
      def g, do: Code.compile_string("defmodule G do end")
      def h, do: Protocol.derive(Inspect, M)
    end
    '''

    assert module_form_lines(source) == [1]
  end

  # The `.ex` files below each compile path, sorted, as Mix's own compiler lists a directory
  # (`Mix.Utils.extract_files(paths, [:ex])`). Mix also takes a compile path that is a single
  # file; the fence fails on one instead, since `elixirc_paths` here holds only directories.
  defp compiled_files(paths) do
    assert Enum.reject(paths, &File.dir?/1) == [],
           "These compile paths are not a directory, so the walk cannot list their files: " <>
             inspect(Enum.reject(paths, &File.dir?/1))

    paths |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*.ex"))) |> Enum.uniq() |> Enum.sort()
  end

  # `{path, lines}` for each file with more than one module form, the lines of its forms.
  defp offenders(files) do
    for path <- files,
        lines = path |> File.read!() |> module_form_lines(path),
        length(lines) > 1,
        do: {path, lines}
  end

  defp message(offenders) do
    "These files Mix compiles define more than one module:\n" <>
      Enum.map_join(offenders, "", fn {path, lines} ->
        "#{path}: lines #{Enum.join(lines, ", ")}\n"
      end) <>
      "Move each extra module into its own file, named after the module. " <>
      @usage_rule <> " (docs/agents/testing.md)."
  end

  # The lines of the module forms in the parsed source, at any depth. A string's, a sigil's and a
  # heredoc's contents are not code, and the parser drops comments, so neither holds a form.
  defp module_form_lines(source, file \\ "nofile") do
    ast = Code.string_to_quoted!(source, file: file)

    {_ast, lines} =
      Macro.prewalk(ast, [], fn node, lines ->
        if module_form?(node), do: {node, [line(node) | lines]}, else: {node, lines}
      end)

    Enum.sort(lines)
  end

  defp module_form?({name, _meta, args}) when name in @kernel_forms and is_list(args), do: true

  defp module_form?({{:., _, [{:__aliases__, _, kernel}, name]}, _meta, args})
       when kernel in @kernel and name in @kernel_forms and is_list(args),
       do: true

  defp module_form?({{:., _, [{:__aliases__, _, module}, :create]}, _meta, args})
       when module in @module and is_list(args),
       do: true

  defp module_form?(_node), do: false

  defp line({_call, meta, _args}), do: Keyword.fetch!(meta, :line)
end
