defmodule Cinder.CodeHealth.RemoteTypesTest do
  # Every remote type that a compiled `:cinder` module's typespecs name, such as `Movie.t()`, is a
  # public type of its module (#852). Specs named `t/0` on Ecto schemas that defined none, and
  # ElixirLS Dialyzer then reported 20 to 60 "Unknown type" warnings after each edit in a fresh
  # worktree, which hid its real findings. Neither `mix test` nor CI runs Dialyzer, so this test
  # does that one check. It reads the typespecs from each module's `.beam` with `Code.Typespec`:
  # `@spec`, `@callback` and `@macrocallback` entries and the bodies of `@type`, `@typep` and
  # `@opaque`, remote types nested inside other types included. A remote type passes when its
  # module defines a `@type` or an `@opaque` of that name and arity. It fails when the module
  # defines none, when the type is a `@typep`, when the module's types cannot be read (no such
  # module, or a `.beam` without debug info), and on a remote type whose module or name is not a
  # literal atom. A `:cinder` module whose typespecs cannot be read fails too. Forms the check
  # does not see include: typespecs in `.exs` files (tests, `scripts/`, `mix.exs`, `config/`),
  # which leave no `.beam` in the app; and type names written in docs or comments (#850).
  #
  # Not async: `compile/1` sets global compiler options, and an async module that restored them
  # while another compiled a fixture left that fixture without debug info (#830,
  # `test/code_health/compiler_options_test.exs`).
  use ExUnit.Case, async: false

  test "every remote type in the app's typespecs is a public type of its module" do
    modules = Application.spec(:cinder, :modules)

    # An empty or wrong module list would pass the check below on nothing.
    assert Cinder.Catalog.Movie in modules
    assert length(modules) > 300

    beams =
      for module <- modules do
        {^module, binary, _path} = :code.get_object_code(module)
        {module, binary}
      end

    problems = problems(beams, &Code.Typespec.fetch_types/1)

    assert problems == [],
           "These typespecs name a remote type its module does not define as public:\n" <>
             Enum.join(problems, "\n") <>
             "\nDefine the type in that module, such as `@type t :: %__MODULE__{}` on an Ecto " <>
             "schema, or name a type it has."
  end

  describe "the check" do
    test "fails a spec written across lines and skips a type named in a comment, a doc or a string" do
      [{_, binary}] =
        beams =
        compile("""
        defmodule #{name(:text)} do
          @moduledoc "Names Cinder.Catalog.Movie.in_moduledoc()."

          # @spec g() :: Cinder.Catalog.Movie.in_comment()
          @doc "Returns Cinder.Catalog.Movie.in_doc()."
          @spec f(
                  atom()
                ) ::
                  Cinder.Catalog.Movie.split()
          def f(_), do: "Cinder.Catalog.Movie.in_string()"
        end
        """)

      # The docs are in the binary, so the check skips them rather than never seeing them.
      assert {:ok, _} = :beam_lib.chunks(binary, [~c"Docs"])
      assert beams |> problems(fixture_fetch()) |> Enum.map(&missing_type/1) == ["split/0"]
    end

    test "does not see a module defined in an .exs file" do
      assert String.ends_with?(__ENV__.file, ".exs")
      refute __MODULE__ in Application.spec(:cinder, :modules)
    end

    test "passes a defined public type, an @opaque one and the module's own types" do
      [{target, _}] =
        compile("""
        defmodule #{name(:green_target)} do
          @type t :: atom()
          @opaque o :: atom()
          @type p(a) :: [a]
        end
        """)

      problems =
        check("""
        defmodule #{name(:green)} do
          @type local :: #{inspect(target)}.t()
          @spec f(local()) :: #{inspect(target)}.o()
          def f(_), do: nil
          @callback c() :: #{inspect(target)}.p(String.t())
        end
        """)

      assert problems == []
    end

    test "fails an undefined type in each form that holds one" do
      problems =
        check("""
        defmodule #{name(:forms)} do
          @type t1 :: Cinder.Catalog.Movie.missing_t1()
          @typep t2 :: Cinder.Catalog.Movie.missing_t2()
          @opaque t3 :: t2()
          @spec f() :: Cinder.Catalog.Movie.missing_spec()
          def f, do: nil
          @spec m(term()) :: Cinder.Catalog.Movie.missing_macro_spec()
          defmacro m(x), do: x
          @callback c(Cinder.Catalog.Movie.missing_callback()) :: :ok
          @macrocallback mc() :: Cinder.Catalog.Movie.missing_macrocallback()
        end
        """)

      for {form, type} <- [
            {"@type t1/0", "missing_t1/0"},
            {"@typep t2/0", "missing_t2/0"},
            {"@spec f/0", "missing_spec/0"},
            {"@spec m/1", "missing_macro_spec/0"},
            {"@callback c/1", "missing_callback/0"},
            {"@macrocallback mc/0", "missing_macrocallback/0"}
          ] do
        assert Enum.any?(
                 problems,
                 &(&1 =~
                     "#{form} names Cinder.Catalog.Movie.#{type}, which Cinder.Catalog.Movie " <>
                       "does not define")
               ),
               "no problem for #{form} in:\n" <> Enum.join(problems, "\n")
      end

      assert length(problems) == 6
    end

    test "fails an @opaque whose body names an undefined type" do
      problems =
        check("""
        defmodule #{name(:opaque)} do
          @opaque o :: Cinder.Catalog.Movie.missing_o()
        end
        """)

      assert [problem] = problems
      assert problem =~ "@opaque o/0 names Cinder.Catalog.Movie.missing_o/0"
    end

    test "fails a remote type nested in a list, a tuple and another remote type's argument" do
      problems =
        check("""
        defmodule #{name(:nested)} do
          @spec f() :: [Cinder.Catalog.Movie.in_list()]
          def f, do: []
          @spec g() :: {:ok, Cinder.Catalog.Movie.in_tuple()}
          def g, do: {:ok, nil}
          @spec h() :: Keyword.t(Cinder.Catalog.Movie.in_arg())
          def h, do: []
        end
        """)

      assert Enum.map(problems, &missing_type/1) |> Enum.sort() ==
               ["in_arg/0", "in_list/0", "in_tuple/0"]
    end

    test "fails a defined type named with the wrong arity" do
      assert [problem] =
               check("""
               defmodule #{name(:arity)} do
                 @spec f() :: String.t(atom())
                 def f, do: ""
               end
               """)

      assert problem =~ "@spec f/0 names String.t/1, which String does not define"
    end

    test "fails a type its module defines as @typep" do
      [{target, _}] =
        compile("""
        defmodule #{name(:private_target)} do
          @typep hidden :: atom()
          @type shown :: hidden()
        end
        """)

      assert [problem] =
               check("""
               defmodule #{name(:private)} do
                 @spec f() :: #{inspect(target)}.hidden()
                 def f, do: nil
               end
               """)

      assert problem =~
               "names #{inspect(target)}.hidden/0, which #{inspect(target)} defines " <>
                 "as @typep"
    end

    test "fails a type of a module whose types cannot be read" do
      [{stripped_target, binary}] =
        compile("""
        defmodule #{name(:stripped_target)} do
          @type t :: atom()
        end
        """)

      {:ok, {_, stripped}} = :beam_lib.strip(binary)

      source = """
      defmodule #{name(:unreadable)} do
        @spec f() :: #{inspect(stripped_target)}.t()
        def f, do: nil
        @spec g() :: Cinder.CodeHealth.RemoteTypesTest.NoSuchModule.t()
        def g, do: nil
      end
      """

      beams = compile(source)
      fetch = fixture_fetch([{stripped_target, stripped}])

      # Sorted by line: `Code.Typespec` returns a module's specs in no set order.
      assert [no_debug, no_module] = beams |> problems(fetch) |> Enum.sort()
      assert no_debug =~ "@spec f/0 names #{inspect(stripped_target)}.t/0, but the types of "
      assert no_debug =~ "cannot be read"
      assert no_module =~ "@spec g/0 names Cinder.CodeHealth.RemoteTypesTest.NoSuchModule.t/0"
      assert no_module =~ "cannot be read"
    end

    test "fails a module whose own typespecs cannot be read" do
      [{module, binary}] =
        compile("""
        defmodule #{name(:stripped)} do
          @spec f() :: atom()
          def f, do: nil
        end
        """)

      {:ok, {_, stripped}} = :beam_lib.strip(binary)

      assert [problem] = problems([{module, stripped}], &Code.Typespec.fetch_types/1)
      assert problem =~ "#{inspect(module)}: its typespecs cannot be read"
    end

    test "fails a remote type whose module or name is not a literal atom" do
      form = {:remote_type, 7, [{:var, 7, :M}, {:atom, 7, :t}, []]}

      assert [{:unreadable, 7, ^form} = ref] = remote_types(form)
      assert problem(ref, %{}) =~ "names a remote type whose module or name is not a literal atom"
    end

    test "names the source file and line of the remote type" do
      assert [problem] =
               check("""
               defmodule #{name(:location)} do

                 @spec f() :: Cinder.Catalog.Movie.missing()
                 def f, do: nil
               end
               """)

      assert problem =~ ~r/^nofile:3: /
    end
  end

  # Compiles the fixture source and checks only its modules.
  defp check(source), do: source |> compile() |> problems(fixture_fetch())

  # Compiles in memory and keeps each binary for `fixture_fetch/1`. Purges the modules on exit,
  # so a repeated run defines them anew without a redefinition warning. Mix defaults to
  # `docs: false` and `debug_info: false` when it compiles tests
  # (`Mix.Compilers.Test.require_and_run/4`), unless the project's `test_elixirc_options`, which
  # this repo does not set, override them; `iex -S mix test -b` also turns `debug_info` on. Mix
  # sets them as global compiler options for the run. Without debug info a fixture has no
  # typespecs to read, and without docs the doc fixture holds no doc for the check to skip, so
  # the compile turns both on and restores them. The options are global to the VM, so this
  # module is not async: a restore that lands while another module compiles takes the chunks
  # from that module's fixture.
  defp compile(source) do
    previous = Code.compiler_options(debug_info: true, docs: true)

    beams =
      try do
        Code.compile_string(source)
      after
        Code.compiler_options(previous)
      end

    for {module, binary} <- beams, do: Process.put({__MODULE__, module}, binary)

    on_exit(fn ->
      for {module, _} <- beams do
        :code.purge(module)
        :code.delete(module)
      end
    end)

    beams
  end

  # `Code.Typespec.fetch_types/1` given a module reads its `.beam` on the code path, which a
  # fixture compiled in memory lacks. So a fixture's types come from the binary `compile/1` kept,
  # or from `overrides`, and an app module's from its `.beam`.
  defp fixture_fetch(overrides \\ []) do
    overrides = Map.new(overrides)

    fn module ->
      case Map.get(overrides, module) || Process.get({__MODULE__, module}) do
        nil -> Code.Typespec.fetch_types(module)
        binary -> Code.Typespec.fetch_types(binary)
      end
    end
  end

  defp name(tag), do: "Cinder.CodeHealth.RemoteTypesTest.Fixture.#{Macro.camelize("#{tag}")}"

  defp missing_type(problem) do
    [_, type] = Regex.run(~r/names Cinder\.Catalog\.Movie\.(\S+),/, problem)
    type
  end

  # The problems of the given compiled modules, one line each. `fetch_types` reads a module's
  # types as `Code.Typespec.fetch_types/1` does.
  defp problems(beams, fetch_types) do
    read = Enum.map(beams, &read_module/1)
    problems = for {:error, problem} <- read, do: problem
    refs = for {:ok, ref} <- read, do: ref

    targets =
      for {_, _, found} <- refs, {_, {_, _, module, _, _}} <- found, uniq: true, do: module

    types = Map.new(targets, &{&1, public_and_private_types(fetch_types.(&1))})

    remote_problems =
      for {module, source, found} <- refs,
          {form, ref} <- found,
          problem <- [problem(ref, types)],
          problem != nil,
          uniq: true do
        "#{source}:#{line(ref)}: #{inspect(module)} #{form} #{problem}"
      end

    problems ++ remote_problems
  end

  # A module's remote types, each with the typespec form that names it.
  defp read_module({module, binary}) do
    case typespecs(binary) do
      {:ok, entries} ->
        found = for {form, body} <- entries, ref <- remote_types(body), do: {form, ref}
        {:ok, {module, source(binary), found}}

      :error ->
        {:error, "#{inspect(module)}: its typespecs cannot be read"}
    end
  end

  defp typespecs(binary) do
    with {:ok, specs} <- Code.Typespec.fetch_specs(binary),
         {:ok, callbacks} <- Code.Typespec.fetch_callbacks(binary),
         {:ok, types} <- Code.Typespec.fetch_types(binary) do
      {:ok,
       Enum.map(specs, fn {key, body} -> {"@spec #{display(key)}", body} end) ++
         Enum.map(callbacks, fn {key, body} -> {callback_form(key), body} end) ++
         Enum.map(types, fn {kind, {name, body, args}} ->
           {"@#{kind} #{name}/#{length(args)}", body}
         end)}
    end
  end

  defp callback_form({name, _} = key) do
    if macro?(name), do: "@macrocallback #{display(key)}", else: "@callback #{display(key)}"
  end

  # A macro's spec or callback is stored under `MACRO-<name>`, with the caller's env as one more
  # argument.
  defp display({name, arity}) do
    if macro?(name),
      do: "#{String.replace_prefix(Atom.to_string(name), "MACRO-", "")}/#{arity - 1}",
      else: "#{name}/#{arity}"
  end

  defp macro?(name), do: String.starts_with?(Atom.to_string(name), "MACRO-")

  defp source(binary) do
    {:ok, {_, [compile_info: info]}} = :beam_lib.chunks(binary, [:compile_info])
    info |> Keyword.get(:source, ~c"nofile") |> List.to_string() |> Path.relative_to_cwd()
  end

  # Every remote type in an abstract type form, as `{:remote, anno, module, name, arity}`, or
  # `{:unreadable, line, form}` for a remote type whose module or name is not a literal atom.
  defp remote_types(form), do: form |> walk([]) |> Enum.reverse()

  defp walk({:remote_type, anno, [{:atom, _, module}, {:atom, _, name}, args]}, acc)
       when is_list(args),
       do: walk(args, [{:remote, anno, module, name, length(args)} | acc])

  defp walk({:remote_type, anno, _} = form, acc),
    do: [{:unreadable, :erl_anno.line(anno), form} | acc]

  defp walk(form, acc) when is_tuple(form), do: walk(Tuple.to_list(form), acc)
  defp walk(form, acc) when is_list(form), do: Enum.reduce(form, acc, &walk/2)
  defp walk(_form, acc), do: acc

  defp line({:remote, anno, _, _, _}), do: :erl_anno.line(anno)
  defp line({:unreadable, line, _}), do: line

  defp public_and_private_types({:ok, types}) do
    Map.new(types, fn {kind, {name, _, args}} -> {{name, length(args)}, kind} end)
  end

  defp public_and_private_types(:error), do: :error

  defp problem({:unreadable, _, form}, _types),
    do: "names a remote type whose module or name is not a literal atom: #{inspect(form)}"

  defp problem({:remote, _, module, name, arity}, types) do
    ref = "#{inspect(module)}.#{name}/#{arity}"

    case types do
      %{^module => :error} ->
        "names #{ref}, but the types of #{inspect(module)} cannot be read " <>
          "(no such module, or its .beam has no debug info)"

      %{^module => %{{^name, ^arity} => kind}} when kind in [:type, :opaque] ->
        nil

      %{^module => %{{^name, ^arity} => :typep}} ->
        "names #{ref}, which #{inspect(module)} defines as @typep"

      _ ->
        "names #{ref}, which #{inspect(module)} does not define"
    end
  end
end
