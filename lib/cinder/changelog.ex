defmodule Cinder.Changelog do
  @moduledoc """
  Folds the changelog fragments in `changelog.d/` into a dated section of `CHANGELOG.md` (#843).

  A PR adds one fragment instead of editing `## [Unreleased]`, so two PRs never conflict on the
  changelog. A fragment holds Keep a Changelog `###` headings, each followed by entries. Entry
  text is opaque: only column-0 Markdown headings are read, so nested lists and blank lines
  inside an entry pass through unchanged.

  The struct is a parsed `CHANGELOG.md` plus its fragments: `head` runs up to the
  `## [Unreleased]` heading, `rest` from the last release heading on, `previous` is that
  release's version, `sections` holds every `{heading, line, entries}` in fold order, and
  `problems` every malformed line, as `"<path>:<line>: <problem>"`.
  """

  defstruct head: "", rest: "", previous: nil, sections: [], problems: []

  @headings ~w(Added Changed Deprecated Removed Fixed Security Internal)
  @heading_list "### " <> Enum.join(@headings, ", ")

  @note "Unreleased changes not listed below are in [`changelog.d/`](changelog.d/), one file " <>
          "per change,\nuntil a release folds them into its dated section."

  @unreleased_link ~r/^\[Unreleased\]: (\S+)\/compare\/v(\S+?)\.\.\.HEAD$/m

  @dir "changelog.d"
  @fragment_name ~r/\A\d+-[a-z0-9][a-z0-9_-]*\.md\z/
  @stray "not a fragment; name it <number>-<slug>.md: the issue or PR number, then lowercase " <>
           "letters, digits, - and _"

  @doc "The note that `[Unreleased]` holds once a release has folded everything under it."
  def note, do: @note

  @doc "The text under `## [Unreleased]`, trimmed; `\"\"` when `changelog` has no such heading."
  def unreleased(changelog) do
    case split(changelog) do
      {:ok, _head, body, _rest} -> String.trim(body)
      {:error, _problems} -> ""
    end
  end

  @doc """
  Folds the fragments in `root`'s `changelog.d/` into its `CHANGELOG.md` as `version`, then
  deletes them and returns their paths. Writes and deletes nothing when `fold/4` or the
  fragment listing has a problem. The first fragment that cannot be deleted raises `File.Error`
  after `CHANGELOG.md` is written, leaving it and the fragments after it in place.
  """
  def release(root, version, %Date{} = date) do
    {changelog, fragments, strays} = load(root)

    case {fold(changelog, fragments, version, date), strays} do
      {{:ok, folded}, []} ->
        File.write!(Path.join(root, "CHANGELOG.md"), folded)
        paths = fragments |> Enum.sort_by(&order/1) |> Enum.map(&elem(&1, 0))
        Enum.each(paths, &File.rm!(Path.join(root, &1)))
        {:ok, paths}

      {{:ok, _folded}, strays} ->
        {:error, strays}

      {{:error, problems}, strays} ->
        {:error, strays ++ problems}
    end
  end

  @doc """
  Lists the problems a release of `root` would hit in its `CHANGELOG.md` and `changelog.d/`,
  apart from the version and having nothing to release. `[]` means every fragment folds.
  """
  def check(root) do
    {changelog, fragments, strays} = load(root)

    case read(changelog, fragments) do
      {:ok, %__MODULE__{problems: problems}} -> strays ++ problems
      {:error, problems} -> strays ++ problems
    end
  end

  @doc """
  Returns `changelog` with a `## [version] - date` section built from the entries under
  `[Unreleased]` and from `fragments`, a list of `{path, text}`. Fragments fold in the order of
  the number their file name starts with; problems name them by `path`. The result has LF line
  endings, whatever `changelog` had.

  Returns `{:error, problems}` instead when a fragment or a legacy entry is malformed, when
  `version` is not newer than the last release, or when there is nothing to release.
  """
  def fold(changelog, fragments, version, %Date{} = date) do
    with {:ok, parsed} <- read(changelog, fragments) do
      problems = version_problems(version, parsed.previous) ++ parsed.problems

      cond do
        problems != [] ->
          {:error, problems}

        parsed.sections == [] ->
          {:error, ["nothing to release: [Unreleased] and changelog.d/ hold no entries"]}

        true ->
          {:ok,
           parsed.head <>
             "\n" <>
             @note <>
             "\n\n" <>
             render(version, date, parsed.sections) <> move_links(parsed.rest, version)}
      end
    end
  end

  # `{changelog, fragments, problems}`: `root`'s CHANGELOG.md, every `{path, text}` fragment,
  # and a problem for each other entry in `changelog.d/` except its README.
  defp load(root) do
    dir = Path.join(root, @dir)

    {names, problems} =
      case File.ls(dir) do
        {:ok, names} -> {List.delete(names, "README.md"), []}
        {:error, :enoent} -> {[], []}
        {:error, reason} -> {[], ["#{@dir}/: cannot be listed (#{:file.format_error(reason)})"]}
      end

    {fragments, strays} =
      Enum.split_with(
        names,
        &(Regex.match?(@fragment_name, &1) and File.regular?(Path.join(dir, &1)))
      )

    {File.read!(Path.join(root, "CHANGELOG.md")),
     for(name <- fragments, do: {"#{@dir}/#{name}", File.read!(Path.join(dir, name))}),
     problems ++ for(name <- Enum.sort(strays), do: "#{@dir}/#{name}: #{@stray}")}
  end

  defp read(changelog, fragments) do
    with {:ok, head, body, rest} <- split(changelog),
         {:ok, previous} <- last_release(rest) do
      # The body starts on the line after the `## [Unreleased]` heading.
      body_line = head |> String.split("\n") |> length()

      {sections, problems} =
        [
          parse_legacy(body, body_line)
          | for({path, text} <- Enum.sort_by(fragments, &order/1), do: parse_fragment(path, text))
        ]
        |> Enum.unzip()

      {:ok,
       %__MODULE__{
         head: head,
         rest: rest,
         previous: previous,
         sections: List.flatten(sections),
         problems: List.flatten(problems)
       }}
    end
  end

  # Issue order: `999-b.md` before `1000-a.md`.
  defp order({path, _text}) do
    name = Path.basename(path)

    case Integer.parse(name) do
      {number, _rest} -> {0, number, name}
      :error -> {1, 0, name}
    end
  end

  # Splits at the `## [Unreleased]` heading and the released section below it. The body between
  # them holds the note and the entries written there before fragments existed.
  defp split(changelog) do
    changelog = String.replace(changelog, "\r\n", "\n")

    with [head, after_heading] <- String.split(changelog, "## [Unreleased]\n", parts: 2),
         [body, rest] <- String.split(after_heading, ~r/^(?=## \[)/m, parts: 2) do
      {:ok, head <> "## [Unreleased]\n", body, rest}
    else
      _ -> {:error, ["CHANGELOG.md has no `## [Unreleased]` heading above a released version"]}
    end
  end

  # The version the `[Unreleased]` compare link starts from, which must be the release heading
  # `rest` starts with.
  defp last_release(rest) do
    link = Regex.run(@unreleased_link, rest, capture: :all_but_first)
    heading = Regex.run(~r/\A## \[([^\]\n]+)\]/, rest, capture: :all_but_first)

    case {link, heading} do
      {nil, _heading} ->
        {:error, ["CHANGELOG.md has no `[Unreleased]: <url>/compare/v<version>...HEAD` link"]}

      {_link, nil} ->
        [line | _] = String.split(rest, "\n", parts: 2)

        {:error,
         [
           "CHANGELOG.md's last release heading #{inspect(line)} is not " <>
             "## [<version>] - <date>"
         ]}

      {[_base, previous], [previous]} ->
        {:ok, previous}

      {[_base, previous], [heading]} ->
        {:error,
         [
           "CHANGELOG.md's [Unreleased] link compares from v#{previous}, but the last release " <>
             "heading is [#{heading}]"
         ]}
    end
  end

  defp version_problems(version, previous) do
    with {:ok, new} <- Version.parse(version),
         {:ok, old} <- Version.parse(previous),
         :gt <- Version.compare(new, old) do
      []
    else
      :error ->
        ["#{version} or #{previous} is not a semantic version"]

      _not_newer ->
        [
          "version #{version} is not newer than #{previous}, the last release; bump " <>
            "`version:` in mix.exs first"
        ]
    end
  end

  # The `[Unreleased]` body may hold the note and may be empty. The note is blanked out line for
  # line, so problems keep pointing at the right line of CHANGELOG.md.
  defp parse_legacy(body, first_line) do
    blanked = String.replace(body, @note, String.replace(@note, ~r/[^\n]/, ""), global: false)
    parse_lines("CHANGELOG.md", blanked, first_line)
  end

  defp parse_fragment(path, text) do
    case parse_lines(path, String.replace(text, "\r\n", "\n"), 1) do
      {[], []} -> {[], ["#{path}: no ### heading with entries"]}
      parsed -> parsed
    end
  end

  # Returns `{[{heading, line, entries}], problems}`.
  defp parse_lines(name, text, first_line) do
    {sections, problems, _prose?} =
      text
      |> String.split("\n")
      |> Enum.with_index(first_line)
      |> Enum.reduce({[], [], false}, &parse_line(name, &1, &2))

    sections =
      for {heading, line, lines} <- Enum.reverse(sections) do
        entries =
          lines
          |> Enum.drop_while(&blank?/1)
          |> Enum.reverse()
          |> Enum.drop_while(&blank?/1)
          |> Enum.join("\n")

        {heading, line, entries}
      end

    empty =
      for {heading, line, ""} <- sections, do: "#{name}:#{line}: ### #{heading} has no entries"

    {sections, Enum.reverse(problems) ++ empty}
  end

  defp parse_line(name, {line, n}, {sections, problems, prose?}) do
    heading = Regex.run(~r/\A### (\w+)\s*\z/, line, capture: :all_but_first)

    cond do
      match?([known] when known in @headings, heading) ->
        {[{hd(heading), n, []} | sections], problems, prose?}

      # A Markdown heading, or a typo of one (`###Fixed`); `#843` alone is entry text.
      Regex.match?(~r/\A(\#{1,6}(\s|\z)|\#{2,})/, line) ->
        problem = "#{name}:#{n}: #{inspect(line)} is not one of #{@heading_list}"
        {sections, [problem | problems], prose?}

      sections != [] ->
        [{current, start, lines} | rest] = sections
        {[{current, start, [line | lines]} | rest], problems, prose?}

      prose? or blank?(line) ->
        {sections, problems, prose?}

      true ->
        {sections, ["#{name}:#{n}: text before the first ### heading" | problems], true}
    end
  end

  defp blank?(line), do: String.trim(line) == ""

  defp render(version, date, sections) do
    groups =
      for heading <- @headings,
          entries = for({^heading, _line, text} <- sections, do: text),
          entries != [] do
        "### #{heading}\n" <> Enum.join(entries, "\n")
      end

    "## [#{version}] - #{Date.to_iso8601(date)}\n\n" <> Enum.join(groups, "\n\n") <> "\n\n"
  end

  defp move_links(rest, version) do
    Regex.replace(
      @unreleased_link,
      rest,
      "[Unreleased]: \\1/compare/v#{version}...HEAD\n[#{version}]: \\1/compare/v\\2...v#{version}"
    )
  end
end
