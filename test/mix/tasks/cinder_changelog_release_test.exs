defmodule Mix.Tasks.Cinder.Changelog.ReleaseTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Cinder.Changelog
  alias Mix.Tasks.Cinder.Changelog.Release

  @moduletag :tmp_dir

  # `run/1` folds the directory it runs in; `run/2` takes that directory, so these tests fold a
  # copy and never the repo itself.
  setup %{tmp_dir: root} do
    File.mkdir_p!(Path.join(root, "changelog.d"))

    File.write!(Path.join(root, "CHANGELOG.md"), """
    # Changelog

    ## [Unreleased]

    #{Changelog.note()}

    ## [0.0.1] - 2026-01-01

    ### Added
    - First.

    [Unreleased]: https://example.test/cinder/compare/v0.0.1...HEAD
    [0.0.1]: https://example.test/cinder/releases/tag/v0.0.1
    """)

    :ok
  end

  test "folds the fragments as the mix.exs version", %{tmp_dir: root} do
    File.write!(Path.join(root, "changelog.d/843-fix.md"), "### Fixed\n- A fix.\n")
    version = Mix.Project.config()[:version]

    output = capture_io(fn -> Release.run(["--date", "2026-10-21"], root) end)

    assert output =~ "CHANGELOG.md: added [#{version}] from 1 fragment(s)."

    assert File.read!(Path.join(root, "CHANGELOG.md")) =~
             "## [#{version}] - 2026-10-21\n\n### Fixed\n- A fix.\n\n## [0.0.1] - 2026-01-01\n"

    assert File.ls!(Path.join(root, "changelog.d")) == []
  end

  test "lists every problem and writes nothing when a fragment is malformed", %{tmp_dir: root} do
    File.write!(Path.join(root, "changelog.d/843-fix.md"), "A fix with no heading.\n")
    before = File.read!(Path.join(root, "CHANGELOG.md"))

    assert_raise Mix.Error,
                 "No release written:\n  changelog.d/843-fix.md:1: text before the first ### heading",
                 fn -> Release.run([], root) end

    assert File.read!(Path.join(root, "CHANGELOG.md")) == before
    assert File.ls!(Path.join(root, "changelog.d")) == ["843-fix.md"]
  end

  test "refuses a date that is not YYYY-MM-DD", %{tmp_dir: root} do
    assert_raise Mix.Error, ~s(--date must be YYYY-MM-DD, got "21/10/2026"), fn ->
      Release.run(["--date", "21/10/2026"], root)
    end
  end

  test "refuses a version argument: the version comes from mix.exs", %{tmp_dir: root} do
    assert_raise Mix.Error, ~r/takes no arguments/, fn -> Release.run(["3.1.0"], root) end
  end
end
