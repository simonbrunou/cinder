defmodule Cinder.Acquisition.Indexer.Cardigann.TemplateTest do
  use ExUnit.Case, async: true

  alias Cinder.Acquisition.Indexer.Cardigann.Template

  @now ~U[2026-11-25 19:45:30Z]

  defp render(template, variables, opts \\ []),
    do: Template.render(template, variables, @now, opts)

  defp url_encode(value), do: URI.encode(value, &URI.char_unreserved?/1)

  describe "output_cap/0" do
    test "is 65_536 bytes" do
      assert Template.output_cap() == 65_536
    end
  end

  describe "text and simple variables" do
    test "text with no {{ comes back unchanged within the cap" do
      assert render("/search/x.html", %{}) == {:ok, "/search/x.html"}
      assert render("", %{}) == {:ok, ""}
    end

    test "a variable gives its value, and nil gives empty text" do
      vars = %{".Keywords" => "dune", ".Config.filter-id" => "2", ".Query.Season" => nil}
      assert render("q={{ .Keywords }}&f={{.Config.filter-id}}", vars) == {:ok, "q=dune&f=2"}
      assert render("[{{ .Query.Season }}]", vars) == {:ok, "[]"}
    end

    test "the evaluator fills .True, .False and .Today.Year, which the caller cannot change" do
      vars = %{".True" => "no", ".False" => "yes", ".Today.Year" => "1999"}

      assert render("{{ .True }}|{{ .False }}|{{ .Today.Year }}", vars) ==
               {:ok, "True||2026"}
    end

    test "a substituted value is never read again as template text" do
      vars = %{".Keywords" => "{{ .Config.apikey }}", ".Config.apikey" => "s3cr3t"}
      assert render("{{ .Keywords }}", vars) == {:ok, "{{ .Config.apikey }}"}
    end
  end

  describe "if" do
    test "keeps A for a non-blank value and B for nil" do
      template = "{{ if .Config.flag }}{{ .Keywords }}{{ else }}home{{ end }}"

      assert render(template, %{".Config.flag" => ".True", ".Keywords" => "dune"}) ==
               {:ok, "dune"}

      assert render(template, %{".Config.flag" => nil, ".Keywords" => "dune"}) == {:ok, "home"}
    end

    test "a whitespace-only value and an empty list are false, a non-empty list true" do
      template = "{{ if .X }}A{{ else }}B{{ end }}"
      assert render(template, %{".X" => " \t "}) == {:ok, "B"}
      assert render(template, %{".X" => []}) == {:ok, "B"}
      assert render(template, %{".X" => ["1"]}) == {:ok, "A"}
      assert render(template, %{".X" => "x"}) == {:ok, "A"}
    end

    test "an empty branch gives empty text" do
      template = "{{ if .Keywords }}{{ else }}2{{ end }}"
      assert render(template, %{".Keywords" => "dune"}) == {:ok, ""}
      assert render(template, %{".Keywords" => nil}) == {:ok, "2"}
    end

    test "a condition that is not a variable is an error tag" do
      for template <- [
            ~S'{{ if "x" }}A{{ else }}B{{ end }}',
            "{{ if foo }}A{{ else }}B{{ end }}",
            "{{ if }}A{{ else }}B{{ end }}"
          ] do
        assert render(template, %{}) == {:error, {:template, :if_condition}}
      end
    end

    test "an if with no else, an else or end with no if, and an open block are error tags" do
      assert render("{{ if .X }}A{{ end }}", %{".X" => "1"}) ==
               {:error, {:template, :if_without_else}}

      assert render("A{{ else }}B", %{}) == {:error, {:template, :unexpected_else}}
      assert render("A{{ end }}", %{}) == {:error, {:template, :unexpected_end}}

      assert render("{{ if .X }}A{{ else }}B", %{".X" => "1"}) ==
               {:error, {:template, :unclosed_block}}

      assert render("{{ if .X }}A{{ else }}B{{ else }}C{{ end }}", %{".X" => "1"}) ==
               {:error, {:template, :unexpected_else}}
    end
  end

  describe "logic functions" do
    test "and, eq and ne nest, inner calls first" do
      template = ~S'{{ if and (eq .Result.a "1") (ne .Result.b "YES") }}x{{ else }}y{{ end }}'
      assert render(template, %{".Result.a" => "1", ".Result.b" => "NO"}) == {:ok, "x"}
      assert render(template, %{".Result.a" => "1", ".Result.b" => "YES"}) == {:ok, "y"}
      assert render(template, %{".Result.a" => "2", ".Result.b" => "NO"}) == {:ok, "y"}
    end

    test "Nyaa.si's doubly nested condition" do
      template =
        ~S'{{ if and (and (eq .Result.a "1") (ne .Result.b "YES")) (eq .Result.c "NULL") }}' <>
          "S01{{ else }}none{{ end }}"

      vars = %{".Result.a" => "1", ".Result.b" => "NO", ".Result.c" => "NULL"}
      assert render(template, vars) == {:ok, "S01"}
      assert render(template, %{vars | ".Result.c" => "S02"}) == {:ok, "none"}
    end

    test "and gives the first blank variable, else the last one, ignoring literals" do
      vars = %{".A" => "a", ".B" => nil, ".C" => "c", ".D" => "  "}
      assert render(~S'{{ and .A "lit" .C }}', vars) == {:ok, "c"}
      assert render("{{ and .B .A }}", vars) == {:ok, ""}
      assert render("{{ and (.A) (.D) (.C) }}", vars) == {:ok, "  "}
      assert render("{{ if and .A .B }}T{{ else }}F{{ end }}", vars) == {:ok, "F"}
      assert render("{{ if and .A .C }}T{{ else }}F{{ end }}", vars) == {:ok, "T"}
    end

    test "or gives the first non-blank variable, else the last one" do
      vars = %{".A" => "a", ".B" => nil, ".C" => "c", ".D" => " "}
      assert render("{{ or (.B) (.A) }}", vars) == {:ok, "a"}
      assert render("{{ or .B .D }}", vars) == {:ok, " "}
      assert render("{{ or .A .C }}", vars) == {:ok, "a"}
      assert render(~S'{{ or "lit" .B .C }}', vars) == {:ok, "c"}
    end

    test "and and or over literals alone are an error tag" do
      assert render(~S'{{ and "a" "b" }}', %{}) == {:error, {:template, :logic_arguments}}
      assert render(~S'{{ or "a" "b" }}', %{}) == {:error, {:template, :logic_arguments}}
    end

    test "eq is true for equal values, two nils and a literal without its quotes" do
      template = fn call -> "{{ if #{call} }}T{{ else }}F{{ end }}" end
      vars = %{".N1" => nil, ".N2" => nil, ".A" => "1", ".B" => "1", ".C" => "2"}
      assert render(template.("eq .N1 .N2"), vars) == {:ok, "T"}
      assert render(template.("eq .A .B"), vars) == {:ok, "T"}
      assert render(template.("eq .A .C"), vars) == {:ok, "F"}
      assert render(template.(~S'eq .A "1"'), vars) == {:ok, "T"}
      assert render(template.(~S'eq .N1 ""'), vars) == {:ok, "F"}
      assert render(template.("ne .A .C"), vars) == {:ok, "T"}
      assert render(template.("ne .N1 .N2"), vars) == {:ok, "F"}
      # A list compares as nil, as Prowlarr's `as string` reads it.
      assert render(template.("eq .L .N1"), Map.put(vars, ".L", ["1"])) == {:ok, "T"}
      lists = Map.merge(vars, %{".L" => ["1"], ".M" => ["2"]})
      assert render(template.("eq .L .M"), lists) == {:ok, "T"}
      # eq reads its first two arguments only.
      assert render(template.(~S'eq .A "1" .C'), vars) == {:ok, "T"}
    end

    test "a call with one argument, or an unparenthesized inner call, is an error tag" do
      assert render("{{ and .A }}", %{".A" => "1"}) == {:error, {:template, :logic_arguments}}

      assert render("{{ and .A eq .A .A }}", %{".A" => "1"}) ==
               {:error, {:template, :logic_arguments}}

      assert render(~S'{{ if and eq .A "1" .A }}T{{ else }}F{{ end }}', %{".A" => "1"}) ==
               {:error, {:template, :logic_arguments}}
    end
  end

  describe "re_replace, join and range" do
    test "re_replace replaces every match of the value, .NET syntax included" do
      template = ~S'{{ re_replace .Keywords "\b0(\d{1})\b" "$1" }}'
      assert render(template, %{".Keywords" => "show 05"}) == {:ok, "show 5"}
      assert render(template, %{".Keywords" => nil}) == {:ok, ""}
    end

    test "Nyaa.si's second search input" do
      template =
        ~S'{{ if .Keywords }}{{ re_replace .Keywords "\b0(\d{1})\b" "$1" }}{{ else }}{{ end }}'

      assert render(template, %{".Keywords" => "kaiju 07"}) == {:ok, "kaiju 7"}
      assert render(template, %{".Keywords" => nil}) == {:ok, ""}
    end

    test "a re_replace result that holds template text stays literal" do
      template = ~S'{{ re_replace .Keywords "x" "{{ .Config.apikey }}" }}'
      vars = %{".Keywords" => "x", ".Config.apikey" => "s3cr3t"}
      assert render(template, vars) == {:ok, "{{ .Config.apikey }}"}
    end

    test "join joins a list" do
      assert render(~S'{{ join .Categories "," }}', %{".Categories" => ["1", "2"]}) ==
               {:ok, "1,2"}

      assert render(~S'{{ join .Categories "," }}', %{".Categories" => []}) == {:ok, ""}
    end

    test "range repeats its body per element, with the optional index" do
      vars = %{".Categories" => ["1_0", "1_2"]}
      assert render("{{ range .Categories }}c={{.}}&{{end}}", vars) == {:ok, "c=1_0&c=1_2&"}

      assert render("{{ range $i, $e := .Categories }}{{$i}}={{ . }};{{ end }}", vars) ==
               {:ok, "0=1_0;1=1_2;"}

      assert render("{{ range .Categories }}c={{.}}&{{end}}", %{".Categories" => []}) == {:ok, ""}
    end

    test "a value of the wrong shape is an error tag" do
      assert render(~S'{{ join .X "," }}', %{".X" => "a"}) == {:error, {:template, :not_a_list}}

      assert render("{{ range .X }}{{.}}{{end}}", %{".X" => nil}) ==
               {:error, {:template, :not_a_list}}

      assert render("{{ .X }}", %{".X" => ["a"]}) == {:error, {:template, :not_text}}

      assert render(~S'{{ re_replace .X "a" "b" }}', %{".X" => ["a"]}) ==
               {:error, {:template, :not_text}}
    end

    test "{{.}} outside a range, and an unknown action, are error tags" do
      assert render("{{.}}", %{}) == {:error, {:template, :unsupported_action}}
      assert render("{{ $i }}", %{}) == {:error, {:template, :unsupported_action}}

      assert render("{{ printf .X }}", %{".X" => "a"}) ==
               {:error, {:template, :unsupported_action}}

      assert render("{{- .X }}", %{".X" => "a"}) == {:error, {:template, :unsupported_action}}
      assert render("a {{ .X", %{".X" => "a"}) == {:error, {:template, :unclosed_action}}

      assert render(~S'{{ re_replace .X "a }}', %{".X" => "a"}) ==
               {:error, {:template, :unclosed_action}}

      assert render(~S'{{ re_replace .X "a" }}', %{".X" => "a"}) ==
               {:error, {:template, :unsupported_action}}
    end

    test "a pattern past the match limit is an error tag" do
      template = ~S'{{ re_replace .X "^(\w+\s?)+$" "y" }}'

      assert render(template, %{".X" => String.duplicate("a", 40) <> "!"}) ==
               {:error, :regex_limit}

      assert render(template, %{".X" => "aa a"}) == {:ok, "y"}
    end
  end

  describe "unknown variables" do
    test "are an error tag naming the construct" do
      for {template, construct} <- [
            {"{{ .Nope }}", :variable},
            {"{{ if .Nope }}A{{ else }}B{{ end }}", :if},
            {~S'{{ re_replace .Nope "a" "b" }}', :re_replace},
            {~S'{{ join .Nope "," }}', :join},
            {"{{ range .Nope }}{{.}}{{end}}", :range},
            {"{{ and .Nope .A }}", :and},
            {"{{ or .A .Nope }}", :or},
            {~S'{{ eq .Nope "1" }}', :eq},
            {~S'{{ ne "1" .Nope }}', :ne}
          ] do
        assert render(template, %{".A" => ""}) == {:error, {:unknown_variable, construct}}
      end
    end

    test "only the branch an if keeps is evaluated" do
      assert render("{{ if .A }}{{ .Nope }}{{ else }}B{{ end }}", %{".A" => nil}) == {:ok, "B"}
    end
  end

  describe "input of the wrong shape" do
    test "is an error tag, never a raise" do
      assert render(nil, %{}) == {:error, {:template, :invalid_input}}
      assert render("{{ .X }}", nil) == {:error, {:template, :invalid_input}}
      assert Template.render("x", %{}, nil) == {:error, {:template, :invalid_input}}
    end
  end

  describe "the modifier" do
    test "encodes each substituted value, never the template text" do
      opts = [modifier: &url_encode/1]

      assert render("/search/{{ .Keywords }}.html", %{".Keywords" => "a b"}, opts) ==
               {:ok, "/search/a%20b.html"}

      vars = %{".K" => "a b", ".L" => ["x y", "z"], ".F" => ".True"}
      assert render(~S'{{ re_replace .K "a" "c/" }}', vars, opts) == {:ok, "c%2F%20b"}
      assert render(~S'{{ join .L "+" }}', vars, opts) == {:ok, "x%20y%2Bz"}
      assert render("{{ range .L }}c={{.}}&{{end}}", vars, opts) == {:ok, "c=x%20y&c=z&"}
      assert render("{{ if .F }}a b/{{ else }}c{{ end }}", vars, opts) == {:ok, "a b/"}
      assert render("{{ or .K .F }}", vars, opts) == {:ok, "a%20b"}
    end

    test "leaves a range index unchanged" do
      vars = %{".L" => ["x"]}
      opts = [modifier: &("[" <> &1 <> "]")]
      assert render("{{ range $i, $e := .L }}{{$i}}={{.}}{{ end }}", vars, opts) == {:ok, "0=[x]"}
    end

    test "runs after a join or a re_replace result is counted against the budget" do
      opts = [max_bytes: 3, modifier: fn _value -> "x" end]

      assert render(~S'{{ join .X "" }}', %{".X" => ["abcd"]}, opts) ==
               {:error, :filter_output_cap}

      assert render(~S'{{ re_replace .X "a" "abcd" }}', %{".X" => "a"}, opts) ==
               {:error, :filter_output_cap}

      assert render("{{ .X }}", %{".X" => "abcd"}, opts) == {:ok, "x"}
    end
  end

  describe "the output cap" do
    test "an output of exactly the cap passes and one byte more fails" do
      at_cap = String.duplicate("a", 65_536)
      assert render("{{ .X }}", %{".X" => at_cap}) == {:ok, at_cap}
      assert render("{{ .X }}!", %{".X" => at_cap}) == {:error, :filter_output_cap}
      assert render("{{ .X }}", %{".X" => at_cap <> "a"}) == {:error, :filter_output_cap}
      assert render(at_cap <> "!", %{}) == {:error, :filter_output_cap}
    end

    test "a range, a join and a re_replace past the cap fail" do
      list = List.duplicate(String.duplicate("a", 1024), 64)
      assert {:ok, _} = render(~S'{{ join .L "" }}', %{".L" => list})
      assert render(~S'{{ join .L "," }}', %{".L" => list}) == {:error, :filter_output_cap}

      assert render("{{ range .L }}{{.}},{{end}}", %{".L" => list}) ==
               {:error, :filter_output_cap}

      half = String.duplicate("a", 32_768)
      assert {:ok, _} = render(~S'{{ re_replace .X "(a)" "$1$1" }}', %{".X" => half})

      assert render(~S'{{ re_replace .X "(a)" "$1$1" }}', %{".X" => half <> "a"}) ==
               {:error, :filter_output_cap}
    end

    test "max_bytes lowers the cap and never raises it" do
      assert render("{{ .X }}", %{".X" => "abcd"}, max_bytes: 3) == {:error, :filter_output_cap}
      big = String.duplicate("a", 65_537)

      assert render("{{ .X }}", %{".X" => big}, max_bytes: 100_000) ==
               {:error, :filter_output_cap}
    end
  end
end
