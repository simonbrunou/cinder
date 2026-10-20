defmodule Cinder.CodeHealthTest do
  @moduledoc """
  Guards against a single `lib/` file regrowing into an unreviewable mega-module (the trigger for
  the 2026-07-26 `Cinder.Catalog` split), and fences the module boundaries earlier refactors
  drew: the catalog's split by concept (#740), the staging engine (#739) and the guarded-write
  adapters (#743). It also keeps new changelog entries in `changelog.d/` (#843).
  """
  use ExUnit.Case, async: true

  @max_lines 1500

  test "no lib/ file exceeds #{@max_lines} lines" do
    offenders =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.map(fn path -> {path, path |> File.read!() |> String.split("\n") |> length()} end)
      |> Enum.filter(fn {_path, lines} -> lines > @max_lines end)

    assert offenders == [],
           "the following file(s) exceed #{@max_lines} lines — split it by concept, the " <>
             "way #740 split Cinder.Catalog:\n" <>
             Enum.map_join(offenders, "\n", fn {path, lines} -> "  #{path} (#{lines} lines)" end)
  end

  # #739: the staging engine settles nothing about media. Calls back into `Cinder.Library` are how
  # keep-or-replace and quality decisions used to creep into it, and why books needed an entry
  # point of their own.
  test "the staging engine calls nothing in Cinder.Library itself" do
    {:ok, ast} = "lib/cinder/library/stage_engine.ex" |> File.read!() |> Code.string_to_quoted()

    {_ast, calls} =
      Macro.prewalk(ast, [], fn
        # `alias Cinder.Library.{A, B}` parses as a call to `:{}`; it names submodules only.
        {{:., _, [{:__aliases__, _, aliases}, fun]}, meta, _args} = node, acc
        when aliases in [[:Library], [:Cinder, :Library]] and fun != :{} ->
          {node, ["Library.#{fun} (line #{meta[:line]})" | acc]}

        node, acc ->
          {node, acc}
      end)

    assert calls == [],
           "StageEngine must not call `Cinder.Library`; settle the decision in the stager and " <>
             "pass it in:\n  " <> Enum.join(calls, "\n  ")
  end

  # #740: the facade holds no implementation, so nothing a concept needs can land there.
  test "Cinder.Catalog only delegates" do
    {:ok, ast} = "lib/cinder/catalog.ex" |> File.read!() |> Code.string_to_quoted()

    {_ast, defs} =
      Macro.prewalk(ast, [], fn
        {kind, meta, [head | _]} = node, acc when kind in [:def, :defp, :defmacro, :defmacrop] ->
          {node, ["#{kind} #{Macro.to_string(head)} (line #{meta[:line]})" | acc]}

        node, acc ->
          {node, acc}
      end)

    assert defs == [],
           "move the implementation into the concept module that owns it and `defdelegate` " <>
             "to it:\n  " <> Enum.join(Enum.reverse(defs), "\n  ")
  end

  # #740: `Cinder.Catalog` is the facade for code outside the catalog. A concept module calls the
  # module that owns what it needs, so nothing under `lib/cinder/catalog/` calls back up into it.
  test "no catalog module calls the Cinder.Catalog facade" do
    calls =
      for path <- Path.wildcard("lib/cinder/catalog/**/*.ex"),
          call <- facade_calls(path),
          do: "#{path}: Catalog.#{call}"

    assert calls == [],
           "call the concept module that owns the function, not the facade:\n  " <>
             Enum.join(calls, "\n  ")
  end

  defp facade_calls(path) do
    {:ok, ast} = path |> File.read!() |> Code.string_to_quoted()

    {_ast, calls} =
      Macro.prewalk(ast, [], fn
        # `alias Cinder.Catalog.{A, B}` parses as a call to `:{}`; it names submodules only.
        {{:., _, [{:__aliases__, _, aliases}, fun]}, meta, _args} = node, acc
        when aliases in [[:Catalog], [:Cinder, :Catalog]] and fun != :{} ->
          {node, ["#{fun} (line #{meta[:line]})" | acc]}

        # `alias Cinder.Catalog, as: C` would let a call slip past the match above.
        {:alias, meta, [{:__aliases__, _, [:Cinder, :Catalog]} | _]} = node, acc ->
          {node, ["aliased (line #{meta[:line]})" | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(calls)
  end

  # #740: the CI scripts drive the release over `bin/cinder rpc` with Elixir inside Python
  # strings the compiler never sees, so a rename in `lib/` used to surface only in CI's container
  # job.
  test "every Cinder function the CI scripts call over rpc exists" do
    calls =
      for path <- Path.wildcard(".github/scripts/**/*.py"),
          [_call, module, fun] <-
            Regex.scan(~r/\b(Cinder(?:\.[A-Z]\w*)+)\.([a-z_]\w*[?!]?)\(/, File.read!(path)),
          uniq: true,
          do: {path, module, fun}

    missing =
      for {path, module, fun} <- calls,
          not exported?(Module.concat([module]), String.to_atom(fun)),
          do: "#{path}: #{module}.#{fun}"

    assert calls != []

    assert missing == [],
           "the CI scripts call functions lib/ no longer has; update the rpc strings:\n  " <>
             Enum.join(missing, "\n  ")
  end

  defp exported?(module, fun),
    do: Code.ensure_loaded?(module) and Keyword.has_key?(module.__info__(:functions), fun)

  # #739: the engine's scratch-file names are its own. Tests other than the staged-import ones
  # reach them through `Cinder.LibraryStubs`, so renaming them touches two files.
  test "only the staged-import tests and LibraryStubs spell out the candidate file name" do
    marker = ".cinder-" <> "stage-"
    allowed = ["test/cinder/library/staged_import_test.exs", "test/support/library_stubs.ex"]

    offenders =
      "test/**/*.{ex,exs}"
      |> Path.wildcard()
      |> Enum.reject(&(&1 in allowed))
      |> Enum.filter(&(&1 |> File.read!() |> String.contains?(marker)))

    assert offenders == [],
           "use `Cinder.LibraryStubs.candidate_path?/1` or `candidate_marker/0` instead of " <>
             "spelling out #{marker} in:\n  " <> Enum.join(offenders, "\n  ")
  end

  # #743: a guarded-write adapter is reachable only through its owner, so no caller can write a
  # movie status around a `MovieLifecycle` verb, or a request around the approval gate.
  test "only its owner names each guarded-write adapter" do
    # adapter => {its own file, its owner}
    adapters = %{
      "MovieTransition" =>
        {"lib/cinder/catalog/movie_transition.ex", "lib/cinder/catalog/movie_lifecycle.ex"},
      "EpisodeTransition" =>
        {"lib/cinder/catalog/episode_transition.ex", "lib/cinder/catalog/episodes.ex"},
      "BookTargetTransition" =>
        {"lib/cinder/books/book_target_transition.ex", "lib/cinder/books.ex"},
      "RequestTransition" =>
        {"lib/cinder/requests/request_transition.ex", "lib/cinder/requests.ex"}
    }

    offenders =
      for path <- Path.wildcard("lib/**/*.ex"),
          source = File.read!(path),
          {adapter, {own, owner}} <- adapters,
          String.contains?(source, adapter),
          path not in [own, owner],
          do: "#{path} names #{adapter} (owner: #{owner})"

    assert offenders == [],
           "call the owner's guarded write instead of naming its adapter:\n  " <>
             Enum.join(offenders, "\n  ")
  end

  # #757: `Book*` names the book family, e-books and audiobooks together. A `Book*` module beside
  # an `Audiobook*` sibling is the e-book half of a pair, so it is named `Ebook*` instead.
  test "no Book* module has an Audiobook* sibling" do
    modules = Application.spec(:cinder, :modules)

    offenders =
      for module <- modules,
          [last | parent] = module |> Module.split() |> Enum.reverse(),
          "Audiobook" <> rest <- [last],
          counterpart = Module.concat(Enum.reverse(["Book" <> rest | parent])),
          counterpart in modules,
          do: "#{inspect(counterpart)} (sibling of #{inspect(module)})"

    assert offenders == [],
           "an e-book-only module is named Ebook*, not Book*:\n  " <> Enum.join(offenders, "\n  ")
  end

  alias Cinder.Changelog

  # #843: a PR's changelog entry goes in changelog.d/, so two PRs never conflict on CHANGELOG.md.
  # The entries written under [Unreleased] before then stay as they are until the next release
  # folds them; this hash keeps them fixed until then, and that release deletes it.
  @legacy_unreleased_sha256 "1c7a845fd192270e41f13d26bc21d9613ae9cfbd797af21505e993bb6cb085b9"

  test "no PR adds an entry under CHANGELOG.md's [Unreleased]" do
    body = "CHANGELOG.md" |> File.read!() |> Changelog.unreleased()
    hash = :sha256 |> :crypto.hash(body) |> Base.encode16(case: :lower)

    assert body == Changelog.note() or hash == @legacy_unreleased_sha256,
           "CHANGELOG.md's [Unreleased] changed. Write the entry as " <>
             "changelog.d/<number>-<slug>.md instead (format: changelog.d/README.md). Only a " <>
             "deliberate edit to an entry from before #843 updates @legacy_unreleased_sha256."
  end

  test "every changelog.d/ fragment folds into a release" do
    problems = Changelog.check(".")

    assert problems == [],
           "a release would refuse these; fix them on this PR:\n  " <>
             Enum.join(problems, "\n  ")
  end

  # `Phoenix.LiveView.TagEngine.Parser`/`Tokenizer` are `@moduledoc false` — private
  # phoenix_live_view API, not a documented contract. If a future phoenix_live_view upgrade
  # changes these token shapes, this test breaks loudly at `mix test` time; that is
  # acceptable — a red test here beats a silently broken guard.
  alias Phoenix.LiveView.TagEngine.Parser

  test "no keyless :for row renders (directly or via a component) a data-poster element" do
    templates = poster_guard_templates()
    poster_components = poster_guard_poster_components(templates)
    offenders = poster_guard_offenders(templates, poster_components)

    poster_callees = Enum.map_join(poster_components, ", ", &"<.#{&1}>")

    assert offenders == [],
           "the following `:for` row(s) render a `data-poster` element — directly or via " <>
             "#{poster_callees} — without an `id`. morphdom treats a keyless `:for` row as " <>
             "a positional patch (it reuses the previous occupant's element instead of " <>
             "inserting a new one), so LiveView's onNodeAdded never fires for nodes nested " <>
             "inside it and the poster-failure handling in assets/js/app.js (#592/#594) " <>
             "silently never runs — see #597. Key the row with a stable `id`, the way " <>
             "media_card/detail_poster/thumb_poster and the cast_strip cast list already " <>
             "are:\n" <>
             Enum.map_join(offenders, "\n", fn {file, line, el} -> "  #{file}:#{line} #{el}" end)
  end

  # Every `~H` sigil in `lib/cinder_web/**/*.ex`, as {file, enclosing def/defp name, absolute
  # source line of the sigil's first content line, raw HEEx source}.
  defp poster_guard_templates do
    "lib/cinder_web/**/*.ex"
    |> Path.wildcard()
    |> Enum.flat_map(&poster_guard_sigils/1)
  end

  defp poster_guard_sigils(file) do
    ast = file |> File.read!() |> Code.string_to_quoted!()

    {_ast, sigils} =
      Macro.prewalk(ast, [], fn
        {kind, _, [head, [do: body]]} = node, acc when kind in [:def, :defp] ->
          fun = poster_guard_fun_name(head)

          found =
            body
            |> Macro.prewalk([], fn
              {:sigil_H, meta, [{:<<>>, _, [source]}, _]} = sigil, acc2
              when is_binary(source) ->
                # `meta[:line]` is the `~H"""` line itself; the tokenizer numbers the
                # (already-dedented) sigil content from 1, so a token's absolute source line
                # is `sigil_line + token_relative_line`.
                {sigil, [{file, fun, meta[:line], source} | acc2]}

              other, acc2 ->
                {other, acc2}
            end)
            |> elem(1)

          {node, found ++ acc}

        other, acc ->
          {other, acc}
      end)

    sigils
  end

  defp poster_guard_fun_name({:when, _, [call, _guard]}), do: poster_guard_fun_name(call)
  defp poster_guard_fun_name({name, _, _}) when is_atom(name), do: name

  # `Phoenix.LiveView.TagEngine.Tokenizer` alone chokes on classic EEx tags (`<%= %>`, `<% %>`,
  # `<%!-- --%>`), which this codebase's `~H` sigils use throughout (layouts.ex, settings.ex,
  # book_discovery_live.ex, and others). `Parser.tokenize/2` is what the real HEEx compile path
  # calls: it runs `EEx.tokenize/2` first and only hands the intervening text to the tag
  # tokenizer, interleaving `{:eex, ...}` tokens back in — which we skip like `:text`.
  defp poster_guard_tokenize(source) do
    Parser.tokenize(source,
      tag_handler: Phoenix.LiveView.HTMLEngine,
      file: "nofile",
      indentation: 0
    )
  end

  defp poster_guard_has_attr?(attrs, name), do: Enum.any?(attrs, fn {n, _, _} -> n == name end)

  defp poster_guard_data_poster_tag?({:tag, _name, attrs, _meta}),
    do: poster_guard_has_attr?(attrs, "data-poster")

  defp poster_guard_data_poster_tag?(_token), do: false

  # Pass 1: which function components render `data-poster` in their own template — derived,
  # not hardcoded, so a poster added to a new component later is picked up automatically
  # instead of needing this test to be told about it.
  defp poster_guard_poster_components(templates) do
    templates
    |> Enum.filter(fn {_file, _fun, _sigil_line, source} ->
      source |> poster_guard_tokenize() |> Enum.any?(&poster_guard_data_poster_tag?/1)
    end)
    |> Enum.map(fn {_file, fun, _sigil_line, _source} -> fun end)
    |> Enum.uniq()
  end

  # A remote component tag name is `Alias.segments.fun_name`; only the last segment is the
  # function name that a local `def`/`defp` in the poster set would also be keyed by.
  defp poster_guard_fun_atom(name),
    do: name |> String.split(".") |> List.last() |> String.to_atom()

  # Pass 2: walk each template's tokens with a stack of open `:for`-carrying frames. Whenever
  # a `data-poster` tag or a poster-rendering component call opens, every `:for` frame
  # currently open (including the element itself, if it is the one carrying `:for`) must
  # carry an `id`.
  defp poster_guard_offenders(templates, poster_components) do
    templates
    |> Enum.flat_map(fn {file, _fun, sigil_line, source} ->
      {offenders, _stack} =
        source
        |> poster_guard_tokenize()
        |> Enum.reduce({[], []}, &poster_guard_step(&1, &2, file, sigil_line, poster_components))

      offenders
    end)
    |> Enum.uniq()
  end

  # Self-closing/void elements never push (no `:close` token will ever arrive for them).
  defp poster_guard_step(
         {:close, _type, _name, _meta},
         {offenders, [_current | rest]},
         _file,
         _sigil_line,
         _poster_components
       ) do
    {offenders, rest}
  end

  defp poster_guard_step(
         {type, name, attrs, meta},
         {offenders, stack},
         file,
         sigil_line,
         poster_components
       )
       when type in [:tag, :local_component, :remote_component, :slot] do
    has_for = poster_guard_has_attr?(attrs, ":for")
    has_id = poster_guard_has_attr?(attrs, "id")

    frame = %{
      has_id: has_id,
      line: sigil_line + meta.line,
      element: "<#{meta.tag_name}>"
    }

    for_frames = Enum.filter(stack, & &1.has_for)
    checked = if has_for, do: [Map.put(frame, :has_for, true) | for_frames], else: for_frames

    poster? =
      case type do
        :tag ->
          poster_guard_has_attr?(attrs, "data-poster")

        component when component in [:local_component, :remote_component] ->
          poster_guard_fun_atom(name) in poster_components

        :slot ->
          false
      end

    new_offenders =
      if poster? do
        checked
        |> Enum.reject(& &1.has_id)
        |> Enum.map(&{file, &1.line, &1.element})
      else
        []
      end

    frame = Map.put(frame, :has_for, has_for)
    new_stack = if Map.get(meta, :closing), do: stack, else: [frame | stack]

    {offenders ++ new_offenders, new_stack}
  end

  defp poster_guard_step(_token, acc, _file, _sigil_line, _poster_components), do: acc
end
