defmodule Cinder.CodeHealth.TailwindFlakePinTest do
  # #889: the dev shell points MIX_TAILWIND_PATH at a Tailwind binary in the read-only Nix store.
  # On a version mismatch, `tailwind.install --if-missing` downloads the configured version with
  # :httpc and cannot write it there. So flake.nix's tailwindVersion must equal
  # `config :tailwind, version:`.
  #
  # #1090: the check read the first line of flake.nix that looked like the pin, so a binding in
  # an inner scope, or a pin-shaped line in a string or comment above the real one, passed while
  # the fetch read another version. This fence reads no Nix grammar. The pin is the one whole
  # line `tailwindVersion = "<version>";`. With every such line blanked and each
  # ${tailwindVersion} dropped, the fence keeps only the file's ASCII letters, joined across
  # lines, and fails on each tailwindVersion left, in code, a comment or a string alike. That
  # catches a name in quotes or escapes, one split across lines, and one built from strings with
  # nothing but symbols between them. A name Nix builds from parts with other letters between
  # them (a comment, a function call) and supplies through `with`, or a binding from another
  # file, is past any text check.
  use ExUnit.Case, async: true

  @version "4.1.12"

  # A whole line: leading and trailing blanks, never a carriage return, and a value with no
  # quote, escape or interpolation.
  @pin ~r/\A[ \t]*tailwindVersion = "([^"\\$]+)";[ \t]*\z/

  @bump "bump these together: `config :tailwind, version:`, the Dockerfile's " <>
          "ARG TAILWIND_VERSION and both of its sha256 sums, and flake.nix's " <>
          "tailwindVersion and both of its sha256 sums (all from the release's " <>
          "sha256sums.txt)"

  @flake ~S'''
  {
    outputs = { nixpkgs, ... }:
      let
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
        # The pin below must equal `config :tailwind, version:`.
        tailwindVersion = "4.1.12";
        tailwindcss = pkgs.tailwindcss_4.overrideAttrs {
          version = "${tailwindVersion}";
          src = pkgs.fetchurl {
            url = "https://example.com/v${tailwindVersion}/tailwindcss-linux-x64";
            sha256 = "5eeee66ea237eae9a160fa3314fd0cf76ab993551a99fafb16fa1db6c6b90289";
          };
        };
      in
      { devShells.x86_64-linux.default = pkgs.mkShell { packages = [ tailwindcss ]; }; };
  }
  '''

  @pin_line ~s(      tailwindVersion = "4.1.12";\n)

  @mention_problem "names tailwindVersion other than as ${tailwindVersion}, " <>
                     "which this check cannot read"

  @no_pin ~s(flake.nix has no line tailwindVersion = "<version>";)

  test "the flake pins the Tailwind version config.exs asks for" do
    problems =
      pin_problems(
        {"flake.nix", File.read!("flake.nix")},
        Application.fetch_env!(:tailwind, :version)
      )

    assert problems == [],
           "flake.nix's Tailwind pin disagrees with `config :tailwind, version:` or cannot be " <>
             "read:\n  " <>
             Enum.join(problems, "\n  ") <>
             "\n\nSet the version on the one line tailwindVersion = \"<version>\";, and read it " <>
             "only as ${tailwindVersion}, in code, comments and strings alike."
  end

  test "the fixture passes, and a pin that differs from the config fails" do
    assert problems(@flake) == []

    assert problems(String.replace(@flake, ~s("4.1.12";), ~s("4.1.12"; \t))) == []
    assert problems(String.replace(@flake, @pin_line, "\t" <> @pin_line)) == []

    assert problems(String.replace(@flake, ~s("4.1.12"), ~s("4.1.13"))) == [
             ~s(flake.nix:6 sets tailwindVersion to "4.1.13", but ) <>
               ~s(config :tailwind, version: is "4.1.12": ) <> @bump
           ]
  end

  test "a second pin line fails on each, wherever it sits" do
    # Nix reads the first as a string and drops the second as a comment, so the fetch reads the
    # binding below them.
    for above <- [
          ~s(      note = ''\n  #{@pin_line}      '';\n),
          ~s(      /*\n  #{@pin_line}      */\n)
        ] do
      flake = String.replace(@flake, @pin_line, above <> String.replace(@pin_line, "2", "3"))
      assert {above, problems(flake)} == {above, [second_pin(7), second_pin(9)]}
    end

    # A nested let shadows the outer binding for the override.
    nested =
      String.replace(@flake, "      tailwindcss = pkgs.tailwindcss_4", """
            tailwindcss =
              let
                tailwindVersion = "4.1.13";
              in
              pkgs.tailwindcss_4\
      """)

    assert problems(nested) == [second_pin(6), second_pin(9)]
  end

  test "any other mention of tailwindVersion fails, naming its line" do
    for line <- [
          ~S(      "tailwind\Version" = "4.1.13";),
          ~S(      ${"tailwindVersion"} = "4.1.13";),
          ~S(      t = with { ${"tailwind" + "Version"} = "4.1.13"; }; tailwindcss;),
          "      inherit (s) tailwindVersion;",
          "      f = tailwindVersion: tailwindcss;",
          "      f = { tailwindVersion ? \"4.1.13\" }: tailwindcss;",
          ~S(      url = "https://example.com/v${ tailwindVersion }";),
          ~s(      # tailwindVersion = "4.1.11";),
          ~s(      s = "tailwindVersion = \\"4.1.11\\";";)
        ] do
      flake = String.replace(@flake, @pin_line, @pin_line <> line <> "\n")
      assert {line, problems(flake)} == {line, [mention(7)]}
    end

    bare =
      String.replace(@flake, ~s(version = "${tailwindVersion}";), "version = tailwindVersion;")

    assert problems(bare) == [mention(8)]
  end

  test "a pin or a name split across lines fails on the line where it starts" do
    split =
      String.replace(@flake, ~s(tailwindVersion = "4.1.12";), ~s(tailwindVersion =\n"4.1.12";))

    assert problems(split) == [mention(6), @no_pin]

    # With the pin in a comment, `with` supplies the name it builds to the references.
    supplied =
      @flake
      |> String.replace(@pin_line, "      /*\n" <> @pin_line <> "      */\n")
      |> String.replace("      tailwindcss = pkgs", """
            tailwindcss = with { ${"tailwind" +
              "Version"} = "4.1.13"; }; pkgs\
      """)

    assert problems(supplied) == [mention(9)]
  end

  test "a flake with no pin line fails" do
    assert problems(String.replace(@flake, @pin_line, "")) == [@no_pin]

    for pin <- [
          ~S(tailwindVersion = "4.1.1\2";),
          ~S(tailwindVersion = "4.1.${"12"}";),
          ~S(tailwindVersion = "4.1.12" ;),
          ~S(tailwindVersion="4.1.12";)
        ] do
      flake = String.replace(@flake, ~s(tailwindVersion = "4.1.12";), pin)
      assert {pin, problems(flake)} == {pin, [mention(6), @no_pin]}
    end
  end

  test "the text reads as UTF-8 with line feeds" do
    assert problems(<<0xFF>> <> @flake) == [
             "flake.nix is not valid UTF-8, which this check cannot read"
           ]

    # The pin line ends in a carriage return, so it is no pin.
    assert problems(String.replace(@flake, "\n", "\r\n")) == [mention(6), @no_pin]

    crlf = "flake.nix" |> File.read!() |> String.replace("\n", "\r\n") |> problems()
    assert @no_pin in crlf
    assert Enum.any?(crlf, &(&1 =~ @mention_problem))
  end

  defp problems(flake), do: pin_problems({"flake.nix", flake}, @version)

  defp mention(number), do: "flake.nix:#{number} " <> @mention_problem

  defp second_pin(number),
    do: "flake.nix:#{number} is one of 2 pin lines, and this check reads only one"

  # Every problem in a flake, `{path, source}`, against the Tailwind version the config asks for,
  # each naming its line. The real file and the fixtures both go through here.
  defp pin_problems({path, source}, version) do
    if String.valid?(source),
      do: read_problems(path, source, version),
      else: ["#{path} is not valid UTF-8, which this check cannot read"]
  end

  defp read_problems(path, source, version) do
    lines = source |> String.split("\n") |> Enum.with_index(1)
    pins = Enum.filter(lines, fn {line, _number} -> line =~ @pin end)
    no_pin = if pins == [], do: [~s(#{path} has no line tailwindVersion = "<version>";)], else: []

    (count_problems(pins) ++ mention_problems(lines, pins) ++ mismatch_problems(pins, version))
    |> Enum.uniq()
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {number, problem} -> "#{path}:#{number} #{problem}" end)
    |> Kernel.++(no_pin)
  end

  defp count_problems([_pin]), do: []

  defp count_problems(pins) do
    for {_line, number} <- pins,
        do: {number, "is one of #{length(pins)} pin lines, and this check reads only one"}
  end

  # Each tailwindVersion left in the file's ASCII letters, joined across lines, once the pin lines
  # are blanked and each ${tailwindVersion} is dropped. A Nix name holds only ASCII letters,
  # digits, _, ' and -, so dropping every other byte only joins letters: any spelling of the name
  # in the text still shows, and so do some other names, which fail too.
  defp mention_problems(lines, pins) do
    letters =
      for {line, number} = entry <- lines,
          entry not in pins,
          <<byte <- String.replace(line, "${tailwindVersion}", "")>>,
          byte in ?a..?z or byte in ?A..?Z,
          do: {byte, number}

    text = for {byte, _number} <- letters, into: "", do: <<byte>>
    numbers = letters |> Enum.map(&elem(&1, 1)) |> List.to_tuple()

    for {start, _length} <- :binary.matches(text, "tailwindVersion"),
        do: {elem(numbers, start), @mention_problem}
  end

  defp mismatch_problems([{line, number}], version) do
    [value] = Regex.run(@pin, line, capture: :all_but_first)

    if value == version,
      do: [],
      else: [
        {number,
         ~s(sets tailwindVersion to "#{value}", but config :tailwind, version: is "#{version}": ) <>
           @bump}
      ]
  end

  defp mismatch_problems(_pins, _version), do: []
end
