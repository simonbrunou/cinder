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
  # nothing but symbols between them.
  #
  # #1103: a name Nix builds from parts with other letters between them (a comment, a function
  # call) never shows in those letters. A `let` refuses a built name and a `rec` set does not
  # scope one, but `with` brings it into scope, and `with import ./x.nix;` supplies the name with
  # no mention in flake.nix at all. So the fence also fails on every `with` in the raw
  # lines, in code, a comment or a string alike: each one with no ASCII letter, digit, _, ' or -
  # right before or after it. Those are the bytes a Nix name holds, so `withPackages` and `x-with`
  # are names, not the keyword.
  #
  # #1261: a `rec` set or a legacy `let { ... }` block that holds the pin line can also hold an
  # `__overrides` attribute. Nix replaces the set's own bindings with the ones it holds, for the
  # references inside the set too, and a built name there never shows in the letters. Nix applies
  # `__overrides` only under a static name, and each static spelling (quoted, escaped,
  # `${"__overrides"}`, `inherit`) leaves `overrides` in the letters. So the fence also fails on
  # each `overrides` in the letters, case-sensitive, in code, a comment or a string alike. That
  # fails prose whose joined letters spell it ("it override" before a word that starts with s,
  # on the same line or the next), and code too: `.override { stdenv = ...; }` and an attribute
  # named `overrides`. Put no name that starts with s right after `override`, for example with
  # `.override (old: { ... })`, and move code that needs an `overrides` attribute out of
  # flake.nix.
  #
  # Forms this check does not catch include: a ${tailwindVersion} read in another file, which the
  # fence does not read; `builtins.scopedImport`, which can supply the name to the file it
  # imports, and which `builtins.${"scoped" + /* c */ "Import"}` reaches without spelling its own
  # name.
  use ExUnit.Case, async: true

  @version "4.1.12"

  # A whole line: leading and trailing blanks, never a carriage return, and a value with no
  # quote, escape or interpolation.
  @pin ~r/\A[ \t]*tailwindVersion = "([^"\\$]+)";[ \t]*\z/

  # A `with` that no byte a Nix name can hold touches on either side, so `withPackages` passes.
  @with_keyword ~r/(?<![A-Za-z0-9_'-])with(?![A-Za-z0-9_'-])/

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

  @with_problem "uses with, which can bring tailwindVersion into scope where this check " <>
                  "cannot see it: write the attribute path out in code, and reword prose"

  @overrides_problem "spells overrides, which as __overrides can replace tailwindVersion's " <>
                       "value where this check cannot see it: reword prose, and in code put " <>
                       "no name that starts with s right after override, or move the code " <>
                       "out of flake.nix"

  # The issue's override: a rec set applies it to the references inside it, and the name it
  # builds never shows in the letters.
  @issue_override ~S|      __overrides = { ${"tailwind" + /* c */ "Version"} = "4.1.13"; };|

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
             "\n\nSet the version on the one line tailwindVersion = \"<version>\";, read it " <>
             "only as ${tailwindVersion}, write no with, and let no letters spell overrides, " <>
             "even across words and lines, in code, comments and strings alike."
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

    # The name it builds shows in the letters, so the `with` fails on both counts.
    built = ~S(      t = with { ${"tailwind" + "Version"} = "4.1.13"; }; tailwindcss;)
    flake = String.replace(@flake, @pin_line, @pin_line <> built <> "\n")
    assert problems(flake) == [mention(7), with_used(7)]

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

    assert problems(supplied) == [mention(9), with_used(9)]
  end

  test "a with that supplies a name the letters never show fails on its line" do
    # With the pin in a comment, each `with` supplies the references their tailwindVersion.
    commented = String.replace(@flake, @pin_line, "      /*\n" <> @pin_line <> "      */\n")

    for scope <- [
          ~S(with { ${"tailwind" + /* x */ "Version"} = "4.1.13"; };),
          ~S|with { ${"tailwind" + (builtins.substring 0 1 "Vx") + "ersion"} = "4.1.13"; };|,
          "with import ./x.nix;"
        ] do
      flake = String.replace(commented, "tailwindcss = pkgs", "tailwindcss = #{scope} pkgs")
      assert {scope, problems(flake)} == {scope, [with_used(9)]}
    end
  end

  test "every with fails, in code, a comment or a string, and a longer name passes" do
    # After (, ;, =, :, ${ and */, and before {, Nix reads the keyword.
    for line <- [
          "      t = (with pkgs; tailwindcss_4);",
          "      t = assert true;with pkgs; tailwindcss_4;",
          "      t =with pkgs; tailwindcss_4;",
          "      f = { x }:with pkgs; tailwindcss_4;",
          ~S(      s = "${with pkgs; tailwindcss_4.version}";),
          "      t = /* c */with pkgs; tailwindcss_4;",
          "      t = with{ a = 1; }; a;",
          "      # built with nixfmt",
          ~s(      s = "built with nixfmt";)
        ] do
      flake = String.replace(@flake, @pin_line, @pin_line <> line <> "\n")
      assert {line, problems(flake)} == {line, [with_used(7)]}
    end

    start =
      String.replace(@flake, @pin_line, @pin_line <> "      t =\nwith pkgs; tailwindcss_4;\n")

    assert problems(start) == [with_used(8)]

    # A byte a Nix name holds, on either side, makes a longer name.
    for line <- [
          "      python = pkgs.python3.withPackages (ps: [ ]);",
          "      # without a venv"
          | for(byte <- ~w(a Z 0 _ ' -), do: "      # x#{byte}with with#{byte}x")
        ] do
      flake = String.replace(@flake, @pin_line, @pin_line <> line <> "\n")
      assert {line, problems(flake)} == {line, []}
    end
  end

  test "an __overrides in a rec set or a let { } block fails on its line, in every spelling" do
    assert problems(in_set(:rec, @issue_override)) == [overrides(7)]
    assert problems(in_set(:let, @issue_override)) == [overrides(7)]

    # Each static spelling Nix applies.
    for line <- [
          ~S|      "__overrides" = { ${"tailwind" + /* c */ "Version"} = "4.1.13"; };|,
          ~S|      "__\overrides" = { ${"tailwind" + /* c */ "Version"} = "4.1.13"; };|,
          ~S|      "__\o\v\err\i\d\e\s" = { ${"tailwind" + /* c */ "Version"} = "4.1.13"; };|,
          ~S|      ${"__overrides"} = { ${"tailwind" + /* c */ "Version"} = "4.1.13"; };|,
          "      inherit (x) __overrides;",
          "      inherit __overrides;"
        ] do
      assert {line, problems(in_set(:rec, line))} == {line, [overrides(7)]}
    end

    # Nix applies no __Overrides, and the fence reads the letters case-sensitive.
    capital = String.replace(@issue_override, "__overrides", "__Overrides")
    assert problems(in_set(:rec, capital)) == []
  end

  test "every overrides in the letters fails, in code, a comment or a string" do
    for line <- [
          "      # this overrides nothing",
          "      /* this overrides nothing */",
          ~s(      s = "this overrides nothing";),
          "      x = pkgs.hello.override { stdenv = pkgs.clangStdenv; };",
          "      h = pkgs.haskellPackages.override { overrides = self: super: { }; };",
          # Prose whose letters spell it across two words, or across two lines.
          "      # it override src",
          "      # it override\n      # s nothing",
          ~s(      "__over\nrides" = { };)
        ] do
      flake = String.replace(@flake, @pin_line, @pin_line <> line <> "\n")
      assert {line, problems(flake)} == {line, [overrides(7)]}
    end

    for line <- [
          "      # overridden by nothing",
          "      x = pkgs.hello.overrideAttrs { };",
          "      x = pkgs.hello.override (old: { stdenv = pkgs.clangStdenv; });"
        ] do
      flake = String.replace(@flake, @pin_line, @pin_line <> line <> "\n")
      assert {line, problems(flake)} == {line, []}
    end
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

  defp with_used(number), do: "flake.nix:#{number} " <> @with_problem

  defp overrides(number), do: "flake.nix:#{number} " <> @overrides_problem

  # The fixture with its let turned into a rec set that `.body` reads, or into a legacy
  # `let { ... }` block, and `line` right after the pin line. Nix applies an __overrides in
  # either to the references inside it.
  defp in_set(kind, line) do
    {open, close} = if kind == :rec, do: {"(rec {", "}).body;"}, else: {"let {", "};"}

    @flake
    |> String.replace("    let\n", "    #{open}\n")
    |> String.replace(@pin_line, @pin_line <> line <> "\n")
    |> String.replace("    in\n    { devShells", "      body = { devShells")
    |> String.replace("; }; };\n}", "; }; };\n    #{close}\n}")
  end

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
    letters = letters(lines, pins)

    (count_problems(pins) ++
       letter_problems(letters, "tailwindVersion", @mention_problem) ++
       letter_problems(letters, "overrides", @overrides_problem) ++
       with_problems(lines) ++ mismatch_problems(pins, version))
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

  # The file's ASCII letters, joined across lines, once the pin lines are blanked and each
  # ${tailwindVersion} is dropped, with the line number of each letter. A Nix name holds only
  # ASCII letters, digits, _, ' and -, so dropping every other byte only joins letters: any
  # spelling of a name in the text still shows, and so do some other names, which fail too.
  defp letters(lines, pins) do
    letters =
      for {line, number} = entry <- lines,
          entry not in pins,
          <<byte <- String.replace(line, "${tailwindVersion}", "")>>,
          byte in ?a..?z or byte in ?A..?Z,
          do: {byte, number}

    text = for {byte, _number} <- letters, into: "", do: <<byte>>
    {text, letters |> Enum.map(&elem(&1, 1)) |> List.to_tuple()}
  end

  # Each `word` in the letters, on the line where it starts.
  defp letter_problems({text, numbers}, word, problem) do
    for {start, _length} <- :binary.matches(text, word), do: {elem(numbers, start), problem}
  end

  # Each line holding a `with`, read on the raw line: the letters-only text joins words.
  defp with_problems(lines) do
    for {line, number} <- lines, line =~ @with_keyword, do: {number, @with_problem}
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
