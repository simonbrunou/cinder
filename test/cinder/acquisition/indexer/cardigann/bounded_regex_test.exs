defmodule Cinder.Acquisition.Indexer.Cardigann.BoundedRegexTest do
  use ExUnit.Case, async: true

  alias Cinder.Acquisition.Indexer.Cardigann.BoundedRegex

  # 40 `a` then `!`: `^(\w+\s?)+$` backtracks through every split of the run before it fails.
  @hostile "^(\\w+\\s?)+$"
  @hostile_subject String.duplicate("a", 40) <> "!"
  @cap 65_536

  defp words(_alphabet, 0), do: [""]

  defp words(alphabet, n),
    do: for(word <- words(alphabet, n - 1), char <- alphabet, do: word <> char)

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

    test "group counts come from the compiled pattern" do
      # `:re` keeps the count in an undocumented slot of the compiled pattern; a new OTP that
      # moves it turns these rows red.
      assert BoundedRegex.group_count("abc") == {:ok, 0}
      assert BoundedRegex.group_count("(a)(b)?(c)?") == {:ok, 3}
      assert BoundedRegex.group_count("[(]\\(x\\)(?:y)") == {:ok, 0}
    end
  end
end
