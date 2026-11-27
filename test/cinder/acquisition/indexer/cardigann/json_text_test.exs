defmodule Cinder.Acquisition.Indexer.Cardigann.JsonTextTest do
  # Every expected text here is the output of Newtonsoft.Json 13.0.4 on the .NET SDK 8.0.427 the
  # flake pins, invariant culture and TZ=UTC, run on the same JSON for #1678's PR:
  # `JToken.Parse(json)`, then `ToString()` for a text and `Value<string>()` for a value.
  use ExUnit.Case, async: true

  alias Cinder.Acquisition.Indexer.Cardigann.JsonPath
  alias Cinder.Acquisition.Indexer.Cardigann.JsonText

  defp decoded(json) do
    {:ok, value} = JsonPath.decode(json)
    value
  end

  defp text(json), do: json |> decoded() |> JsonText.text()
  defp value(json), do: json |> decoded() |> JsonText.string_value()

  describe "scalars" do
    test "booleans, null and integers read as Newtonsoft prints them" do
      assert text("true") == "True"
      assert text("false") == "False"
      assert text("null") == ""
      assert value("null") == nil
      assert text("42") == "42"
      assert text("-7") == "-7"
    end

    test "an integer outside the signed 64-bit range prints, but Value<string>() refuses it" do
      assert text("12345678901234567890") == "12345678901234567890"
      assert value("12345678901234567890") == :error
      assert value("9223372036854775807") == "9223372036854775807"
      assert value("-9223372036854775808") == "-9223372036854775808"
      assert value("-9223372036854775809") == :error
    end

    test "a fraction reads in fixed notation for a decimal exponent above -5 and below 17" do
      for {json, expected} <- [
            {"1.5", "1.5"},
            {"1.0", "1"},
            {"100.0", "100"},
            {"0.1", "0.1"},
            {"-0.0", "-0"},
            {"1e15", "1000000000000000"},
            {"1e14", "100000000000000"},
            {"123456789012345.6", "123456789012345.6"},
            {"3.14159265358979", "3.14159265358979"},
            {"0.0001", "0.0001"},
            {"0.001", "0.001"},
            {"0.00012345", "0.00012345"},
            {"1e16", "10000000000000000"},
            {"9e15", "9000000000000000"},
            {"1.5e16", "15000000000000000"},
            {"1.2345678901234567e16", "12345678901234568"},
            {"123456789.123", "123456789.123"},
            {"2.0e0", "2"},
            {"1E2", "100"},
            {"0.5", "0.5"},
            {"1.0000000000000001", "1"}
          ] do
        assert {json, text(json)} == {json, expected}
      end
    end

    test "a fraction outside that range reads in scientific notation" do
      for {json, expected} <- [
            {"0.00001", "1E-05"},
            {"1.1e-5", "1.1E-05"},
            {"1.5e-7", "1.5E-07"},
            {"2.5e20", "2.5E+20"},
            {"1e17", "1E+17"},
            {"12345678901234567e1", "1.2345678901234566E+17"},
            {"1e20", "1E+20"},
            {"100000000000000000000.0", "1E+20"},
            {"1e21", "1E+21"},
            {"1e22", "1E+22"},
            {"1.7976931348623157e308", "1.7976931348623157E+308"},
            {"5e-324", "5E-324"}
          ] do
        assert {json, text(json)} == {json, expected}
      end
    end

    test "a string reads as written" do
      assert text(~S("hé \"q\"")) == ~S(hé "q")
      assert value(~S("x")) == "x"
    end
  end

  describe "dates" do
    test "an ISO 8601 date and time reads MM/dd/yyyy HH:mm:ss, in UTC when it has a zone" do
      for {date, expected} <- [
            {"2021-10-18T00:34:50.000000Z", "10/18/2021 00:34:50"},
            {"2026-02-20T18:17:51.514900+00:00", "02/20/2026 18:17:51"},
            {"2026-02-20T18:17:51+02:00", "02/20/2026 16:17:51"},
            {"2026-02-20T18:17:51+0200", "02/20/2026 16:17:51"},
            {"2026-02-20T18:17:51+02", "02/20/2026 16:17:51"},
            {"2026-02-20T18:17:51-05:30", "02/20/2026 23:47:51"},
            {"2026-02-20T18:17:51+14:00", "02/20/2026 04:17:51"},
            {"2026-02-20T18:17:51", "02/20/2026 18:17:51"},
            {"2026-02-20T18:17:51.1234567Z", "02/20/2026 18:17:51"},
            {"2026-02-20T18:17:51.5Z", "02/20/2026 18:17:51"},
            {"2026-02-20T18:17:51z", "02/20/2026 18:17:51"},
            {"2026-02-20T24:00:00Z", "02/21/2026 00:00:00"},
            {"0001-01-01T00:00:00Z", "01/01/0001 00:00:00"}
          ] do
        assert {date, JsonText.text(date)} == {date, expected}
      end
    end

    test "a /Date(ms)/ string reads in UTC, an offset after the milliseconds ignored" do
      assert JsonText.text("/Date(1700000000000)/") == "11/14/2023 22:13:20"
      assert JsonText.text("/Date(1700000000000+0200)/") == "11/14/2023 22:13:20"
      assert JsonText.text("/Date(-1000)/") == "12/31/1969 23:59:59"
    end

    test "any other string reads as written" do
      for kept <- [
            "2026-02-20 18:17:51",
            "2026-02-20",
            "2026-02-20T18:17Z",
            "2026-02-20T18:17:51.12345678Z",
            "2026-02-20t18:17:51Z",
            "2026-13-20T18:17:51Z",
            "2026-02-30T18:17:51Z",
            " 2026-02-20T18:17:51Z",
            "2026-02-20T18:17:51.Z",
            "99999-02-20T18:17:51Z",
            "2026-02-20T18:17:60Z"
          ] do
        assert JsonText.text(kept) == kept
      end
    end
  end

  describe "objects and arrays" do
    test "Value<string>() refuses them" do
      assert value(~S({"a": 1})) == :error
      assert value("[1, 2]") == :error
    end

    test "they read as indented JSON, two spaces a level" do
      assert text(~S({"a": 1})) == ~s({\n  "a": 1\n})
      assert text("[1, 2]") == ~s([\n  1,\n  2\n])

      assert text(~S({"a": "x\ny", "b": [1, {"c": null}], "e": {}, "ea": [], "u": "é<>&'"})) ==
               ~s({\n  "a": "x\\ny",\n  "b": [\n    1,\n    {\n      "c": null\n    }\n  ],\n) <>
                 ~s(  "e": {},\n  "ea": [],\n  "u": "é<>&'"\n})
    end

    test "a whole fraction inside them keeps a point" do
      assert text(~S({"f": 1e15, "g": 1e-5, "h": 1.5, "t": true})) ==
               ~s({\n  "f": 1000000000000000.0,\n  "g": 1E-05,\n  "h": 1.5,\n  "t": true\n})
    end

    test "a key written twice keeps its first place and its last value" do
      assert text(~S({"a": 1, "b": 2, "a": 3})) == ~s({\n  "a": 3,\n  "b": 2\n})
    end
  end

  describe "items/1" do
    test "an array gives each item's text, nested values indented" do
      assert JsonText.items(decoded(~S([1, 2.5, true, null, "x", {"k": "v"}, [3, 4]]))) ==
               ["1", "2.5", "True", "", "x", ~s({\n  "k": "v"\n}), ~s([\n  3,\n  4\n])]
    end

    test "an object gives each property as \"key\": value, a scalar gives none" do
      assert JsonText.items(decoded(~S({"a": 1, "b": {"c": 2}}))) ==
               [~s("a": 1), ~s("b": {\n  "c": 2\n})]

      assert JsonText.items("x") == []
      assert JsonText.items(nil) == []
    end
  end

  describe "join/3" do
    @leaves [
      nil,
      true,
      false,
      0,
      -12,
      12_345_678_901_234_567_890,
      1.0,
      1.5e-7,
      "",
      "a\"b\\\n\u0001é",
      "2021-01-01T00:00:00Z",
      "/Date(0)/"
    ]

    # A value `depth` containers deep, each holding `width` children: arrays, objects, or the two
    # in turn by level. The leaves cycle through @leaves.
    defp nested(0, _width, _kind, seed), do: Enum.at(@leaves, rem(seed, length(@leaves)))

    defp nested(depth, width, kind, seed) do
      children = for i <- 1..width//1, do: nested(depth - 1, width, kind, seed * 3 + i)

      if kind == :array or (kind == :mixed and rem(depth, 2) == 0),
        do: children,
        else: %Jason.OrderedObject{values: Enum.with_index(children, &{"k#{&2}\t", &1})}
    end

    # The size `join/3` counts mirrors the text `items/1` builds: each value below joins at its
    # text's exact size and refuses one byte less.
    test "counts the joined text's size exactly, for every shape of value" do
      empty = %Jason.OrderedObject{values: []}

      values =
        @leaves ++
          [[empty], [[]], %Jason.OrderedObject{values: [{"k", empty}, {"l", []}]}, [[empty, []]]] ++
          for depth <- [1, 2, 3, 6],
              width <- [0, 1, 2, 3],
              kind <- [:array, :object, :mixed],
              seed <- [0, 5],
              do: nested(depth, width, kind, seed)

      for value <- values, separator <- ["", ",", ", "] do
        text = value |> JsonText.items() |> Enum.join(separator)
        size = byte_size(text)
        assert JsonText.join(value, separator, size) == {:ok, text}, inspect({value, separator})

        if size > 0,
          do: assert(JsonText.join(value, separator, size - 1) == :too_large, inspect(value))
      end
    end

    # The value's indented text is about 127 MB: a million items 62 arrays deep. Counting it
    # takes no heap past the value's own, where building it is killed at this cap.
    test "refuses a text past the budget without building it" do
      parent = self()

      pid =
        start_supervised!(
          {Task,
           fn ->
             Process.flag(:max_heap_size, %{size: 12_000_000, kill: true, error_logger: false})
             value = Enum.reduce(1..61, List.duplicate(0, 1_000_000), fn _level, acc -> [acc] end)
             send(parent, {:joined, JsonText.join([value], ",", 65_536)})
           end},
          id: make_ref()
        )

      ref = Process.monitor(pid)
      assert_receive {:joined, :too_large}, 10_000
      assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 10_000
      assert reason in [:normal, :noproc]
    end
  end
end
