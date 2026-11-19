defmodule Cinder.CodeHealth.ManifestWritersTest do
  # Only `Cinder.Subtitles.SidecarTransaction` and its modules under
  # `lib/cinder/subtitles/sidecar_transaction/` write the subtitle manifest's sync record, its two
  # cleanup journals and its backup tombstone. The fence skips
  # `lib/cinder/subtitles/sidecar_transaction.ex` and every file under that directory, and fails
  # any other file under `lib/` that names one of `@writers` on `Cinder.Subtitles.Manifest`, or
  # `Manifest.put/7` or `put/8`, or that imports `Manifest`. The seventh argument of `put` opens
  # the replacement cleanup journal when it is not `nil`; `put/4` to `put/6` cannot pass it. Until
  # #1481 the fence failed only `put/7`, so the `put/8` that #1098 added passed it.
  #
  # It walks each file's AST from `Code.string_to_quoted!/1`, so a comment, a doc or a string that
  # names a writer passes. It catches a call, fully qualified, split across lines or piped (a pipe
  # adds its left side to the arity); a capture, `&Manifest.clear_sync/2` or
  # `&Manifest.clear_sync(&1, "en")`; a module reached through `alias`, plain, with `as:`, in a
  # `{...}` group or under a parent alias (`Subtitles.Manifest`), through `require` with `as:`, or
  # written as a quoted atom (`:"Elixir.Cinder.Subtitles.Manifest"`) in a call, a capture, an
  # import, a delegate, or an `alias` or `require` with `as:`; a `defdelegate` or
  # `Kernel.defdelegate` to `Manifest`; and an `import` of `Manifest`, with or without `only:`.
  # A module counts as `Manifest` when its name, after the file's aliases, ends in `Manifest`:
  # `lib/` holds no other module of that name, and an `alias __MODULE__.Manifest` then counts
  # too. The aliases are the whole file's, so an alias name that two aliases in the file give two
  # modules counts as both.
  #
  # Forms the walk does not follow include: `apply/3`, `Function.capture/3` or any call that takes
  # the module and the function name as values; a module held in a variable or a module attribute;
  # and a module name built at runtime (`Module.concat/1`). A fixture below shows each.
  #
  # #1481 moved this fence here from `SidecarTransactionResetTest`, where it matched the writer
  # names with a regex over each file's text and so passed a capture with an arity
  # (`&Manifest.clear_sync/2`) or a call through an `as:` alias and failed a comment. It stays a
  # source walk rather than the `.beam` walk docs/agents/testing.md gives a fence on which modules
  # a module calls (`series_identity_sync_calls_test.exs`): that fence bans whole modules, while
  # this one bans a few functions of a module that `lib/` calls elsewhere (`Manifest.read/1`), and
  # #1481 asked for the source walk the `put` half already used.
  use ExUnit.Case, async: true

  @transaction "lib/cinder/subtitles/sidecar_transaction"
  @kernel [[:Kernel], [:"Elixir", :Kernel]]
  @writers [
    :put_sync,
    :clear_sync,
    :begin_replacement_cleanup,
    :clear_replacement_cleanup,
    :begin_reset_cleanup,
    :finish_reset_cleanup,
    :put_backup_tombstone
  ]

  test "only the transaction writes the manifest's record, journal and tombstone fields" do
    problems = "lib/**/*.ex" |> Path.wildcard() |> Enum.map(&{&1, File.read!(&1)}) |> problems()

    assert problems == [],
           "Only Cinder.Subtitles.SidecarTransaction writes the manifest's sync record, cleanup " <>
             "journals and backup tombstone (#1481):\n  " <>
             Enum.join(problems, "\n  ") <>
             "\nCall the SidecarTransaction function that makes this change instead."
  end

  # A walk that found nothing would pass the fence above on nothing.
  test "the walk finds every writer and a put with 7 or more arguments in the transaction's files" do
    found =
      for path <- Path.wildcard("lib/**/*.ex"),
          transaction?(path),
          ref <- path |> File.read!() |> manifest_refs(),
          writes?(ref),
          into: MapSet.new(),
          do: elem(ref, 0)

    assert found == MapSet.new([:put | @writers])
  end

  test "the fence skips the transaction's files and no other" do
    files =
      for path <- [
            "lib/cinder/subtitles/sidecar_transaction.ex",
            "lib/cinder/subtitles/sidecar_transaction/backup.ex",
            "lib/cinder/subtitles/sidecar_transaction_probe.ex",
            "lib/cinder/subtitles/sync.ex"
          ],
          do: {path, "Manifest.clear_sync(v, l)"}

    assert problems(files) == [
             "lib/cinder/subtitles/sidecar_transaction_probe.ex:1: " <>
               "Cinder.Subtitles.Manifest.clear_sync/2",
             "lib/cinder/subtitles/sync.ex:1: Cinder.Subtitles.Manifest.clear_sync/2"
           ]
  end

  describe "the walk" do
    caught = [
      {"a fully qualified call", "Cinder.Subtitles.Manifest.clear_sync(v, l)", {:clear_sync, 2}},
      {"a call through a grouped alias",
       "alias Cinder.Subtitles.{Manifest, Sync}\nManifest.clear_sync(v, l)", {:clear_sync, 2}},
      {"a call through an as: alias",
       "alias Cinder.Subtitles.Manifest, as: M\nM.clear_sync(v, l)", {:clear_sync, 2}},
      {"a call through a parent alias",
       "alias Cinder.Subtitles\nSubtitles.Manifest.clear_sync(v, l)", {:clear_sync, 2}},
      {"an as: alias of a parent alias",
       "alias Cinder.Subtitles\nalias Subtitles.Manifest, as: M\nM.clear_sync(v, l)",
       {:clear_sync, 2}},
      {"an alias name that a later alias gives another module",
       "alias Cinder.Subtitles.Manifest, as: M\nalias Cinder.Other, as: M\nM.clear_sync(v, l)",
       {:clear_sync, 2}},
      {"a grouped alias of a name an earlier alias gave another module",
       "alias Cinder.Other, as: Manifest\nalias Cinder.Subtitles.{Manifest, Sync}\n" <>
         "Manifest.clear_sync(v, l)", {:clear_sync, 2}},
      {"a call through a require with as:",
       "require Cinder.Subtitles.Manifest, as: M\nM.clear_sync(v, l)", {:clear_sync, 2}},
      {"a call on the module's quoted atom",
       ~S|:"Elixir.Cinder.Subtitles.Manifest".clear_sync(v, l)|, {:clear_sync, 2}},
      {"an as: alias of the module's quoted atom",
       ~S|alias :"Elixir.Cinder.Subtitles.Manifest", as: M| <> "\nM.clear_sync(v, l)",
       {:clear_sync, 2}},
      {"a require with as: of the module's quoted atom",
       ~S|require :"Elixir.Cinder.Subtitles.Manifest", as: M| <> "\nM.clear_sync(v, l)",
       {:clear_sync, 2}},
      {"a capture of the module's quoted atom",
       ~S|f = &:"Elixir.Cinder.Subtitles.Manifest".clear_sync/2|, {:clear_sync, 2}},
      {"a defdelegate to the module's quoted atom",
       ~S|defdelegate clear_sync(v, l), to: :"Elixir.Cinder.Subtitles.Manifest"|,
       {:clear_sync, 2}},
      {"a Kernel.defdelegate",
       "Kernel.defdelegate wipe(v, l), to: Cinder.Subtitles.Manifest, as: :clear_sync",
       {:clear_sync, 2}},
      {"a call through alias __MODULE__.Manifest",
       "alias __MODULE__.Manifest\nManifest.clear_sync(v, l)", {:clear_sync, 2}},
      {"a call split across lines", "Manifest\n.clear_sync(\n  v,\n  l\n)", {:clear_sync, 2}},
      {"a capture with an arity", "f = &Manifest.clear_sync/2", {:clear_sync, 2}},
      {"a capture through an as: alias",
       "alias Cinder.Subtitles.Manifest, as: M\nf = &M.clear_sync/2", {:clear_sync, 2}},
      {"a capture with arguments", ~S|f = &Manifest.clear_sync(&1, "en")|, {:clear_sync, 2}},
      {"a piped call, counting the piped value", "v |> Manifest.put(l, a, b, c, d, e)",
       {:put, 7}},
      {"a call at the end of a chain of pipes",
       "v |> String.trim() |> Manifest.put(l, a, b, c, d, e)", {:put, 7}},
      {"a capture of put/8", "f = &Manifest.put/8", {:put, 8}},
      {"a defdelegate", "defdelegate clear_sync(v, l), to: Cinder.Subtitles.Manifest",
       {:clear_sync, 2}},
      {"a defdelegate with as:",
       "alias Cinder.Subtitles.Manifest\ndefdelegate wipe(v, l), to: Manifest, as: :clear_sync",
       {:clear_sync, 2}}
    ]

    for {form, source, {name, arity}} <- caught do
      test "catches #{form}" do
        assert [{unquote(name), unquote(arity), _line}] = manifest_refs(unquote(source))
      end
    end

    test "catches an import of Manifest, with or without only:" do
      for source <- [
            "import Cinder.Subtitles.Manifest",
            ~S|import :"Elixir.Cinder.Subtitles.Manifest"|,
            "alias Cinder.Subtitles\nimport Subtitles.Manifest, only: [clear_sync: 2]"
          ] do
        refs = manifest_refs(source)
        assert match?([{:import, _line}], refs), source
        assert Enum.all?(refs, &writes?/1)
      end
    end

    test "reports the line of each reference" do
      source = "x = 1\n\nManifest.clear_sync(v, l)\nf = &Manifest.put_sync/3"

      assert [{:clear_sync, 2, 3}, {:put_sync, 3, 4}] = manifest_refs(source)
    end

    test "fails a writer, put/7 and put/8 and passes a read and the other put arities" do
      source = """
      Manifest.read(v)
      Manifest.put(v, h, l, o)
      Manifest.put(v, h, l, o, s)
      Manifest.put(v, h, l, o, s, m)
      Manifest.put(v, h, l, o, s, m, c)
      Manifest.put(v, h, l, o, s, m, c, t)
      Manifest.put_backup_tombstone(v, l, i)
      """

      assert source |> manifest_refs() |> Enum.filter(&writes?/1) |> Enum.map(&line/1) ==
               [5, 6, 7]
    end

    test "skips a writer named in a comment, a doc or a string" do
      source = ~S'''
      # Manifest.clear_sync(v, l) is only for the transaction
      @doc """
      Manifest.clear_sync(v, l)
      """
      x = "Manifest.clear_sync(v, l)"
      y = ~s(&Manifest.clear_sync/2)
      '''

      assert manifest_refs(source) == []
    end

    test "skips a module of another name aliased as Manifest" do
      assert manifest_refs("alias Cinder.Other, as: Manifest\nManifest.clear_sync(v, l)") == []

      # A `require` without `as:` leaves the alias as it was.
      for require <- [
            "require Cinder.Subtitles.Manifest",
            "require Cinder.Subtitles.Manifest, warn: false"
          ] do
        source = "alias Cinder.Other, as: Manifest\n#{require}\nManifest.clear_sync(v, l)"
        assert manifest_refs(source) == [], source
      end
    end

    test "does not see the forms its header lists as unseen" do
      for source <- [
            "apply(Cinder.Subtitles.Manifest, :clear_sync, [v, l])",
            "Function.capture(Cinder.Subtitles.Manifest, :clear_sync, 2)",
            "m = Cinder.Subtitles.Manifest\nm.clear_sync(v, l)",
            "@m Cinder.Subtitles.Manifest\ndef f(v, l), do: @m.clear_sync(v, l)",
            "Module.concat(Cinder.Subtitles, Manifest).clear_sync(v, l)"
          ] do
        assert source |> manifest_refs() |> Enum.filter(&writes?/1) == [], source
      end
    end
  end

  # `{path, source}` pairs => one line per write outside the transaction's files.
  defp problems(files) do
    for {path, source} <- files,
        not transaction?(path),
        ref <- manifest_refs(source),
        writes?(ref),
        do: "#{path}:#{line(ref)}: #{describe(ref)}"
  end

  defp transaction?(path),
    do: path == @transaction <> ".ex" or String.starts_with?(path, @transaction <> "/")

  defp writes?({:import, _line}), do: true
  defp writes?({:put, arity, _line}), do: arity >= 7
  defp writes?({name, _arity, _line}), do: name in @writers

  defp line({:import, line}), do: line
  defp line({_name, _arity, line}), do: line

  defp describe({:import, _line}), do: "import of Cinder.Subtitles.Manifest"
  defp describe({name, arity, _line}), do: "Cinder.Subtitles.Manifest.#{name}/#{arity}"

  # Each reference the source makes to `Manifest`: `{name, arity, line}` for a call, a capture or
  # a `defdelegate`, and `{:import, line}` for an import.
  defp manifest_refs(source) do
    ast = source |> Code.string_to_quoted!() |> Macro.prewalk(&normalize/1)
    aliases = aliases(ast)

    {_ast, refs} = Macro.prewalk(ast, [], fn node, acc -> {node, ref(node, aliases) ++ acc} end)
    Enum.reverse(refs)
  end

  # `v |> M.f(a)` is `M.f(v, a)`, `&M.f/2` names `M.f` with two arguments, and
  # `Kernel.defdelegate` is `defdelegate`. `Macro.prewalk/2` walks the node it gets back, so a
  # chain of pipes unwinds one pipe at a time.
  defp normalize({:|>, _, [left, {call, meta, args}]}) when is_list(args),
    do: {call, meta, [left | args]}

  defp normalize({{:., _, [{:__aliases__, _, kernel}, :defdelegate]}, meta, args})
       when kernel in @kernel,
       do: {:defdelegate, meta, args}

  defp normalize({:&, _, [{:/, _, [{{:., _, [_, _]} = call, meta, []}, arity]}]})
       when is_integer(arity),
       do: {call, meta, List.duplicate(:captured, arity)}

  defp normalize(node), do: node

  defp ref({{:., _, [module, name]}, meta, args}, aliases) when is_atom(name) and is_list(args) do
    if manifest?(module, aliases), do: [{name, length(args), meta[:line]}], else: []
  end

  defp ref({:defdelegate, meta, [{name, _, args}, opts]}, aliases) when is_list(opts) do
    if manifest?(opts[:to], aliases),
      do: [{Keyword.get(opts, :as, name), length(args || []), meta[:line]}],
      else: []
  end

  defp ref({:import, meta, [module | _]}, aliases) do
    if manifest?(module, aliases), do: [{:import, meta[:line]}], else: []
  end

  defp ref(_node, _aliases), do: []

  # Whether a module node, an alias such as `Subtitles.Manifest` or a quoted atom such as
  # `:"Elixir.Cinder.Subtitles.Manifest"`, names `Manifest`.
  defp manifest?({:__aliases__, _, module}, aliases),
    do: module |> expansions(aliases) |> Enum.any?(&manifest_name?(List.last(&1)))

  defp manifest?(module, _aliases) when is_atom(module), do: manifest_name?(module)
  defp manifest?(_module, _aliases), do: false

  # The last segment of a module name: `:Manifest` from an alias, or a whole quoted atom that an
  # `as:` alias stands for.
  defp manifest_name?(:Manifest), do: true

  defp manifest_name?(name) when is_atom(name),
    do: name |> Atom.to_string() |> String.ends_with?(".Manifest")

  defp manifest_name?(_name), do: false

  # Alias name => every module name the file's `alias` forms, and its `require` forms with `as:`,
  # give it, in the order they appear.
  defp aliases(ast) do
    {_ast, aliases} =
      Macro.prewalk(ast, %{}, fn
        {:alias, _, [target | opts]} = node, acc -> {node, add_alias(target, opts, acc)}
        {:require, _, [target, opts]} = node, acc -> {node, add_require(target, opts, acc)}
        node, acc -> {node, acc}
      end)

    aliases
  end

  # `require Mod, as: M` aliases `Mod` as `M`; a `require` without `as:` aliases nothing.
  defp add_require(target, opts, acc) when is_list(opts) do
    if Keyword.has_key?(opts, :as), do: add_alias(target, [opts], acc), else: acc
  end

  defp add_require(_target, _opts, acc), do: acc

  defp add_alias({:__aliases__, _, module}, opts, acc),
    do: put_alias(acc, alias_name(module, opts), module)

  defp add_alias({{:., _, [{:__aliases__, _, base}, :{}]}, _, children}, _opts, acc) do
    Enum.reduce(children, acc, fn
      {:__aliases__, _, child}, acc -> put_alias(acc, List.last(child), base ++ child)
      _child, acc -> acc
    end)
  end

  # `alias :"Elixir.Cinder.Subtitles.Manifest", as: M` gives `M` the atom as its one segment.
  # Without `as:`, the alias name is the atom's last segment, which counts as `Manifest` on its
  # own already.
  defp add_alias(module, [opts], acc) when is_atom(module) and is_list(opts) do
    case opts[:as] do
      {:__aliases__, _, [as]} -> put_alias(acc, as, [module])
      _ -> acc
    end
  end

  defp add_alias(_target, _opts, acc), do: acc

  defp alias_name(module, [opts]) when is_list(opts) do
    case opts[:as] do
      {:__aliases__, _, [as]} -> as
      _ -> List.last(module)
    end
  end

  defp alias_name(module, _opts), do: List.last(module)

  defp put_alias(aliases, name, module) do
    expanded = expansions(module, aliases)
    Map.update(aliases, name, expanded, &(&1 ++ expanded))
  end

  # The module names `module` can stand for, its first segment expanded through the file's aliases.
  defp expansions([first | rest] = module, aliases) do
    case Map.get(aliases, first, []) do
      [] -> [module]
      fulls -> Enum.map(fulls, &(&1 ++ rest))
    end
  end
end
