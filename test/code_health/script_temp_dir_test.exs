defmodule Cinder.CodeHealth.ScriptTempDirTest do
  # Inside the flake's dev shell, TMPDIR is a /tmp/nix-shell.* directory on the tmpfs that every
  # session on the Linux host shares. On #1153, scripts/merge-fences made its worktree with
  # ${TMPDIR:-/var/tmp}, so a run from the dev shell put a whole worktree and its _build there
  # (fixed by #1328). A script names its temp directory instead of reading TMPDIR, as
  # merge-fences' MERGE_FENCES_TMPDIR, which defaults to /var/tmp, does.
  #
  # The fence reads each file under scripts/, in subfolders and dotfiles too, by its kind:
  # - Elixir (.ex, .exs): it walks the AST and fails a `System.tmp_dir/0` or `System.tmp_dir!/0`
  #   call or capture, and a string or charlist that names TMPDIR or mktemp. The parser drops
  #   comments.
  # - Shell (a bash or sh shebang): no parser, so it reads each line but a `#` comment line. It
  #   fails a line that names TMPDIR, and each mktemp but the form merge-fences uses: flags from
  #   -d, -q, --directory and --quiet, then one template that holds a `/` and no `$(`. A call's
  #   words end at `;`, `|`, `&`, `)` or a backtick. A bare mktemp and one with -t use TMPDIR, as
  #   --tmpdir and -p do when they name no directory, so the reader fails all four, and a
  #   template split by a space or a line continuation.
  # - Python (a python shebang): it fails a line that names TMPDIR, tempfile or mktemp, comment
  #   lines included, since no script under scripts/ uses one.
  # - Any other file: it fails, so a new kind gets a reader before it lands.
  # Forms the fence does not follow include: a program that puts its own temporary files under
  # TMPDIR, such as sort or bash; a `#` line inside a shell here-document body or a quoted string
  # that spans lines; a path the script writes under /tmp itself, in a mktemp template
  # (`/tmp/x.XXXXXX`, `"/tmp"/x.XXXXXX`, `"${root:-/tmp}/x.XXXXXX"`) or anywhere else, since the
  # fence reads TMPDIR and mktemp's fallback to it, not /tmp; a template under a variable whose
  # value the fence does not read (`$TMP`); a name built from parts (`"TMP""DIR"`,
  # `"temp" + "file"`); in Elixir, `System` under another alias, `apply/3` and a single-quoted
  # charlist.
  use ExUnit.Case, async: true

  @name ~r/(?<![\w-])(TMPDIR|mktemp)(?![\w-])/
  @python_name ~r/(?<![\w-])(TMPDIR|tempfile|mktemp)(?![\w-])/
  @mktemp ~r/(?<![\w-])mktemp(?![\w-])([^;|&)`]*)/
  @mktemp_flags ~w(-d -q --directory --quiet)

  test "no script under scripts/ puts temp files under TMPDIR" do
    scans = scans("scripts")

    # Each reader ran on a real script, so none passes on nothing.
    assert scans |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.sort() ==
             [:elixir, :python, :shell]

    found = found(scans)

    assert found == [],
           "These lines put temp files under TMPDIR, which the dev shell points at the shared " <>
             "/tmp tmpfs. Name the directory: mktemp -d /var/tmp/<name>.XXXXXX, or a variable " <>
             "of the script's own that defaults to /var/tmp (MERGE_FENCES_TMPDIR in " <>
             "scripts/merge-fences):\n  " <> Enum.join(found, "\n  ")
  end

  @tag :tmp_dir
  test "the scan reads scripts in subfolders and dotfiles, and skips folders", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "sub/empty"))
    File.write!(Path.join(dir, "sub/deep"), "#!/usr/bin/env bash\nx=$TMPDIR\n")
    File.write!(Path.join(dir, ".hidden.exs"), "System.tmp_dir!()\n")

    assert dir |> scans() |> found() |> Enum.sort() == [
             "#{dir}/.hidden.exs:1: calls System.tmp_dir!",
             "#{dir}/sub/deep:2: names TMPDIR"
           ]
  end

  test "each kind comes from the extension or the shebang, and any other file fails" do
    assert kind("scripts/a.exs", "IO.puts(1)\n") == :elixir
    assert kind("scripts/a.ex", "defmodule A, do: nil\n") == :elixir
    assert kind("scripts/a", "#!/usr/bin/env bash\n") == :shell
    assert kind("scripts/a.sh", "#!/bin/sh\n") == :shell
    assert kind("scripts/a", "#!/usr/bin/env python3\n") == :python
    assert kind("scripts/a", "#!/usr/bin/env zsh\n") == :unknown
    assert kind("scripts/a.sh", "echo hi\n") == :unknown

    assert uses(:unknown, "echo hi\n") ==
             [{1, "is a kind of script the fence cannot read; give it a reader in this fence"}]
  end

  test "the shell scan fails each TMPDIR and mktemp form and passes merge-fences' form" do
    source = ~S"""
    #!/usr/bin/env bash
    # a comment may name $TMPDIR and mktemp -d
    a=${TMPDIR:-/var/tmp}
    b=$TMPDIR/x
    c=$(mktemp -d)
    d=$(mktemp)
    mktemp -d -q | cat
    e=$(mktemp -t x.XXXXXX)
    f=$(mktemp -d -p /var/tmp x.XXXXXX)
    g=$(mktemp --tmpdir x.XXXXXX)
    h=$(mktemp -d \
      /var/tmp/x.XXXXXX)
    i=$(mktemp -d "$(/bin/pwd)/x.XXXXXX")
    fail "mktemp failed"
    export TMPDIR=/var/tmp
    j=$(mktemp -d /var/tmp/x.XXXXXX)
    k=$(mktemp -d "$tmp_root/x.XXXXXX") || fail "no dir in $tmp_root"
    l=$(mktemp -q --directory "${root}/x.XXXXXX"); m=${MERGE_FENCES_TMPDIR:-/var/tmp}
      # an indented comment: mktemp $TMPDIR
    n=$(mktemp -d "$root/a b.XXXXXX")
    o=$(mktemp -d /var/tmp/x.XXXXXX) p=1
    mktemp -d /var/tmp/x.XXXXXX && echo made
    q=`mktemp -d /var/tmp/x.XXXXXX` r=1
    s=$(my_mktemp) t=$mktemp_dir
    mktemp -d /var/tmp/x.XXXXXX; echo made
    mktemp -d /var/tmp/x.XXXXXX | xargs echo
    u=$(mktemp -d --tmpdir sub/x.XXXXXX)
    v=$(mktemp -t sub/x.XXXXXX)
    """

    assert uses(:shell, source) == [
             {3, "names TMPDIR"},
             {4, "names TMPDIR"},
             {5, "calls mktemp without one template in a named directory"},
             {6, "calls mktemp without one template in a named directory"},
             {7, "calls mktemp without one template in a named directory"},
             {8, "calls mktemp without one template in a named directory"},
             {9, "calls mktemp without one template in a named directory"},
             {10, "calls mktemp without one template in a named directory"},
             {11, "calls mktemp without one template in a named directory"},
             {13, "calls mktemp without one template in a named directory"},
             {14, "calls mktemp without one template in a named directory"},
             {15, "names TMPDIR"},
             {20, "calls mktemp without one template in a named directory"},
             {27, "calls mktemp without one template in a named directory"},
             {28, "calls mktemp without one template in a named directory"}
           ]
  end

  test "the shell and Python scans miss the forms the header names" do
    source = ~S"""
    #!/usr/bin/env bash
    cat > run.sh <<EOF
    # $TMPDIR here is a body line bash expands, not a comment
    EOF
    note="first line
    # $TMPDIR inside a quoted string
    "
    sort -u big.txt
    a=$(mktemp -d "$TMP/x.XXXXXX")
    b=$(mktemp -d /tmp/x.XXXXXX)
    c=$(mktemp -d "/tmp"/x.XXXXXX)
    d=$(mktemp -d "${root:-/tmp}/x.XXXXXX")
    cp big.txt /tmp/big.txt
    printenv "TMP""DIR"
    """

    assert uses(:shell, source) == []
    assert uses(:python, ~S|t = __import__("temp" + "file")|) == []
  end

  test "the Elixir scan fails tmp_dir calls and strings that name TMPDIR or mktemp" do
    source = ~S'''
    # a comment may name System.tmp_dir!() and $TMPDIR
    a = System.tmp_dir!()
    b = System.tmp_dir()
    c = :"Elixir.System".tmp_dir!()
    d = &System.tmp_dir!/0
    e =
      System.
        tmp_dir!()
    f = System.get_env("TMPDIR")
    g = "#{a}/$TMPDIR/x"
    h = :os.getenv(~c"TMPDIR")
    i = System.cmd("mktemp", ["-d"])
    j = """
    TMPDIR
    """
    k = System.get_env("MERGE_FENCES_TMPDIR")
    l = Path.join("/var/tmp", "x")
    m = Elixir.System.tmp_dir!()
    n = "TMPDIR, then TMPDIR again"
    '''

    assert uses(:elixir, source) == [
             {2, "calls System.tmp_dir!"},
             {3, "calls System.tmp_dir"},
             {4, "calls System.tmp_dir!"},
             {5, "calls System.tmp_dir!"},
             {8, "calls System.tmp_dir!"},
             {9, "names TMPDIR"},
             {10, "names TMPDIR"},
             {11, "names TMPDIR"},
             {12, "names mktemp"},
             {13, "names TMPDIR"},
             {18, "calls System.tmp_dir!"},
             {19, "names TMPDIR"}
           ]
  end

  test "the Elixir scan misses System under another alias, apply/3 and a quoted charlist" do
    source = ~S"""
    alias System, as: S
    a = S.tmp_dir!()
    b = apply(System, :tmp_dir!, [])
    c = :os.getenv('TMPDIR')
    """

    assert uses(:elixir, source) == []
  end

  test "the Python scan fails each line that names TMPDIR, tempfile or mktemp" do
    source = ~S"""
    #!/usr/bin/env python3
    # comment lines count: tempfile
    import tempfile
    d = os.environ["TMPDIR"]
    subprocess.run(["mktemp", "-d"])
    e = os.environ["MERGE_FENCES_TMPDIR"]
    f = "/var/tmp/x"
    """

    assert uses(:python, source) == [
             {2, "names tempfile"},
             {3, "names tempfile"},
             {4, "names TMPDIR"},
             {5, "names mktemp"}
           ]
  end

  # Each file under root, subfolders and dotfiles included, with its kind and text.
  defp scans(root) do
    for path <- Path.wildcard(Path.join(root, "**/*"), match_dot: true), File.regular?(path) do
      source = File.read!(path)
      {path, kind(path, source), source}
    end
  end

  defp found(scans) do
    for {path, kind, source} <- scans,
        {line, what} <- uses(kind, source),
        do: "#{path}:#{line}: #{what}"
  end

  defp kind(path, source) do
    shebang = source |> String.split("\n", parts: 2) |> hd()

    cond do
      Path.extname(path) in [".ex", ".exs"] -> :elixir
      shebang =~ ~r/\A#!.*\bpython/ -> :python
      shebang =~ ~r/\A#!.*\b(ba)?sh\b/ -> :shell
      true -> :unknown
    end
  end

  defp uses(:elixir, source) do
    {:ok, ast} =
      Code.string_to_quoted(source,
        emit_warnings: false,
        literal_encoder: &{:ok, {:__block__, &2, [&1]}}
      )

    {_ast, found} = Macro.prewalk(ast, [], &elixir_use/2)
    Enum.sort(found)
  end

  defp uses(:shell, source) do
    for {line, number} <- numbered(source),
        not String.starts_with?(String.trim_leading(line), "#"),
        what <- shell_uses(line),
        do: {number, what}
  end

  defp uses(:python, source) do
    for {line, number} <- numbered(source),
        [name | _] <- Regex.scan(@python_name, line, capture: :all_but_first),
        do: {number, "names #{name}"}
  end

  defp uses(:unknown, _source),
    do: [{1, "is a kind of script the fence cannot read; give it a reader in this fence"}]

  defp numbered(source), do: source |> String.split("\n") |> Enum.with_index(1)

  defp shell_uses(line) do
    tmpdir = if line =~ ~r/(?<![\w-])TMPDIR(?![\w-])/, do: ["names TMPDIR"], else: []

    mktemp =
      for [args] <- Regex.scan(@mktemp, line, capture: :all_but_first),
          not named_template?(String.split(args)),
          do: "calls mktemp without one template in a named directory"

    tmpdir ++ mktemp
  end

  # The form merge-fences uses: flags from @mktemp_flags only, then one template that holds a
  # `/` and takes no directory from a command substitution.
  defp named_template?(words) do
    case Enum.split_with(words, &String.starts_with?(&1, "-")) do
      {flags, [template]} ->
        Enum.all?(flags, &(&1 in @mktemp_flags)) and String.contains?(template, "/") and
          not String.contains?(template, "$(")

      _split ->
        false
    end
  end

  defp elixir_use({{:., _, [module, fun]}, meta, _args} = node, found)
       when fun in [:tmp_dir, :tmp_dir!] do
    if system?(module),
      do: {node, [{meta[:line], "calls System.#{fun}"} | found]},
      else: {node, found}
  end

  defp elixir_use({:__block__, meta, [text]} = node, found) when is_binary(text),
    do: {node, text_uses(text, meta[:line]) ++ found}

  defp elixir_use({:<<>>, meta, parts} = node, found) do
    texts = for part <- parts, is_binary(part), use <- text_uses(part, meta[:line]), do: use
    {node, texts ++ found}
  end

  defp elixir_use(node, found), do: {node, found}

  defp system?({:__aliases__, _, [:System]}), do: true
  defp system?({:__aliases__, _, [:"Elixir", :System]}), do: true
  defp system?({:__block__, _, [System]}), do: true
  defp system?(_module), do: false

  defp text_uses(text, line) do
    for [name | _] <- Regex.scan(@name, text, capture: :all_but_first) |> Enum.uniq(),
        do: {line, "names #{name}"}
  end
end
