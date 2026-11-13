defmodule Cinder.CodeHealth.TrivyignoreEntriesTest do
  # The `container` job's Trivy step passes each ID that `.trivyignore` lists (#1246). ci.md
  # "Venv advisory" asks for one CVE per entry, under comment lines of its own that say why the
  # scan may pass it and what removes the entry. A bare ID passes the scan just as well, and only
  # a reviewer would see it. trivy-action copies the file into its own ignore file, which Trivy
  # 0.70.0's `parseIgnore` (pkg/result/ignore.go) reads line by line: it trims each line, skips
  # a blank one or one that starts with `#`, and takes any other line as an entry. This fence
  # reads each line the same way. It fails an entry that is not a bare `CVE-` or `GHSA-` ID (an
  # `exp:` date, a second field, another ID form such as `PYSEC-`), an entry whose line above is
  # not a comment, and an entry whose comment lines run on from the file's opening header with
  # no blank line between, since those lines read as the header. To accept another ID form, add
  # it to `@id` with a fixture. Forms the fence does not check include: what the comment lines
  # say.
  use ExUnit.Case, async: true

  @path ".trivyignore"
  @id ~r/\A(CVE-\d{4}-\d{4,}|GHSA(-[23456789cfghjmpqrvwx]{4}){3})\z/

  test ".trivyignore gives each ID comment lines of its own" do
    problems = @path |> File.read!() |> problems()

    assert problems == [],
           "Fix these #{@path} lines as docs/agents/ci.md \"Venv advisory\" says:\n" <>
             Enum.join(problems, "\n")
  end

  test "an entry under its own comment block passes" do
    assert problems(header() <> "\n# why and when to drop it\nCVE-2022-40899\n") == []

    assert problems(header() <> "\n# one\nCVE-2022-40899\n\n# two\nGHSA-h4gh-qq45-vh27\n") ==
             []
  end

  test "the scan trims each line and skips an ID inside a comment, as Trivy does" do
    assert problems(header() <> "\n  # indented why\n\tCVE-2022-40899  \n") == []
    assert problems("# header\r\n\r\n# why\r\nCVE-2022-40899\r\n") == []
    assert problems(header() <> "\n# CVE-2022-40898 was dropped\n   \n") == []
  end

  test "an ID with no comment line above it fails" do
    assert problems(header() <> "\nCVE-2022-40899\n") ==
             [".trivyignore:4: CVE-2022-40899 has no comment line right above it"]

    assert problems("CVE-2022-40899\n") ==
             [".trivyignore:1: CVE-2022-40899 has no comment line right above it"]
  end

  test "a second ID under the same comment block fails" do
    assert problems(header() <> "\n# why\nCVE-2022-40899\nCVE-2022-40898\n") ==
             [".trivyignore:6: CVE-2022-40898 has no comment line right above it"]
  end

  test "an ID whose comment lines run on from the file's opening header fails" do
    for {text, number} <- [
          {header() <> "CVE-2022-40899\n", 3},
          {header() <> "# why and when to drop it\nCVE-2022-40899\n", 4}
        ] do
      assert problems(text) == [
               ".trivyignore:#{number}: CVE-2022-40899 sits right under the file's header; " <>
                 "give it comment lines of its own, with a blank line between them and the header"
             ]
    end
  end

  test "a line that is not a bare CVE or GHSA ID fails" do
    for line <- [
          "CVE-2022-40899 exp:2027-01-01",
          "CVE-2022-40899 CVE-2022-40898",
          "CVE-2022-40899 # why",
          "X-CVE-2022-40899",
          "future",
          "CVE-2022-123",
          "GHSA-aaaa-bbbb-cccc",
          "PYSEC-2022-42"
        ] do
      assert problems(header() <> "\n# why\n" <> line <> "\n") ==
               [".trivyignore:5: #{inspect(line)} is not a bare CVE or GHSA ID"]
    end
  end

  defp header, do: "# header line one\n# header line two\n"

  # Numbers the trimmed lines from 1, takes the opening run of comment lines as the header, and
  # checks each line that is neither blank nor a comment against the line above it.
  defp problems(text) do
    lines = text |> String.split("\n") |> Enum.map(&String.trim/1)
    header_end = lines |> Enum.take_while(&comment?/1) |> length()

    for {{line, above}, number} <- lines |> Enum.zip(["" | lines]) |> Enum.with_index(1),
        line != "" and not comment?(line),
        problem <- problem(line, above, number, header_end),
        do: "#{@path}:#{number}: #{problem}"
  end

  defp problem(line, above, number, header_end) do
    cond do
      not Regex.match?(@id, line) ->
        ["#{inspect(line)} is not a bare CVE or GHSA ID"]

      not comment?(above) ->
        ["#{line} has no comment line right above it"]

      number - 1 == header_end ->
        [
          "#{line} sits right under the file's header; give it comment lines of its own, " <>
            "with a blank line between them and the header"
        ]

      true ->
        []
    end
  end

  defp comment?(line), do: String.starts_with?(line, "#")
end
