defmodule Cinder.TestAtBaseScriptTest do
  # Runs `scripts/test-at-base` in a throwaway git repo against a stub `mix` on PATH, so its exit
  # codes, its swaps and its restores, a failed restore included, stay covered without a nested
  # `mix test` run. The stub writes what it saw of a.ex, b.ex, c.ex and each path in $TAB_EXTRA,
  # and its arguments, to $TAB_SEEN. It writes a file at $TAB_LITTER when that is set, then exits
  # with $TAB_EXIT, sleeps when $TAB_SLEEP is set, or first puts a folder where a.ex was when
  # $TAB_SWAPDIR is set. PATH holds only the stub and links to the tools the
  # script, the stub and the signal tests' shell call, so the real `mix` is never found. The one
  # path left out is a write that fails during the swap: CI runs the suite as root, so no file
  # mode makes it fail.
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  @tools ~w(bash cat sleep seq git grep python3 rm mkdir)

  @script Path.expand("scripts/test-at-base")

  @stub """
  #!/usr/bin/env bash
  for f in a.ex b.ex c.ex $TAB_EXTRA; do
    if [ -e "$f" ]; then echo "$f=$(cat "$f")"; else echo "$f absent"; fi
  done > "$TAB_SEEN"
  echo "args: $*" >> "$TAB_SEEN"
  [ -n "$TAB_LITTER" ] && echo x > "$TAB_LITTER"
  [ -n "$TAB_SLEEP" ] && exec sleep 30
  [ -n "$TAB_SWAPDIR" ] && rm a.ex && mkdir a.ex
  printf '\\nResult: stub\\n'
  exit "${TAB_EXIT:-0}"
  """

  setup %{tmp_dir: dir} do
    repo = Path.join(dir, "repo")
    File.mkdir_p!(repo)
    git = fn args -> {_, 0} = System.cmd("git", args, cd: repo, stderr_to_stdout: true) end
    git.(["init", "-q"])
    File.write!(Path.join(repo, "a.ex"), "BASE A")
    File.write!(Path.join(repo, "c.ex"), "BASE C")
    git.(["add", "a.ex", "c.ex"])

    git.(
      ~w(-c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m base --no-verify)
    )

    File.write!(Path.join(repo, "a.ex"), "WORK A")
    File.write!(Path.join(repo, "b.ex"), "WORK B")
    File.rm!(Path.join(repo, "c.ex"))

    bin = Path.join(dir, "bin")
    bare = Path.join(dir, "bare")

    for folder <- [bin, bare] do
      File.mkdir_p!(folder)

      for tool <- @tools,
          do: File.ln_s!(System.find_executable(tool), Path.join(folder, tool))
    end

    File.write!(Path.join(bin, "mix"), @stub)
    File.chmod!(Path.join(bin, "mix"), 0o755)
    %{dir: dir, repo: repo, bin: bin, bare: bare, seen: Path.join(dir, "seen")}
  end

  defp run(ctx, args, env \\ []) do
    env = [{"PATH", ctx.bin}, {"TAB_SEEN", ctx.seen} | env]
    System.cmd("python3", ["-I", @script | args], cd: ctx.repo, env: env, stderr_to_stdout: true)
  end

  defp working_copy(ctx) do
    for name <- ~w(a.ex b.ex c.ex) do
      case File.read(Path.join(ctx.repo, name)) do
        {:ok, body} -> {name, body}
        {:error, :enoent} -> {name, :absent}
      end
    end
  end

  @restored [{"a.ex", "WORK A"}, {"b.ex", "WORK B"}, {"c.ex", :absent}]

  test "runs mix on the base's files, then restores each working copy", ctx do
    {out, code} = run(ctx, ["HEAD", "a.ex", "b.ex", "c.ex", "--", "t.exs:3"], [{"TAB_EXIT", "2"}])

    assert code == 2, out

    assert File.read!(ctx.seen) ==
             "a.ex=BASE A\nb.ex absent\nc.ex=BASE C\nargs: test.unchecked t.exs:3\n"

    assert out =~ "at HEAD: a.ex\nat HEAD: b.ex\nat HEAD: c.ex\n"
    assert out =~ "Result: stub"
    assert out =~ "restored: a.ex b.ex c.ex"
    assert working_copy(ctx) == @restored
  end

  # A working copy can lack the folder of a file the base holds, such as a checkout of a commit
  # that deleted or renamed the folder's last file. The script makes the folders the base's file
  # needs, then removes them.
  for {label, from, to} <- [
        {"a deleted file", "w/v.ex", nil},
        {"a file renamed out of a nested folder", "x/deep/y.ex", "z/y.ex"}
      ] do
    test "#{label} whose folder is gone: makes the folder for the run, then removes it", ctx do
      names = move_out(ctx, unquote(from), unquote(to))

      {out, code} =
        run(ctx, ["HEAD" | names] ++ ["--", "t.exs"], [{"TAB_EXTRA", Enum.join(names, " ")}])

      assert code == 0, out
      assert File.read!(ctx.seen) =~ "#{unquote(from)}=BASE #{unquote(from)}\n"
      refute File.exists?(Path.join(ctx.repo, top(unquote(from)))), out

      assert_moved_to_kept(ctx, unquote(to))
      assert working_copy(ctx) == @restored
    end
  end

  test "exits 3 and names a folder it made that the run left a file in", ctx do
    names = move_out(ctx, "w/v.ex", nil)
    {out, code} = run(ctx, ["HEAD" | names] ++ ["--", "t.exs"], [{"TAB_LITTER", "w/litter"}])

    assert code == 3, out
    assert out =~ ~r/test-at-base: cannot remove \S*\/w: /
    refute out =~ "restored:"
    refute File.exists?(Path.join(ctx.repo, "w/v.ex"))
    assert working_copy(ctx) == @restored
  end

  # Commits `from` on top of the base, then moves it to `to` (or deletes it when `to` is nil) and
  # removes its top folder, so the working copy lacks the folder the base's file needs. Returns
  # the paths to name.
  defp move_out(ctx, from, to) do
    git = fn args -> {_, 0} = System.cmd("git", args, cd: ctx.repo, stderr_to_stdout: true) end
    File.mkdir_p!(Path.join(ctx.repo, Path.dirname(from)))
    File.write!(Path.join(ctx.repo, from), "BASE #{from}")
    git.(["add", from])

    git.(
      ~w(-c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m more --no-verify)
    )

    if to do
      File.mkdir_p!(Path.join(ctx.repo, Path.dirname(to)))
      File.write!(Path.join(ctx.repo, to), "WORK #{to}")
    end

    File.rm_rf!(Path.join(ctx.repo, top(from)))
    [from | List.wrap(to)]
  end

  defp top(path), do: path |> Path.split() |> hd()

  # A rename's new path is absent during the run and holds its working bytes after it.
  defp assert_moved_to_kept(_ctx, nil), do: :ok

  defp assert_moved_to_kept(ctx, to) do
    assert File.read!(ctx.seen) =~ "#{to} absent\n"
    assert File.read!(Path.join(ctx.repo, to)) == "WORK #{to}"
  end

  for exit <- ["0", "1"] do
    test "exits #{exit} when mix exits #{exit}", ctx do
      {out, code} = run(ctx, ["HEAD", "a.ex", "--", "t.exs"], [{"TAB_EXIT", unquote(exit)}])

      assert code == String.to_integer(unquote(exit)), out
      assert working_copy(ctx) == @restored
    end
  end

  for {label, args, message} <- [
        {"no --", ["HEAD", "a.ex", "t.exs"], "usage:"},
        {"nothing after --", ["HEAD", "a.ex", "--"], "usage:"},
        {"no file", ["HEAD", "--", "t.exs"], "usage:"},
        {"an unknown base", ["nosuch", "b.ex", "--", "t.exs"],
         "git cannot read the commit nosuch"},
        {"a file outside the repo", ["HEAD", "../seen", "--", "t.exs"], "is outside the repo"},
        {"a folder", ["HEAD", "a.ex", "sub", "--", "t.exs"], "sub is not a regular file"}
      ] do
    test "exits 3 and runs nothing on #{label}", ctx do
      File.mkdir_p!(Path.join(ctx.repo, "sub"))
      {out, code} = run(ctx, unquote(args))

      assert code == 3, out
      assert out =~ unquote(message)
      refute File.exists?(ctx.seen)
      assert working_copy(ctx) == @restored
    end
  end

  test "exits 3 and names the file when a restore fails, after restoring the others", ctx do
    {out, code} = run(ctx, ["HEAD", "a.ex", "b.ex", "--", "t.exs"], [{"TAB_SWAPDIR", "1"}])

    assert code == 3, out
    assert out =~ ~r/test-at-base: cannot restore \S*a\.ex: /
    refute out =~ "restored:"
    assert File.dir?(Path.join(ctx.repo, "a.ex"))
    assert File.read!(Path.join(ctx.repo, "b.ex")) == "WORK B"
  end

  test "exits 3 and restores the files when no mix is on PATH", ctx do
    {out, code} = run(ctx, ["HEAD", "a.ex", "c.ex", "--", "t.exs"], [{"PATH", ctx.bare}])

    assert code == 3, out
    assert out =~ "no mix on PATH"
    assert working_copy(ctx) == @restored
  end

  for signal <- ["TERM", "INT"] do
    test "restores the files and exits 130 on SIG#{signal} during the run", ctx do
      # A background job in a non-interactive bash starts with SIGINT ignored, so the SIGINT
      # case passes only while the script installs its own handler for it. The signal waits for
      # the stub's last line, `args:`: the stub writes $TAB_SEEN a line at a time, and on a
      # loaded runner a signal sent after the first line killed it before the c.ex line (#1362).
      shell = """
      python3 -I "$0" HEAD a.ex b.ex c.ex -- t.exs > /dev/null 2>&1 & p=$!
      for i in $(seq 1 200); do grep -qs '^args: ' "$TAB_SEEN" && break; sleep 0.1; done
      kill -#{unquote(signal)} $p; wait $p; echo "exit=$?"
      """

      env = [{"PATH", ctx.bin}, {"TAB_SEEN", ctx.seen}, {"TAB_SLEEP", "1"}]
      {out, 0} = System.cmd("bash", ["-c", shell, @script], cd: ctx.repo, env: env)

      assert out =~ "exit=130"
      assert File.read!(ctx.seen) =~ "a.ex=BASE A\nb.ex absent\nc.ex=BASE C\n"
      assert working_copy(ctx) == @restored
    end
  end
end
