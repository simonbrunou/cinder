defmodule Cinder.UtilTest do
  use ExUnit.Case, async: true

  alias Cinder.Util

  describe "blank_to_nil/1" do
    test "nilifies nil, empty, and whitespace-only strings" do
      assert Util.blank_to_nil(nil) == nil
      assert Util.blank_to_nil("") == nil
      assert Util.blank_to_nil("   ") == nil
    end

    test "passes a non-blank string through untrimmed" do
      assert Util.blank_to_nil("  hello  ") == "  hello  "
    end

    test "passes non-string values through unchanged" do
      assert Util.blank_to_nil(true) == true
      assert Util.blank_to_nil(42) == 42
    end
  end

  describe "trim_to_nil/1" do
    test "trims a string and nilifies a blank result" do
      assert Util.trim_to_nil("  hello  ") == "hello"
      assert Util.trim_to_nil("") == nil
      assert Util.trim_to_nil("   ") == nil
    end

    test "non-string values are nil" do
      assert Util.trim_to_nil(nil) == nil
      assert Util.trim_to_nil(42) == nil
    end
  end

  describe "present?/1" do
    test "true only for non-blank strings" do
      assert Util.present?("hello")
      refute Util.present?("   ")
      refute Util.present?("")
      refute Util.present?(nil)
      refute Util.present?(42)
    end
  end

  describe "positive_integer/1" do
    test "passes positive integers through, everything else is nil" do
      assert Util.positive_integer(7) == 7
      assert Util.positive_integer(0) == nil
      assert Util.positive_integer(-3) == nil
      assert Util.positive_integer("7") == nil
      assert Util.positive_integer(nil) == nil
    end
  end

  describe "tap_ok/2" do
    test "runs the fun on an ok value and returns the result unchanged" do
      parent = self()
      assert Util.tap_ok({:ok, 1}, &send(parent, {:tapped, &1})) == {:ok, 1}
      assert_received {:tapped, 1}
    end

    test "passes other terms through without calling the fun" do
      parent = self()
      assert Util.tap_ok({:error, :nope}, &send(parent, {:tapped, &1})) == {:error, :nope}
      refute_received {:tapped, _value}
    end
  end
end
