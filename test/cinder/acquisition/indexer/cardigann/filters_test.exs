defmodule Cinder.Acquisition.Indexer.Cardigann.FiltersTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Cinder.Acquisition.Indexer.Cardigann.Filters

  @now ~U[2026-11-25 19:45:30Z]
  @hostile "^(\\w+\\s?)+$"
  @hostile_subject String.duplicate("a", 40) <> "!"

  defp f(name, args \\ nil), do: %{name: name, args: args}
  defp run(input, filters, vars \\ %{}), do: Filters.apply(input, filters, vars, @now)

  describe "supported/0" do
    test "lists the seven filters of this slice" do
      assert Filters.supported() ==
               ~w(append dateparse re_replace regexp replace split trim)
    end
  end

  describe "each filter" do
    test "split splits on the first character of its separator, from the end when negative" do
      assert run("/?c=1_2", [f("split", ["=", "-1"])]) == {:ok, "1_2"}
      assert run("/?c=1_2", [f("split", ["=", "-1"]), f("split", ["_", "0"])]) == {:ok, "1"}
      assert run("a=b=c", [f("split", ["=x", "1"])]) == {:ok, "b"}
      assert run("a=b=c", [f("split", ["=", "-3"])]) == {:ok, "a"}
    end

    test "split outside the parts, or with a bad argument, is an error tag" do
      assert run("a=b", [f("split", ["=", "2"])]) == {:error, :split_index}
      assert run("a=b", [f("split", ["=", "-3"])]) == {:error, :split_index}
      assert run("a=b", [f("split", ["=", "x"])]) == {:error, {:filter_args, "split"}}
      assert run("a=b", [f("split", ["", "0"])]) == {:error, {:filter_args, "split"}}
      assert run("a=b", [f("split", "=")]) == {:error, {:filter_args, "split"}}
    end

    test "regexp gives the first match's group 1, empty text when nothing matches" do
      assert run("Show S02E01", [f("regexp", "(?i)(S\\d{1,3})")]) == {:ok, "S02"}
      assert run("Show", [f("regexp", "(?i)(S\\d{1,3})")]) == {:ok, ""}
      assert run("Show", [f("regexp", ["(S)"])]) == {:error, {:filter_args, "regexp"}}
    end

    test "re_replace evaluates its replacement as a template, then replaces every match" do
      vars = %{".Config.multilanguage" => "MULTi FRENCH"}

      assert run(
               "Film MULTI 1080p",
               [f("re_replace", ["(?i)\\b(MULTI)\\b", "{{ .Config.multilanguage }}"])],
               vars
             ) ==
               {:ok, "Film MULTi FRENCH 1080p"}

      assert run("a b", [f("re_replace", ["\\s+", " "]), f("re_replace", ["(a) (b)", "$2-$1"])]) ==
               {:ok, "b-a"}
    end

    test "re_replace with Nyaa.si's nested condition and group references" do
      replacement =
        "$1$2$3{{ if and (.Config.radarr_compatibility) (.Result.title_keyword_year) }} " <>
          "{{ .Result.title_keyword_year }} $4{{ else }}$4{{ end }}"

      step = [f("re_replace", ["^(\\[.+?\\] ?)?(\\[.+?\\] ?)?(.+?)(\\[)", replacement])]
      title = "[Grp] Kaiju Harbor [1080p]"
      on = %{".Config.radarr_compatibility" => ".True", ".Result.title_keyword_year" => "2024"}
      off = %{on | ".Config.radarr_compatibility" => nil}
      # $3 keeps the space before `[`; Nyaa.si's later `\s+` step folds the two spaces.
      assert run(title, step, on) == {:ok, "[Grp] Kaiju Harbor  2024 [1080p]"}
      assert run(title, step, off) == {:ok, "[Grp] Kaiju Harbor [1080p]"}
    end

    test "re_replace inserts a bracketed $0, $&, $$, $1, $` or ${x} variable as text" do
      step = [f("re_replace", ["a", "[{{ .X }}]"])]

      for value <- ["$0", "$&", "$$", "$1", "$`", "${x}"] do
        assert {value, run("ab", step, %{".X" => value})} == {value, {:ok, "[#{value}]b"}}
      end
    end

    test "re_replace still reads a $ written in its replacement as replacement syntax" do
      step = [f("re_replace", ["a", "[{{ .X }}]$0"])]
      # The inserted $0 is text and the written $0 is the match.
      assert run("ab", step, %{".X" => "$0"}) == {:ok, "[$0]ab"}
    end

    test "re_replace inserts a $ from or, and, join, range or a nested re_replace as text" do
      vars = %{".X" => "$0", ".L" => ["$0", "$`"]}

      for {replacement, expected} <- [
            {"{{ or .X \"z\" }}", "$0"},
            {"{{ and .X .X }}", "$0"},
            {"{{ join .L \",\" }}", "$0,$`"},
            {"{{ range .L }}{{.}}{{ end }}", "$0$`"},
            {"{{ re_replace .X \"z\" \"y\" }}", "$0"}
          ] do
        result = run("a", [f("re_replace", ["a", replacement])], vars)
        assert {replacement, result} == {replacement, {:ok, expected}}
      end
    end

    test "re_replace's eq condition reads a variable's $ before it is escaped" do
      step = [f("re_replace", ["a", "{{ if eq .X \"$0\" }}Y{{ else }}N{{ end }}"])]
      assert run("a", step, %{".X" => "$0"}) == {:ok, "Y"}
    end

    test "re_replace still joins a $ written right before an inserted value with it (#1786)" do
      step = [f("re_replace", ["a", "${{ .X }}"])]
      # The written $ pairs with the first $ of the escaped $$0, so $0 then reads as the match.
      assert run("ab", step, %{".X" => "$0"}) == {:ok, "$ab"}
      assert run("ab", step, %{".X" => "0"}) == {:ok, "ab"}
    end

    test "replace and append insert a template's $ as text, with no escaping" do
      vars = %{".X" => "$0$$"}
      assert run("a.b", [f("replace", [".", "{{ .X }}"])], vars) == {:ok, "a$0$$b"}
      assert run("a", [f("append", "{{ .X }}$1")], vars) == {:ok, "a$0$$$1"}
    end

    test "replace replaces every literal occurrence, its target a template" do
      assert run("a b c", [f("replace", [" ", "-"])]) == {:ok, "a-b-c"}
      assert run("a.b", [f("replace", [".", "{{ .X }}"])], %{".X" => "*"}) == {:ok, "a*b"}
      assert run("a.b", [f("replace", ["", "x"])]) == {:error, {:filter_args, "replace"}}
    end

    test "append appends its argument evaluated as a template" do
      assert run("Title", [f("append", " Spanish")]) == {:ok, "Title Spanish"}
      assert run("S01", [f("append", "{{ .X }}")], %{".X" => "NULL"}) == {:ok, "S01NULL"}
    end

    test "trim trims whitespace, or its argument's first character at both ends" do
      assert run("  x ", [f("trim")]) == {:ok, "x"}
      # .NET's String.Trim() also trims a no-break space and an em space.
      assert run(<<0xA0::utf8>> <> " x" <> <<0x2003::utf8>>, [f("trim")]) == {:ok, "x"}
      assert run("--x--", [f("trim", "-+")]) == {:ok, "x"}
      assert run("x", [f("trim", "")]) == {:error, {:filter_args, "trim"}}
    end

    test "dateparse writes the canonical text, and leaves text it cannot read unchanged" do
      filters = [f("append", " -00:00"), f("dateparse", "yyyy-MM-dd HH:mm zzz")]
      assert run("2026-11-25 14:02", filters) == {:ok, "2026-11-25T14:02:00Z"}
      assert run("25/11/2026", [f("dateparse", "dd/MM/yyyy")]) == {:ok, "2026-11-25T00:00:00Z"}
      assert run("garbage", [f("dateparse", "yyyy-MM-dd")]) == {:ok, "garbage"}

      assert run("2026", [f("dateparse", "yyyy fff")]) ==
               {:error, {:not_supported, {:date_layout, "fff"}}}
    end

    test "a filter outside this slice is a not-supported tag" do
      assert run("x", [f("base64decode")]) ==
               {:error, {:not_supported, {:filter, "base64decode"}}}

      assert run("x", [f("trim"), f("tolower")]) ==
               {:error, {:not_supported, {:filter, "tolower"}}}
    end

    test "input of the wrong shape is an error tag, never a raise" do
      assert Filters.apply(nil, [], %{}, @now) == {:error, :filter_invalid}
      assert Filters.apply("x", nil, %{}, @now) == {:error, :filter_invalid}
      assert run("x", [%{args: "y"}]) == {:error, :filter_invalid}
      assert run("x", ["trim"]) == {:error, :filter_invalid}
      assert run("x", [%{name: 42, args: nil}]) == {:error, :filter_invalid}
      refute Filters.andmatch?(nil, "Dune", nil)
    end

    test "an empty list gives the input" do
      assert run("x", []) == {:ok, "x"}
    end
  end

  describe "the match limit" do
    test "ends the chain through regexp, re_replace and a template's re_replace" do
      template = ~s'{{ re_replace .X "#{@hostile}" "y" }}'

      for filters <- [
            [f("regexp", @hostile)],
            [f("re_replace", [@hostile, "y"])],
            [f("append", template)],
            [f("replace", ["a", template])]
          ] do
        assert run(@hostile_subject, filters, %{".X" => @hostile_subject}) ==
                 {:error, :regex_limit}

        # Positive control: the same chain on a subject the pattern matches.
        assert {:ok, _} = run("aa a", filters, %{".X" => "aa a"})
      end
    end
  end

  describe "the output cap" do
    test "a chain whose outputs sum to the cap passes, and one byte more fails" do
      at_half = String.duplicate("a", 32_768)
      assert run(at_half, [f("trim"), f("trim")]) == {:ok, at_half}
      assert run(at_half <> "a", [f("trim"), f("trim")]) == {:error, :filter_output_cap}
      at_cap = String.duplicate("a", 65_536)
      assert run(at_cap, [f("trim")]) == {:ok, at_cap}
      assert run(at_cap <> "a", [f("trim")]) == {:error, :filter_output_cap}
    end

    test "a template a step evaluates counts against the chain" do
      # Template 30,000 bytes plus output 30,000; then 40,000 plus 40,000 passes the cap.
      assert {:ok, _} = run("", [f("append", String.duplicate("b", 30_000))])
      assert run("", [f("append", String.duplicate("b", 40_000))]) == {:error, :filter_output_cap}
    end

    test "a doubling re_replace chain ends once the sum of its outputs passes the cap" do
      double = f("re_replace", ["(.+)", "$1$1"])
      start = String.duplicate("a", 1024)
      # Outputs 2, 4, 8, 16 and 32 KiB: 62 KiB in all.
      assert {:ok, out} = run(start, List.duplicate(double, 5))
      assert byte_size(out) == 32_768
      assert run(start, List.duplicate(double, 6)) == {:error, :filter_output_cap}
    end

    test "a re_replace charges the chain its escaped replacement" do
      step = [f("re_replace", ["a", "{{ .X }}"])]
      # N inserted `$` charge 2N bytes of escaped replacement plus N bytes of output.
      largest_fitting = String.duplicate("$", 21_845)
      assert run("a", step, %{".X" => largest_fitting}) == {:ok, largest_fitting}
      over = String.duplicate("$", 21_846)
      assert run("a", step, %{".X" => over}) == {:error, :filter_output_cap}
    end

    test "a replace or an append past the cap is an error tag" do
      assert run(String.duplicate("a", 20_000), [f("replace", ["a", "bbbb"])]) ==
               {:error, :filter_output_cap}

      assert {:ok, _} = run(String.duplicate("a", 10_000), [f("replace", ["a", "bbbb"])])
      # The appended template counts once and the output once: 65_534 + 1 + 1 is the cap.
      start = String.duplicate("a", 65_534)
      assert {:ok, _} = run(start, [f("append", "b")])
      assert run(start, [f("append", "bb")]) == {:error, :filter_output_cap}
    end
  end

  describe "errors and logs" do
    test "hold no subject, pattern, replacement or variable value" do
      secret = "Zx9secretQ"
      vars = %{".Config.apikey" => secret, ".X" => String.duplicate("a", 40) <> secret <> "!"}

      cases = [
        {secret <> String.duplicate(" a", 30_000), [f("trim"), f("trim")], :filter_output_cap},
        {String.duplicate("a", 40) <> "!" <> secret, [f("regexp", "^(\\w+\\s?)+$")],
         :regex_limit},
        {secret, [f("regexp", "(" <> secret)], :regex_invalid},
        {secret, [f("append", "{{ .Nope" <> secret <> " }}")], {:unknown_variable, :variable}},
        {secret, [f("re_replace", ["x(" <> secret <> ")?", "${" <> secret <> "}"])],
         {:not_supported, {:replacement, "${name}"}}},
        {secret, [f("append", "{{ re_replace .X \"^(\\w+\\s?)+$\" \"y\" }}")], :regex_limit},
        {"é" <> secret, [f("re_replace", ["\\C", "x"])], :regex_invalid},
        {<<0x1C>> <> "é" <> secret, [f("re_replace", ["\\c\\\\C", "x"])], :regex_invalid}
      ]

      for {input, filters, reason} <- cases do
        log = capture_log(fn -> send(self(), {:result, run(input, filters, vars)}) end)
        assert_received {:result, {:error, ^reason} = error}
        refute inspect(error, limit: :infinity, printable_limit: :infinity) =~ secret
        refute log =~ secret
      end
    end
  end

  describe "andmatch?/3" do
    test "keeps a row when two terms, or the only term, occur in the title or description" do
      for {query, title, description, keep?} <- [
            {"dune part two", "Dune Part Two 2024", nil, true},
            {"dune", "Dune Part Two 2024", nil, true},
            {"DUNE", "dune part two 2024", "", true},
            {"the matrix", "Dune Part Two 2024", nil, false},
            {"dune matrix", "Dune", "a matrix rip", true},
            {"dune matrix", "Dune", "a rip", false},
            {"dune matrix", "Dune", nil, false},
            {"the an", "the an", "the an", false},
            {"", "Dune", nil, false},
            {"a b c", "a b c", nil, false},
            # 2 of 3 terms is enough; a term may match inside a word.
            {"dune part three", "Dune Part Two", nil, true},
            {"dune: part-two!", "Dune Part Two", nil, true},
            {"AND OF dune", "Dune", nil, true},
            {"é dune", "Dune", nil, true},
            # .NET's \w excludes ³ (a No digit), so it splits the term.
            {"ab³cd", "ab cd", nil, true}
          ] do
        cell = {query, title, description, Filters.andmatch?(query, title, description)}
        assert cell == {query, title, description, keep?}
      end
    end
  end
end
