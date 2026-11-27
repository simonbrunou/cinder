defmodule Cinder.Acquisition.Indexer.Cardigann.XmlSelectorTest do
  # The strict grammar a selector on an XML answer passes before Floki reads it (#1678), and
  # Floki's answers on a SimpleForm tree for each form it lets through.
  use ExUnit.Case, async: true

  alias Cinder.Acquisition.Indexer.Cardigann.XmlSelector

  @tree [
    {"rss", [],
     [
       {"channel", [],
        [
          {"item", [{"id", "a"}, {"class", "big new"}], [{"title", [], ["One"]}]},
          {"item", [{"lang", "en-US"}],
           [{"title", [], ["Two"]}, {"attr", [{"name", "seeders"}, {"value", "4"}], []}]},
          {"Item", [], [{"title", [], ["Three"]}]}
        ]}
     ]}
  ]

  defp compiled!(selector) do
    assert {:ok, %{whole: whole, needles: []}} = XmlSelector.compile(selector, "t")
    whole
  end

  defp texts(selector),
    do: @tree |> Floki.find(compiled!(selector)) |> Enum.map(&Floki.text/1)

  test "each form the grammar reads compiles and Floki answers it as AngleSharp does" do
    for {selector, expected} <- [
          {"title", ["One", "Two", "Three"]},
          {"rss > channel > item > title", ["One", "Two"]},
          {"channel title", ["One", "Two", "Three"]},
          {"item#a", ["One"]},
          {"item.big", ["One"]},
          {"item.big.new", ["One"]},
          {"[lang]", ["Two"]},
          {"[lang=en-US]", ["Two"]},
          {~S([lang="en-US"]), ["Two"]},
          {"[lang='en-US']", ["Two"]},
          {"[lang|=en]", ["Two"]},
          {"[lang^=en]", ["Two"]},
          {"[lang$=US]", ["Two"]},
          {"[lang*=n-U]", ["Two"]},
          {"[class~=new]", ["One"]},
          {"[ name = seeders ]", [""]},
          {"item + item > title", ["Two"]},
          {"item ~ Item > title", ["Three"]},
          {"Item > title", ["Three"]},
          {"*#a > title", ["One"]},
          {"item#a > title, Item > title", ["One", "Three"]},
          {"  title  ", ["One", "Two", "Three"]}
        ] do
      assert {selector, texts(selector)} == {selector, expected}
    end
  end

  test ":contains goes through as a marker and a needle" do
    assert {:ok, %{whole: whole, needles: ["One"]}} =
             XmlSelector.compile(~S|title:contains("One")|, "t")

    refute whole =~ ":contains"
  end

  test "any other pseudo-class is refused by its name" do
    for {selector, name} <- [
          {"item:has(title)", "has"},
          {"item:not(.big)", "not"},
          {"item:empty", "empty"},
          {"item:first-child", "first-child"},
          {"item:nth-child(2)", "nth-child"},
          {"title:contains(\"x\"):root", "root"}
        ] do
      assert {selector, XmlSelector.compile(selector, "t")} ==
               {selector, {:error, {:xml_selector, name}}}
    end
  end

  test "anything else the grammar does not read is refused as invalid" do
    for selector <- [
          "",
          " ",
          ",",
          "item,",
          ", item",
          "item >",
          "> item",
          "item >> title",
          "1item",
          "--item",
          "#",
          ".",
          "#1",
          "[]",
          "[lang",
          "[lang=]",
          "[lang==x]",
          "[lang=en US]",
          "[lang!=x]",
          "[lang=\"x]",
          "[1=x]",
          "t\\:title",
          "item/*c*/",
          "{{ .Nope }}",
          "item:",
          ":#",
          "item::before",
          "item:" <> String.duplicate("a", 33),
          "item@x",
          "ns|item"
        ] do
      assert {selector, XmlSelector.compile(selector, "t")} ==
               {selector, {:error, {:xml_selector, :invalid}}}
    end
  end
end
