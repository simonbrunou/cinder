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
      body='{"state":"success","statuses":[{"context":"CI / test (pull_request)","status":"success"}]}'
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

  defp write!(repo, files) do
    for {path, body} <- files do
      full = Path.join(repo, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, body)
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
end
