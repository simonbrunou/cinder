defmodule Cinder.CodeHealth.TailwindDockerfilePinTest do
  # #867: the Dockerfile fetches Tailwind with curl against pinned sha256 sums. On a version
  # mismatch, `tailwind.install --if-missing` replaces that binary with its own unverified
  # download, or fails on the GitHub redirect the curl step avoids. So the Dockerfile's
  # ARG TAILWIND_VERSION must equal `config :tailwind, version:`.
  #
  # #1077: the pin sits after the builder stage's FROM, where Docker allows every instruction,
  # heredocs and continued lines included, so no part of the file holds only whole ARG lines (the
  # region BeamVersionPinsTest reads). This fence reads no Docker grammar. The pin is the first
  # line `ARG TAILWIND_VERSION=<version>`. The fence fails on every other line that names
  # TAILWIND_VERSION, unless as the reference ${TAILWIND_VERSION}. It fails on every ENV or ARG
  # key that is not a plain name, since Docker drops quotes and escapes and fills in expansions
  # there, and on any other instruction whose literal parts spell the name once its quotes,
  # escapes and expansions are dropped. It also fails on a heredoc or a continued line above the
  # pin, either of which can make the pin part of another instruction. A name a RUN builds from
  # an expansion's value, such as `export TAILWIND_${X:-V}ERSION=1`, is past any text check.
  use ExUnit.Case, async: true

  @version "4.1.12"

  @pin ~r/\AARG TAILWIND_VERSION=(\S+)[ \t]*\z/

  # A line ending in Docker's default escape character \ or in `, which an escape directive can
  # set instead, before trailing blanks.
  @continued ~r/([\\`])[ \t]*\z/

  # A shell or Docker expansion: ${...}, $(...), $NAME, $1, a special parameter, or `...`.
  @expansion ~r/\$(?:\{[^{}]*\}|\([^()]*\)|[A-Za-z_][A-Za-z0-9_]*|[0-9]+|[@*#?$!-])|`[^`]*`/

  # An ENV or ARG instruction, its keyword and its arguments. The class is Go's unicode.IsSpace,
  # which Docker trims and splits with, not PCRE's \s, which also takes U+180E.
  @env_or_arg ~r/\A[\t-\r\x{85}\p{Z}]*(ENV|ARG)[\t-\r\x{85}\p{Z}]+(.*)\z/iu

  @bump "bump the Dockerfile's ARG TAILWIND_VERSION and both of its sha256 sums together with " <>
          "`config :tailwind, version:`"

  @dockerfile ~S'''
  FROM debian AS builder
  # TAILWIND_VERSION must equal `config :tailwind, version:`.
  ARG TAILWIND_VERSION=4.1.12
  RUN case "$(dpkg --print-architecture)" in \
      amd64) target=linux-x64 ;; \
    esac \
    && curl -fsSLo tailwindcss "https://example.com/v${TAILWIND_VERSION}/tailwindcss-${target}"
  '''

  @continued_pin ~S'''
  FROM debian AS builder
  RUN echo a \

    # Docker drops this comment and the blank line, so the RUN goes on with the pin.
  ARG TAILWIND_VERSION=4.1.12
  RUN curl "https://example.com/v${TAILWIND_VERSION}"
  '''

  @mention_problem "names TAILWIND_VERSION other than as ${TAILWIND_VERSION}, " <>
                     "which this check cannot read"

  @spelled_problem "spells TAILWIND_VERSION through quoting or an expansion, " <>
                     "which this check cannot read"

  test "the Dockerfile pins the Tailwind version config.exs asks for" do
    problems =
      pin_problems(
        {"Dockerfile", File.read!("Dockerfile")},
        Application.fetch_env!(:tailwind, :version)
      )

    assert problems == [],
           "The Dockerfile's Tailwind pin disagrees with `config :tailwind, version:` or " <>
             "cannot be read:\n  " <>
             Enum.join(problems, "\n  ") <>
             "\n\nSet the version on the one line ARG TAILWIND_VERSION=<version>, and read it " <>
             "only as ${TAILWIND_VERSION}."
  end

  test "the fixture passes, and a pin that differs from the config fails" do
    assert problems(@dockerfile) == []

    assert problems(String.replace(@dockerfile, "=4.1.12", "=4.1.12 \t")) == []

    assert problems(String.replace(@dockerfile, "=4.1.12", "=4.1.13")) == [
             ~s(Dockerfile:3 sets ARG TAILWIND_VERSION to "4.1.13", but ) <>
               ~s(config :tailwind, version: is "4.1.12": ) <> @bump
           ]
  end

  test "any other line naming TAILWIND_VERSION fails" do
    for line <- [
          "ARG TAILWIND_VERSION=4.1.13",
          "ARG TAILWIND_VERSION",
          "ENV TAILWIND_VERSION=4.1.13",
          "ENV TAILWIND_VERSION 4.1.13",
          "RUN TAILWIND_VERSION=4.1.13 curl -fsSLo tailwindcss https://example.com",
          "RUN export TAILWIND_VERSION=4.1.13",
          ~S(RUN echo "$TAILWIND_VERSION"),
          ~S(RUN echo "${TAILWIND_VERSION:-4.1.13}"),
          "ARG A=1 TAILWIND_VERSION=4.1.13"
        ] do
      assert {line, problems(after_pin(line))} == {line, ["Dockerfile:4 " <> @mention_problem]}
    end
  end

  test "an ENV or ARG key that is not a plain name fails" do
    for {line, key} <- [
          {~S|ENV TAILWIND_"VERSION"=4.1.13|, ~S|TAILWIND_"VERSION"|},
          {~S|ENV TAILWIND\_VERSION=4.1.13|, ~S|TAILWIND\_VERSION|},
          {~S|ENV TAILWIND_'VERSION' 4.1.13|, ~S|TAILWIND_'VERSION'|},
          {~S|ENV TAILWIND_${UNSET:-V}ERSION=4.1.13|, ~S|TAILWIND_${UNSET:-V}ERSION|},
          {~S|ENV A="x y" TAILWIND_${V}ERSION=4.1.13|, ~S|TAILWIND_${V}ERSION|},
          {~S|arg TAILWIND_"VERSION"=4.1.13|, ~S|TAILWIND_"VERSION"|}
        ] do
      assert {line, problems(after_pin(line))} ==
               {line,
                [
                  "Dockerfile:4 names the variable #{key}, which is not a plain name this check " <>
                    "can read"
                ]}
    end

    # Under this escape directive, `V is an escaped V.
    backtick = "# escape=`\n" <> after_pin("ENV TAILWIND_`V`ERSION=4.1.13")

    assert problems(backtick) == [
             "Dockerfile:5 names the variable TAILWIND_`V`ERSION, which is not a plain name " <>
               "this check can read"
           ]

    # Without the directive, ` is a plain character, so the second word is a key. Under it, so
    # is \.
    assert problems(after_pin(~S|ENV A=` TAILWIND_${X:-V}ERSION=4.1.13|)) == [
             "Dockerfile:4 names the variable TAILWIND_${X:-V}ERSION, which is not a plain name " <>
               "this check can read"
           ]

    backslash = "# escape=`\n" <> after_pin(~S|ENV A=\ TAILWIND_${X:-V}ERSION=4.1.13|)

    assert problems(backslash) == [
             "Dockerfile:5 names the variable TAILWIND_${X:-V}ERSION, which is not a plain name " <>
               "this check can read"
           ]

    # A heredoc whose terminator is a comment line ends before the ENV, which Docker reads as its
    # own instruction.
    after_heredoc = after_pin("RUN <<'#'\ntrue \\\n#\nENV TAILWIND_${X:-V}ERSION=4.1.13")

    assert problems(after_heredoc) == [
             "Dockerfile:7 names the variable TAILWIND_${X:-V}ERSION, which is not a plain name " <>
               "this check can read"
           ]

    # An expansion or a quote in a value sets no variable.
    assert problems(after_pin(~S|ENV PATH="/opt/bin:${PATH}" LANG=C.UTF-8 MSG='a b'|)) == []
    assert problems(after_pin(~S|ENV GREETING hello "$USER" ${HOME}|)) == []
  end

  test "a RUN that spells the name through quoting or an expansion fails" do
    for line <- [
          ~S|RUN export TAILWIND_"VERSION"=4.1.13|,
          ~S|RUN export TAILWIND_''VERSION=4.1.13|,
          ~S|RUN export TAILWIND_$(true)VERSION=4.1.13|,
          ~S|RUN export TAILWIND_`true`VERSION=4.1.13|,
          ~S|RUN export TAILWIND_$1VERSION=4.1.13|
        ] do
      assert {line, problems(after_pin(line))} == {line, ["Dockerfile:4 " <> @spelled_problem]}
    end

    # A heredoc body line that reads like an ENV is still shell.
    body = ~S|RUN <<EOT| <> "\n" <> ~S|env true && export TAILWIND_"VERSION"=4.1.13| <> "\nEOT"
    assert problems(after_pin(body)) == ["Dockerfile:5 " <> @spelled_problem]
  end

  test "a name split across continued lines fails" do
    assert problems(after_pin("ENV TAILWIND_\\\nVERSION=4.1.13")) == [
             "Dockerfile:4 spells TAILWIND_VERSION in the instruction it continues to line 5, " <>
               "which this check cannot read"
           ]

    # Docker drops the blank line and the comment inside a continued instruction.
    split = "RUN TAIL\\\n\n# a comment\nWIND_VER\\\nSION=4.1.13 curl https://example.com"

    assert problems(after_pin(split)) == [
             "Dockerfile:4 spells TAILWIND_VERSION in the instruction it continues to line 8, " <>
               "which this check cannot read"
           ]

    # Under this escape directive, ` continues a line.
    backtick = "# escape=`\n" <> after_pin("RUN export TAILWIND_`\nVERSION=4.1.13")

    assert problems(backtick) == [
             "Dockerfile:5 spells TAILWIND_VERSION in the instruction it continues to line 6, " <>
               "which this check cannot read"
           ]

    # A comment after a heredoc still drops out of a continued instruction.
    after_heredoc = "RUN <<EOT\ntrue\nEOT\nENV TAILWIND_\\\n# c\nVERSION=4.1.13"

    assert problems(after_pin(after_heredoc)) == [
             "Dockerfile:7 spells TAILWIND_VERSION in the instruction it continues to line 9, " <>
               "which this check cannot read"
           ]
  end

  test "a Dockerfile with no pin line fails" do
    assert problems(String.replace(@dockerfile, "ARG TAILWIND_VERSION=4.1.12\n", "")) == [
             "Dockerfile has no line ARG TAILWIND_VERSION=<version>"
           ]

    for pin <- ["arg TAILWIND_VERSION=4.1.12", "  ARG TAILWIND_VERSION=4.1.12"] do
      assert {pin, problems(String.replace(@dockerfile, "ARG TAILWIND_VERSION=4.1.12", pin))} ==
               {pin,
                [
                  "Dockerfile:3 " <> @mention_problem,
                  "Dockerfile has no line ARG TAILWIND_VERSION=<version>"
                ]}
    end
  end

  test "a pin continued from the line above fails" do
    assert problems(@continued_pin) == [
             "Dockerfile:2 continues onto the pin on line 5 with \\, which this check cannot read"
           ]

    backtick = "# escape=`\n" <> String.replace(@continued_pin, "echo a \\", "echo a `")

    assert problems(backtick) == [
             "Dockerfile:3 continues onto the pin on line 6 with `, which this check cannot read"
           ]
  end

  test "a heredoc body naming TAILWIND_VERSION fails, above or below the pin" do
    above = ~S'''
    FROM debian AS builder
    RUN <<EOT
    ARG TAILWIND_VERSION=4.1.12
    EOT
    ARG TAILWIND_VERSION=4.1.13
    RUN curl "https://example.com/v${TAILWIND_VERSION}"
    '''

    assert problems(above) == [
             "Dockerfile:2 opens a heredoc above the pin on line 3, which this check cannot read",
             "Dockerfile:5 " <> @mention_problem
           ]

    # Docker joins the continued line before it looks for a heredoc.
    split = ~S'''
    FROM debian AS builder
    RUN cat <\
    <EOT
    ARG TAILWIND_VERSION=4.1.12
    EOT
    '''

    assert problems(split) == [
             "Dockerfile:2 opens a heredoc above the pin on line 4, which this check cannot read"
           ]

    assert problems(after_pin("RUN <<EOT\nARG TAILWIND_VERSION=4.1.13\nEOT")) == [
             "Dockerfile:5 " <> @mention_problem
           ]

    # A heredoc body is text, so Docker keeps a line in it that starts with #.
    body = ~s(RUN <<EOT\nx="\n#"; TAILWIND_VERSION=4.1.13\necho "${TAILWIND_VERSION}"\nEOT)
    assert problems(after_pin(body)) == ["Dockerfile:6 " <> @mention_problem]

    # The body starts on the line after the one that opens it, even when that line ends in the
    # escape character.
    body = ~s(RUN sh <<'EOT' # `\nx='`\n#'; TAILWIND_VERSION=4.1.13\ny=1\nEOT)
    assert problems("# escape=`\n" <> after_pin(body)) == ["Dockerfile:7 " <> @mention_problem]
  end

  test "a comment naming TAILWIND_VERSION does not count" do
    dockerfile = ~S'''
    FROM debian AS builder
    # ARG TAILWIND_VERSION=4.1.13
    ARG TAILWIND_VERSION=4.1.12
      # ARG TAILWIND_VERSION=4.1.13, and a comment continues nothing \
    RUN curl "https://example.com/v${TAILWIND_VERSION}"
    '''

    assert problems(dockerfile) == []

    # A comment after a Unicode space is still a comment. U+180E is not a space to Docker, which
    # trims what Go's unicode.IsSpace accepts, so a line it leads is an instruction.
    led = <<0xA0::utf8>> <> "# ENV TAILWIND_VERSION=4.1.13\n" <> dockerfile
    assert problems(led) == []

    mongolian = after_pin(<<0x180E::utf8>> <> "# ; TAILWIND_VERSION=4.1.13")
    assert problems(mongolian) == ["Dockerfile:4 " <> @mention_problem]
  end

  test "the text reads as Docker reads it" do
    assert problems(<<0xFF>> <> @dockerfile) == [
             "Dockerfile is not valid UTF-8, which this check cannot read"
           ]

    # Docker skips a byte order mark, so the first line is a comment.
    bom = <<0xFEFF::utf8>> <> "# ARG TAILWIND_VERSION=4.1.13\n" <> @dockerfile
    assert problems(bom) == []

    # Docker strips every carriage return before a line feed, so the RUN still goes on with the
    # pin.
    assert problems(String.replace(@dockerfile, "\n", "\r\n")) == []

    assert problems(String.replace(@continued_pin, "\n", "\r\r\n")) == [
             "Dockerfile:2 continues onto the pin on line 5 with \\, which this check cannot read"
           ]
  end

  defp problems(dockerfile), do: pin_problems({"Dockerfile", dockerfile}, @version)

  defp after_pin(lines),
    do:
      String.replace(
        @dockerfile,
        "ARG TAILWIND_VERSION=4.1.12\n",
        "ARG TAILWIND_VERSION=4.1.12\n" <> lines <> "\n"
      )

  # Every problem in a Dockerfile, `{path, source}`, against the Tailwind version the config asks
  # for, each naming its line. The real file and the fixtures both go through here.
  defp pin_problems({path, source}, version) do
    if String.valid?(source),
      do: source |> numbered_lines() |> read_problems(path, version),
      else: ["#{path} is not valid UTF-8, which this check cannot read"]
  end

  # Every line as `{line, number}`. Docker skips a byte order mark and strips every carriage
  # return before a line feed.
  defp numbered_lines(source) do
    source
    |> String.trim_leading(<<0xFEFF::utf8>>)
    |> String.split("\n")
    |> Enum.map(&String.trim_trailing(&1, "\r"))
    |> Enum.with_index(1)
  end

  # The class is Go's unicode.IsSpace, which Docker trims with (see @env_or_arg).
  defp blank?({line, _number}), do: line =~ ~r/\A[\t-\r\x{85}\p{Z}]*\z/u
  defp comment?({line, _number}), do: line =~ ~r/\A[\t-\r\x{85}\p{Z}]*#/u

  defp read_problems(lines, path, version) do
    code = Enum.reject(lines, &(blank?(&1) or comment?(&1)))
    escapes = escapes(lines)
    instructions = Enum.flat_map(escapes, &instructions(code, &1))
    body = heredoc_comments(lines, instructions)
    pin = Enum.find(code, fn {line, _number} -> line =~ @pin end)
    mentions = mention_problems(code ++ body, pin)
    named = MapSet.new(mentions, &elem(&1, 0))

    checked =
      for {group, _text, _escape} = instruction <-
            instructions ++ Enum.map(body, &{[&1], elem(&1, 0), "\\"}),
          pin not in group,
          not Enum.any?(group, fn {_line, number} -> number in named end),
          problem <- instruction_problems(instruction),
          do: problem

    no_pin = if pin, do: [], else: ["#{path} has no line ARG TAILWIND_VERSION=<version>"]

    (mentions ++
       checked ++ swallow_problems(code, pin, escapes) ++ mismatch_problems(pin, version))
    |> Enum.uniq()
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {number, problem} -> "#{path}:#{number} #{problem}" end)
    |> Kernel.++(no_pin)
  end

  # Docker's escape character is \ unless a parser directive sets `, and a directive is a comment,
  # so a file with no comment that reads like one is read for \ alone.
  defp escapes(lines) do
    directive = ~r/\A[\t-\r\x{85}\p{Z}]*#\s*escape\s*=\s*`/iu

    if Enum.any?(lines, fn {line, _number} -> line =~ directive end),
      do: ["\\", "`"],
      else: ["\\"]
  end

  # The instruction that starts on each line that is neither blank nor a comment, as
  # `{lines, text, escape}`: a line ending in the escape character goes on with the next such
  # line. Docker drops the escape character, the blanks after it and the line feed, and keeps the
  # next line's leading blanks. An instruction starts on every line, not only after the last one
  # ended, since Docker does not continue a line inside a heredoc body, whose end this check
  # cannot find: an ENV after a body line that ends in the escape character is read as its own.
  defp instructions(code, escape) do
    ending = Regex.compile!(Regex.escape(escape) <> "[ \\t]*\\z")

    for start <- 0..(length(code) - 1)//1 do
      {continued, rest} =
        code |> Enum.drop(start) |> Enum.split_while(fn {line, _number} -> line =~ ending end)

      lines = continued ++ Enum.take(rest, 1)
      text = Enum.map_join(lines, fn {line, _number} -> String.replace(line, ending, "") end)
      {lines, text, escape}
    end
  end

  # A heredoc body is text, where Docker keeps a line that starts with #, so every # line after
  # the first line of the first instruction that holds << counts as text.
  defp heredoc_comments(lines, instructions) do
    case for({[{_line, first} | _], text, _escape} <- instructions, text =~ "<<", do: first) do
      [] ->
        []

      firsts ->
        opened = Enum.min(firsts)
        Enum.filter(lines, fn {_line, number} = entry -> number > opened and comment?(entry) end)
    end
  end

  defp mention_problems(lines, pin) do
    for {line, number} = entry <- lines,
        entry != pin,
        line |> String.replace("${TAILWIND_VERSION}", "") |> String.contains?("TAILWIND_VERSION"),
        do: {number, @mention_problem}
  end

  # An instruction that holds no line named above. Docker reads an ENV or ARG key itself, so a
  # key must be a plain name. When every key is, or for any other instruction, it fails when its
  # literal parts spell the name. A heredoc body line can read like an ENV and still be shell.
  defp instruction_problems({[{_line, first} | _] = lines, text, escape}) do
    key_problems =
      case Regex.run(@env_or_arg, text, capture: :all_but_first) do
        [keyword, args] ->
          for key <- keys(String.upcase(keyword), args, escape),
              problem <- key_problems(key, lines),
              do: {first, problem}

        nil ->
          []
      end

    cond do
      key_problems != [] -> key_problems
      text |> unquoted() |> String.contains?("TAILWIND_VERSION") -> [{first, spelled(lines)}]
      true -> []
    end
  end

  # The keys an ENV or ARG instruction sets, read word by word: plain and escaped characters and
  # quoted strings, up to a blank outside quotes, with a stray quote or escape character kept in
  # the word. `ENV key value`, with no = in its first word, is the legacy form, whose value is the
  # rest of the line.
  defp keys(keyword, args, escape) do
    word =
      ~S<(?:[^\t-\r\x{85}\p{Z}"'E]|E.|"(?:[^"E]|E.)*"|'[^']*'|["'E])+>
      |> String.replace("E", Regex.escape(escape))
      |> Regex.compile!("u")

    words = word |> Regex.scan(args) |> Enum.map(&hd/1)

    if keyword == "ENV" and words != [] and not String.contains?(hd(words), "="),
      do: [hd(words)],
      else: Enum.map(words, &(&1 |> String.split("=", parts: 2) |> hd()))
  end

  defp key_problems("TAILWIND_VERSION", lines), do: [spelled(lines)]

  defp key_problems(key, _lines) do
    if key =~ ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/,
      do: [],
      else: ["names the variable #{key}, which is not a plain name this check can read"]
  end

  defp spelled([_line]), do: @spelled_problem

  defp spelled(lines) do
    {_line, last} = List.last(lines)

    "spells TAILWIND_VERSION in the instruction it continues to line #{last}, " <>
      "which this check cannot read"
  end

  # The text with each ${TAILWIND_VERSION} reference dropped, then every other expansion, and
  # then every quote and escape character, so a name built from quoted or empty parts shows.
  defp unquoted(text) do
    text
    |> String.replace("${TAILWIND_VERSION}", "")
    |> drop_expansions()
    |> String.replace(~r/["'\\`]/, "")
  end

  # Inner expansions go first, so an expansion nested in another one is dropped too.
  defp drop_expansions(text) do
    case Regex.replace(@expansion, text, "") do
      ^text -> text
      dropped -> drop_expansions(dropped)
    end
  end

  # A heredoc that opens above the pin can hold it as text, and a line above it that ends in an
  # escape character makes it part of that line's instruction.
  defp swallow_problems(_code, nil, _escapes), do: []

  defp swallow_problems(code, {_line, pin} = entry, escapes) do
    above = Enum.take_while(code, &(&1 != entry))

    # One problem for the first line that starts a heredoc, though a later line can start an
    # instruction that holds the same <<.
    heredocs =
      for(
        escape <- escapes,
        {[{_line, first} | _], text, _escape} <- instructions(above, escape),
        text =~ "<<",
        do: first
      )
      |> Enum.sort()
      |> Enum.take(1)
      |> Enum.map(
        &{&1, "opens a heredoc above the pin on line #{pin}, which this check cannot read"}
      )

    continued =
      with {line, number} <- List.last(above),
           [escape] <- Regex.run(@continued, line, capture: :all_but_first) do
        [
          {number,
           "continues onto the pin on line #{pin} with #{escape}, which this check cannot read"}
        ]
      else
        _none -> []
      end

    heredocs ++ continued
  end

  defp mismatch_problems(nil, _version), do: []

  defp mismatch_problems({line, number}, version) do
    [value] = Regex.run(@pin, line, capture: :all_but_first)

    if value == version,
      do: [],
      else: [
        {number,
         ~s(sets ARG TAILWIND_VERSION to "#{value}", ) <>
           ~s(but config :tailwind, version: is "#{version}": ) <> @bump}
      ]
  end
end
