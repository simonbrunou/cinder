defmodule Cinder.BoundedCommandLookupTest do
  # `Cinder.BoundedCommand.find_executable/1` resolves a command the way `System.find_executable/1`
  # does, without the VM's one file server (#1146). Each row sets `PATH`, which is global to the
  # VM, so the module is not async.
  use ExUnit.Case, async: false

  import Cinder.BoundedWalkHelpers

  alias Cinder.BoundedCommand

  @moduletag :tmp_dir

  # A call meant to finish gets a deadline a loaded CI runner cannot miss (docs/agents/testing.md).
  @answer_ms 10_000

  setup do
    path = System.get_env("PATH")

    on_exit(fn ->
      if path, do: System.put_env("PATH", path), else: System.delete_env("PATH")
    end)
  end

  test "find_executable/1 resolves what System.find_executable/1 resolves on each PATH shape",
       %{tmp_dir: tmp} do
    first = dir!(tmp, "first")
    second = dir!(tmp, "second")
    tool = executable!(second, "tool")
    executable!(second, "sub/tool")
    plain!(first, "tool")
    File.mkdir_p!(Path.join(first, "shadow"))
    executable!(second, "shadow")
    File.ln_s!(tool, Path.join(first, "linked"))
    File.ln_s!(Path.join(tmp, "missing"), Path.join(first, "broken"))
    plain = plain!(tmp, "plain")
    # The suite runs from the repo root, where an empty PATH element looks, as `.`.
    cwd_script = "scripts/seed-worktree"
    in_cwd = "./" <> cwd_script

    rows = [
      {"on PATH", "tool", "#{first}:#{second}", Path.join(second, "tool")},
      {"missing", "absent", "#{first}:#{second}", nil},
      {"absolute executable", tool, "", tool},
      {"absolute file without an exec bit", plain, "#{first}", nil},
      {"absolute directory", first, "#{first}", nil},
      {"absolute missing", Path.join(tmp, "missing"), "#{second}", nil},
      {"a directory named like the program, earlier on PATH", "shadow", "#{first}:#{second}",
       Path.join(second, "shadow")},
      {"a symlink to an executable", "linked", "#{first}", Path.join(first, "linked")},
      {"a broken symlink", "broken", "#{first}:#{second}", nil},
      {"a name with a slash", "sub/tool", "#{second}", Path.join(second, "sub/tool")},
      {"a quoted PATH element", "tool", ~s("#{second}"), Path.join(second, "tool")},
      {"an empty PATH", cwd_script, "", in_cwd},
      {"an empty PATH element", cwd_script, "#{first}::#{second}", in_cwd},
      {"a trailing colon", cwd_script, "#{first}:", in_cwd},
      # `:filename.join/2` puts an empty base at the root.
      {"a PATH element of two double quotes", "bin/sh", ~s(""), "/bin/sh"},
      {"a PATH entry that is a file", "tool", "#{plain}:#{second}", Path.join(second, "tool")}
    ]

    for {label, name, path, expected} <- rows do
      System.put_env("PATH", path)
      assert System.find_executable(name) == expected, "#{label}: the oracle row is wrong"
      assert BoundedCommand.find_executable(name) == expected, label
    end

    System.delete_env("PATH")
    assert BoundedCommand.find_executable(cwd_script) == System.find_executable(cwd_script)
    assert BoundedCommand.find_executable("tool") == nil

    assert_raise ArgumentError, fn -> BoundedCommand.find_executable("to\0ol") end
  end

  test "find_executable/1 and run/4 answer while the VM file server is blocked",
       %{tmp_dir: tmp} do
    tool = executable!(dir!(tmp, "bin"), "tool", "printf ran")
    System.put_env("PATH", Path.dirname(tool))

    lookups = fn ->
      {BoundedCommand.find_executable("tool"), BoundedCommand.run("tool", [], @answer_ms),
       BoundedCommand.run("absent", [], @answer_ms)}
    end

    expected = {tool, {:ok, "ran", 0}, {:error, %ErlangError{original: :enoent}}}

    assert lookups.() == expected
    assert yield_while_file_server_blocked(lookups, @answer_ms) == {:ok, expected}
  end

  defp dir!(parent, name) do
    dir = Path.join(parent, name)
    File.mkdir_p!(dir)
    dir
  end

  defp executable!(dir, name, body \\ "exit 0") do
    path = Path.join(dir, name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "#!/bin/sh\n#{body}\n")
    File.chmod!(path, 0o755)
    path
  end

  defp plain!(dir, name) do
    path = Path.join(dir, name)
    File.write!(path, "not a program\n")
    File.chmod!(path, 0o644)
    path
  end
end
