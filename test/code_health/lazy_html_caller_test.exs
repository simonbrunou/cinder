defmodule Cinder.CodeHealth.LazyHtmlCallerTest do
  # #1665: lazy_html wraps lexbor, which ends the VM that runs it on some selectors
  # (`td:has(b[border=1])` exits 139). It is a runtime dependency only so that
  # `Cinder.Indexers.ParserWorker` can run it in a worker OS process of its own, and no other
  # module under lib/ may name it: a call from the VM that runs Cinder takes that VM down with it.
  #
  # The check reads, for each module of the `:cinder` application whose source sits under lib/,
  # the function bodies in its `.beam` debug info as Erlang abstract code, and fails on a
  # function whose body holds the atom `LazyHTML` or one under `LazyHTML.`. The compiler has
  # expanded every alias and import there, as in `series_identity_sync_calls_test.exs`, whose
  # approach this copies. A fixture below shows each form it catches: an aliased, an `as:`
  # aliased, a fully qualified, an imported and a split-across-lines call, a capture, `apply/3`,
  # a `%LazyHTML{}` struct, a module held in a tuple or a module attribute, a quoted atom, a
  # submodule and a private function. A `.beam` without debug info fails. Forms the check does
  # not see include: a module name built at runtime (`Module.concat/1`, `String.to_atom/1`), a
  # module named only in a typespec, a doc, a comment or a string, and a call that runs at
  # compile time in the module body. A fixture shows each.
  #
  # Not async: `compile/1` sets global compiler options (`compiler_options_test.exs`).
  use ExUnit.Case, async: false

  alias Cinder.Indexers.ParserWorker

  test "no module under lib/ but ParserWorker names LazyHTML" do
    problems =
      for module <- lib_modules(),
          module != ParserWorker,
          problem <- lazy_html_refs(object_code(module)),
          do: problem

    assert problems == [],
           "these functions name LazyHTML outside Cinder.Indexers.ParserWorker (#1665):\n  " <>
             Enum.join(problems, "\n  ") <>
             "\nRun the query through Cinder.Indexers.ParserWorker.run/3 instead."
  end

  test "ParserWorker itself names LazyHTML, so the check reads its calls" do
    assert lazy_html_refs(object_code(ParserWorker)) != []
  end

  test "the check reads every module under lib/, cinder_web/ included, and none from test/" do
    modules = lib_modules()
    sources = Enum.map(modules, &List.to_string(&1.module_info(:compile)[:source]))

    assert ParserWorker in modules
    assert CinderWeb.Router in modules
    assert Cinder.Indexers.Definitions.LoadCheck in modules
    refute Cinder.ConfigCase in modules

    lib_files = Path.wildcard("lib/**/*.ex")
    assert MapSet.new(sources, &Path.relative_to_cwd/1) == MapSet.new(lib_files)
  end

  describe "the check" do
    test "fails each form that keeps LazyHTML in a function body" do
      forms = %{
        aliased: "alias LazyHTML, as: L\ndef f(d), do: L.query(d, \"a\")",
        remote: "def f(d), do: LazyHTML.query(d, \"a\")",
        imported: "import LazyHTML, only: [query: 2]\ndef f(d), do: query(d, \"a\")",
        split_across_lines: "def f(d) do\n  LazyHTML\n  .query(d, \"a\")\nend",
        capture: "def f, do: &LazyHTML.from_fragment/1",
        apply: "def f(d), do: apply(LazyHTML, :query, [d, \"a\"])",
        struct: "def f(%LazyHTML{} = d), do: d",
        tuple: "def f, do: {LazyHTML, :query, []}",
        attribute: "@module LazyHTML\ndef f(d), do: @module.query(d, \"a\")",
        quoted_atom: ~S|def f, do: :"Elixir.LazyHTML"|,
        submodule: "def f(t), do: LazyHTML.Tree.to_html(t)",
        private: "def f(d), do: g(d)\ndefp g(d), do: LazyHTML.text(d)"
      }

      for {form, body} <- forms do
        binary = compile_one(form, body)
        assert lazy_html_refs(binary) != [], "the #{form} form passed the check"
      end
    end

    test "names the function that holds the reference" do
      binary = compile_one(:named, "def f(d), do: g(d)\ndefp g(d), do: LazyHTML.text(d)")
      assert lazy_html_refs(binary) == ["#{name(:named)}.g/1 names LazyHTML"]
    end

    test "passes a module that names no LazyHTML, nor a module whose name only starts so" do
      binary =
        compile_one(:clean, """
        def f, do: Jason.encode!("<a></a>")
        def g, do: :"Elixir.LazyHTMLX"
        """)

      assert lazy_html_refs(binary) == []
    end

    test "does not see the forms its header lists as unseen" do
      unseen = %{
        concat: ~S|def f, do: Module.concat(["LazyHTML"])|,
        to_atom: ~S|def f, do: String.to_atom("Elixir.LazyHTML")|,
        string: ~S|def f, do: "LazyHTML.query(d, sel)"|,
        comment: "# LazyHTML.query(d, sel)\ndef f, do: :ok",
        doc: "@doc \"Calls LazyHTML.query/2.\"\ndef f, do: :ok",
        typespec: "@spec f() :: LazyHTML.t()\ndef f, do: :ok",
        compile_time:
          "@text LazyHTML.text(LazyHTML.from_fragment(\"<a>x</a>\"))\ndef f, do: @text"
      }

      for {form, body} <- unseen do
        binary = compile_one(form, body)
        assert lazy_html_refs(binary) == [], "the #{form} form was seen"
      end
    end

    # `:beam_lib.strip/1` drops the debug info chunk without flipping a global compiler option.
    test "fails a .beam without debug info" do
      {:ok, {_, stripped}} = :no_debug_info |> compile_one("def f, do: :ok") |> :beam_lib.strip()

      assert [problem] = lazy_html_refs(stripped)
      assert problem =~ "cannot read the debug info"
    end
  end

  # The `:cinder` modules compiled from a file under lib/; test/support compiles into the app too.
  defp lib_modules do
    lib = Path.expand("lib")
    {:ok, modules} = :application.get_key(:cinder, :modules)

    Enum.filter(modules, fn module ->
      source = module.module_info(:compile)[:source]
      String.starts_with?(List.to_string(source), lib <> "/")
    end)
  end

  # Each `{:function, ...}` form of the module's Erlang abstract code that holds `LazyHTML` or an
  # atom under `LazyHTML.`.
  defp lazy_html_refs(binary) do
    module = binary |> :beam_lib.info() |> Keyword.fetch!(:module)

    case abstract_code(module, binary) do
      {:ok, forms} ->
        for {:function, _line, name, arity, _clauses} = form <- forms,
            Enum.any?(atoms(form), &lazy_html?/1),
            do: "#{inspect(module)}.#{name}/#{arity} names LazyHTML"

      error ->
        ["#{inspect(module)}: cannot read the debug info in its .beam (#{inspect(error)})"]
    end
  end

  defp lazy_html?(atom) do
    name = Atom.to_string(atom)
    name == "Elixir.LazyHTML" or String.starts_with?(name, "Elixir.LazyHTML.")
  end

  # Anything but a readable Elixir debug info chunk falls through as the error.
  defp abstract_code(module, binary) do
    with {:ok, {^module, [debug_info: {:debug_info_v1, backend, data}]}} <-
           :beam_lib.chunks(binary, [:debug_info]) do
      backend.debug_info(:erlang_v1, module, data, [])
    end
  end

  # Abstract code is tuples, lists and atoms; a map literal is a `{:map, ...}` tuple there.
  defp atoms(term) when is_atom(term), do: [term]
  defp atoms(term) when is_tuple(term), do: term |> Tuple.to_list() |> atoms()
  defp atoms(term) when is_list(term), do: Enum.flat_map(term, &atoms/1)
  defp atoms(_term), do: []

  defp object_code(module) do
    {^module, binary, _path} = :code.get_object_code(module)
    binary
  end

  defp compile_one(tag, body) do
    [{_, binary}] = compile("defmodule #{name(tag)} do\n#{body}\nend\n")
    binary
  end

  # The same options `SeriesIdentitySyncCallsTest` sets. Both modules are not async, so no other
  # compile runs while they are set.
  defp compile(source) do
    previous = Code.compiler_options(debug_info: true, docs: true)

    beams =
      try do
        Code.compile_string(source)
      after
        Code.compiler_options(previous)
      end

    on_exit(fn ->
      for {module, _} <- beams do
        :code.purge(module)
        :code.delete(module)
      end
    end)

    beams
  end

  defp name(tag), do: "Cinder.CodeHealth.LazyHtmlCallerTest.Fixture.#{Macro.camelize("#{tag}")}"
end
