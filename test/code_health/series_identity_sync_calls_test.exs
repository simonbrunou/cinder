defmodule Cinder.CodeHealth.SeriesIdentitySyncCallsTest do
  # #830: `Cinder.Catalog.SeriesIdentitySync` is the TMDB identity sync that series creation
  # (`SeriesCatalog`), the refresh (`MetadataRefresh`) and the scene-numbering save
  # (`SceneNumbering`) call one way. It calls none of them, nor the `Cinder.Catalog` facade that
  # delegates to them, and `SeriesCatalog` and `SceneNumbering` no longer call each other, which
  # they did while the sync was split between them. Its public functions, and `SceneNumbering`'s
  # and `SeriesCatalog`'s, each carry a doc: the sync and the season-available query used to be
  # `@doc false` publics that only a sibling called. `SeriesCatalog` keeps one, the facade's
  # `persist_requested_series/4`, which #830 left out of scope.
  #
  # The call check reads each module's function bodies from the debug info in its `.beam`, as
  # Erlang abstract code, and fails on a function whose body holds a banned module's atom. It
  # departs from the source-AST walk docs/agents/testing.md asks of a fence because the compiler
  # has already expanded every alias and import there, so `alias X, as: Y` or an `import` needs
  # no tracking of its own. A fixture below shows each form it catches: an aliased, fully
  # qualified, imported or split-across-lines call, a capture, `apply/3`, and a module held in a
  # tuple, list, map or module attribute. The `.beam` atom table alone missed the capture and the
  # literals. A `.beam` without debug info fails. Forms the check does not see include: a module
  # name built at runtime (`Module.concat/1`, `String.to_atom/1`), a module named only in a
  # typespec, a doc, a comment or a string, a call that runs at compile time in the module body,
  # and a macro of a banned module, which expands away. A fixture shows each.
  #
  # The doc check reads each module's `Docs` chunk and fails on a public function with
  # `@doc false` or no doc, and on a module whose docs cannot be read.
  #
  # Not async: `compile/1` sets global compiler options, and its restore, run while
  # `RemoteTypesTest` compiled a fixture, left that fixture without debug info (#830,
  # `test/code_health/compiler_options_test.exs`).
  use ExUnit.Case, async: false

  alias Cinder.Catalog.{MetadataRefresh, SceneNumbering, SeriesCatalog, SeriesIdentitySync}

  @banned [
    {SeriesIdentitySync, [Cinder.Catalog, SeriesCatalog, MetadataRefresh, SceneNumbering]},
    {SeriesCatalog, [SceneNumbering]},
    {SceneNumbering, [SeriesCatalog]}
  ]

  # Module => the problems `undocumented/1` reports for it on purpose.
  @documented [
    {SeriesIdentitySync, []},
    {SceneNumbering, []},
    {SeriesCatalog, ["Cinder.Catalog.SeriesCatalog.persist_requested_series/4 has @doc false"]}
  ]

  test "SeriesIdentitySync calls none of its callers, and SeriesCatalog and SceneNumbering " <>
         "call neither the other" do
    problems =
      for {module, banned} <- @banned,
          problem <- banned_refs(object_code(module), banned),
          do: problem

    assert problems == [],
           "these functions name a module they must not call (#830):\n  " <>
             Enum.join(problems, "\n  ") <>
             "\nMove what the call needs into Cinder.Catalog.SeriesIdentitySync, or have the " <>
             "caller pass it in."
  end

  test "every public function of SeriesIdentitySync, SceneNumbering and SeriesCatalog has a doc" do
    problems =
      for {module, kept} <- @documented,
          problem <- undocumented(object_code(module)),
          problem not in kept,
          do: problem

    assert problems == [],
           "document these public functions, or make them private (#830):\n  " <>
             Enum.join(problems, "\n  ")
  end

  test "every problem @documented keeps is still reported" do
    stale =
      for {module, kept} <- @documented,
          reported = undocumented(object_code(module)),
          problem <- kept,
          problem not in reported,
          do: problem

    assert stale == [],
           "remove these @documented entries and the header sentence that names them, " <>
             "nothing reports them now:\n  " <> Enum.join(stale, "\n  ")
  end

  describe "the call check" do
    @series_identity_banned [Cinder.Catalog, SeriesCatalog, MetadataRefresh, SceneNumbering]

    test "fails a call to each banned module" do
      calls = %{
        facade: {Cinder.Catalog, "count_series()"},
        series_catalog: {SeriesCatalog, "count_series()"},
        metadata_refresh: {MetadataRefresh, "refresh_series(%Cinder.Catalog.Series{})"},
        scene_numbering: {SceneNumbering, "get_episode_group(nil)"}
      }

      for {tag, {banned, call}} <- calls do
        binary = compile_one(tag, "def f, do: #{inspect(banned)}.#{call}")

        assert [problem] = banned_refs(binary, @series_identity_banned)
        assert problem =~ "f/0 names #{inspect(banned)}"
      end
    end

    test "fails each form that keeps the module in a function body" do
      forms = %{
        aliased: "alias Cinder.Catalog.SeriesCatalog\ndef f, do: SeriesCatalog.count_series()",
        aliased_as:
          "alias Cinder.Catalog.SeriesCatalog, as: Other\ndef f, do: Other.count_series()",
        multi_alias:
          "alias Cinder.Catalog.{Events, SeriesCatalog}\n" <>
            "def f, do: {Events.subscribe_series(), SeriesCatalog.count_series()}",
        split_across_lines: "def f do\n  Cinder.Catalog.SeriesCatalog\n  .count_series()\nend",
        imported:
          "import Cinder.Catalog.SeriesCatalog, only: [count_series: 0]\n" <>
            "def f, do: count_series()",
        capture: "def f, do: &Cinder.Catalog.SeriesCatalog.count_series/0",
        apply: "def f, do: apply(Cinder.Catalog.SeriesCatalog, :count_series, [])",
        tuple: "def f, do: {Cinder.Catalog.SeriesCatalog, :count_series, []}",
        list: "def f, do: [Cinder.Catalog.SeriesCatalog]",
        map: "def f, do: %{module: Cinder.Catalog.SeriesCatalog}",
        attribute: "@module Cinder.Catalog.SeriesCatalog\ndef f, do: @module.count_series()",
        quoted_atom: ~S|def f, do: :"Elixir.Cinder.Catalog.SeriesCatalog"|,
        private: "def f, do: g()\ndefp g, do: Cinder.Catalog.SeriesCatalog.count_series()"
      }

      for {form, body} <- forms do
        binary = compile_one(form, body)

        assert banned_refs(binary, [SeriesCatalog]) != [], "the #{form} form passed the check"
      end
    end

    test "passes a module that names no banned module" do
      binary =
        compile_one(
          :clean,
          "def f, do: Cinder.Catalog.Identity.list_coordinates(%Cinder.Catalog.Series{})"
        )

      assert banned_refs(binary, @series_identity_banned) == []
    end

    test "does not see the forms its header lists as unseen" do
      # A banned module of its own, for the forms that need a type, a macro or a
      # compile-time call no real banned module has.
      compile_one(:banned_fixture, """
      @type t :: atom()
      defmacro m, do: :expanded
      def value, do: 1
      """)

      banned_name = name(:banned_fixture)
      banned = [Module.concat([banned_name])]

      unseen = %{
        concat: "def f, do: Module.concat([Cinder, Catalog, SeriesCatalog])",
        to_atom: ~S|def f, do: String.to_atom("Elixir.Cinder.Catalog.SeriesCatalog")|,
        string: ~S|def f, do: "Cinder.Catalog.SeriesCatalog.count_series()"|,
        comment: "# Cinder.Catalog.SeriesCatalog.count_series()\ndef f, do: :ok",
        doc: "@doc \"Calls Cinder.Catalog.SeriesCatalog.count_series/0.\"\ndef f, do: :ok"
      }

      for {form, body} <- unseen do
        binary = compile_one(form, body)
        assert banned_refs(binary, [SeriesCatalog]) == [], "the #{form} form was seen"
      end

      fixture_unseen = %{
        typespec: "@spec f() :: #{banned_name}.t()\ndef f, do: :ok",
        compile_time: "@value #{banned_name}.value()\ndef f, do: @value",
        macro: "require #{banned_name}\ndef f, do: #{banned_name}.m()"
      }

      for {form, body} <- fixture_unseen do
        binary = compile_one(form, body)
        assert banned_refs(binary, banned) == [], "the #{form} form was seen"
      end

      # The control: the same banned fixture module is seen once a function body names it.
      binary = compile_one(:fixture_call, "def f, do: #{banned_name}.value()")
      assert [_] = banned_refs(binary, banned)
    end

    # `:beam_lib.strip/1` drops the debug info chunk. Compiling with `debug_info: false` instead
    # would flip a global compiler option that every concurrent compile reads.
    test "fails a .beam without debug info" do
      {:ok, {_, stripped}} = :no_debug_info |> compile_one("def f, do: :ok") |> :beam_lib.strip()

      assert [problem] = banned_refs(stripped, [SeriesCatalog])
      assert problem =~ "cannot read the debug info"
    end
  end

  describe "the doc check" do
    test "fails a public function with @doc false or no doc, and passes a documented one" do
      binary =
        compile_one(:docs, """
        @doc false
        def hidden, do: :ok

        def bare, do: :ok

        @doc "Documented."
        def documented(a \\\\ 1), do: a

        defp private, do: :ok
        def calls_private, do: private()
        """)

      assert binary |> undocumented() |> Enum.sort() == [
               "#{name(:docs)}.bare/0 has no doc",
               "#{name(:docs)}.calls_private/0 has no doc",
               "#{name(:docs)}.hidden/0 has @doc false"
             ]
    end

    test "fails a module whose docs cannot be read" do
      {:ok, {_, stripped}} =
        :no_docs |> compile_one("@doc \"Documented.\"\ndef f, do: :ok") |> :beam_lib.strip()

      assert [problem] = undocumented(stripped)
      assert problem =~ "cannot read the docs"
    end
  end

  # Each `{:function, ...}` form of the module's Erlang abstract code that holds a banned atom.
  defp banned_refs(binary, banned) do
    module = module_name(binary)

    case abstract_code(module, binary) do
      {:ok, forms} ->
        for {:function, _line, name, arity, _clauses} = form <- forms,
            ref <- banned,
            ref in atoms(form),
            do: "#{inspect(module)}.#{name}/#{arity} names #{inspect(ref)}"

      error ->
        ["#{inspect(module)}: cannot read the debug info in its .beam (#{inspect(error)})"]
    end
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

  defp undocumented(binary) do
    module = module_name(binary)

    case :beam_lib.chunks(binary, [~c"Docs"]) do
      {:ok, {^module, [{~c"Docs", docs}]}} ->
        {:docs_v1, _, _, _, _, _, entries} = :erlang.binary_to_term(docs)

        for {{:function, name, arity}, _anno, _signature, doc, _meta} <- entries,
            doc in [:hidden, :none],
            do: "#{inspect(module)}.#{name}/#{arity} has #{doc_problem(doc)}"

      {:error, :beam_lib, reason} ->
        ["#{inspect(module)}: cannot read the docs in its .beam (#{inspect(reason)})"]
    end
  end

  defp doc_problem(:hidden), do: "@doc false"
  defp doc_problem(:none), do: "no doc"

  defp module_name(binary), do: binary |> :beam_lib.info() |> Keyword.fetch!(:module)

  defp object_code(module) do
    {^module, binary, _path} = :code.get_object_code(module)
    binary
  end

  defp compile_one(tag, body) do
    [{_, binary}] = compile("defmodule #{name(tag)} do\n#{body}\nend\n")
    binary
  end

  # The same options `RemoteTypesTest` sets. Both modules are not async, so no other compile
  # runs while they are set.
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

  defp name(tag),
    do: "Cinder.CodeHealth.SeriesIdentitySyncCallsTest.Fixture.#{Macro.camelize("#{tag}")}"
end
