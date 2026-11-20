defmodule CinderWeb.JsHooksTest do
  # Runs the Node tests of the LiveView hooks under test/js (`node --test`). LiveViewTest runs no
  # JavaScript, so a hook's handling of a failed push, a rejoin or a closed dialog shows only
  # here or in a real browser. On #1568 each of those bugs reached a review round before a probe
  # caught it. node comes from the flake's dev shell, and CI's act-26.04 image has it on PATH.
  use ExUnit.Case, async: true

  @tests Path.wildcard("test/js/*_test.mjs")

  test "test/js holds the hook tests this file runs" do
    assert "test/js/passkeys_test.mjs" in @tests
  end

  for file <- @tests do
    @file_path file
    test "node --test #{file}" do
      node =
        System.find_executable("node") ||
          flunk("no node on PATH: run `mix test` in the flake's dev shell (`nix develop`)")

      {output, status} =
        System.cmd(node, ["--test", "--test-timeout=5000", @file_path], stderr_to_stdout: true)

      assert status == 0, output
    end
  end
end
