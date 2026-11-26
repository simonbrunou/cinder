defmodule Cinder.MergePrScriptTest do
  # Runs a copy of `scripts/merge-pr` in a fixture clone of a bare origin, with a stub `curl` that
  # answers the Forgejo API from files, a stub `sleep`, and a stub `scripts/merge-fences` that logs
  # its arguments, so the wiring of check 7 stays covered without the forge or a `mix` run
  # (#1153). The stub `curl` answers each merge POST with the next code in $STUB/posts, and after
  # a 405 runs $STUB/move when it exists, which pushes a new origin/main commit.
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  @script Path.expand("scripts/merge-pr")
  @api "https://git.sbrn.eu/api/v1/repos/simonbrunou/cinder"

  @curl_stub """
  #!/usr/bin/env bash
  method=GET
  while [[ $# -gt 1 ]]; do
    [[ $1 == -X ]] && method=$2
    shift
  done
  path=${1##{@api}}
  echo "$method $path" >> "$STUB/curl.log"
  case "$method $path" in
    "GET /pulls/7")
      if [[ -e $STUB/merged ]]; then
        body='{"merged":true,"merge_commit_sha":"m1"}'
      else
        body="{\\"state\\":\\"open\\",\\"merged\\":false,\\"title\\":\\"fix: x\\",\\"base\\":{\\"ref\\":\\"main\\"},\\"head\\":{\\"sha\\":\\"$(cat "$STUB/head")\\"}}"
      fi
      code=200 ;;
    "GET /commits/"*"/status")
      if [[ -e $STUB/status ]]; then
        body=$(cat "$STUB/status")
      else
        body='{"state":"success","statuses":[{"context":"CI / test (pull_request)","status":"success"}]}'
      fi
      code=200 ;;
    "POST /pulls/7/merge")
      code=$(head -n 1 "$STUB/posts")
      sed -i 1d "$STUB/posts"
      body='{"message":"try again"}'
      if [[ $code == 405 && -e $STUB/move ]]; then bash "$STUB/move" >&2; rm "$STUB/move"; fi
      [[ $code == 200 ]] && touch "$STUB/merged"
      ;;
    *) body='{}'; code=404 ;;
  esac
  printf '%s\\n%s' "$body" "$code"
  """

  @fences_stub """
  #!/usr/bin/env bash
  echo "fences $1 $2" >> "$STUB/fences.log"
  exit "${FENCES_EXIT:-0}"
  """

  @ci """
  name: CI
  jobs:
    test:
      runs-on: x
  """

  setup %{tmp_dir: dir} do
    stub = Path.join(dir, "stub")
    bin = Path.join(dir, "bin")
    File.mkdir_p!(stub)
    File.mkdir_p!(bin)
    exe!(Path.join(bin, "curl"), @curl_stub)
    exe!(Path.join(bin, "sleep"), "#!/usr/bin/env bash\n")

    home = Path.join(dir, "home")
    keys = Path.join(home, ".local/share/forgejo-cli/keys.json")
    File.mkdir_p!(Path.dirname(keys))
    File.write!(keys, ~s({"hosts":{"git.sbrn.eu":{"token":"t"}}}))

    origin = Path.join(dir, "origin.git")
    git!(dir, ["init", "-q", "--bare", "-b", "main", origin])
    work = Path.join(dir, "work")
    File.mkdir_p!(work)
    git!(work, ["init", "-q", "-b", "main"])
    git!(work, ["remote", "add", "origin", origin])

    write!(work, %{
      ".forgejo/workflows/ci.yml" => @ci,
      "test/code_health_test.exs" => "  @max_lines 1500\n",
      "priv/repo/migrations/.formatter.exs" => "[]\n",
      "priv/repo/migrations/20260101000000_base.exs" => "",
      "a.txt" => "a\n"
    })

    File.mkdir_p!(Path.join(work, "scripts"))
    File.cp!(@script, Path.join(work, "scripts/merge-pr"))
    exe!(Path.join(work, "scripts/merge-fences"), @fences_stub)
    commit!(work, "base")
    git!(work, ["push", "-q", "origin", "main"])

    git!(work, ["checkout", "-q", "-b", "pr"])
    write!(work, %{"b.txt" => "b\n"})
    commit!(work, "fix: x\n\nThe fix's body.")
    head = git!(work, ["rev-parse", "HEAD"])
    git!(work, ["push", "-q", "origin", "HEAD:refs/pull/7/head"])
    File.write!(Path.join(stub, "head"), head)

    git!(work, ["checkout", "-q", "main"])
    write!(work, %{"c.txt" => "c\n"})
    commit!(work, "main moves")
    git!(work, ["push", "-q", "origin", "main"])

    %{dir: dir, bin: bin, stub: stub, home: home, work: work, head: head}
  end

  defp exe!(path, body) do
    File.write!(path, body)
    File.chmod!(path, 0o755)
  end

  # Writes each file of `files` under `repo`, and deletes each one whose body is nil.
  defp write!(repo, files) do
    for {path, body} <- files do
      full = Path.join(repo, path)

      if body == nil do
        File.rm_rf!(full)
      else
        File.mkdir_p!(Path.dirname(full))
        File.write!(full, body)
      end
    end
  end

  defp identity,
    do: for(k <- ~w(AUTHOR COMMITTER), f <- ~w(NAME EMAIL), do: {"GIT_#{k}_#{f}", "t"})

  defp git!(repo, args) do
    {out, 0} =
      System.cmd("git", args,
        cd: repo,
        env: [{"HOME", repo} | identity()],
        stderr_to_stdout: true
      )

    String.trim(out)
  end

  defp commit!(repo, message) do
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", message])
  end

  defp run(ctx, args, extra \\ []) do
    env =
      [
        {"PATH", ctx.bin <> ":" <> System.get_env("PATH")},
        {"HOME", ctx.home},
        {"STUB", ctx.stub}
      ] ++ identity() ++ extra

    System.cmd("bash", ["scripts/merge-pr" | args],
      cd: ctx.work,
      env: env,
      stderr_to_stdout: true
    )
  end

  defp lines(ctx, name) do
    case File.read(Path.join(ctx.stub, name)) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  defp posts(ctx), do: Enum.count(lines(ctx, "curl.log"), &(&1 == "POST /pulls/7/merge"))

  defp main_sha(ctx), do: git!(ctx.work, ["rev-parse", "origin/main"])

  test "--dry-run runs check 7 on the head and the fetched origin/main SHA", ctx do
    {out, code} = run(ctx, ["--dry-run", "7"])

    assert code == 0, out
    assert out =~ "DRY RUN: every check passed"
    assert out =~ "migrations: 1, no version or name twice"
    assert lines(ctx, "fences.log") == ["fences #{ctx.head} #{main_sha(ctx)}"]
    assert posts(ctx) == 0
  end

  test "a failing check 7 stops the merge before the POST", ctx do
    File.write!(Path.join(ctx.stub, "posts"), "200\n")

    {out, code} = run(ctx, ["7"], [{"FENCES_EXIT", "1"}])

    assert code == 1, out
    assert length(lines(ctx, "fences.log")) == 1
    assert posts(ctx) == 0
  end

  test "check 7 runs after the squash body check, so a missing --body-from stops first", ctx do
    git!(ctx.work, ["checkout", "-q", "pr"])
    write!(ctx.work, %{"d.txt" => "d\n"})
    commit!(ctx.work, "review fix")
    head = git!(ctx.work, ["rev-parse", "HEAD"])
    git!(ctx.work, ["push", "-q", "-f", "origin", "HEAD:refs/pull/7/head"])
    File.write!(Path.join(ctx.stub, "head"), head)

    {out, code} = run(ctx, ["--dry-run", "7"])

    assert code == 1, out
    assert out =~ "FAIL: read that message against the final diff"
    assert lines(ctx, "fences.log") == []
  end

  test "a 405 retry does not re-run check 7 while the merged tree is unchanged", ctx do
    File.write!(Path.join(ctx.stub, "posts"), "405\n200\n")

    {out, code} = run(ctx, ["7"])

    assert code == 0, out
    assert out =~ "MERGED: #7 as m1"
    assert out =~ "fences: the merged tree is unchanged since they passed"
    assert length(lines(ctx, "fences.log")) == 1
    assert posts(ctx) == 2
  end

  # The wait counts retries, not seconds, so the minutes check 7 takes never shorten it.
  for {answers, merged?} <- [{15, true}, {16, false}] do
    test "#{answers} answers of 405 #{if merged?, do: "still merge", else: "stop the merge"}",
         ctx do
      codes = List.duplicate("405", unquote(answers)) ++ ["200"]
      File.write!(Path.join(ctx.stub, "posts"), Enum.join(codes, "\n") <> "\n")

      {out, code} = run(ctx, ["7"])

      if unquote(merged?) do
        assert code == 0, out
        assert out =~ "retry 15 of 15 in 20 s"
        assert posts(ctx) == 16
      else
        assert code == 1, out
        assert out =~ "FAIL: Forgejo still answers 405 after 15 retries 20 s apart: try again"
        assert posts(ctx) == 16
      end
    end
  end

  test "a 405 retry re-runs check 7 on the new origin/main when the merged tree changed", ctx do
    File.write!(Path.join(ctx.stub, "posts"), "405\n200\n")
    first = main_sha(ctx)

    File.write!(Path.join(ctx.stub, "move"), """
    cd #{ctx.work}
    echo moved > moved.txt
    git add -A
    git commit -q -m moved
    git push -q origin main
    """)

    {out, code} = run(ctx, ["7"])

    assert code == 0, out
    moved = git!(ctx.work, ["rev-parse", "main"])
    refute moved == first

    assert lines(ctx, "fences.log") == [
             "fences #{ctx.head} #{first}",
             "fences #{ctx.head} #{moved}"
           ]

    assert posts(ctx) == 2
  end

  describe "migrations on the merged tree" do
    test "stops when main and the head each add a migration with one version", ctx do
      main_adds!(ctx, %{"priv/repo/migrations/20260102000000_from_main.exs" => ""})
      push_head!(ctx, %{"priv/repo/migrations/20260102000000_from_pr.exs" => ""})
      File.write!(Path.join(ctx.stub, "posts"), "200\n")

      {out, code} = run(ctx, ["7"])

      assert code == 1, out
      assert out =~ "share the migration version 20260102000000 on the merged tree"
      assert out =~ "20260102000000_from_main.exs"
      assert out =~ "20260102000000_from_pr.exs"

      assert out =~
               "Fix: give the one origin/main lacks a version after the newest on origin/main"

      assert posts(ctx) == 0
    end

    test "names main as the place to fix when origin/main already holds both files", ctx do
      main_adds!(ctx, %{
        "priv/repo/migrations/20260102000000_one.exs" => "",
        "priv/repo/migrations/20260102000000_two.exs" => ""
      })

      {out, code} = run(ctx, ["--dry-run", "7"])

      assert code == 1, out
      assert out =~ "share the migration version 20260102000000 on the merged tree"
      assert out =~ "origin/main already holds both, so main itself is broken: fix it there first"
      refute out =~ "Fix: "
    end

    test "stops when main and the head each add a migration with one name", ctx do
      main_adds!(ctx, %{"priv/repo/migrations/20260102000000_add_x.exs" => ""})
      push_head!(ctx, %{"priv/repo/migrations/20260103000000_add_x.exs" => ""})

      {out, code} = run(ctx, ["--dry-run", "7"])

      assert code == 1, out
      assert out =~ "share the migration name add_x on the merged tree"
      assert out =~ "Fix: rename the one origin/main lacks, and its module"
    end

    test "stops on a file of another form, naming it", ctx do
      for path <- [
            "priv/repo/migrations/sub/20260102000000_nested.exs",
            "priv/repo/migrations/20260102000000_compiled.ex",
            "priv/repo/migrations/2026010200000_short.exs",
            "priv/repo/migrations/202601020000000_long.exs",
            "priv/repo/migrations/20260102000000_backup.exs.bak",
            "priv/repo/migrations/20260102000000_Upper.exs",
            "priv/repo/migrations/notes.md"
          ] do
        push_head!(ctx, %{path => ""})

        {out, code} = run(ctx, ["--dry-run", "7"])

        assert {path, code} == {path, 1}, out

        assert out =~
                 "#{path} on the merged tree is not priv/repo/migrations/<14 digits>_<name>.exs"
      end
    end

    test "stops when the merged tree holds no migration", ctx do
      push_head!(ctx, %{"priv/repo/migrations/20260101000000_base.exs" => nil})

      {out, code} = run(ctx, ["--dry-run", "7"])

      assert code == 1, out
      assert out =~ "FAIL: no migration under priv/repo/migrations on the merged tree"
    end

    test "stops when git cannot list the merged tree's migrations", ctx do
      exe!(Path.join(ctx.bin, "git"), """
      #!/usr/bin/env bash
      [[ $1 == ls-tree ]] && exit 128
      exec #{System.find_executable("git")} "$@"
      """)

      {out, code} = run(ctx, ["--dry-run", "7"])

      assert code == 1, out
      assert out =~ "FAIL: git cannot list priv/repo/migrations on the merged tree"
    end

    test "a 405 retry checks the migrations again on the new origin/main", ctx do
      push_head!(ctx, %{"priv/repo/migrations/20260102000000_from_pr.exs" => ""})
      File.write!(Path.join(ctx.stub, "posts"), "405\n200\n")

      File.write!(Path.join(ctx.stub, "move"), """
      cd '#{ctx.work}'
      mkdir -p priv/repo/migrations
      : > priv/repo/migrations/20260102000000_from_main.exs
      git add -A
      git -c user.name=f -c user.email=f@example.invalid commit -q -m 'main takes the version'
      git push -q origin main
      """)

      {out, code} = run(ctx, ["7"])

      assert code == 1, out
      assert out =~ "migrations: 2, no version or name twice"
      assert out =~ "share the migration version 20260102000000 on the merged tree"
      assert posts(ctx) == 1
    end
  end

  describe "a skipped container job (#1486)" do
    @gate_ci """
    name: CI
    jobs:
      test:
        runs-on: x
      image-inputs:
        runs-on: x
      container:
        needs: image-inputs
        runs-on: x
    """

    @gate_files %{".forgejo/workflows/ci.yml" => @gate_ci, "image-inputs.txt" => "# x\nlib\n"}

    test "passes when the head changes no listed path against origin/main", ctx do
      gate_head!(ctx, %{})
      statuses!(ctx, %{"container" => "skipped"})

      {out, code} = run(ctx, ["--dry-run", "7"])

      assert code == 0, out
      assert out =~ "CI / container (pull_request): skipped\n"
      assert out =~ "container: skipped, and the head changes no path of image-inputs.txt since "
    end

    test "stops when the head changes a listed path against origin/main", ctx do
      gate_head!(ctx, %{"lib/a.ex" => "a\n"})
      statuses!(ctx, %{"container" => "skipped"})

      {out, code} = run(ctx, ["--dry-run", "7"])

      assert code == 1, out
      assert out =~ "it changes these paths of image-inputs.txt: lib/a.ex"
      assert out =~ "Merge origin/main into the branch and push"
    end

    test "stops on a skipped job other than container", ctx do
      for job <- ["test", "image-inputs"] do
        gate_head!(ctx, %{})
        statuses!(ctx, %{job => "skipped"})

        {out, code} = run(ctx, ["--dry-run", "7"])

        assert {job, code} == {job, 1}, out
        assert out =~ "CI / #{job} (pull_request): skipped; only the container job may skip"
      end
    end

    test "stops when the head has no image-inputs job, no list, or a list it cannot read", ctx do
      for {files, message} <- [
            {%{
               ".forgejo/workflows/ci.yml" =>
                 String.replace(@gate_ci, "  image-inputs:\n    runs-on: x\n", "")
             }, "but its ci.yml has no image-inputs job"},
            {%{"image-inputs.txt" => nil}, "which holds no image-inputs.txt"},
            {%{"image-inputs.txt" => "lib\nlib/\n"}, "image-inputs.txt:2 at "},
            {%{"image-inputs.txt" => "lib\n../x\n"}, "image-inputs.txt:2 at "},
            {%{"image-inputs.txt" => "# none\n"}, "holds no path"}
          ] do
        gate_head!(ctx, files)
        statuses!(ctx, %{"container" => "skipped"})

        {out, code} = run(ctx, ["--dry-run", "7"])

        assert {message, code} == {message, 1}, out
        assert out =~ message
      end
    end

    test "a 405 retry checks the skip again against the origin/main it read", ctx do
      # The head adds lib/a.ex, then removes it: against the first origin/main it changes no
      # listed path. main then takes the adding commit, so against the new merge base the head
      # deletes lib/a.ex.
      gate_head!(ctx, %{"lib/a.ex" => "a\n"})
      adding = git!(ctx.work, ["rev-parse", "pr"])
      git!(ctx.work, ["checkout", "-q", "pr"])
      git!(ctx.work, ["rm", "-q", "lib/a.ex"])
      commit!(ctx.work, "drop a")
      head = git!(ctx.work, ["rev-parse", "HEAD"])
      git!(ctx.work, ["push", "-q", "-f", "origin", "HEAD:refs/pull/7/head"])
      File.write!(Path.join(ctx.stub, "head"), head)
      git!(ctx.work, ["checkout", "-q", "main"])
      statuses!(ctx, %{"container" => "skipped"})
      File.write!(Path.join(ctx.stub, "posts"), "405\n200\n")

      File.write!(Path.join(ctx.stub, "move"), """
      cd '#{ctx.work}'
      git -c user.name=f -c user.email=f@example.invalid merge -q --no-edit #{adding}
      git push -q origin main
      """)

      {out, code} = run(ctx, ["--body-from=#{adding}", "7"])

      assert code == 1, out
      assert out =~ "container: skipped, and the head changes no path of image-inputs.txt since "
      assert out =~ "it changes these paths of image-inputs.txt: lib/a.ex"
      assert posts(ctx) == 1
    end

    test "checks the skip against the origin/main the merge-tree check read", ctx do
      # Another thread's fetch moves origin/main to a commit that holds the head's adding commit
      # right after the merge-tree check: against that origin/main the head deletes lib/a.ex.
      gate_head!(ctx, %{"lib/a.ex" => "a\n"})
      adding = git!(ctx.work, ["rev-parse", "pr"])
      git!(ctx.work, ["checkout", "-q", "pr"])
      git!(ctx.work, ["rm", "-q", "lib/a.ex"])
      commit!(ctx.work, "drop a")
      head = git!(ctx.work, ["rev-parse", "HEAD"])
      git!(ctx.work, ["push", "-q", "-f", "origin", "HEAD:refs/pull/7/head"])
      File.write!(Path.join(ctx.stub, "head"), head)
      git!(ctx.work, ["checkout", "-q", "main"])
      statuses!(ctx, %{"container" => "skipped"})

      exe!(Path.join(ctx.bin, "git"), """
      #!/usr/bin/env bash
      real=#{System.find_executable("git")}
      if [[ $1 == merge-tree ]]; then
        "$real" "$@"
        code=$?
        "$real" update-ref refs/remotes/origin/main #{adding}
        exit "$code"
      fi
      exec "$real" "$@"
      """)

      {out, code} = run(ctx, ["--dry-run", "--body-from=#{adding}", "7"])

      assert code == 0, out
      assert out =~ "container: skipped, and the head changes no path of image-inputs.txt since "
      assert git!(ctx.work, ["rev-parse", "origin/main"]) == adding
    end

    test "reads a last list line with no newline", ctx do
      gate_head!(ctx, %{"image-inputs.txt" => "b.txt", "lib/a.ex" => nil})
      statuses!(ctx, %{"container" => "skipped"})

      {out, code} = run(ctx, ["--dry-run", "7"])

      assert code == 1, out
      assert out =~ "it changes these paths of image-inputs.txt: b.txt"
    end
  end

  # Rewrites the PR's one commit with the gate files and `files` laid over its tree, pushes it as
  # the PR head and returns its SHA.
  defp gate_head!(ctx, files), do: push_head!(ctx, Map.merge(@gate_files, files))

  # Rewrites the PR's one commit with `files` laid over its tree (nil deletes a file), pushes it
  # as the PR head and returns its SHA.
  defp push_head!(ctx, files) do
    git!(ctx.work, ["checkout", "-q", "pr"])
    git!(ctx.work, ["reset", "-q", "--hard", ctx.head])
    write!(ctx.work, files)
    git!(ctx.work, ["add", "-A"])
    git!(ctx.work, ["commit", "-q", "--amend", "--no-edit"])
    head = git!(ctx.work, ["rev-parse", "HEAD"])
    git!(ctx.work, ["push", "-q", "-f", "origin", "HEAD:refs/pull/7/head"])
    File.write!(Path.join(ctx.stub, "head"), head)
    git!(ctx.work, ["checkout", "-q", "main"])
    head
  end

  # Commits `files` on main and pushes it to origin.
  defp main_adds!(ctx, files) do
    write!(ctx.work, files)
    commit!(ctx.work, "main adds")
    git!(ctx.work, ["push", "-q", "origin", "main"])
  end

  # Serves the three jobs' statuses, each success unless `overrides` names it.
  defp statuses!(ctx, overrides) do
    statuses =
      for job <- ["test", "image-inputs", "container"],
          do: %{context: "CI / #{job} (pull_request)", status: Map.get(overrides, job, "success")}

    File.write!(
      Path.join(ctx.stub, "status"),
      JSON.encode!(%{state: "success", statuses: statuses})
    )
  end
end
