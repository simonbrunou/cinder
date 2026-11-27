defmodule Cinder.Acquisition.Indexer.Cardigann.JsonPathTest do
  # The answers below were read from `JToken.Parse(json).SelectToken(path)` in a run of
  # Newtonsoft.Json 13.0.4 on the .NET SDK 8.0.427 the flake pins, for #1678's PR, on the same JSON.
  use ExUnit.Case, async: true

  alias Cinder.Acquisition.Indexer.Cardigann.JsonPath

  @json ~S({"rows": [{"id": 1, "name": "A", "tags": ["x"]}, {"id": 2}],
            "data": {"data": [{"promotion_info": {"down_multiplier": 1}}]}, "n": null})

  setup do
    {:ok, root} = JsonPath.decode(@json)
    %{root: root}
  end

  defp at(root, path) do
    {:ok, steps} = JsonPath.parse(path)
    JsonPath.select(root, steps)
  end

  describe "decode/1" do
    test "keeps object order and a twice-written key's first place and last value" do
      assert {:ok, %Jason.OrderedObject{values: [{"b", 1}, {"a", 3}, {"c", 2}]}} =
               JsonPath.decode(~S({"b": 1, "a": 2, "c": 2, "a": 3}))
    end

    test "refuses what Jason refuses, Newtonsoft's lenient forms included" do
      for text <- ["", "  ", "nul", "{'a': 1}", "{a: 1}", ~S({"a": 1,}), ~S({"a": 1} // c)] do
        assert JsonPath.decode(text) == :error
      end
    end

    # The .NET run: `JToken.Parse` of 64 nested arrays, or an object holding 63, parses; one
    # more level throws `JsonReaderException` ("The reader's MaxDepth of 64 has been exceeded").
    test "takes 64 nested objects and arrays and refuses a 65th, as JToken.Parse does" do
      arrays = fn d -> String.duplicate("[", d) <> String.duplicate("]", d) end

      assert {:ok, _} = JsonPath.decode(arrays.(64))
      assert JsonPath.decode(arrays.(65)) == :error
      assert {:ok, _} = JsonPath.decode(~s({"data":#{arrays.(63)}}))
      assert JsonPath.decode(~s({"data":#{arrays.(64)}})) == :error
      assert {:ok, _} = JsonPath.decode(~s({"a":#{arrays.(63)},"b":#{arrays.(63)}}))
      assert JsonPath.decode(~s({"a":1,"b":[{"c":#{arrays.(63)}}]})) == :error
    end
  end

  describe "parse/1 and select/2" do
    test "read the path shapes of the v11 definitions", %{root: root} do
      assert {:ok, [_, _]} = at(root, "rows")
      assert at(root, "rows[0].name") == {:ok, "A"}
      assert at(root, "$") == {:ok, root}
      assert at(root, "") == {:ok, root}
      assert {:ok, [_, _]} = at(root, "$.rows")
      assert at(root, "$.rows[1].id") == {:ok, 2}
      assert at(root, "data.data[0].promotion_info.down_multiplier") == {:ok, 1}
      assert at(root, "rows[0].tags[0]") == {:ok, "x"}
      assert at(root, "n") == {:ok, nil}
    end

    test "select nothing where SelectToken gives null", %{root: root} do
      assert at(root, "rows[5]") == :none
      assert at(root, "rows.id") == :none
      assert at(root, "missing") == :none
      assert at(root, "$[0]") == :none
      assert at(root, "rows[0].name.x") == :none
    end

    test "$[0].id indexes an array root" do
      {:ok, root} = JsonPath.decode(~S([{"id": 7}]))
      assert at(root, "$[0].id") == {:ok, 7}
    end

    test "refuse every other path syntax" do
      for path <- [
            "rows[*].id",
            "..id",
            "rows[-1]",
            "rows[0]['name']",
            "$..id",
            "rows[?(@.id)]",
            "a..b",
            "a.",
            ".a",
            "$.",
            "a b",
            "a[0]b",
            "$[0]x",
            "a:b"
          ] do
        assert {path, JsonPath.parse(path)} == {path, :error}
      end
    end
  end

  describe "chain/1" do
    test "reads a path then :has, :not and :contains filters" do
      assert JsonPath.chain("data") == {:ok, %{path: [{:key, "data"}], filters: []}}

      assert JsonPath.chain("data:has(id):not(attributes.hidden):contains(\"x\")") ==
               {:ok,
                %{
                  path: [{:key, "data"}],
                  filters: [
                    {:has, [{:key, "id"}]},
                    {:not, [{:key, "attributes"}, {:key, "hidden"}]},
                    {:contains, ~S("x")}
                  ]
                }}
    end

    test "reads a key that holds a filter as a chain of its own" do
      assert JsonPath.chain("$:not(tags:contains(nuked))") ==
               {:ok,
                %{
                  path: [],
                  filters: [
                    {:not, %{path: [{:key, "tags"}], filters: [{:contains, "nuked"}]}}
                  ]
                }}
    end

    test "refuses any other pseudo-class, a bad path or key, and text the pattern leaves" do
      for selector <- [
            "data:first",
            "data:eq(1)",
            "data[*]:has(id)",
            "data:has(a[*])",
            "data:has(id)x",
            "data:has()",
            "data:not(a:eq(1))"
          ] do
        assert {selector, JsonPath.chain(selector)} == {selector, :error}
      end
    end
  end

  describe "rows/2 and field/2" do
    setup do
      {:ok, root} =
        JsonPath.decode(~S({"data": [
          {"id": 1, "tags": ["a"], "attributes": {"hidden": true}},
          {"id": 2, "tags": ["nuked"]},
          {"name": "no id", "tags": []}
        ], "scalar": [1, 2], "object": {"id": 1}}))

      %{list: root}
    end

    defp ids(root, selector) do
      {:ok, chain} = JsonPath.chain(selector)

      case JsonPath.rows(root, chain) do
        {:ok, rows} -> Enum.map(rows, &Enum.into(&1.values, %{})["id"])
        :error -> :error
      end
    end

    test "keep the objects that pass every filter", %{list: root} do
      assert ids(root, "data") == [1, 2, nil]
      assert ids(root, "data:has(id)") == [1, 2]
      assert ids(root, "data:not(id)") == [nil]
      assert ids(root, "data:has(attributes.hidden)") == [1]
      assert ids(root, "data:not(attributes.hidden)") == [2, nil]
      assert ids(root, "data:not(tags:contains(nuked))") == [1, nil]
      assert ids(root, "data:has(tags:contains(nuked))") == [2]
      assert ids(root, ~S[data:contains("nuked")]) == [2]
      assert ids(root, ~S[data:contains("id": 1)]) == [1]
      assert ids(root, "data:has(id):not(attributes)") == [2]
    end

    test "fail on a path that selects nothing, no array, or an array of other values", %{
      list: root
    } do
      assert ids(root, "missing") == :error
      assert ids(root, "object") == :error
      assert ids(root, "scalar") == :error
    end

    test "field/2 answers the path when the value passes its filters", %{list: root} do
      {:ok, chain} = JsonPath.chain("data[0]:has(id)")
      assert JsonPath.field(root, chain) == {:ok, [{:key, "data"}, {:index, 0}]}
      {:ok, chain} = JsonPath.chain("data:has(id)")
      assert JsonPath.field(root, chain) == :none
      {:ok, chain} = JsonPath.chain("object:has(name)")
      assert JsonPath.field(root, chain) == :none
      {:ok, chain} = JsonPath.chain("missing")
      assert JsonPath.field(root, chain) == :none
    end
  end
end
