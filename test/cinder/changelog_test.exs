defmodule Cinder.ChangelogTest do
  use ExUnit.Case, async: true

  alias Cinder.Changelog

  @note Changelog.note()

  defp changelog(unreleased_body) do
    """
    # Changelog

    Intro.

    ## [Unreleased]

    #{unreleased_body}

    ## [1.1.0] - 2026-08-01

    ### Fixed
    - Old fix.

    [Unreleased]: https://example.test/cinder/compare/v1.1.0...HEAD
    [1.1.0]: https://example.test/cinder/compare/v1.0.0...v1.1.0
    """
  end

  describe "fold/4" do
    test "turns a fragment into a dated section and moves the compare links" do
      fragment = """
      ### Fixed
      - **A fix (#843).** It works now.
      """

      assert Changelog.fold(changelog(@note), [{"843-fix.md", fragment}], "1.2.0", ~D[2026-10-21]) ==
               {:ok,
                """
                # Changelog

                Intro.

                ## [Unreleased]

                #{@note}

                ## [1.2.0] - 2026-10-21

                ### Fixed
                - **A fix (#843).** It works now.

                ## [1.1.0] - 2026-08-01

                ### Fixed
                - Old fix.

                [Unreleased]: https://example.test/cinder/compare/v1.2.0...HEAD
                [1.2.0]: https://example.test/cinder/compare/v1.1.0...v1.2.0
                [1.1.0]: https://example.test/cinder/compare/v1.0.0...v1.1.0
                """}
    end

    test "merges the legacy entries and the fragments under one heading each, in Keep a Changelog order" do
      legacy = """
      #{@note}

      ### Fixed
      - Legacy fix one.

      ### Added
      - Legacy feature. It has a list:
        - first item

        A paragraph after a blank line, inside the same entry.

      ### Fixed
      - Legacy fix two.
      """

      fragments = [
        {"900-b.md", "### Security\n- Fragment B security.\n\n### Fixed\n- Fragment B fix.\n"},
        {"850-a.md", "\n### Fixed\n- Fragment A fix.\n  Wrapped line.\n"}
      ]

      assert {:ok, folded} = Changelog.fold(changelog(legacy), fragments, "1.2.0", ~D[2026-10-21])

      assert section(folded, "1.2.0") == """
             ## [1.2.0] - 2026-10-21

             ### Added
             - Legacy feature. It has a list:
               - first item

               A paragraph after a blank line, inside the same entry.

             ### Fixed
             - Legacy fix one.
             - Legacy fix two.
             - Fragment A fix.
               Wrapped line.
             - Fragment B fix.

             ### Security
             - Fragment B security.

             """

      assert folded =~ "## [Unreleased]\n\n#{@note}\n\n## [1.2.0] - 2026-10-21\n"
      # What the guard in code_health_test.exs reads back after a release.
      assert Changelog.unreleased(folded) == @note
    end

    test "reports every malformed fragment and legacy line by file and line" do
      legacy =
        "#{@note}\n\n### Fixed\n- Fine.\n\n### Improved\n- Not a Keep a Changelog heading.\n"

      fragments = [
        {"1-prose.md", "Some prose first.\n\n### Fixed\n- Fix.\n"},
        {"2-heading.md", "### Fixed\n- Fix.\n\n## [9.9.9]\n#### Detail\n"},
        {"3-empty.md", "\n\n"},
        {"4-bare.md", "### Added\n\n### Fixed\n- Fix.\n"},
        {"5-blank.md", "### Fixed\n   \n"},
        {"6-typo.md", "### Added\n- A.\n###Fixed\n- B.\n##[9.9.9]\n"}
      ]

      assert Changelog.fold(changelog(legacy), fragments, "1.2.0", ~D[2026-10-21]) ==
               {:error,
                [
                  "CHANGELOG.md:13: \"### Improved\" is not one of ### Added, Changed, " <>
                    "Deprecated, Removed, Fixed, Security, Internal",
                  "1-prose.md:1: text before the first ### heading",
                  "2-heading.md:4: \"## [9.9.9]\" is not one of ### Added, Changed, " <>
                    "Deprecated, Removed, Fixed, Security, Internal",
                  "2-heading.md:5: \"#### Detail\" is not one of ### Added, Changed, " <>
                    "Deprecated, Removed, Fixed, Security, Internal",
                  "3-empty.md: no ### heading with entries",
                  "4-bare.md:1: ### Added has no entries",
                  "5-blank.md:1: ### Fixed has no entries",
                  "6-typo.md:3: \"###Fixed\" is not one of ### Added, Changed, Deprecated, " <>
                    "Removed, Fixed, Security, Internal",
                  "6-typo.md:5: \"##[9.9.9]\" is not one of ### Added, Changed, Deprecated, " <>
                    "Removed, Fixed, Security, Internal"
                ]}
    end

    test "folds fragments in issue-number order, not text order" do
      fragments = [{"1000-a.md", "### Fixed\n- A1000.\n"}, {"999-b.md", "### Fixed\n- B999.\n"}]

      assert {:ok, folded} = Changelog.fold(changelog(@note), fragments, "1.2.0", ~D[2026-10-21])

      assert section(folded, "1.2.0") ==
               "## [1.2.0] - 2026-10-21\n\n### Fixed\n- B999.\n- A1000.\n\n"
    end

    test "keeps a column-0 line that starts with # but is not a heading" do
      fragment = "### Fixed\n- A fix, wrapped lazily after\n#843 without an indent.\n"

      assert {:ok, folded} =
               Changelog.fold(
                 changelog(@note),
                 [{"843-fix.md", fragment}],
                 "1.2.0",
                 ~D[2026-10-21]
               )

      assert folded =~ "- A fix, wrapped lazily after\n#843 without an indent.\n"
    end

    test "reads a CHANGELOG.md with CRLF line endings" do
      crlf = String.replace(changelog(@note), "\n", "\r\n")

      assert Changelog.unreleased(crlf) == @note

      assert {:ok, folded} =
               Changelog.fold(
                 crlf,
                 [{"843-fix.md", "### Fixed\r\n- Fix.\r\n"}],
                 "1.2.0",
                 ~D[2026-10-21]
               )

      assert section(folded, "1.2.0") == "## [1.2.0] - 2026-10-21\n\n### Fixed\n- Fix.\n\n"
    end

    test "refuses a release heading with no closing bracket" do
      broken =
        String.replace(changelog(@note), "## [1.1.0] - 2026-08-01", "## [1.1.0 - 2026-08-01")

      assert Changelog.fold(
               broken,
               [{"843-fix.md", "### Fixed\n- Fix.\n"}],
               "1.2.0",
               ~D[2026-10-21]
             ) ==
               {:error,
                [
                  "CHANGELOG.md's last release heading \"## [1.1.0 - 2026-08-01\" is not " <>
                    "## [<version>] - <date>"
                ]}
    end

    test "refuses a version that is not newer than the last release" do
      fragments = [{"843-fix.md", "### Fixed\n- Fix.\n"}]

      for version <- ["1.1.0", "1.0.9"] do
        assert Changelog.fold(changelog(@note), fragments, version, ~D[2026-10-21]) ==
                 {:error,
                  [
                    "version #{version} is not newer than 1.1.0, the last release; bump " <>
                      "`version:` in mix.exs first"
                  ]}
      end
    end

    test "refuses a changelog whose [Unreleased] link does not start at the last release" do
      stale = String.replace(changelog(@note), "compare/v1.1.0...HEAD", "compare/v1.0.0...HEAD")

      assert Changelog.fold(
               stale,
               [{"843-fix.md", "### Fixed\n- Fix.\n"}],
               "1.2.0",
               ~D[2026-10-21]
             ) ==
               {:error,
                [
                  "CHANGELOG.md's [Unreleased] link compares from v1.0.0, but the last " <>
                    "release heading is [1.1.0]"
                ]}
    end

    test "refuses a release with no entries" do
      assert Changelog.fold(changelog(@note), [], "1.2.0", ~D[2026-10-21]) ==
               {:error, ["nothing to release: [Unreleased] and changelog.d/ hold no entries"]}
    end
  end

  describe "release/3" do
    @describetag :tmp_dir

    setup %{tmp_dir: root} do
      File.mkdir_p!(Path.join(root, "changelog.d"))
      File.write!(Path.join(root, "CHANGELOG.md"), changelog(@note))
      File.write!(Path.join(root, "changelog.d/README.md"), "# Changelog fragments\n")
      :ok
    end

    test "writes the release into CHANGELOG.md and deletes the folded fragments", %{tmp_dir: root} do
      File.write!(Path.join(root, "changelog.d/843-fix.md"), "### Fixed\n- **A fix (#843).**\n")
      File.write!(Path.join(root, "changelog.d/850-feature.md"), "### Added\n- A feature.\n")

      assert Changelog.release(root, "1.2.0", ~D[2026-10-21]) ==
               {:ok, ["changelog.d/843-fix.md", "changelog.d/850-feature.md"]}

      changelog = File.read!(Path.join(root, "CHANGELOG.md"))

      assert section(changelog, "1.2.0") ==
               "## [1.2.0] - 2026-10-21\n\n### Added\n- A feature.\n\n### Fixed\n" <>
                 "- **A fix (#843).**\n\n"

      assert File.ls!(Path.join(root, "changelog.d")) == ["README.md"]
    end

    test "changes nothing when changelog.d/ holds a file that is not a fragment", %{tmp_dir: root} do
      File.write!(Path.join(root, "changelog.d/843-fix.md"), "### Fixed\n- A fix.\n")
      File.write!(Path.join(root, "changelog.d/.hidden.md"), "### Fixed\n- Hidden.\n")
      File.write!(Path.join(root, "changelog.d/Notes.txt"), "notes\n")
      File.write!(Path.join(root, "changelog.d/fix.thing.md"), "### Fixed\n- No number.\n")
      File.mkdir_p!(Path.join(root, "changelog.d/drafts"))

      strays = [".hidden.md", "Notes.txt", "drafts", "fix.thing.md"]

      assert Changelog.release(root, "1.2.0", ~D[2026-10-21]) ==
               {:error, Enum.map(strays, &stray/1)}

      assert File.read!(Path.join(root, "CHANGELOG.md")) == changelog(@note)

      assert Enum.sort(File.ls!(Path.join(root, "changelog.d"))) ==
               Enum.sort(["843-fix.md", "README.md" | strays])
    end
  end

  describe "check/1" do
    @describetag :tmp_dir

    test "lists the problems a release would hit, without needing a fragment", %{tmp_dir: root} do
      File.mkdir_p!(Path.join(root, "changelog.d"))
      File.write!(Path.join(root, "CHANGELOG.md"), changelog(@note))
      assert Changelog.check(root) == []

      File.write!(Path.join(root, "changelog.d/843-fix.md"), "Fixed a bug.\n")
      File.write!(Path.join(root, "changelog.d/notes.txt"), "notes\n")

      assert Changelog.check(root) == [
               stray("notes.txt"),
               "changelog.d/843-fix.md:1: text before the first ### heading"
             ]
    end

    test "reports a changelog.d that cannot be listed", %{tmp_dir: root} do
      File.write!(Path.join(root, "CHANGELOG.md"), changelog(@note))
      File.write!(Path.join(root, "changelog.d"), "a file, not a folder\n")

      assert Changelog.check(root) == ["changelog.d/: cannot be listed (not a directory)"]
    end
  end

  defp stray(name) do
    "changelog.d/#{name}: not a fragment; name it <number>-<slug>.md: the issue or PR " <>
      "number, then lowercase letters, digits, - and _"
  end

  # The text from `## [version]` up to the next `## [` heading.
  defp section(changelog, version) do
    [_, from] = String.split(changelog, "## [#{version}]", parts: 2)
    [body | _] = String.split(from, ~r/^## \[/m, parts: 2)
    "## [#{version}]" <> body
  end
end
