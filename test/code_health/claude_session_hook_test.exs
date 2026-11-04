defmodule Cinder.CodeHealth.ClaudeSessionHookTest do
  # #1134: a SessionStart hook tells each Claude Code session whether the flake dev shell is
  # active. It used to live in sbrn's home directory, wired by an ignored settings.local.json, so
  # fixes to it skipped review. The tracked .claude/settings.json now runs the tracked
  # .claude/hooks/nix-devshell.sh through $CLAUDE_PROJECT_DIR, so every checkout and worktree runs
  # the committed copy. The hook tests run the settings command itself under a PATH the test
  # builds, so they hold on CI and on a dev host, inside `nix develop` or outside it.
  use ExUnit.Case, async: true

  @settings ".claude/settings.json"
  @hook ".claude/hooks/nix-devshell.sh"
  @ci ".forgejo/workflows/ci.yml"
  @nix "/nix/var/nix/profiles/default/bin/nix"

  # The one command form a hook may take: bash on a repo path through the project dir. A path
  # holding a quote, a space, `$`, a backtick or a backslash, or anything after the closing
  # quote, is another form, so the test fails on it rather than reading part of it.
  @command_form ~r/\Abash "\$CLAUDE_PROJECT_DIR\/([^"\s$`\\]+)"\z/

  # BeamVersionPinsTest's matcher for an erlef/setup-beam step.
  @setup_beam ~r{(?:\A|/)setup-beam@}i

  # The tools the hook runs besides `elixir`, which each test provides or leaves out.
  @tools ~w(bash grep head sed tr)

  test "settings.json runs the tracked hook on every SessionStart through $CLAUDE_PROJECT_DIR" do
    assert [%{"matcher" => "*", "hooks" => [%{"type" => "command", "command" => command}]}] =
             settings()["hooks"]["SessionStart"]

    assert script_path(command) == {:ok, @hook}
  end

  test "every hook command runs a tracked script through $CLAUDE_PROJECT_DIR" do
    # A failed match raises before `assert` reads its message, so each check asserts a boolean.
    for {event, command} <- hook_commands() do
      result = script_path(command)

      assert match?({:ok, _}, result),
             "#{event} hook #{inspect(command)} is not " <>
               ~s(bash "$CLAUDE_PROJECT_DIR/<path>", the one form this test reads, so it ) <>
               "cannot check that the hook runs a tracked script"

      {:ok, path} = result

      assert git_status(["ls-files", "--error-unmatch", "--", path]) == 0,
             "#{event} hook runs #{path}, which git does not track"
    end
  end

  test "the command form takes only bash on one project-dir path" do
    assert script_path(~s(bash "$CLAUDE_PROJECT_DIR/.claude/hooks/x.sh")) ==
             {:ok, ".claude/hooks/x.sh"}

    for command <- [
          "/home/sbrn/.claude/hooks/x.sh",
          ~s("$CLAUDE_PROJECT_DIR/.claude/hooks/x.sh"),
          ~s(bash "$CLAUDE_PROJECT_DIR"/.claude/hooks/x.sh),
          ~s(bash "$CLAUDE_PROJECT_DIR/.claude/hooks/x.sh" && /home/sbrn/y.sh),
          ~s(bash "$CLAUDE_PROJECT_DIR/.claude/hooks/x.sh"\n/home/sbrn/y.sh),
          ~s|bash "$CLAUDE_PROJECT_DIR/.claude/hooks/$(id).sh"|,
          ~s(bash "$CLAUDE_PROJECT_DIR/.claude/hooks/x.sh" "$HOME/y.sh"),
          ~s(bash "$CLAUDE_PROJECT_DIR/../x.sh\\")
        ] do
      assert script_path(command) == :error, "read #{inspect(command)} as a project-dir path"
    end
  end

  test "git tracks the settings and the hook, and still ignores settings.local.json" do
    {listed, 0} = git(["ls-files", "--", ".claude"])
    tracked = String.split(listed, "\n", trim: true)

    assert @settings in tracked
    assert @hook in tracked

    # `--no-index` reads the rules even for a tracked path. Exit 1 means not ignored, so a new
    # script under .claude/hooks is added without `git add -f`.
    for path <- [@settings, @hook, ".claude/hooks/another.sh"] do
      status = git_status(["check-ignore", "--no-index", "-q", "--", path])

      assert status == 1,
             "git check-ignore exited #{status} on #{path}, where 0 means ignored; .gitignore " <>
               "needs a negation for it"
    end

    assert git_status(["check-ignore", "--no-index", "-q", "--", ".claude/settings.local.json"]) ==
             0
  end

  describe "the hook's message" do
    @describetag :tmp_dir

    test "with no elixir on PATH, it says the dev shell is not active", %{tmp_dir: tmp_dir} do
      assert run_hook!(bin_dir(tmp_dir, nil)) ==
               "Cinder flake dev shell NOT active, and elixir is not on PATH. Run every repo " <>
                 "command as 'nix develop #{File.cwd!()} -c <cmd>' (git commit and git push " <>
                 "included). nix is at #{@nix}."
    end

    test "inside a dev shell with the Elixir ci.yml pins, it says the shell is active",
         %{tmp_dir: tmp_dir} do
      bin = bin_dir(tmp_dir, ci_elixir_pin())

      assert run_hook!(bin, in_nix_shell: "impure") ==
               "Cinder flake dev shell active: Elixir #{ci_elixir_pin()} (compiled with " <>
                 "Erlang/OTP 29) at #{bin}/elixir, the Elixir CI pins; mix/elixir are usable " <>
                 "directly."
    end

    test "the pinned Elixir outside a dev shell is not active", %{tmp_dir: tmp_dir} do
      context = run_hook!(bin_dir(tmp_dir, ci_elixir_pin()))

      assert context =~ ~r/\ACinder flake dev shell NOT active\. Bare elixir is Elixir /
      assert context =~ "CI pins Elixir #{ci_elixir_pin()}. "
    end

    # Another flake's dev shell sets IN_NIX_SHELL too, and home-manager puts its own Elixir on
    # PATH (cinder#983, cinder#1092).
    test "a dev shell with another Elixir is not active", %{tmp_dir: tmp_dir} do
      context = run_hook!(bin_dir(tmp_dir, "1.0.0"), in_nix_shell: "impure")

      assert context =~
               "NOT active. Bare elixir is Elixir 1.0.0 (compiled with Erlang/OTP 29) at " <>
                 "#{tmp_dir}/bin/elixir; CI pins Elixir #{ci_elixir_pin()}. "
    end

    # The project dir lands in the message. A quote and a backslash in it must reach the JSON
    # escaped, and a control character is dropped. This dir has no ci.yml, so the message says
    # it found no pin.
    test "a project dir with a quote, a backslash and a tab still gives valid JSON",
         %{tmp_dir: tmp_dir} do
      project = Path.join(tmp_dir, "a\"b\\c\td")
      File.mkdir_p!(Path.join(project, ".claude/hooks"))
      File.cp!(@hook, Path.join(project, @hook))
      shown = Path.join(tmp_dir, "a\"b\\cd")

      assert run_hook!(bin_dir(tmp_dir, "1.0.0"), project_dir: project) ==
               "Cinder flake dev shell NOT active. Bare elixir is Elixir 1.0.0 (compiled with " <>
                 "Erlang/OTP 29) at #{tmp_dir}/bin/elixir; CI pins Elixir (no quoted " <>
                 "elixir-version in #{shown}/.forgejo/workflows/ci.yml). Run every repo " <>
                 "command as 'nix develop #{shown} -c <cmd>' (git commit and git push included)."
    end

    # The hook adds nix to PATH through CLAUDE_ENV_FILE, appending a line that keeps `$PATH`
    # literal. It skips that when nix is not installed, as on CI, so CI checks the skip and a
    # dev host with nix checks the line.
    test "it appends the nix PATH line to CLAUDE_ENV_FILE when nix is installed",
         %{tmp_dir: tmp_dir} do
      env_file = Path.join(tmp_dir, "claude-env")
      File.write!(env_file, "export KEPT=1\n")

      run_hook!(bin_dir(tmp_dir, nil), env_file: env_file)

      appended =
        if File.regular?(@nix),
          do: ~s(export PATH="#{Path.dirname(@nix)}:$PATH"\n),
          else: ""

      assert File.read!(env_file) == "export KEPT=1\n" <> appended
    end
  end

  defp hook_commands do
    for {event, entries} <- settings()["hooks"],
        entry <- entries,
        %{"command" => command} <- entry["hooks"],
        do: {event, command}
  end

  defp settings, do: @settings |> File.read!() |> Jason.decode!()

  defp script_path(command) do
    case Regex.run(@command_form, command) do
      [_, path] -> {:ok, path}
      nil -> :error
    end
  end

  defp git(args), do: System.cmd("git", args, stderr_to_stdout: true)

  defp git_status(args), do: args |> git() |> elem(1)

  # The elixir-version of every erlef/setup-beam step in ci.yml. BeamVersionPinsTest keeps them
  # equal; the hook reads the first quoted one.
  defp ci_elixir_pin do
    [workflow] = YamlElixir.read_all_from_string!(File.read!(@ci))

    pins =
      for {_, job} <- workflow["jobs"],
          %{"uses" => uses, "with" => with} <- job["steps"] || [],
          uses =~ @setup_beam,
          uniq: true,
          do: with["elixir-version"]

    assert [pin] = pins
    pin
  end

  # A PATH holding only the tools the hook runs, plus a stub `elixir` that prints a real
  # `elixir --version` layout for `version`, or no `elixir` when `version` is nil.
  defp bin_dir(tmp_dir, version) do
    bin = Path.join(tmp_dir, "bin")
    File.mkdir_p!(bin)

    for tool <- @tools do
      File.ln_s!(
        System.find_executable(tool) || flunk("#{tool} is not on PATH"),
        "#{bin}/#{tool}"
      )
    end

    if version do
      File.write!("#{bin}/elixir", """
      #!#{System.find_executable("bash")}
      printf 'Erlang/OTP 29 [erts-16.0]\\n\\nElixir %s (compiled with Erlang/OTP 29)\\n' '#{version}'
      """)

      File.chmod!("#{bin}/elixir", 0o755)
    end

    bin
  end

  # Runs the SessionStart command from settings.json as Claude Code does, through a shell, and
  # returns the additionalContext it prints. Stderr joins stdout, so any stderr line fails the
  # JSON decode. CLAUDE_ENV_FILE is cleared unless the test passes one, so a run inside a Claude
  # session never appends to that session's env file.
  defp run_hook!(bin, opts \\ []) do
    [{"SessionStart", command}] = Enum.filter(hook_commands(), &match?({"SessionStart", _}, &1))

    env = [
      {"PATH", bin},
      {"IN_NIX_SHELL", opts[:in_nix_shell]},
      {"CLAUDE_PROJECT_DIR", Keyword.get(opts, :project_dir, File.cwd!())},
      {"CLAUDE_ENV_FILE", opts[:env_file]}
    ]

    assert {output, 0} = System.cmd("bash", ["-c", command], env: env, stderr_to_stdout: true)

    assert %{
             "hookSpecificOutput" => %{
               "hookEventName" => "SessionStart",
               "additionalContext" => context
             }
           } = Jason.decode!(output)

    context
  end
end
