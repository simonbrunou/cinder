defmodule Cinder.PushRepeatsPr do
  @moduledoc ~S"""
  Tells the merging agent whether the CI run that a merge starts on `main` repeats the PR run's
  jobs and steps (AGENTS.md "Merge authority", #1254). It ports simonbrunou.bzh's
  `scripts/check-push-repeats-pr.js` and garde-manger's `scripts/check-push-repeats-pr.ts`. It
  sits under test/support because it reads YAML with yamerl, which yaml_elixir brings in for dev
  and test only, and a worktree that `scripts/seed-worktree` seeded holds only `_build/test`.
  Run it after `git fetch origin`, with the SHA the PR's CI passed:

      MIX_ENV=test mix run --no-start scripts/check-push-repeats-pr.exs <pushed SHA>

  It reads the files at that SHA through git, not the working tree, and prints each difference
  it finds:

  - in a workflow anywhere under .forgejo/workflows/, subfolders included: no `push` or no
    `pull_request` trigger, a `pull_request` filter, a `push` filter beyond `branches: [main]`,
    a trigger other than those two, `schedule` and `workflow_dispatch`, and a job that calls a
    reusable workflow (`jobs.<id>.uses`), whose steps this check cannot read;
  - in a workflow under .github/workflows/, a trigger other than a push of tags. Forgejo reads
    those files only when .forgejo/workflows/ holds none, which this check reports too;
  - in a workflow, in any other YAML file under .forgejo/, in an action.yml or action.yaml
    anywhere and in a .github/workflows/ file: a symbolic link, whose target's name is all that
    git stores, a file that is not UTF-8 or that yamerl cannot read, more than one YAML
    document, a directive (`%YAML`, `%TAG` or a reserved one), a tag (`!!binary`, `!!str`, a
    lone `!`), an anchor, an alias and a merge key (`<<`), which this check does not follow;
  - in those files but the .github/workflows/ ones, as yamerl decodes them, so an escape such as
    `\x24` or a `!!binary` value counts: an `if` key (and an action's `pre-if` and `post-if`), a
    `${{ }}` expression in a key or a value, a step that uses actions/github-script, whose code
    gets the event, and a name of the next item in a key or a value;
  - in any file outside Markdown: a name made of GITHUB, FORGEJO or FORGE and an underscore,
    which a script could read the event through, and the names of the actions toolkit's github
    module and its event property. This module, its script and its test hold none of them, so
    the scan reads all three. A symbolic link counts too when its target leaves the tree or
    passes through or ends at another link or a path where the tree holds no file or folder
    (.git/HEAD, deps/), and a link outside Markdown when it leads to a Markdown file, since a
    step that runs the link runs the file it reaches;
  - a file name that the tree holds twice, since git reads one entry and a checkout may take
    the other, and a submodule, whose files this tree does not hold.

  It allows the differences cinder's CI keeps on purpose, each only at the key where `ci.yml` or
  `release.yml` holds it today. The same text anywhere else is a difference.

  1. `${{ github.ref }}` in the workflow-level `concurrency.group`. It only picks the run that a
     newer push to the same ref cancels.
  2. `${{ runner.os }}`, `${{ steps.beam.outputs.otp-version }}`,
     `${{ steps.beam.outputs.elixir-version }}` and `${{ hashFiles('**/mix.lock') }}` in the
     `key` and `restore-keys` inputs of an `actions/cache@` step. The same tree gives the same
     keys. A push run can still miss a cache that the PR run hit, and a miss rebuilds the same
     dependencies from the same mix.lock.
  3. `if: always()` on a step, and `if: steps.deps-build.outputs.cache-hit != 'true'` on the
     step that installs cmake for a dependency rebuild, for the reason in 2. That step holds
     only that `if` and a `run` of `@cmake_run`'s text, and its job has an `actions/cache@`
     step with `id: deps-build`.
  4. `${{ github.run_id }}` and `${{ github.run_attempt }}` in a value of a job's or a step's
     `env`, and `${{ env.CINDER_IMAGE }}` in the `image-ref` input of an
     `aquasecurity/trivy-action@` step. They name the run and read no event.
  5. The runner's token and workspace variables (GITHUB, then `_TOKEN` or `_WORKSPACE`) in the
     step named `Download the Trivy vulnerability DB`, which holds only `name` and `run`: in its
     `run`, only as `env -u` of the token and as the workspace followed by `/.cache/trivy`; in
     the comment lines right above the step, at its dash's indentation, by name. The step unsets
     the token for the download and writes under the workspace. Any other runner name there
     still counts.
  6. The token as `${{ secrets.<token> }}` in the `password` input of a `docker/login-action@`
     step in .github/workflows/release.yml, while that file's only trigger is a push of tags. A
     merge to `main` pushes no tag.

  It cannot see code that branches on commit metadata (the push run checks out `main` at the
  merge commit, whose subject, SHA and parents differ from the pushed SHA's), what a third-party
  action (`uses: owner/repo@ref`) does with the event, code that the runner or its image runs in
  every step, a workflow or job `defaults` or `env` that makes the cmake step of 3 run other
  code, a YAML form outside the list above that yamerl and the runner's reader read apart, a
  step that runs a Markdown file by its own name, and code that reads the event by a route the
  list above leaves out. Such code passes.

  Exit 0: no difference, so the push run repeats the PR run. Exit 1: it printed a difference, so
  wait on main's run. Exit 2: the arguments are wrong, git failed, the SHA is unknown, yamerl
  cannot start, or the check itself raised; wait too. test/cinder/push_repeats_pr_test.exs holds
  one case per difference.
  """

  alias __MODULE__.Context

  @runner_names Enum.map(~w(GITHUB FORGEJO FORGE), &(&1 <> "_"))
  # Built from parts, like @runner_names, so this file does not match itself.
  @event_reads [Enum.join(["@actions", "github"], "/"), "event" <> "Name"]
  @names_source Enum.map_join(@runner_names ++ @event_reads, "|", &Regex.escape/1)
  @names Regex.compile!(@names_source)

  @expression ~r/\$\{\{(.*?)\}\}/s
  @other_triggers ~w(schedule workflow_dispatch)

  @cache_keys [
    "runner.os",
    "steps.beam.outputs.otp-version",
    "steps.beam.outputs.elixir-version",
    "hashFiles('**/mix.lock')"
  ]
  @run_names ["github.run_id", "github.run_attempt"]

  @cmake_if "steps.deps-build.outputs.cache-hit != 'true'"
  @cmake_run ~S"""
  for attempt in 1 2 3; do
    sudo apt-get update && break
    if [ "$attempt" = 3 ]; then exit 1; fi
    echo "apt-get update failed (attempt $attempt of 3); retrying in 30 s"
    sleep 30
  done
  sudo apt-get install -y --no-install-recommends cmake
  """

  @trivy_db "Download the Trivy vulnerability DB"
  @token hd(@runner_names) <> "TOKEN"
  @workspace hd(@runner_names) <> "WORKSPACE"
  @trivy_run_forms [
    Regex.compile!("env -u " <> @token <> "(?![A-Za-z0-9_])"),
    Regex.compile!(Regex.escape("$" <> @workspace <> "/.cache/trivy"))
  ]
  @trivy_comment_forms [
    Regex.compile!("(?<![A-Za-z0-9_])(?:" <> @token <> "|" <> @workspace <> ")(?![A-Za-z0-9_])")
  ]

  @release ".github/workflows/release.yml"
  @release_password "${{ secrets." <> @token <> " }}"
  @release_forms [Regex.compile!(Regex.escape(@release_password))]

  @usage "usage: MIX_ENV=test mix run --no-start scripts/check-push-repeats-pr.exs <pushed SHA>"

  @doc """
  Runs the check on `argv`, prints its lines (an exit 2 line on stderr) and returns the exit code.
  """
  @spec main([String.t()], keyword()) :: 0 | 1 | 2
  def main(argv, opts \\ []) do
    {code, lines} =
      case argv do
        [sha] -> check(sha, opts)
        _ -> {2, ["check-push-repeats-pr: " <> @usage]}
      end

    device = if code == 2, do: :stderr, else: :stdio
    Enum.each(lines, &IO.puts(device, &1))
    code
  end

  @doc """
  Checks the commit `sha` names in the repo that holds `opts[:cd]` (the current directory by
  default) and returns `{exit code, lines}`. `opts[:yaml_app]` names the YAML application to
  start (`:yamerl`), so a test can name one that is missing.
  """
  @spec check(String.t(), keyword()) :: {0 | 1 | 2, [String.t()]}
  def check(sha, opts \\ []) do
    {code, lines} = run(sha, opts)
    {code, Enum.map(lines, &printable/1)}
  end

  defp run(sha, opts) do
    dir = Keyword.get(opts, :cd, File.cwd!())

    with {:ok, top} <- git(dir, ["rev-parse", "--show-toplevel"], stderr: true),
         top = String.trim_trailing(top, "\n"),
         {:ok, commit} <- resolve(top, sha),
         :ok <- start_yaml(Keyword.get(opts, :yaml_app, :yamerl)),
         {:ok, tree} <- git(top, ["ls-tree", "-r", "-z", commit]) do
      report(top, commit, tree |> String.split(<<0>>, trim: true) |> Enum.map(&tree_entry/1))
    else
      {:error, message} -> {2, ["check-push-repeats-pr: " <> message]}
    end
  rescue
    error -> {2, ["check-push-repeats-pr: the check raised: " <> Exception.message(error)]}
  end

  defp resolve(top, sha) do
    case git(top, ["rev-parse", "--verify", "--quiet", "--end-of-options", sha <> "^{commit}"],
           ok: [0, 1]
         ) do
      {:ok, ""} -> {:error, "unknown commit: " <> sha}
      {:ok, commit} -> {:ok, String.trim_trailing(commit, "\n")}
      error -> error
    end
  end

  defp start_yaml(app) do
    case Application.ensure_all_started(app) do
      {:ok, _started} -> :ok
      {:error, reason} -> {:error, "cannot start #{app}, the YAML reader: #{inspect(reason)}"}
    end
  end

  # Every GIT_ variable of the caller is unset: GIT_DIR would point git at another repo, and
  # GIT_ICASE_PATHSPECS would make `:(exclude)*.md` skip a.MD as well.
  defp git(dir, args, opts \\ []) do
    env =
      for {name, _value} <- System.get_env(), String.starts_with?(name, "GIT_"), do: {name, nil}

    stderr = Keyword.get(opts, :stderr, false)
    {out, status} = System.cmd("git", args, cd: dir, env: env, stderr_to_stdout: stderr)

    if status in Keyword.get(opts, :ok, [0]),
      do: {:ok, out},
      else: {:error, "git #{Enum.join(args, " ")} failed (exit #{status}): #{String.trim(out)}"}
  end

  defp blob(top, commit, path) do
    {:ok, text} = git(top, ["cat-file", "blob", commit <> ":" <> path])
    text
  end

  # `<mode> <type> <object>\t<path>`, as `git ls-tree -z` prints each entry.
  defp tree_entry(entry) do
    [meta, path] = String.split(entry, "\t", parts: 2)
    {hd(String.split(meta, " ")), path}
  end

  defp report(top, commit, entries) do
    files = Enum.map(entries, &elem(&1, 1))
    workflows = Enum.filter(files, &workflow_path?/1)
    links = for {"120000", path} <- entries, do: path
    yaml_links = Enum.filter(links, &yaml_read?/1)
    yaml = files |> Enum.uniq() |> Enum.filter(&yaml_read?/1) |> Enum.reject(&(&1 in yaml_links))

    {yaml_differences, allowed_lines} =
      Enum.reduce(yaml, {[], %{}}, fn path, {differences, allowed} ->
        {found, lines} = read_yaml(path, blob(top, commit, path))
        {differences ++ found, Map.merge(allowed, lines)}
      end)

    differences =
      duplicates(files) ++
        Enum.map(yaml_links, &"#{&1}: a symbolic link, which this check does not follow") ++
        link_problems(top, commit, entries, links) ++
        submodules(entries) ++
        if(workflows == [], do: [".forgejo/workflows/: no workflow file"], else: []) ++
        yaml_differences ++ name_scan(top, commit, allowed_lines)

    short = String.slice(commit, 0, 8)

    if differences == [] do
      {0,
       [
         "check-push-repeats-pr: #{short}: the push run repeats the PR run " <>
           "(#{length(workflows)} workflow file(s), #{length(yaml)} YAML file(s) read)"
       ]}
    else
      {1,
       differences ++
         [
           "check-push-repeats-pr: #{short}: #{length(differences)} difference(s); " <>
             "wait on main's run"
         ]}
    end
  end

  # A step that runs a link runs the file it reaches, which the name scan does not read when it
  # lies out of the tree (the run's own /proc/self/environ, say), behind another link, at a path
  # the tree does not hold (.git/HEAD, or deps/ that a run fills), or, for a link outside
  # Markdown, in a Markdown file.
  defp link_problems(top, commit, entries, links) do
    kinds = kinds(entries)

    for path <- links,
        where <- link_where(path, reach(path, blob(top, commit, path), kinds), kinds),
        do: "#{path}: a symbolic link #{where}"
  end

  # What the tree holds at each path: a :file, a :link, a :gitlink or a :folder.
  defp kinds(entries) do
    folders =
      for {_mode, path} <- entries,
          parts = String.split(path, "/"),
          count <- 1..(length(parts) - 1)//1,
          into: %{},
          do: {parts |> Enum.take(count) |> Enum.join("/"), :folder}

    for {mode, path} <- entries, into: folders, do: {path, kind(mode)}
  end

  defp kind("120000"), do: :link
  defp kind("160000"), do: :gitlink
  defp kind(_mode), do: :file

  defp link_where(_path, :out, _kinds),
    do: ["out of the tree or through another link, which the scan cannot follow"]

  defp link_where(_path, :absent, _kinds),
    do: [
      "through or to a path where the tree holds no file or folder, which the scan cannot read"
    ]

  # A folder named like Markdown holds files the scan reads.
  defp link_where(path, reached, kinds) do
    if kinds[reached] == :file and String.ends_with?(reached, ".md") and
         not String.ends_with?(path, ".md"),
       do: ["to Markdown, which the scan skips"],
       else: []
  end

  # Walks the target from the link's folder part by part, as the kernel does, to the file or
  # folder it reaches. It stops at :out when the target is absolute, when its `..` climb above
  # the root, or when a part names another link, which the kernel follows before any `..` after
  # it and this walk does not. It stops at :absent when a part names a path where the tree holds
  # no file or folder, such as .git or deps, where a run can meet a link of its own.
  defp reach(_path, "/" <> _target, _kinds), do: :out

  defp reach(path, target, kinds) do
    folders = path |> String.split("/") |> Enum.drop(-1)

    case Enum.reduce_while(String.split(target, "/"), folders, &step(&1, &2, kinds)) do
      stop when stop in [:out, :absent] -> stop
      parts -> Enum.join(parts, "/")
    end
  end

  defp step(part, folders, _kinds) when part in ["", "."], do: {:cont, folders}
  defp step("..", [], _kinds), do: {:halt, :out}
  defp step("..", folders, _kinds), do: {:cont, Enum.drop(folders, -1)}

  defp step(part, folders, kinds) do
    next = folders ++ [part]

    case Map.get(kinds, Enum.join(next, "/")) do
      :link -> {:halt, :out}
      kind when kind in [:file, :folder] -> {:cont, next}
      _gitlink_or_absent -> {:halt, :absent}
    end
  end

  defp submodules(entries) do
    for {"160000", path} <- entries,
        do: "#{path}: a submodule, whose files this check cannot read"
  end

  defp duplicates(files) do
    for {path, count} <- Enum.frequencies(files),
        count > 1,
        do: "#{path}: a file name the tree holds #{count} times"
  end

  defp yaml?(path), do: String.ends_with?(path, [".yml", ".yaml"])
  defp workflow_path?(path), do: String.starts_with?(path, ".forgejo/workflows/") and yaml?(path)
  defp action?(path), do: Path.basename(path) in ["action.yml", "action.yaml"]
  defp tag_workflow?(path), do: String.starts_with?(path, ".github/workflows/") and yaml?(path)

  defp full?(path), do: (String.starts_with?(path, ".forgejo/") and yaml?(path)) or action?(path)

  defp yaml_read?(path), do: full?(path) or tag_workflow?(path)

  # The differences of one YAML file, and `%{{path, line} => forms}`: the forms that rules 5 and 6
  # allow on a line of it.
  defp read_yaml(path, text) do
    with true <- String.valid?(text),
         {:ok, documents} <- construct(text) do
      root = List.first(documents)

      forms =
        token_problems(path, text) ++
          if(length(documents) > 1,
            do: ["#{path}: #{length(documents)} YAML documents, which this check does not read"],
            else: []
          )

      {forms ++ rules(path, root), allowed_lines(path, text, root)}
    else
      false -> {["#{path}: not UTF-8 text, which this check cannot read"], %{}}
      {:error, message} -> {["#{path}: not readable as YAML (#{message})"], %{}}
    end
  end

  defp construct(text) do
    documents = :yamerl_constr.string(text, [:str_node_as_binary, detailed_constr: true])
    {:ok, for({:yamerl_doc, root} <- documents, do: to_node(root))}
  catch
    :throw,
    {:yamerl_exception, [{:yamerl_parsing_error, _type, message, line, _, _, _, _} | _]} ->
      {:error, "line #{line}: #{message}"}

    kind, reason ->
      {:error, Exception.format_banner(kind, reason)}
  end

  # yamerl's detailed nodes as {:map, line, pairs}, {:seq, line, items}, {:str, line, text} (a
  # `!!binary` value as its decoded bytes), {:null, line} and {:other, line}.
  defp to_node({:yamerl_map, _module, _tag, pres, pairs}),
    do:
      {:map, pres[:line], Enum.map(pairs, fn {key, value} -> {to_node(key), to_node(value)} end)}

  defp to_node({:yamerl_seq, _module, _tag, pres, items, _count}),
    do: {:seq, pres[:line], Enum.map(items, &to_node/1)}

  defp to_node({type, _module, _tag, pres, text}) when type in [:yamerl_str, :yamerl_binary],
    do: {:str, pres[:line], text}

  defp to_node({:yamerl_null, _module, _tag, pres}), do: {:null, pres[:line]}
  defp to_node(other), do: {:other, elem(other, 3)[:line]}

  defp line({_kind, line, _value}), do: line
  defp line({_kind, line}), do: line

  # yamerl reads each token of the file into this process's mailbox.
  defp token_problems(path, text) do
    me = self()
    ref = make_ref()

    :yamerl_parser.string(text,
      token_fun: fn token ->
        send(me, {ref, token})
        :ok
      end
    )

    ref |> drain_tokens([]) |> Enum.flat_map(&token_problem(path, &1))
  end

  defp drain_tokens(ref, tokens) do
    receive do
      {^ref, token} -> drain_tokens(ref, [token | tokens])
    after
      0 -> Enum.reverse(tokens)
    end
  end

  defp token_problem(path, {:yamerl_anchor, line, _column, name}),
    do: ["#{path}:#{line}: an anchor (&#{name}), which this check does not follow"]

  defp token_problem(path, {:yamerl_alias, line, _column, name}),
    do: ["#{path}:#{line}: an alias (*#{name}), which this check does not follow"]

  defp token_problem(path, {:yamerl_scalar, line, column, tag, _style, substyle, text}) do
    merge =
      if substyle == :plain and text == ~c"<<",
        do: ["#{path}:#{line}: a merge key (<<), which this check does not follow"],
        else: []

    merge ++ tag_problem(path, line, column, tag)
  end

  defp token_problem(path, {:yamerl_collection_start, line, column, tag, _style, _kind}),
    do: tag_problem(path, line, column, tag)

  defp token_problem(path, token)
       when elem(token, 0) in [
              :yamerl_yaml_directive,
              :yamerl_tag_directive,
              :yamerl_reserved_directive
            ],
       do: ["#{path}:#{elem(token, 1)}: a directive, which this check does not read"]

  defp token_problem(_path, _token), do: []

  # yamerl gives every node a tag. One the file writes (`!!str`, a lone `!`) sits before its node;
  # an implied one sits where its node does.
  defp tag_problem(path, line, column, {:yamerl_tag, tag_line, tag_column, uri}) do
    if {tag_line, tag_column} == {line, column},
      do: [],
      else: ["#{path}:#{tag_line}: a tag (#{tag_text(uri)}), which this check does not read"]
  end

  defp tag_text({:non_specific, mark}), do: to_string(mark)
  defp tag_text(uri), do: to_string(uri)

  defp rules(path, root) do
    workflow = workflow_path?(path)

    walked =
      if full?(path),
        do: walk(root, [], %Context{path: path, workflow?: workflow and not action?(path)}),
        else: []

    walked ++
      if(workflow, do: trigger_problems(path, root) ++ reusable_jobs(path, root), else: []) ++
      if(tag_workflow?(path), do: tag_trigger_problems(path, root), else: [])
  end

  defp walk({:map, _line, pairs} = map, where, ctx) do
    ctx = enter(map, where, ctx)

    Enum.flat_map(pairs, fn {key, value} ->
      name = key_name(key)
      inner = where ++ [name]

      key_problems(key, inner, ctx) ++
        pair_problems(name, value, where, ctx) ++ walk(value, inner, ctx)
    end)
  end

  defp walk({:seq, _line, items}, where, ctx) do
    items
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, index} -> walk(item, where ++ [index], ctx) end)
  end

  defp walk({:str, line, text}, where, ctx), do: text_problems(text, line, where, :value, ctx)
  defp walk(_scalar, _where, _ctx), do: []

  defp enter(map, ["jobs", _job], ctx), do: %{ctx | job: map}
  defp enter(map, ["jobs", _job, "steps", _index], ctx), do: %{ctx | step: map}
  defp enter(_map, _where, ctx), do: ctx

  defp key_name({:str, _line, text}), do: text
  defp key_name(_key), do: "?"

  defp key_problems({:str, line, text}, where, ctx),
    do: text_problems(text, line, where, :key, ctx)

  defp key_problems(key, where, ctx), do: walk(key, where, ctx)

  # An action's `pre-if` and `post-if` are conditions too, and no allowance covers them.
  defp pair_problems(name, value, where, ctx) when name in ["if", "pre-if", "post-if"] do
    if name == "if" and allowed_if?(value, where, ctx),
      do: [],
      else: ["#{at(ctx, value)}: #{dotted(where ++ [name])}: an if: #{scalar_text(value)}"]
  end

  defp pair_problems("uses", {:str, _line, text} = value, where, ctx) do
    if String.contains?(text, "github-script"),
      do: [
        "#{at(ctx, value)}: #{dotted(where ++ ["uses"])}: runs code that gets the event: #{text}"
      ],
      else: []
  end

  defp pair_problems(_name, _value, _where, _ctx), do: []

  defp text_problems(text, line, where, role, ctx) do
    place = "#{ctx.path}:#{line}: #{dotted(where)}#{if role == :key, do: " (key)"}"

    expressions =
      for [whole, inner] <- Regex.scan(@expression, text),
          not (role == :value and allowed_expression?(String.trim(inner), where, ctx)),
          do: "#{place}: an expression: #{whole}"

    names =
      if Regex.match?(@names, text) and not allowed_names?(text, where, ctx),
        do: ["#{place}: names a runner variable or reads the event"],
        else: []

    expressions ++ names
  end

  defp allowed_expression?(_inner, _where, %{workflow?: false}), do: false
  defp allowed_expression?("github.ref", ["concurrency", "group"], _ctx), do: true

  defp allowed_expression?(inner, ["jobs", _job, "steps", _index, "with", input], ctx)
       when input in ["key", "restore-keys"],
       do: inner in @cache_keys and uses?(ctx.step, "actions/cache@")

  defp allowed_expression?(inner, ["jobs", _job, "env", _name], _ctx), do: inner in @run_names

  defp allowed_expression?(inner, ["jobs", _job, "steps", _index, "env", _name], _ctx),
    do: inner in @run_names

  defp allowed_expression?(
         "env.CINDER_IMAGE",
         ["jobs", _job, "steps", _index, "with", "image-ref"],
         ctx
       ),
       do: uses?(ctx.step, "aquasecurity/trivy-action@")

  defp allowed_expression?(_inner, _where, _ctx), do: false

  defp allowed_if?(_value, _where, %{workflow?: false}), do: false

  defp allowed_if?({:str, _line, text}, ["jobs", _job, "steps", _index], ctx) do
    case String.trim(text) do
      "always()" -> true
      @cmake_if -> cmake_step?(ctx)
      _other -> false
    end
  end

  defp allowed_if?(_value, _where, _ctx), do: false

  defp cmake_step?(%{job: job, step: step}) do
    keys(step) == ["if", "run"] and string(step, "run") == @cmake_run and
      Enum.any?(
        steps_of(job),
        &(string(&1, "id") == "deps-build" and uses?(&1, "actions/cache@"))
      )
  end

  defp allowed_names?(_text, _where, %{workflow?: false}), do: false

  defp allowed_names?(text, ["jobs", _job, "steps", _index, "run"], ctx),
    do: trivy_db_step?(ctx.step) and not Regex.match?(@names, strip(text, @trivy_run_forms))

  defp allowed_names?(_text, _where, _ctx), do: false

  defp trivy_db_step?(step),
    do: keys(step) == ["name", "run"] and string(step, "name") == @trivy_db

  defp strip(text, forms), do: Enum.reduce(forms, text, &Regex.replace(&1, &2, ""))

  defp trigger_problems(path, root) do
    case triggers(get(root, "on")) do
      nil -> ["#{path}: no on: triggers"]
      triggers -> missing_triggers(path, triggers) ++ trigger_filters(path, triggers)
    end
  end

  defp missing_triggers(path, triggers) do
    for name <- ["push", "pull_request"],
        not Map.has_key?(triggers, name),
        do: "#{path}: no #{name} trigger"
  end

  defp trigger_filters(path, triggers) do
    Enum.flat_map(triggers, fn
      {"pull_request", filter} ->
        if empty?(filter), do: [], else: ["#{path}: pull_request has a filter"]

      {"push", filter} ->
        if main_only?(filter),
          do: [],
          else: ["#{path}: push has a filter beyond branches: [main]"]

      {name, _filter} ->
        if name in @other_triggers, do: [], else: ["#{path}: trigger #{name}"]
    end)
  end

  # A workflow's triggers as `%{name => filter node or nil}`, or nil when it has no `on`.
  defp triggers({:str, _line, name}), do: %{name => nil}
  defp triggers({:seq, _line, items}), do: Map.new(items, &{scalar_text(&1), nil})

  defp triggers({:map, _line, pairs}),
    do: Map.new(pairs, fn {key, value} -> {key_name(key), value} end)

  defp triggers(_on), do: nil

  defp empty?(nil), do: true
  defp empty?({:null, _line}), do: true
  defp empty?({:map, _line, []}), do: true
  defp empty?(_filter), do: false

  defp main_only?(filter) do
    empty?(filter) or
      match?({:map, _, [{{:str, _, "branches"}, {:str, _, "main"}}]}, filter) or
      match?({:map, _, [{{:str, _, "branches"}, {:seq, _, [{:str, _, "main"}]}}]}, filter)
  end

  defp reusable_jobs(path, root) do
    for {key, job} <- pairs(get(root, "jobs")),
        uses = get(job, "uses"),
        uses != nil,
        do:
          "#{path}:#{line(uses)}: jobs.#{key_name(key)}: calls a reusable workflow: #{scalar_text(uses)}"
  end

  defp tag_trigger_problems(path, root) do
    if tag_push_only?(root), do: [], else: ["#{path}: a trigger other than a push of tags"]
  end

  defp tag_push_only?(root) do
    case get(root, "on") do
      {:map, _line, [{{:str, _, "push"}, {:map, _, [{{:str, _, "tags"}, _tags}]}}]} -> true
      _on -> false
    end
  end

  # `%{{path, line} => forms}` for rule 5 in a workflow and rule 6 in release.yml.
  defp allowed_lines(path, text, root) do
    cond do
      workflow_path?(path) and not action?(path) -> trivy_lines(path, text, root)
      path == @release and tag_push_only?(root) -> release_lines(path, root)
      true -> %{}
    end
  end

  defp trivy_lines(path, text, root) do
    lines = String.split(text, "\n")

    for {:map, first, _pairs} = step <- all_steps(root),
        trivy_db_step?(step),
        column = key_column(lines, first),
        column != nil,
        reduce: %{} do
      allowed ->
        allowed
        |> put_lines(path, body_lines(lines, first, column), @trivy_run_forms)
        |> put_lines(path, comment_lines(lines, first, column), @trivy_comment_forms)
    end
  end

  # The indentation of the step's keys, read from its first line, which opens with `- `. A step
  # written otherwise gets no allowed line.
  defp key_column(lines, first) do
    case Regex.run(~r/^( *)- /, Enum.at(lines, first - 1)) do
      [_whole, dash] -> String.length(dash) + 2
      nil -> nil
    end
  end

  # The step's first line, then each line after it that is blank or indented as deep as its keys.
  defp body_lines(lines, first, column) do
    rest =
      lines
      |> Enum.drop(first)
      |> Enum.with_index(first + 1)
      |> Enum.take_while(fn {text, _number} ->
        String.trim(text) == "" or indent(text) >= column
      end)
      |> Enum.map(&elem(&1, 1))

    [first | rest]
  end

  # The comment lines right above the step, at the indentation of its dash.
  defp comment_lines(lines, first, column) do
    dash = String.duplicate(" ", column - 2)

    lines
    |> Enum.take(first - 1)
    |> Enum.with_index(1)
    |> Enum.reverse()
    |> Enum.take_while(fn {text, _number} -> String.starts_with?(text, dash <> "#") end)
    |> Enum.map(&elem(&1, 1))
  end

  defp indent(text), do: byte_size(text) - byte_size(String.trim_leading(text, " "))

  defp release_lines(path, root) do
    for step <- all_steps(root),
        uses?(step, "docker/login-action@"),
        {:str, line, @release_password} <- [get(get(step, "with"), "password")],
        into: %{},
        do: {{path, line}, @release_forms}
  end

  defp put_lines(allowed, path, numbers, forms),
    do: Enum.reduce(numbers, allowed, &Map.put(&2, {path, &1}, forms))

  # Every file outside Markdown that holds a name of @names, read line by line. A line passes
  # when the forms `allowed` gives it, removed, leave no name.
  defp name_scan(top, commit, allowed) do
    {:ok, out} =
      git(
        top,
        ["grep", "-l", "-z", "-E", "-e", @names_source, commit, "--", ".", ":(exclude)*.md"],
        ok: [0, 1]
      )

    for hit <- String.split(out, <<0>>, trim: true),
        path = String.replace_prefix(hit, commit <> ":", ""),
        difference <- name_lines(path, blob(top, commit, path), allowed),
        do: difference
  end

  defp name_lines(path, text, allowed) do
    if String.contains?(text, <<0>>) do
      ["#{path}: a binary file that names a runner variable or reads the event"]
    else
      for {line, number} <- text |> String.split("\n") |> Enum.with_index(1),
          Regex.match?(@names, strip(line, Map.get(allowed, {path, number}, []))),
          do:
            "#{path}:#{number}: names a runner variable or reads the event: " <>
              String.trim(line)
    end
  end

  defp uses?(step, prefix) do
    case get(step, "uses") do
      {:str, _line, text} -> String.starts_with?(text, prefix)
      _uses -> false
    end
  end

  defp all_steps(root),
    do: Enum.flat_map(pairs(get(root, "jobs")), fn {_id, job} -> steps_of(job) end)

  defp steps_of(job) do
    case get(job, "steps") do
      {:seq, _line, steps} -> steps
      _steps -> []
    end
  end

  defp get({:map, _line, pairs}, key) do
    Enum.find_value(pairs, fn {name, value} -> if key_name(name) == key, do: value end)
  end

  defp get(_node, _key), do: nil

  defp pairs({:map, _line, pairs}), do: pairs
  defp pairs(_node), do: []

  defp keys(node), do: node |> pairs() |> Enum.map(&key_name(elem(&1, 0))) |> Enum.sort()

  defp string(node, key) do
    case get(node, key) do
      {:str, _line, text} -> text
      _value -> nil
    end
  end

  defp scalar_text({:str, _line, text}), do: text
  defp scalar_text(_node), do: "(not a string)"

  defp at(ctx, node), do: "#{ctx.path}:#{line(node)}"

  defp dotted([]), do: "(document)"

  defp dotted(where) do
    where
    |> Enum.map_join(fn
      index when is_integer(index) -> "[#{index}]"
      key -> "." <> key
    end)
    |> String.trim_leading(".")
  end

  # A file name, a key or a value can hold bytes that are not UTF-8, which IO cannot print. Each
  # such byte prints as \xNN, so a name stays apart from its twin that holds U+FFFD instead.
  defp printable(text), do: text |> String.chunk(:valid) |> Enum.map_join(&escape_invalid/1)

  defp escape_invalid(chunk) do
    if String.valid?(chunk),
      do: chunk,
      else: for(<<byte <- chunk>>, into: "", do: "\\x" <> Base.encode16(<<byte>>))
  end
end
