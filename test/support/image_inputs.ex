defmodule Cinder.ImageInputs do
  @moduledoc ~S"""
  Checks that image-inputs.txt covers every path CI's `container` job reads, so that a pull
  request that changes none of its paths leaves the image and the job as its base branch has
  them (#1486).

  The `image-inputs` job in .forgejo/workflows/ci.yml diffs a pull request's branch against its
  base branch over the list's paths and skips `container` when the diff is empty. A path that the build
  or the job reads but the list misses would let such a PR skip the job. `problems/2` names each
  one. test/code_health/image_inputs_test.exs runs it on the working tree, and
  `Cinder.PushRepeatsPr` on the commit it checks.

  A path counts as covered when a list line names it or a folder above it. The paths it requires:

  - the block "The build and the job" of the list, as `@fixed` holds it: the Dockerfile, both
    files that can set what the build context drops (.dockerignore, and Dockerfile.dockerignore,
    which overrides it), .gitattributes, whose checkout rules can change the bytes of a file
    the build copies, the list, the workflow, and the files the job reads besides the image
    (.github/scripts, .trivyignore). A file that the job reads elsewhere goes on the list and in
    `@fixed` by hand: this check does not read the job's steps;
  - each source that a COPY or ADD line of the Dockerfile reads from the build context, cut at its
    first `$`, `*`, `?` or `[` back to the folder above: `config/${MIX_ENV}.exs` requires
    `config`. A COPY with a `--from` flag reads a stage or an image, so it requires nothing.

  It reads no Docker grammar. A line counts as a COPY or ADD when its first word is one, in any
  case, after a byte order mark at the top and any Unicode space. That holds wherever the line
  sits, inside a continued RUN or a heredoc too, so the reader can require more than Docker reads
  but not less. It fails, rather than reads, each form that can reach the build context in a way
  it cannot follow:

  - on a COPY or ADD line: no source, a continued line (ending in `\` or `` ` ``), a heredoc
    (`<<`), the JSON form (`[`), a flag other than `--from`, `--chown`, `--chmod` and `--link`
    (each read with its quotes and `\` dropped, as BuildKit reads flags), and a source that is a
    URL or a git address, holds a quote or a `\`, starts with `/`, holds a `..` part, or that the
    cut leaves empty;
  - a line whose first word is letters, or nothing, then a `\`, since Docker joins a line that
    ends in `\` to the next one, so `CO\` then `PY` is a COPY;
  - a RUN line whose first argument is a flag, which can be a `--mount` of the build context, or
    sits on the next line;
  - an ONBUILD line, which adds a COPY to the builds that start from this image;
  - a `syntax` or `escape` parser directive (`# syntax=`, `# escape=`, `//syntax=`), which can
    change how Docker reads every other line;
  - a symbolic link or a submodule at, above or under a required path, whose changes a diff over
    that path cannot see.

  A list line is a path in letters, digits, `.`, `_`, `-` and `/`, with no empty, `.` or `..`
  part; the job's step fails on any other line, and this check reports it. A line that starts
  with `#` and an empty line are skipped.
  """

  @list "image-inputs.txt"
  @fixed ~w(Dockerfile Dockerfile.dockerignore .dockerignore .gitattributes image-inputs.txt
            .forgejo/workflows/ci.yml .github/scripts .trivyignore)

  # Go's unicode.IsSpace, which Docker trims and splits with.
  @space "[\\t-\\r\\x{85}\\p{Z}]"
  @slash_directive Regex.compile!("\\A#{@space}*//#{@space}*syntax#{@space}*=", "iu")
  @hash_directive Regex.compile!("\\A#{@space}*##{@space}*(?:syntax|escape)#{@space}*=", "iu")
  # Letters, if any, then the escape character: an instruction name continued on the next line.
  @split_name Regex.compile!("\\A#{@space}*[A-Za-z]*\\\\", "u")
  @instruction Regex.compile!("\\A#{@space}*([A-Za-z]+)(?:#{@space}+(.*?))?#{@space}*\\z", "u")

  @list_line ~r/\A[A-Za-z0-9._-]+(?:\/[A-Za-z0-9._-]+)*\z/
  @continued ~r/[\\`]\z/
  @flag_text ~r/["'\\]/
  @kept_flag ~r/\A--(?:(?:chown|chmod)=\S+|link(?:=(?:true|false))?)\z/
  @cut ~r/[$*?\[]/

  @doc "The paths of the list's block \"The build and the job\"."
  @spec fixed() :: [String.t()]
  def fixed, do: @fixed

  @doc """
  Each problem of the tree, as a line naming the file and the line it stands on. `entries` holds
  the tree's `{mode, path}` pairs, as `git ls-tree -r` or `git ls-files -s` prints them, and
  `read` returns `{:ok, text}` for a path of the tree and `:error` for one it lacks.
  """
  @spec problems([{String.t(), String.t()}], (String.t() -> {:ok, binary()} | :error)) ::
          [String.t()]
  def problems(entries, read) do
    {lines, list_problems} = list(read.(@list))
    {sources, docker_problems} = dockerfile(read.("Dockerfile"))
    required = Enum.map(@fixed, &{@list, &1}) ++ sources

    list_problems ++
      docker_problems ++
      for({place, path} <- required, not covered?(path, lines), do: uncovered(place, path)) ++
      link_problems(entries, required)
  end

  @doc """
  The list's paths and the problems of its lines, from the text of image-inputs.txt or `:error`.
  """
  @spec list({:ok, binary()} | :error) :: {[String.t()], [String.t()]}
  def list(:error), do: {[], ["#{@list}: no such file, so the image-inputs job fails"]}

  def list({:ok, text}) do
    {paths, problems} =
      text
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.reduce({[], []}, fn {line, number}, {paths, problems} ->
        cond do
          line == "" or String.starts_with?(line, "#") -> {paths, problems}
          list_path?(line) -> {[line | paths], problems}
          true -> {paths, [bad_line(number, line) | problems]}
        end
      end)

    empty = if paths == [], do: ["#{@list}: no path, so the image-inputs job fails"], else: []
    {Enum.reverse(paths), Enum.reverse(problems) ++ empty}
  end

  defp list_path?(line) do
    Regex.match?(@list_line, line) and
      not Enum.any?(String.split(line, "/"), &(&1 in [".", ".."]))
  end

  defp bad_line(number, line) do
    "#{@list}:#{number}: #{inspect(line)} is not a path the image-inputs job reads (letters, " <>
      "digits, ., _, - and /, with no empty, . or .. part), so the job fails"
  end

  defp covered?(path, lines),
    do: Enum.any?(lines, &(path == &1 or String.starts_with?(path, &1 <> "/")))

  defp uncovered(@list, path),
    do: "#{@list}: no line covers #{path}, which the build or the container job reads"

  defp uncovered(place, path),
    do: "#{place}: reads #{path} from the build context, which no line of #{@list} covers"

  # The `{"Dockerfile:<line>", path}` pairs its COPY and ADD lines require, and its problems.
  defp dockerfile(:error), do: {[], ["Dockerfile: no such file"]}

  defp dockerfile({:ok, text}) do
    text
    |> String.trim_leading(<<0xFEFF::utf8>>)
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce({[], []}, fn {line, number}, {sources, problems} ->
      {found, more} = line_sources("Dockerfile:#{number}", line)
      {sources ++ found, problems ++ more}
    end)
  end

  defp line_sources(place, line) do
    cond do
      Regex.match?(@hash_directive, line) or Regex.match?(@slash_directive, line) ->
        {[], ["#{place}: a parser directive, which can change how Docker reads every line"]}

      Regex.match?(@split_name, line) ->
        {[], ["#{place}: a word continued on the next line, which can split a COPY or ADD"]}

      # A comment's `#` is not a letter, so a comment holds no instruction.
      match = Regex.run(@instruction, line) ->
        instruction(place, String.downcase(Enum.at(match, 1)), Enum.at(match, 2, ""))

      true ->
        {[], []}
    end
  end

  defp instruction(place, keyword, rest) when keyword in ["copy", "add"],
    do: copy(place, if(keyword == "add", do: "an ADD", else: "a COPY"), rest)

  defp instruction(place, "onbuild", _rest),
    do: {[], ["#{place}: an ONBUILD, which adds a COPY to the builds that start from the image"]}

  defp instruction(place, "run", rest) do
    if rest in ["", "\\", "`"] or Regex.match?(~r/\A["'\\]*-/, rest),
      do:
        {[],
         [
           "#{place}: a RUN whose first argument is a flag or sits on the next line, which " <>
             "can mount the build context"
         ]},
      else: {[], []}
  end

  defp instruction(_place, _keyword, _rest), do: {[], []}

  defp copy(place, keyword, rest) do
    cond do
      rest == "" -> {[], ["#{place}: #{keyword} with no source"]}
      Regex.match?(@continued, rest) -> {[], ["#{place}: #{keyword} continued on the next line"]}
      String.contains?(rest, "<<") -> {[], ["#{place}: #{keyword} heredoc"]}
      String.starts_with?(rest, "[") -> {[], ["#{place}: #{keyword} in the JSON form"]}
      true -> rest |> String.split() |> words(place, keyword)
    end
  end

  defp words(words, place, keyword) do
    {flags, args} = Enum.split_while(words, &String.starts_with?(flag(&1), "-"))

    cond do
      Enum.any?(flags, &String.starts_with?(flag(&1), "--from=")) ->
        {[], []}

      bad = Enum.find(flags, &(not Regex.match?(@kept_flag, flag(&1)))) ->
        {[], ["#{place}: #{keyword} flag this check cannot read: #{bad}"]}

      length(args) < 2 ->
        {[], ["#{place}: #{keyword} with no source"]}

      true ->
        args |> Enum.drop(-1) |> Enum.map(&source(place, keyword, &1)) |> split_results()
    end
  end

  defp flag(word), do: Regex.replace(@flag_text, word, "")

  defp split_results(results) do
    {for({:ok, pair} <- results, do: pair), for({:error, problem} <- results, do: problem)}
  end

  defp source(place, keyword, source) do
    path = narrow(source)

    cond do
      String.contains?(source, "://") or String.starts_with?(source, "git@") ->
        {:error, "#{place}: #{keyword} of a URL or a git address: #{source}"}

      Regex.match?(@flag_text, source) or String.starts_with?(source, "/") or
          ".." in String.split(source, "/") ->
        {:error, "#{place}: #{keyword} source this check cannot read: #{source}"}

      path == "" ->
        {:error,
         "#{place}: #{keyword} source that reads the whole build context, or that this " <>
           "check cannot narrow to a folder: #{source}"}

      true ->
        {:ok, {place, path}}
    end
  end

  # The source cut at its first `$`, `*`, `?` or `[` back to the folder above, without `.` parts
  # and the slashes around them.
  defp narrow(source) do
    cut =
      case Regex.split(@cut, source, parts: 2) do
        [whole] -> whole
        [prefix, _rest] -> prefix |> String.split("/") |> Enum.drop(-1) |> Enum.join("/")
      end

    cut |> String.split("/") |> Enum.reject(&(&1 in ["", "."])) |> Enum.join("/")
  end

  defp link_problems(entries, required) do
    links = for {mode, path} <- entries, mode in ["120000", "160000"], do: path

    for {place, path} <- required,
        link <- links,
        link == path or String.starts_with?(path, link <> "/") or
          String.starts_with?(link, path <> "/"),
        uniq: true,
        do:
          "#{place}: #{path} has the symbolic link or submodule #{link} at, above or under it, " <>
            "whose changes a diff over #{path} cannot see"
  end
end
