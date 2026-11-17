defmodule Cinder.CodeHealth.DocNamesTest do
  # Agent docs, repo skills and code comments name functions and files by hand, and every refactor
  # in the #730 run left some of those names dead: a reviewer agent that reads a skill as ground
  # truth then checks the wrong code (#850). This fence reads each backticked `Module.fun/arity`
  # and `lib/...` path in AGENTS.md, docs/agents/, .agents/skills/ and the `#` comments of the
  # `.ex` files under lib/, and fails on each one that does not resolve on the current tree:
  #
  #   * `Module.fun/arity` resolves when a module whose name is `Module`, or ends in `.Module`,
  #     defines `fun` at that arity: public or private, a function or a macro, or a behaviour
  #     callback. Modules are those on the code path in the test env, so lib/, test/support/,
  #     Elixir, OTP and the deps count. A short name with several such modules (`Grabs`) resolves
  #     when any of them defines it. `fun/1,2` and `fun/1..3` need every arity they name, and a
  #     range that names none (`fun/3..1`) fails.
  #   * A bare `fun/arity` in a lib/ comment resolves against the file's first `defmodule` only,
  #     with no imports: write `Kernel.inspect/1`, `Ecto.Changeset.change/2`. In Markdown it is
  #     skipped.
  #   * A `lib/` path resolves when the file or directory exists, a glob when it matches, with any
  #     `:line` suffix dropped.
  #   * `skip-name-check` on the line where a code span opens skips that span: for a name meant as
  #     history, or one a macro defines in other modules (`Cinder.Download.PollerSkeleton`). It
  #     fails on a line that names more than one function or path, so it skips one name only, and
  #     it never skips a backtick run with no partner.
  #
  # Code spans pair each backtick run with the next run of the same length in its paragraph, as
  # Markdown does, so a span may cross lines, in a comment block or a `>` quote too; a name wrapped
  # after a `.` or `/`, or before a `.`, reads whole. A run with no partner fails, since the fence
  # cannot tell which names follow it. Lines inside a ``` block are not read.
  #
  # Forms the walk does not follow include: `@doc` and `@moduledoc` text, a HEEx comment, a bare
  # `fun/arity` in Markdown, a name without backticks, a type (`Movie.t()`, #852), a name with an
  # ExDoc prefix (`t:`, `c:`), an Erlang module (`:global.trans/2`), a module part that does not
  # start with a capital (`__MODULE__.run/1`), a name wrapped right before its `/`, a path outside
  # lib/ or one written from a subdirectory (`settings/registry.ex`), a function of a test `.exs`
  # file, and a ~~~ fence or an indented code block, read as prose.
  use ExUnit.Case, async: true

  @marker "skip-name-check"

  test "every function and lib/ path the agent docs, skills and lib/ comments name exists" do
    markdown =
      for path <-
            ["AGENTS.md"] ++
              Path.wildcard("docs/agents/**/*.md") ++
              Path.wildcard(".agents/skills/**/*.md", match_dot: true),
          do: {path, :markdown, File.read!(path)}

    elixir = for path <- Path.wildcard("lib/**/*.ex"), do: {path, :elixir, File.read!(path)}
    dead = dead_names(markdown ++ elixir)

    assert dead == [],
           "These names do not resolve on the current tree. Rename each to the function or " <>
             "path that exists now: qualify a function another module defines " <>
             "(`HTTPPolicy.sanitize_log/1`, `Kernel.inspect/1`) and give the arity it has " <>
             "today. A name meant as history, or one a macro defines elsewhere, takes " <>
             "#{@marker} on the line where its code span opens. The header of " <>
             "test/code_health/doc_names_test.exs says how each form resolves.\n" <>
             Enum.join(dead, "\n")
  end

  @doc_source """
  Intro with `Cinder.Requests.create_request/2`, `Requests.create_request/2`, `lib/cinder`,
  `lib/cinder/*.ex` and `lib/cinder/requests.ex:42`.

  - dead full name `Cinder.Library.staged_quality/5`
  - dead short name `Library.staged_quality/5`
  - wrong arity `Cinder.Requests.create_request/3`
  - dead path `lib/cinder/nope.ex` and dead glob `lib/nope/*.ex`
  - a bare name is skipped here: `nope/1`
  - history `Cinder.Library.staged_quality/5` skip-name-check
  - a lone ` backtick in one item
  - does not pair with this ` one

  ```elixir
  `Cinder.Nope.f/1` in a code block
  ```

  A span split `Cinder.Library.
  staged_quality/5` across lines, and a lone ` backtick.

  The next paragraph's ` backtick is alone too.

  `Cinder.Catalog.Grabs.finish_grab/1..4` resolves, `Cinder.Catalog.Grabs.finish_grab/1..5` does not.

  Two names `Cinder.Nope.a/1` and `Cinder.Nope.b/1` share skip-name-check.

  Split before the dot `Cinder.Library
  .staged_quality/5` reads whole.

  > Quoted `Cinder.Library.
  > staged_quality/5` reads whole.

  > A quoted lone ` backtick
  >
  > ends its paragraph at the bare `>`.

  Resolve: ``Cinder.Repo.one!/1``, `Cinder.Download.reconcile_matching_intent/3`,
  `Cinder.Library.ep_upgrade?/3` and `lib/cinder/{requests,books}.ex`.

  Dead: ``Cinder.Repo.nope!/1``, `lib/cinder/{nope_a,nope_b}.ex`, `Cinder.Library.staged_quality/
  5` and `lib/cinder/
  nope_dead.ex`.

  Dead: `Cinder.Catalog.Grabs.finish_grab/1..4,6`, `Cinder.Requests.create_request/2..1`.

  `Cinder.Library.nope/1 and Cinder.Library.nope/2` share skip-name-check.

  `Cinder.Library.nope/3
  /tmp` is no path.

  `Cinder.Library.nope/4` skip-name-check, and a lone ` here.

  Dead: `Cinder.Catalog.Grabs.finish_grab/1..4,3..1`.
  """

  test "a doc fails on a dead full name, short name, arity, path and unpaired backtick" do
    assert dead_names([{"doc.md", :markdown, @doc_source}]) == [
             "doc.md:4: `Cinder.Library.staged_quality/5`",
             "doc.md:5: `Library.staged_quality/5`",
             "doc.md:6: `Cinder.Requests.create_request/3`",
             "doc.md:7: `lib/cinder/nope.ex` does not exist",
             "doc.md:7: `lib/nope/*.ex` does not exist",
             "doc.md:10: a backtick run with no partner in its paragraph",
             "doc.md:11: a backtick run with no partner in its paragraph",
             "doc.md:17: `Cinder.Library.staged_quality/5`",
             "doc.md:18: a backtick run with no partner in its paragraph",
             "doc.md:20: a backtick run with no partner in its paragraph",
             "doc.md:22: `Cinder.Catalog.Grabs.finish_grab/1..5`",
             "doc.md:24: #{@marker} shares its line with more than one name",
             "doc.md:26: `Cinder.Library.staged_quality/5`",
             "doc.md:29: `Cinder.Library.staged_quality/5`",
             "doc.md:32: a backtick run with no partner in its paragraph",
             "doc.md:39: `Cinder.Repo.nope!/1`",
             "doc.md:39: `lib/cinder/{nope_a,nope_b}.ex` does not exist",
             "doc.md:39: `Cinder.Library.staged_quality/5`",
             "doc.md:40: `lib/cinder/nope_dead.ex` does not exist",
             "doc.md:43: `Cinder.Catalog.Grabs.finish_grab/1..4,6`",
             "doc.md:43: `Cinder.Requests.create_request/2..1`",
             "doc.md:45: #{@marker} shares its line with more than one name",
             "doc.md:47: `Cinder.Library.nope/3`",
             "doc.md:50: a backtick run with no partner in its paragraph",
             "doc.md:52: `Cinder.Catalog.Grabs.finish_grab/1..4,3..1`"
           ]
  end

  @lib_source ~S'''
  defmodule Cinder.Requests do
    # Private `create_request_for/4` and `snapshot_request/1`, `Grabs.delete_only/1` in one of
    # two `Grabs`, the callback `Cinder.Download.Client.list_managed/0`, the macro
    # `Kernel.if/2`, `Cinder.ConfigCase.put_env/1,2` and `lib/cinder/requests.ex:42` resolve.
    # Dead: `create_request_for/3`, `nope/1`, `inspect/1`, `Cinder.ConfigCase.put_env/1,3`,
    # `lib/cinder/requests.exs`, `create_request_for/4,5`, `create_request_for/4..3`.
    # History: `create_request_for/3` skip-name-check
    def f, do: "# `nope/2` is a string, not a comment"

    # A span split `Cinder.Library.
    # staged_quality/5` across comment lines.
    def g, do: :ok # a trailing `nope/3`

    # > A quoted `Cinder.Library.
    # > staged_quality/5`, a lone ` here,
    # >
    # > and a lone ` there.
  end
  '''

  test "a lib/ comment resolves a bare name against its own module, and fails on a dead one" do
    assert dead_names([{"lib.ex", :elixir, @lib_source}]) == [
             "lib.ex:5: `create_request_for/3`",
             "lib.ex:5: `nope/1`",
             "lib.ex:5: `inspect/1`",
             "lib.ex:5: `Cinder.ConfigCase.put_env/1,3`",
             "lib.ex:6: `lib/cinder/requests.exs` does not exist",
             "lib.ex:6: `create_request_for/4,5`",
             "lib.ex:6: `create_request_for/4..3`",
             "lib.ex:10: `Cinder.Library.staged_quality/5`",
             "lib.ex:12: `nope/3`",
             "lib.ex:14: `Cinder.Library.staged_quality/5`",
             "lib.ex:15: a backtick run with no partner in its paragraph",
             "lib.ex:17: a backtick run with no partner in its paragraph"
           ]
  end

  test "a skill fails on a dead name as a doc does" do
    skill = "---\nname: x\n---\n\nRead `Registry.secret_keys/0` and `Settings.secret?/1`.\n"

    assert dead_names([{".agents/skills/x/SKILL.md", :markdown, skill}]) == [
             ".agents/skills/x/SKILL.md:5: `Registry.secret_keys/0`"
           ]
  end

  test "exports resolve from a module's .beam, or from its loaded copy when it has no .beam" do
    # Mix loads `Cinder.MixProject` from mix.exs, so the code path holds no `.beam` for it.
    assert {~c"Elixir.Cinder.MixProject", [], true} in :code.all_available()

    # `module_info/1` is in the exports chunk only, not in the Elixir debug info.
    doc =
      "Read `Cinder.Requests.module_info/1` and `Cinder.MixProject.project/0`, " <>
        "not `Cinder.MixProject.nope/0`.\n"

    assert dead_names([{"doc.md", :markdown, doc}]) == ["doc.md:1: `Cinder.MixProject.nope/0`"]
  end

  @tag :tmp_dir
  test "a name fails when its module's .beam file cannot be read", %{tmp_dir: tmp_dir} do
    # Loaded, so a read that fell back to the loaded copy's exports would resolve the name.
    Code.ensure_loaded!(Cinder.Requests)
    gone = tmp_dir |> Path.join("Elixir.Cinder.Requests.beam") |> String.to_charlist()

    index = %{
      suffixes: %{"Cinder.Requests" => [Cinder.Requests]},
      paths: %{Cinder.Requests => gone}
    }

    doc = "Read `Cinder.Requests.create_request/2`.\n"

    assert dead_names([{"doc.md", :markdown, doc}]) == []

    assert dead_names([{"doc.md", :markdown, doc}], index) == [
             "doc.md:1: `Cinder.Requests.create_request/2`"
           ]
  end

  # --- extraction

  defp dead_names(sources, index \\ module_index()) do
    for {path, kind, source} <- sources,
        ref <- refs(kind, source),
        not resolves?(ref, index),
        do: "#{path}:#{ref.line}: #{describe(ref)}"
  end

  defp describe(%{kind: :unpaired}), do: "a backtick run with no partner in its paragraph"
  defp describe(%{kind: :shared_marker}), do: "#{@marker} shares its line with more than one name"
  defp describe(%{kind: :path, path: path}), do: "`#{path}` does not exist"

  defp describe(%{module: module, fun: fun, arity_text: arity_text}),
    do: "`#{if module, do: module <> ".", else: ""}#{fun}/#{arity_text}`"

  defp refs(:markdown, source) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce({[], false}, fn {text, line}, {lines, in_code} ->
      cond do
        text |> String.trim_leading() |> String.starts_with?("```") -> {lines, not in_code}
        in_code -> {lines, in_code}
        true -> {[{line, text} | lines], in_code}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
    |> blocks(&markdown_block_start?/1)
    |> Enum.flat_map(&block_refs(&1, nil))
    |> Enum.reject(&(&1.kind == :bare))
  end

  defp refs(:elixir, source) do
    {:ok, ast, comments} = Code.string_to_quoted_with_comments(source)

    comments
    |> Enum.map(&{&1.line, &1.text})
    |> blocks(fn _text -> false end)
    |> Enum.flat_map(&block_refs(&1, file_module(ast)))
  end

  defp file_module(ast) do
    {_ast, module} =
      Macro.prewalk(ast, nil, fn
        {:defmodule, _, [{:__aliases__, _, parts} | _]} = node, nil ->
          {node, Module.concat(parts)}

        node, acc ->
          {node, acc}
      end)

    module
  end

  # A list item, a heading or a table row starts a new Markdown block.
  defp markdown_block_start?(text), do: text =~ ~r/^\s*([-*+]\s|\d+\.\s|#|\|)/

  # Runs of consecutive lines, split at a blank line (or a bare `#`, `>` or `# >`) and before each
  # line `starts_block?` accepts: a code span never crosses a paragraph.
  defp blocks(lines, starts_block?) do
    lines
    |> Enum.chunk_while(
      [],
      fn {line, text} = entry, acc ->
        cond do
          text =~ ~r/^\s*#?\s*>?\s*$/ -> {:cont, Enum.reverse(acc), []}
          acc != [] and elem(hd(acc), 0) != line - 1 -> {:cont, Enum.reverse(acc), [entry]}
          starts_block?.(text) -> {:cont, Enum.reverse(acc), [entry]}
          true -> {:cont, [entry | acc]}
        end
      end,
      fn acc -> {:cont, Enum.reverse(acc), []} end
    )
    |> Enum.reject(&(&1 == []))
  end

  defp block_refs([{first, _text} | _] = lines, module) do
    text = Enum.map_join(lines, "\n", &elem(&1, 1))

    text
    |> spans()
    |> Enum.map(fn {span, offset} ->
      {first + (text |> binary_part(0, offset) |> :binary.matches("\n") |> length()),
       span_refs(span)}
    end)
    |> Enum.reject(fn {_line, refs} -> refs == [] end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.sort()
    |> Enum.flat_map(fn {line, span_refs} ->
      {^line, line_text} = Enum.at(lines, line - first)

      {unpaired, names} = span_refs |> Enum.concat() |> Enum.split_with(&(&1.kind == :unpaired))

      cond do
        not String.contains?(line_text, @marker) -> Enum.concat(span_refs)
        length(names) > 1 -> [%{kind: :shared_marker} | unpaired]
        true -> unpaired
      end
      |> Enum.map(&Map.merge(&1, %{line: line, enclosing: module}))
    end)
  end

  # Each code span with the byte offset of its opening run, and `:unpaired` for a run with no
  # partner of the same length in the block.
  defp spans(text) do
    ~r/`+/
    |> Regex.scan(text, return: :index)
    |> Enum.map(fn [run] -> run end)
    |> pair(text, [])
  end

  defp pair([], _text, acc), do: Enum.reverse(acc)

  defp pair([{start, len} | rest], text, acc) do
    case Enum.split_while(rest, fn {_start, other} -> other != len end) do
      {_inner, []} ->
        pair(rest, text, [{:unpaired, start} | acc])

      {_inner, [{close, ^len} | tail]} ->
        span = text |> binary_part(start + len, close - start - len) |> unwrap()
        pair(tail, text, [{span, start} | acc])
    end
  end

  # A span that crosses lines, without the line break and the next line's indent, `#` or `>`. A
  # break right after a `.` or `/`, or right before a `.`, joins the two halves, so a name wrapped
  # there reads whole. A line that starts with `/` starts a new word: it is a path more often.
  defp unwrap(span) do
    Regex.replace(~r/([.\/]?)\n\s*(?:[#>]\s?)*(?=(\.?))/, span, fn
      _match, "", "" -> " "
      _match, joint, _next -> joint
    end)
  end

  # A name starts after anything but a word character, `.`, `/` or `:`, so `:global.trans/2`,
  # `t:Mod.t/0` and a path segment never match.
  @function ~r/(?<![\w.\/:])((?:[A-Z]\w*\.)*)([a-z_]\w*[?!]?)\/(\d+(?:\.\.\d+)?(?:,\d+(?:\.\.\d+)?)*)(?![\w\/])/
  @path ~r/(?<![\w.\/~-])lib\/(?:[^\s`'"(),;{]|\{[^}\s]*\})*/

  defp span_refs(:unpaired), do: [%{kind: :unpaired}]

  defp span_refs(span) do
    functions =
      for [_match, module, fun, arities] <- Regex.scan(@function, span) do
        %{
          kind: if(module == "", do: :bare, else: :function),
          module: if(module != "", do: String.trim_trailing(module, ".")),
          fun: fun,
          arity_text: arities,
          arities: arities(arities)
        }
      end

    paths =
      for [path] <- Regex.scan(@path, span),
          do: %{kind: :path, path: String.replace(path, ~r/(:\d+)+$/, "")}

    functions ++ paths
  end

  # Every arity a `1,2..4` list names, or none when one of its ranges names none (`3..1`).
  defp arities(text) do
    ranges = text |> String.split(",") |> Enum.map(&arity_range/1)
    if [] in ranges, do: [], else: Enum.concat(ranges)
  end

  defp arity_range(text) do
    case String.split(text, "..") do
      [arity] -> [String.to_integer(arity)]
      [low, high] -> Enum.to_list(String.to_integer(low)..String.to_integer(high)//1)
    end
  end

  # --- resolution

  # Each suffix of every Elixir module name on the code path, to the modules that end in it, and
  # each module to the `.beam` path `:code.all_available/0` gives it. That one call finds every
  # file, so resolving a name reads files and never waits on the code server (#1392).
  defp module_index do
    available =
      for {charlist, path, _loaded} <- :code.all_available(),
          "Elixir." <> name <- [to_string(charlist)],
          do: {Module.concat([name]), name, path}

    suffixes =
      for {module, name, _path} <- available,
          parts = String.split(name, "."),
          suffix <- Enum.map(0..(length(parts) - 1), &(parts |> Enum.drop(&1) |> Enum.join("."))),
          reduce: %{} do
        acc -> Map.update(acc, suffix, [module], &[module | &1])
      end

    %{
      suffixes: suffixes,
      paths: Map.new(available, fn {module, _name, path} -> {module, path} end)
    }
  end

  defp resolves?(%{kind: kind}, _index) when kind in [:unpaired, :shared_marker], do: false

  defp resolves?(%{kind: :path, path: path}, _index) do
    if String.contains?(path, ["*", "?", "{", "["]),
      do: Path.wildcard(path) != [],
      else: File.exists?(path)
  end

  defp resolves?(%{kind: :bare, enclosing: module} = ref, index),
    do: ref.arities != [] and Enum.all?(ref.arities, &defines?(module, ref.fun, &1, index))

  defp resolves?(%{kind: :function, module: name} = ref, index) do
    candidates = Map.get(index.suffixes, name, [])

    ref.arities != [] and
      Enum.all?(ref.arities, fn arity ->
        Enum.any?(candidates, &defines?(&1, ref.fun, arity, index))
      end)
  end

  # `String.to_atom/1`, since a function's name becomes an existing atom only once its module
  # loads or its `.beam` is read, and `definitions/2` reads it after this call.
  defp defines?(module, fun, arity, index),
    do: {String.to_atom(fun), arity} in definitions(module, index.paths)

  defp definitions(module, paths) do
    path = Map.get(paths, module)
    key = {__MODULE__, module, path}

    with nil <- Process.get(key) do
      definitions = read_definitions(module, path)
      Process.put(key, definitions)
      definitions
    end
  end

  # A module's exports, behaviour callbacks and private definitions, read from its `.beam` file
  # without loading it. A module with no `.beam` path, such as `Cinder.MixProject`, which Mix
  # loads from `mix.exs`, is read through `module_info/1` when it is loaded, which asks the code
  # server nothing.
  defp read_definitions(module, [_ | _] = path) do
    case File.read(path) do
      {:ok, binary} ->
        {:ok, {_, [exports: exports]}} = :beam_lib.chunks(binary, [:exports])
        exports ++ callbacks(binary) ++ private_definitions(module, binary)

      {:error, _reason} ->
        []
    end
  end

  defp read_definitions(module, _no_path) do
    if is_atom(module) and :erlang.module_loaded(module),
      do: module.module_info(:exports),
      else: []
  end

  # Each `@callback` and `@macrocallback`, named as `behaviour_info(:callbacks)` names them.
  defp callbacks(binary) do
    case Code.Typespec.fetch_callbacks(binary) do
      {:ok, callbacks} -> for {key, _specs} <- callbacks, do: key
      :error -> []
    end
  end

  # Every `def`, `defp`, `defmacro` and `defmacrop`, default arities included, from the Elixir
  # debug info in the module's .beam.
  defp private_definitions(module, binary) do
    with {:ok, {_, [debug_info: {:debug_info_v1, backend, data}]}} <-
           :beam_lib.chunks(binary, [:debug_info]),
         {:ok, %{definitions: definitions}} <- backend.debug_info(:elixir_v1, module, data, []) do
      for {{name, arity}, _kind, _meta, _clauses} <- definitions, do: {name, arity}
    else
      _no_debug_info -> []
    end
  end
end
