defmodule Cinder.Indexers.SelectorTest do
  use ExUnit.Case, async: true

  alias Cinder.Indexers.Selector

  defp compile(selector), do: Selector.compile(selector, "t")

  describe "the gate's refusals" do
    test "a CSS comment outside quotes is :comment, inside quotes it passes" do
      assert compile("td /* x */ b") == {:error, :comment}
      assert compile("td:has(b /* ):not([x=\" */ :foo /* \"])") == {:error, :comment}
      # The argument reader stops at the comment, before the quote it hides opens a string.
      assert compile(~S|td:has(b /* " */)|) == {:error, :comment}
      assert {:ok, %{whole: ~S|a[title="/* x */"]|}} = compile(~S|a[title="/* x */"]|)
    end

    test "a backslash outside quotes is :escape, inside quotes it passes" do
      assert compile(~S|img[src$=\"/f.gif\"]|) == {:error, :escape}
      assert compile(~S|td:has(img[src$=\"/f.gif\"])|) == {:error, :escape}
      assert {:ok, %{whole: ~S|a[title="a\"b"]|}} = compile(~S|a[title="a\"b"]|)
    end

    test "a template is :template" do
      assert compile("a[href*=\"{{ .Config.x }}\"]") == {:error, :template}
    end

    test "an unclosed quote or parenthesis, or a stray ) is :structure" do
      for selector <- ["td:has(b", ~S|a[title="x]|, "td)", "td:not(b", ":contains(\"x\""] do
        assert compile(selector) == {:error, :structure}, selector
      end
    end

    test "an empty argument item is :structure" do
      for selector <- ["td:has()", "td:has(b,)", "td:is(, b)", "td:where( )"] do
        assert compile(selector) == {:error, :structure}, selector
      end
    end

    test "a relative item is :structure in :is() and :where(), and runs as * <item> in :has()" do
      assert compile("td:is(> b)") == {:error, :structure}
      assert compile("td:where(+ b)") == {:error, :structure}
      assert compile("td:is(b, ~ i)") == {:error, :structure}

      assert {:ok, %{parts: ["td[cinder-t-f]", "* > b", "* ~ i"], whole: "td:has(> b, ~ i)"}} =
               compile("td:has(> b, ~ i)")
    end

    test "a line break inside a quoted string is :structure" do
      for char <- ["\n", "\r", "\f"] do
        assert compile(~s|a[title="x#{char}y"]|) == {:error, :structure}, inspect(char)
      end

      assert {:ok, _compiled} = compile("td\nb")
    end

    test "a NUL byte or bytes that are not UTF-8 are :structure" do
      assert compile("td\0b") == {:error, :structure}
      assert compile(<<"td", 0xFF>>) == {:error, :structure}
    end

    test "a selector of 4,096 bytes passes and one of 4,097 is :structure" do
      assert Selector.max_bytes() == 4096
      assert {:ok, _compiled} = compile(String.duplicate("b", 4096))
      assert compile(String.duplicate("b", 4097)) == {:error, :structure}
    end

    test "8 nested parentheses pass and 9 are :structure, quoted ones aside" do
      assert Selector.max_depth() == 8
      nest = fn n -> String.duplicate("td:not(", n) <> "b" <> String.duplicate(")", n) end

      assert {:ok, _compiled} = compile(nest.(8))
      assert compile(nest.(9)) == {:error, :structure}
      assert {:ok, _compiled} = compile(~s|a[title="#{String.duplicate("(", 20)}"]|)
    end

    test "a :contains() argument with quotes outside one string is :structure" do
      assert compile(~S|td:contains("a" b)|) == {:error, :structure}
      assert compile(~S|td:contains(a"b)|) == {:error, :structure}
      assert compile(~S|td:contains(a"b"c)|) == {:error, :structure}
    end

    test "the read stops at the first refusal from the left" do
      assert compile(~S|a\b /* c */|) == {:error, :escape}
      assert compile(~S|a /* \b */|) == {:error, :comment}
    end
  end

  describe "the parts" do
    test "a selector without :has(), :is() or :where() has no parts" do
      assert compile("td:nth-child(2) a:not(.x)") ==
               {:ok, %{parts: [], whole: "td:nth-child(2) a:not(.x)", needles: []}}
    end

    test "the skeleton comes first, then each argument item, split on top-level commas" do
      assert {:ok,
              %{
                parts: [
                  "tr[cinder-t-f][cinder-t-f]",
                  "a[href]",
                  "img[src$=\"/x,y\"]",
                  "b:not(i, u)"
                ],
                whole: ~S|tr:has(a[href]):has(img[src$="/x,y"], b:not(i, u))|
              }} = compile(~S|tr:has(a[href]):has(img[src$="/x,y"], b:not(i, u))|)
    end

    test "nested arguments split again, and a pseudo-class name in any case counts" do
      assert {:ok, %{parts: ["td[cinder-t-f]", "b[cinder-t-f]", "i", ".x"], whole: whole}} =
               compile("td:HAS(b:Is(i, .x))")

      assert whole == "td:has(b:is(i, .x))"
    end

    test "an :is() or :where() inside another pseudo-class still splits" do
      assert {:ok, %{parts: ["td:not([cinder-t-f])", "b"], whole: "td:not(:where(b))"}} =
               compile("td:not(:where(b))")
    end
  end

  describe ":contains()" do
    test "a quoted, a single-quoted and an unquoted argument become marker attributes" do
      assert {:ok, %{whole: whole, needles: ["Free", "a b", "x"], parts: []}} =
               compile(~S|td:contains("Free") b:contains('a b') i:CONTAINS( x )|)

      assert whole == "td[cinder-t-c0] b[cinder-t-c1] i[cinder-t-c2]"
    end

    test "the same text gets the same marker" do
      assert {:ok, %{whole: "a[cinder-t-c0], b[cinder-t-c0]", needles: ["x"]}} =
               compile(~S|a:contains("x"), b:contains(x)|)
    end

    test "escapes in a quoted argument are read as CSS reads them" do
      assert {:ok, %{needles: [~S|a"b\c|]}} = compile(~S|a:contains("a\"b\\c")|)
      # One whitespace after a hex escape ends it and is dropped.
      assert {:ok, %{needles: ["AB"]}} = compile(~S|a:contains("\41 B")|)
      assert {:ok, %{needles: ["A B"]}} = compile(~S|a:contains("\41  B")|)
    end

    test "a :contains() inside :has() is rewritten in the whole and in its part" do
      assert {:ok,
              %{
                parts: ["td[cinder-t-f]", "h2[cinder-t-c0]"],
                whole: "td:has(h2[cinder-t-c0])",
                needles: ["x"]
              }} = compile(~S|td:has(h2:contains("x"))|)
    end

    test "the marker carries the token given" do
      assert Selector.marker("0f9a", 3) == "cinder-0f9a-c3"
      assert {:ok, %{whole: "a[cinder-0f9a-1-c0]"}} = Selector.compile("a:contains(x)", "0f9a-1")
    end
  end
end
