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
end
