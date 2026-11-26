defmodule Cinder.Acquisition.Indexer.Cardigann.BoundedRegexTest do
  use ExUnit.Case, async: true

  alias Cinder.Acquisition.Indexer.Cardigann.{BoundedRegex, Template}

  # 40 `a` then `!`: `^(\w+\s?)+$` backtracks through every split of the run before it fails.
  @hostile "^(\\w+\\s?)+$"
  @hostile_subject String.duplicate("a", 40) <> "!"
  @cap 65_536

  defp words(_alphabet, 0), do: [""]

  defp words(alphabet, n),
    do: for(word <- words(alphabet, n - 1), char <- alphabet, do: word <> char)

  # Whether PCRE reads `(?<c>` right after `prefix` as a group, or `:unknown` when no closing
  # run makes the prefix compile.
  defp opens_group?(prefix, closers) do
    Enum.find_value(closers, {:ok, :unknown}, fn closer ->
      case :re.compile(BoundedRegex.translate(prefix <> "(?<c>)" <> closer), [:unicode, :ucp]) do
        {:ok, mp} -> {:ok, match?({:namelist, ["c" | _]}, :re.inspect(mp, :namelist))}
        {:error, _} -> nil
      end
    end)
    |> elem(1)
  end

  # Each entry point either refuses the pattern or gives UTF-8 text, and none raises.
  defp utf8_results?(pattern, subject) do
    results = [
      BoundedRegex.first_group(pattern, subject),
      BoundedRegex.replace(pattern, subject, "[$0]", @cap),
      BoundedRegex.split(pattern, subject)
    ]

    Enum.all?(results, fn
      {:ok, parts} when is_list(parts) -> Enum.all?(parts, &String.valid?/1)
      {:ok, text} -> String.valid?(text)
      {:error, _} -> true
    end)
  rescue
    ArgumentError -> false
  end

  describe "match_limit/0" do
    test "is 1_000_000" do
      assert BoundedRegex.match_limit() == 1_000_000
    end
  end

  describe "replace/4 reads .NET replacement syntax" do
    # Each row ran in `dotnet fsi` (.NET 8.0.427): `Regex("(a)(b)").Replace("ab", replacement)`.
    for {replacement, expected} <- [
          {"$2$1", "ba"},
          {"${2}x", "bx"},
          {"$3", "$3"},
          {"$10", "$10"},
          {"$12", "$12"},
          {"$0$0", "abab"},
          {"$&!", "ab!"},
          {"$$1", "$1"},
          {"$x", "$x"},
          {"$", "$"},
          {"$1$", "a$"},
          {"$02", "b"},
          {"${02}", "b"},
          {"${3}", "${3}"},
          {"${}", "${}"},
          {"${2", "${2"},
          {"${-1}", "${-1}"},
          {"$-1", "$-1"},
          {"plain", "plain"}
        ] do
      test "#{inspect(replacement)} gives #{inspect(expected)}" do
        assert BoundedRegex.replace("(a)(b)", "ab", unquote(replacement), @cap) ==
                 {:ok, unquote(expected)}
      end
    end

    test "a group that exists but took no part in the match inserts nothing" do
      # .NET: Regex("(a)|(b)").Replace("a", "[$2]") gives "[]", and "[${2}]" too.
      assert BoundedRegex.replace("(a)|(b)", "a", "[$2]", @cap) == {:ok, "[]"}
      assert BoundedRegex.replace("(a)|(b)", "a", "[${2}]", @cap) == {:ok, "[]"}
      # A trailing group that took no part: `:re` leaves it out of the match list.
      assert BoundedRegex.replace("(a)(b)?(c)?", "a", "[$3]", @cap) == {:ok, "[]"}
      assert BoundedRegex.replace("(a)(b)?(c)?", "a", "[$4]", @cap) == {:ok, "[$4]"}
    end

    test "every match is replaced, text between matches kept" do
      assert BoundedRegex.replace("\\b0(\\d{1})\\b", "show 05 and 07", "$1", @cap) ==
               {:ok, "show 5 and 7"}

      assert BoundedRegex.replace("x", "abc", "-", @cap) == {:ok, "abc"}
    end

    test "empty matches advance as .NET's do" do
      # .NET rows: `a*` on baaac gives -b--c-, `a|` gives -b----c-, `(?=a)|a` on baac gives
      # b-a-ac, and the empty pattern on é€ gives -é-€-.
      assert BoundedRegex.replace("a*", "baaac", "-", @cap) == {:ok, "-b--c-"}
      assert BoundedRegex.replace("a|", "baaac", "-", @cap) == {:ok, "-b----c-"}
      assert BoundedRegex.replace("(?=a)|a", "baac", "-", @cap) == {:ok, "b-a-ac"}
      assert BoundedRegex.replace("", "é€", "-", @cap) == {:ok, "-é-€-"}
    end

    test "a look-behind sees the text before the place a later match starts" do
      # .NET rows: `(?<!a)a` on aaa gives Xaa, `(?<![A-Za-z0-9])(OVA)` on `xOVA OVA` gives
      # `xOVA Y`. A scan that hands the look-behind only the text after the last match would
      # replace all three `a`.
      assert BoundedRegex.replace("(?<!a)a", "aaa", "X", @cap) == {:ok, "Xaa"}

      assert BoundedRegex.replace("(?<![A-Za-z0-9])(OVA)", "xOVA OVA", "Y", @cap) ==
               {:ok, "xOVA Y"}

      pattern = "(?i)(?<![A-Za-z0-9])(Movies?|OVA|OAV)(?![A-Za-z0-9])"
      assert BoundedRegex.replace(pattern, "x OVA yOVA", "YES", @cap) == {:ok, "x YES yOVA"}
    end

    test "the substitutions .NET reads and Cinder does not are an error tag" do
      # .NET rows on `(a)(b)` and xaby: [$`] gives x[x]y, [$'] x[y]y, [$+] x[b]y, [$_] x[xaby]y.
      for token <- ["$`", "$'", "$+", "$_"] do
        assert BoundedRegex.replace("(a)(b)", "xaby", "[" <> token <> "]", @cap) ==
                 {:error, {:not_supported, {:replacement, token}}}
      end

      assert BoundedRegex.replace("(a)(b)", "ab", "${x}", @cap) ==
               {:error, {:not_supported, {:replacement, "${name}"}}}
    end

    test "a group number past Int32 is an error tag, as .NET throws on it" do
      assert BoundedRegex.replace("(a)(b)", "ab", "$99999999999", @cap) ==
               {:error, :replacement_invalid}

      assert BoundedRegex.replace("(a)(b)", "ab", "${99999999999}", @cap) ==
               {:error, :replacement_invalid}

      assert BoundedRegex.replace("(a)(b)", "ab", "$2147483647", @cap) ==
               {:ok, "$2147483647"}
    end

    test "a pattern with a named group is an error tag, since .NET numbers it last" do
      # .NET: Regex("(?<n>a)(b)").Replace("ab", "$2|$1") gives a|b, where PCRE numbers n first.
      assert BoundedRegex.replace("(?<n>a)(b)", "ab", "$2|$1", @cap) ==
               {:error, {:not_supported, :named_group}}
    end

    test "an output past max_bytes stops with the cap tag" do
      assert BoundedRegex.replace("(a)", "aaaa", "$1$1", 8) == {:ok, "aaaaaaaa"}
      assert BoundedRegex.replace("(a)", "aaaa", "$1$1", 7) == {:error, :filter_output_cap}
      assert BoundedRegex.replace("x", "abcd", "x", 3) == {:error, :filter_output_cap}
    end
  end

  describe "first_group/2" do
    test "gives the first match's group 1, or empty text" do
      assert BoundedRegex.first_group("(?i)(S\\d{1,3})", "Show S02E01 S03") == {:ok, "S02"}
      assert BoundedRegex.first_group("(?i)(S\\d{1,3})", "Show") == {:ok, ""}
      # .NET: Regex("ab").Match("ab").Groups[1].Value is empty.
      assert BoundedRegex.first_group("ab", "ab") == {:ok, ""}
      assert BoundedRegex.first_group("(x)|(a)", "a") == {:ok, ""}
    end

    test "a pattern with a named group is an error tag" do
      assert BoundedRegex.first_group("(?<x>a)(b)", "ab") ==
               {:error, {:not_supported, :named_group}}
    end
  end

  describe "split/2" do
    test "gives the text between matches" do
      assert BoundedRegex.split("[^\\w]+", "dune: part-two!") ==
               {:ok, ["dune", "part", "two", ""]}

      assert BoundedRegex.split("x", "abc") == {:ok, ["abc"]}
    end

    test "a pattern with a capture group is an error tag, as .NET adds each group to the parts" do
      # .NET rows: Regex.Split("a,b", "(,)") and "(?<sep>,)" each give [a; ,; b].
      assert BoundedRegex.split("(,)", "a,b") == {:error, {:not_supported, :split_group}}
      assert BoundedRegex.split("(?<sep>,)", "a,b") == {:error, {:not_supported, :split_group}}
      assert BoundedRegex.split("(?:,)", "a,b") == {:ok, ["a", "b"]}
    end
  end

  describe "translate/1 reads .NET-only pattern syntax as PCRE" do
    # Each `.NET` row ran in `dotnet fsi` (.NET 8.0.427): `Regex(pattern).IsMatch(subject)`.
    test "\\uXXXX becomes \\x{XXXX}, in a class too" do
      assert BoundedRegex.translate("\\u0430") == "\\x{0430}"
      assert BoundedRegex.translate("([\\u4e00-\\u9fff])") == "([\\x{4e00}-\\x{9fff}])"
      # .NET: `^а$` matches "а" (U+0430).
      assert BoundedRegex.first_group("(\\u0430)", "xаx") == {:ok, "а"}
      assert BoundedRegex.first_group("([\\s\\u00A0]+)", "a\u00A0b") == {:ok, "\u00A0"}
      # Fewer than four hex digits, or an escaped backslash before the u, stays as written.
      assert BoundedRegex.translate("\\u043") == "\\u043"
      assert BoundedRegex.translate("\\\\u0430") == "\\\\u0430"
    end

    test "the .NET block names v11 uses become PCRE scripts, and no other name does" do
      assert BoundedRegex.translate("[\\p{IsCyrillic}]+\\P{IsCyrillic}") ==
               "[\\p{Cyrillic}]+\\P{Cyrillic}"

      assert BoundedRegex.translate("\\p{IsCJKUnifiedIdeographs}\\P{IsCJKUnifiedIdeographs}") ==
               "\\p{Han}\\P{Han}"

      assert BoundedRegex.translate("\\p{IsGreek}\\p{IsFoo}") == "\\p{IsGreek}\\p{IsFoo}"
      assert BoundedRegex.first_group("([\\p{IsCyrillic}]+)", "Дюна 2") == {:ok, "Дюна"}
      assert BoundedRegex.first_group("(\\P{IsCyrillic})", "Дюна") == {:ok, ""}
      assert BoundedRegex.first_group("(\\P{IsCyrillic})", "Дa") == {:ok, "a"}
      assert BoundedRegex.first_group("(\\p{IsCJKUnifiedIdeographs})", "a沙") == {:ok, "沙"}
      assert BoundedRegex.first_group("(\\p{IsFoo})", "a") == {:error, :regex_invalid}
    end

    test "a script is wider than the .NET block, an accepted difference" do
      # .NET: `^\p{IsCyrillic}$` does not match U+0500 and `^\p{IsCJKUnifiedIdeographs}$` does
      # not match U+3400; the scripts Cinder reads take both.
      assert BoundedRegex.first_group("(\\p{IsCyrillic})", "Ԁ") == {:ok, "Ԁ"}

      assert BoundedRegex.first_group("(\\p{IsCJKUnifiedIdeographs})", "\u{20000}") ==
               {:ok, "\u{20000}"}

      assert BoundedRegex.first_group("(\\p{IsCJKUnifiedIdeographs})", "㐀") ==
               {:ok, "㐀"}
    end

    test "a - after a class escape inside a class is a literal -" do
      # .NET: `^[\s-_]$`, `^[\d-z]$` and `^[\p{L}-z]$` each match "-".
      assert BoundedRegex.translate("[\\w-_]") == "[\\w\\-_]"
      assert String.ends_with?(BoundedRegex.translate("[\\s-_]"), "\\x{3000}\\-_]")
      assert BoundedRegex.translate("[\\d-z][\\p{L}-z][\\W-]") == "[\\d\\-z][\\p{L}\\-z][\\W\\-]"
      assert BoundedRegex.first_group("(?i)T[\\s-_]?(\\d{1,2})", "T-05") == {:ok, "05"}
      assert BoundedRegex.first_group("([\\d-z]+)", "1-z") == {:ok, "1-z"}
      # A range, a - outside a class and a - after a literal stay as written.
      assert BoundedRegex.translate("[a-z]\\d-[\\u0041-Z]") == "[a-z]\\d-[\\x{0041}-Z]"
      # A ] first in a class is a literal, so the class runs on to the next ].
      assert BoundedRegex.translate("[]\\d-]") == "[]\\d\\-]"
      assert BoundedRegex.translate("[^]\\d-]") == "[^]\\d\\-]"
      assert BoundedRegex.translate("[\\]]\\d-") == "[\\]]\\d-"
    end

    test "a templated re_replace's pattern is translated too" do
      template = ~S'{{ re_replace .Keywords "[\u0430]" "б" }}'

      assert Template.render(template, %{".Keywords" => "aаa"}, ~U[2026-11-26 12:00:00Z]) ==
               {:ok, "aбa"}
    end

    test "a balancing group, which PCRE lacks, is a .NET-only pattern" do
      # .NET: `^(?:(?<o>\()|(?<-o>\))|[^()])*(?(o)(?!))$` matches "(a(b))".
      balancing = "^(?:(?<o>\\()|(?<-o>\\))|[^()])*(?(o)(?!))$"
      dotnet_only = {:error, {:not_supported, :dotnet_only}}
      assert BoundedRegex.first_group(balancing, "(a(b))") == dotnet_only
      assert BoundedRegex.check(balancing) == dotnet_only
      assert BoundedRegex.check("(?'a-b'x)") == dotnet_only
      assert BoundedRegex.check("(?<a-b>x)") == dotnet_only
      # An escaped or bracketed one is text, so the pattern compiles or fails as any other.
      assert BoundedRegex.check("\\(?<-o>") == :ok
      assert BoundedRegex.check("[(?<-o>]") == :ok
      assert BoundedRegex.check("(") == {:error, :regex_invalid}
      # A pattern that fails for another reason reads as invalid, not as .NET-only.
      assert BoundedRegex.check("\\(?<-o>)(") == {:error, :regex_invalid}
      assert BoundedRegex.check("[(?<-o>)](") == {:error, :regex_invalid}
    end

    test "a balancing group is .NET-only exactly where PCRE reads the same place as a group" do
      # Each pattern puts `(?<-c>` between a prefix of up to three characters that change how a
      # regex reads what follows (escapes, classes, groups and `(?#` comments) and a suffix of up
      # to three brackets and backslashes, which close what the prefix opened or leave the
      # pattern invalid. Whether that place opens a group depends on the prefix alone: PCRE reads
      # the prefix, then `(?<c>)`, then the first closing run of `)` and `]` that compiles, and
      # its name table says. A prefix no closing run compiles is skipped, and so is the `x` flag's
      # `#` comment, too long for a prefix. So is a pattern with a `(?` outside an escape before
      # anything but `#` or `<`, the only continuations of this alphabet on the allowlist: the
      # allowlist refuses it whatever the place reads.
      alphabet = ["\\", "[", "]", "^", "(", ")", "?", "#", "c"]
      closers = Enum.flat_map(0..3, &words([")", "]"], &1))
      suffixes = Enum.flat_map(0..3, &words([")", "]", "(", "\\"], &1))

      checked =
        for prefix <- Enum.flat_map(0..3, &words(alphabet, &1)),
            group? <- [opens_group?(prefix, closers)],
            group? != :unknown,
            suffix <- suffixes,
            pattern = prefix <> "(?<-c>" <> suffix,
            not (Regex.replace(~r/\\c.|\\./s, pattern, "_") =~ ~r/\(\?(?![#<])/) do
          {pattern, group?,
           BoundedRegex.check(pattern) == {:error, {:not_supported, :dotnet_only}}}
        end

      wrong = for {pattern, group?, dotnet_only?} <- checked, group? != dotnet_only?, do: pattern

      assert "[](?<-c>)](" in Enum.map(checked, &elem(&1, 0))
      assert Enum.count(checked, &elem(&1, 1)) > 1000
      assert Enum.count(checked, &(not elem(&1, 1))) > 1000
      assert Enum.take(wrong, 20) == []
    end

    test "\\s and \\S read .NET's white space, which lacks U+180E" do
      # .NET (`dotnet fsi`, 8.0.427, 2026-11-26) gives each row; PCRE's `\s` also takes U+180E,
      # so PuntoTorrent's `T[\s-_]?` would read `T` U+180E `05` as a season.
      for {pattern, subject, group} <- [
            {"(\\s)", "\u180E", ""},
            {"(\\s+)", "\u2000 \u3000\u0085\t", "\u2000 \u3000\u0085\t"},
            {"([\\s]+)", "\u180E \u3000", " \u3000"},
            {"(\\S+)", "a\u180Eb c", "a\u180Eb"},
            {"([\\S]+)", "a\u180Eb c", "a\u180Eb"},
            {"([^\\s]+)", "a\u180Eb c", "a\u180Eb"},
            {"([^\\S]+)", "\u180E \u00A0x", " \u00A0"},
            {"(?i)T[\\s-_]?(\\d{1,2})", "T\u180E05", ""},
            {"(?i)T[\\s-_]?(\\d{1,2})", "T 05", "05"},
            {"(?i)T[\\s-_]?(\\d{1,2})", "T-05", "05"},
            {"([\\s\\d]+)", "\u180E1 2", "1 2"}
          ] do
        assert {pattern, BoundedRegex.first_group(pattern, subject)} == {pattern, {:ok, group}}
      end
    end

    test "a class subtraction is a .NET-only pattern, a - that is a member is not" do
      # .NET subtracts in each refused row: `([\w-[0-9]]+)` on "ab12" gives "ab", where PCRE
      # would read `[\w\-[0-9]` and a literal `]`, and a look-behind before it does not hide the
      # subtraction. The rows after the look-behinds subtract after a range or an escape. In the
      # accepted rows .NET reads the `-` as a member, an escape or text, and gives the group
      # shown. Two kinds of pattern with no subtraction in .NET are refused all the same: a `--[`
      # that .NET reads as a range and a literal `[`, and a `#` comment of the `x` flag, which is
      # not read as a comment.
      dotnet_only = {:error, {:not_supported, :dotnet_only}}

      for pattern <- [
            "([\\w-[0-9]]+)",
            "([\\p{L}-[a-z]]+)",
            "([a-z-[aeiou]]+)",
            "([\\--[a]]+)",
            "([]-[a]]+)",
            "(?<=x)([\\w-[0-9]]+)",
            "(?<!y)([a-z-[aeiou]]+)",
            "([\\t-z--[a]]+)",
            "([\\cA-z--[a]]+)",
            "([!-\\x2D--[a]]+)",
            "([\\p{L}--[a]]+)"
          ] do
        assert {pattern, BoundedRegex.check(pattern)} == {pattern, dotnet_only}
        assert {pattern, BoundedRegex.first_group(pattern, "ab12")} == {pattern, dotnet_only}
      end

      for {pattern, subject, group} <- [
            {"([-[a]]+)", "-[a]", "a]"},
            {"([a\\-[b]]+)", "a-[b]", "b]"},
            {"(a-[b])", "a-b", "a-b"},
            {"([^-[a]]+)", "b-", ""},
            {"([[]-[a]]+)", "[a", ""},
            {"((?#[a-[b]])x)", "x", "x"}
          ] do
        assert {pattern, BoundedRegex.first_group(pattern, subject)} == {pattern, {:ok, group}}
      end

      # .NET reads no subtraction in these: on "-[!", "%-[" and "-[b]" it gives "-[!", "%-[" and
      # "b]".
      for pattern <- ["([!--[]+)", "([%--[]+)", "([---[b]]+)"] do
        assert {pattern, BoundedRegex.check(pattern)} == {pattern, dotnet_only}
      end

      assert BoundedRegex.check("(?x)(q) # [a-[b]]") == dotnet_only
    end

    test "a (? that opens no group on the allowlist is a .NET-only pattern (#1820, #1825)" do
      # The subtraction scan does not read a `#` comment of the `x` flag, which .NET ends at the
      # newline, so a comment can hide a subtraction from it. On "b!a\"[:Z" .NET 8.0.427 gives
      # "!" for the first two rows, a subtraction, and on "a]cbd" it gives group 1 "c" for the
      # fourth, where Cinder would give "": PCRE reads `[[:alpha:](?+x)]` as one class, and .NET
      # closes it at the first `]` and runs `(?+x)`. .NET reads `x` in either case and after `+`.
      # `(?-x)` turns it off and is refused all the same, as are the conditional, PCRE's own
      # groups, `(?)`, which .NET refuses, and a `(?` inside a class or a comment, which .NET reads
      # as text. `(?-)` sets no option in either engine.
      dotnet_only = {:error, {:not_supported, :dotnet_only}}

      for pattern <- [
            "(?x)(#(?#\n[!-[b]]+)",
            "(?x)(#[\n[]!-[b]]+)",
            "[[:alpha:](?+x)](#[\n[]!-[b]]+)",
            "[[:alpha:](?+x)](#[\n[]!-~-[b]]+)",
            "(?x)(a b)",
            "(?X)(a b)",
            "(?+x)(a b)",
            "(?i+x)(a b)",
            "(?ix)(a b)",
            "(?xi-m)(a b)",
            "(?x:(a b))",
            "(?ix:(a b))",
            "(?-x)(a b)",
            "(?i-x)(a b)",
            "(a)(?(1)b|c)",
            "(?|(a)|(b))",
            "(?P<n>a)",
            "[(?x)](a)",
            "(?#(?x))(a)",
            "(?)(a)"
          ] do
        assert {pattern, BoundedRegex.check(pattern)} == {pattern, dotnet_only}
        assert {pattern, BoundedRegex.first_group(pattern, "b!a\"[:Z")} == {pattern, dotnet_only}
      end

      # .NET 8.0.427 gives each group shown.
      for {pattern, subject, group} <- [
            {"(?i)(a b)", "A B", "A B"},
            {"(?#x)(a)", "a", "a"},
            {"(?i:(x))", "X", "X"},
            {"(?-i:(a))", "a", "a"},
            {"(?:(a))", "a", "a"},
            {"(?=a)(a)", "a", "a"},
            {"(?!b)(a)", "a", "a"},
            {"(?<=x)(a)", "xa", "a"},
            {"(?<!y)(a)", "xa", "a"},
            {"(?>(a))", "a", "a"},
            {"(?ms-i:(a))", "a", "a"},
            {"(?s)(a)", "a", "a"},
            {"(?-)(a)", "a", "a"}
          ] do
        assert {pattern, BoundedRegex.first_group(pattern, subject)} == {pattern, {:ok, group}}
      end
    end

    test "translate/1 leaves the character after \\c as written" do
      assert BoundedRegex.translate("\\c\\u0041") == "\\c\\u0041"
      assert BoundedRegex.translate("[\\c\\s-x]") == "[\\c\\s-x]"
    end

    test "check/1 refuses what the filters refuse" do
      assert BoundedRegex.check("(a)") == :ok
      assert BoundedRegex.check("(?<n>a)") == {:error, {:not_supported, :named_group}}
      assert BoundedRegex.check("\\C") == {:error, :regex_invalid}
      assert BoundedRegex.check(nil) == {:error, :regex_invalid}
    end
  end

  describe "limits and refusals" do
    test "a pattern holding \\C is invalid, as in .NET, through every entry point" do
      # `\C` matches one byte: a match could end inside `é`, where `:re.run/3` raises.
      assert BoundedRegex.replace("\\C", "éSECRET", "x", @cap) == {:error, :regex_invalid}
      assert BoundedRegex.split("\\C|", "éSECRET") == {:error, :regex_invalid}
      assert BoundedRegex.first_group("(\\C)", "é") == {:error, :regex_invalid}
      assert BoundedRegex.group_count("a\\C") == {:error, :regex_invalid}
      # Positive control: an escaped backslash before a C is a backslash and a C.
      assert BoundedRegex.first_group("(\\\\C)", "a\\Cb") == {:ok, "\\C"}
    end

    test "a \\c escape takes the next character, so \\c\\\\C still holds a \\C" do
      # `\c\` is the control character 0x1C, which .NET reads too; the `\C` after it is real.
      subject = <<0x1C>> <> "éSECRET"
      assert BoundedRegex.first_group("(\\c\\\\C)", subject) == {:error, :regex_invalid}
      assert BoundedRegex.replace("\\c\\\\C", subject, "x", @cap) == {:error, :regex_invalid}
      assert BoundedRegex.split("\\c\\\\C", subject) == {:error, :regex_invalid}
      # Positive control: `\c\C` is 0x1C then a literal C.
      assert BoundedRegex.first_group("(\\c\\C)", <<0x1C, ?C>>) == {:ok, <<0x1C, ?C>>}
    end

    test "no short escape or bracket pattern raises or gives text that is not UTF-8" do
      # The second review round on `\C` (#1670) found a bypass, so this runs every pattern of up
      # to five characters, the length of `\c\\C`, over the backslash, the escape letters `C`,
      # `c`, `Q` and `E` and the class and group brackets, on a subject holding a two-byte and a
      # control character, through each entry point.
      alphabet = ["\\", "C", "c", "Q", "E", "[", "]", "(", ")"]
      patterns = Enum.flat_map(1..5, &words(alphabet, &1))
      subject = <<0x1C>> <> "éC\\cQ"

      accepted = Enum.filter(patterns, &match?({:ok, _}, BoundedRegex.group_count(&1)))
      bad = Enum.reject(accepted, &utf8_results?(&1, subject))

      assert "\\c\\\\C" in patterns
      assert length(accepted) > 1000
      assert bad == []
    end

    test "patterns read Unicode word characters and boundaries, as .NET's do" do
      # Without `:ucp`, `\w` stops at `é` and `\b` falls between `é` and `F`.
      assert BoundedRegex.first_group("(\\w+)", "été") == {:ok, "été"}
      assert BoundedRegex.replace("\\bFRENCH", "éFRENCH", "x", @cap) == {:ok, "éFRENCH"}
    end

    test "a pattern that does not compile is an error tag" do
      assert BoundedRegex.replace("(", "x", "y", @cap) == {:error, :regex_invalid}
      assert BoundedRegex.first_group("(", "x") == {:error, :regex_invalid}
      assert BoundedRegex.split("(", "x") == {:error, :regex_invalid}
      assert BoundedRegex.first_group(<<0xFF>>, "x") == {:error, :regex_invalid}
    end

    test "a replacement or a budget of the wrong shape is an error tag" do
      assert BoundedRegex.replace("a", "a", nil, @cap) == {:error, :replacement_invalid}
      assert BoundedRegex.replace("a", "a", <<0xFF>>, @cap) == {:error, :replacement_invalid}
      assert BoundedRegex.replace("a", "a", "b", nil) == {:error, :replacement_invalid}
    end

    test "a subject that is not UTF-8 is an error tag" do
      assert BoundedRegex.first_group("a", <<0xFF>>) == {:error, :regex_subject}
      assert BoundedRegex.replace("a", <<0xFF>>, "b", @cap) == {:error, :regex_subject}
      assert BoundedRegex.split("a", <<0xFF>>) == {:error, :regex_subject}
    end

    test "a match past the limit is an error tag through every entry point" do
      assert BoundedRegex.first_group(@hostile, @hostile_subject) == {:error, :regex_limit}
      assert BoundedRegex.replace(@hostile, @hostile_subject, "x", @cap) == {:error, :regex_limit}
      # split refuses a capture group, so it runs the same pattern with a non-capturing one.
      assert BoundedRegex.split("^(?:\\w+\\s?)+$", @hostile_subject) == {:error, :regex_limit}
      # Positive control: the same pattern on a subject it matches.
      assert BoundedRegex.first_group(@hostile, "aa a") == {:ok, "a"}
    end

    test "Torrent9's title pattern runs on a subject the size of the output cap" do
      # The largest need measured for #1670: a tenth of the limit is too low for it.
      pattern =
        "(?i)\\b(FRENCH|MULTI|TRUEFRENCH|VOSTFR|SUBFRENCH)\\b(.+?)(\\b((19|20)\\d{2})\\b)$"

      title = "Le Voyage Immobile FRENCH HDTV 1080p 2024 "
      body = String.duplicate(title, div(@cap, byte_size(title)))
      subject = String.duplicate("x", @cap - byte_size(body)) <> body
      assert byte_size(subject) == @cap
      assert {:ok, _} = BoundedRegex.replace(pattern, subject, "$3 $1$2", 2 * @cap)
    end

    test "a pattern cannot raise its own limit" do
      raised = "(*LIMIT_MATCH=100000000)" <> @hostile
      assert BoundedRegex.first_group(raised, @hostile_subject) == {:error, :regex_limit}
    end

    test "no short pattern of the translated escapes raises or gives text that is not UTF-8" do
      # The translation rewrites `\u`, `\p{..}` and a `-` after a class escape before the compile,
      # so this runs every pattern of up to five characters over the characters those rules read.
      alphabet = ["\\", "u", "p", "{", "}", "[", "]", "-", "s", "C"]
      patterns = Enum.flat_map(1..5, &words(alphabet, &1))
      subject = "-é\\up{}[]s"

      for pattern <- patterns do
        assert is_binary(BoundedRegex.translate(pattern))
      end

      accepted = Enum.filter(patterns, &match?({:ok, _}, BoundedRegex.group_count(&1)))
      bad = Enum.reject(accepted, &utf8_results?(&1, subject))

      assert "[\\s-s" in patterns
      assert length(accepted) > 1000
      assert bad == []
    end

    test "group counts come from the compiled pattern" do
      # `:re` keeps the count in an undocumented slot of the compiled pattern; a new OTP that
      # moves it turns these rows red.
      assert BoundedRegex.group_count("abc") == {:ok, 0}
      assert BoundedRegex.group_count("(a)(b)?(c)?") == {:ok, 3}
      assert BoundedRegex.group_count("[(]\\(x\\)(?:y)") == {:ok, 0}
    end
  end
end
